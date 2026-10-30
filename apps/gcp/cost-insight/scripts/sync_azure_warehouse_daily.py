"""Fail-closed, single-subscription Azure warehouse refresh using released helpers."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
import uuid
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path

from google.cloud import bigquery
from sqlalchemy import text

from cost_insight.common.bigquery import build_billing_bigquery_client
from cost_insight.common.config import get_settings
from cost_insight.common.db import build_engine
from cost_insight.jobs import state_store
from cost_insight.jobs.cost_sources import get_cost_source
from cost_insight.jobs.refresh_attribution_daily import _validate_tcms_allocation_table
from cost_insight.jobs.sync_azure_billing_summary import _normalize_summary_row
from cost_insight.jobs.sync_gcp_billing_summary import replace_summary_partition_usage_dates
from cost_insight.sources.azure_billing_export import build_azure_billing_summary_query

ACCOUNT = "aaa5414d-7537-4e24-99bd-a7a841221810"
TABLE = "warehouse-f80fbbe8e8.raw_azure_billing.azure_billing_cost_*"
JOB_NAME = "sync_azure_warehouse_daily"
SUMMARY = "cost_bq_export_summary_daily"
METRICS = ("list_cost", "effective_cost", "credit_amount", "net_cost")
MAX_BYTES = 2 * 1024**3
TOLERANCE = Decimal("0.00001")


def emit(event, **fields):
    print(json.dumps({"event": event, **fields}, default=str, sort_keys=True), flush=True)


def dates(start, end):
    while start <= end:
        yield start
        start += timedelta(days=1)


def as_date(value):
    if isinstance(value, datetime):
        raise RuntimeError("Expected a usage date, not a timestamp")
    return value if isinstance(value, date) else date.fromisoformat(str(value))


def amount(value):
    try:
        result = Decimal(str(value))
    except (InvalidOperation, ValueError, TypeError) as exc:
        raise RuntimeError(f"Null/invalid monetary value: {value!r}") from exc
    if not result.is_finite():
        raise RuntimeError("Non-finite monetary value")
    return result


def totals(rows):
    return {m: sum((amount(r.get(m)) for r in rows), Decimal(0)) for m in METRICS}


def assert_money(expected, actual, label):
    for metric in METRICS:
        if abs(amount(expected.get(metric)) - amount(actual.get(metric))) > TOLERANCE:
            raise RuntimeError(f"{label}: {metric}: {expected.get(metric)} != {actual.get(metric)}")


def normalize_rows(rows):
    # Validate before the Azure helper, which supplies vendor/direct scope and defaults credit to zero.
    normalized = []
    for row in rows:
        if ((row.get("vendor"), row.get("account_id"), row.get("currency")) != ("azure", ACCOUNT, "USD")
                or row.get("source_schema_version")
                or row.get("source_allocation_scope", "direct") != "direct"):
            raise RuntimeError("Unexpected source identity/currency/profile")
        totals([row])
        normalized.append(_normalize_summary_row(row))
    return merge_rows(normalized)


def merge_rows(rows):
    """Canonical tag collisions must be merged across the complete result, not each page."""
    merged = {}
    for row in rows:
        row = {**row, **{m: amount(row.get(m)) for m in METRICS}}
        key = row["source_row_hash"]
        if key not in merged:
            merged[key] = row
            continue
        previous = merged[key]
        for metric in METRICS:
            previous[metric] += row[metric]
        times = [t for t in (previous.get("source_export_time"), row.get("source_export_time")) if t]
        previous["source_export_time"] = max(times) if times else None
    return list(merged.values())


def monthly_tables(start, end):
    """Identifiers come only from trusted dates; EA tables never enter schema resolution."""
    if type(start) is not date or type(end) is not date or start > end:
        raise ValueError("Invalid monthly table date bounds")
    return {day.replace(day=1): TABLE[:-1] + day.replace(day=1).strftime("%Y%m%d")
            for day in dates(start, end)}


def monthly_relation(start, end):
    return "(\n" + "\nUNION ALL\n".join(
        f"SELECT raw.*, '{month:%Y%m%d}' AS _TABLE_SUFFIX FROM `{table}` raw "
        "WHERE CAST(date AS DATE) BETWEEN @earliest_usage_date AND @usage_end_date"
        for month, table in monthly_tables(start, end).items()) + "\n)"


def parameters(start, end, sql):
    return [bigquery.ScalarQueryParameter(n, t, v) for n, t, v in (
        ("account_id", "STRING", ACCOUNT),
        ("export_partition_start", "DATE", start.replace(day=1)),
        ("export_partition_end", "DATE", end.replace(day=1)),
        ("earliest_usage_date", "DATE", start),
        ("usage_end_date", "DATE", end),
    ) if f"@{n}" in sql]


def summary_query(start, end):
    sql = build_azure_billing_summary_query(billing_table=TABLE)
    needle = f"FROM `{TABLE}`"
    if sql.count(needle) != 1:
        raise RuntimeError("Released Azure query-builder FROM contract changed")
    return sql.replace(needle, "FROM " + monthly_relation(start, end), 1)


def control_query(start, end):
    return f"""
SELECT SAFE.PARSE_DATE('%Y%m%d', _TABLE_SUFFIX) AS export_partition_date,
       CAST(date AS DATE) AS usage_date, COUNT(*) AS n,
       COUNTIF(billingCurrency IS NULL OR billingCurrency != 'USD') AS non_usd,
       COUNTIF(SAFE_CAST(paygCostInBillingCurrency AS NUMERIC) IS NULL
            OR SAFE_CAST(costInBillingCurrency AS NUMERIC) IS NULL) AS invalid_money,
       SUM(SAFE_CAST(paygCostInBillingCurrency AS NUMERIC)) AS list_cost,
       SUM(SAFE_CAST(costInBillingCurrency AS NUMERIC)) AS effective_cost,
       CAST(0 AS NUMERIC) AS credit_amount,
       SUM(SAFE_CAST(costInBillingCurrency AS NUMERIC)) AS net_cost
FROM {monthly_relation(start, end)}
WHERE CAST(SubscriptionId AS STRING) = @account_id
GROUP BY export_partition_date, usage_date
""".strip()


def query_rows(client, sql, params, label, heartbeat):
    """Dry-run every query and keep the execution budget immutable, with no retries."""
    heartbeat()
    options = dict(query_parameters=params, maximum_bytes_billed=MAX_BYTES, use_query_cache=False)
    preview = client.query(sql, job_config=bigquery.QueryJobConfig(dry_run=True, **options),
                           timeout=30, retry=None, job_retry=None)
    estimate = preview.total_bytes_processed
    emit("query_preflight", query=label, estimated_bytes=estimate, maximum_bytes_billed=MAX_BYTES)
    if type(estimate) is not int or not 0 <= estimate <= MAX_BYTES:
        raise RuntimeError(f"Query {label} has unknown/over-budget estimate: {estimate}")
    job = client.query(sql, job_config=bigquery.QueryJobConfig(**options),
                       timeout=30, retry=None, job_retry=None)
    started = time.monotonic()
    try:
        rows = []
        for row in job.result(page_size=1000, timeout=900, retry=None, job_retry=None):
            if time.monotonic() - started > 900:
                raise TimeoutError(f"Result collection exceeded 900 seconds: {label}")
            heartbeat()
            rows.append(dict(row.items()))
    except BaseException:
        job.cancel(timeout=30, retry=None)
        raise
    heartbeat()
    if type(job.total_bytes_processed) is not int or not 0 <= job.total_bytes_processed <= MAX_BYTES:
        raise RuntimeError(f"Unknown/over-budget actual bytes for {label}")
    emit("query_fetched", query=label, rows=len(rows), bytes_processed=job.total_bytes_processed,
         job_id=job.job_id)
    return rows


def snapshot(client, tables):
    result = {}
    for table_id in tables:
        table = client.get_table(table_id, timeout=30, retry=None)
        if (table.table_type != "TABLE" or table.expires is not None
                or (table.time_partitioning and table.time_partitioning.expiration_ms)):
            raise RuntimeError("Azure source must be permanent, non-expiring physical tables")
        if table.modified is None or table.num_rows is None or table.num_rows < 0 or not table.etag:
            raise RuntimeError("Azure source has an incomplete modification watermark")
        result[table_id] = (table.modified.isoformat(), table.num_rows, table.etag)
    return result


def assert_snapshot(client, original):
    if snapshot(client, original) != original:
        raise RuntimeError("Source snapshot changed; refusing torn reads or further writes")


def validate_registry(connection, start=None):
    source = get_cost_source(connection, vendor="azure", account_id=ACCOUNT)
    if (source is None or not source.is_active or source.source_schema_version not in (None, "")
            or source.source_table not in (None, "", TABLE)):
        raise RuntimeError("Refusing inactive/custom/nondefault Azure source")
    if start and source.source_available_from is not None and source.source_available_from > start:
        raise RuntimeError("Usage window predates Azure source availability")


def validate_rows(rows, controls, start, end):
    partitions = monthly_tables(start, end)
    grouped = defaultdict(list)
    for row in rows:
        if (row["vendor"], row["account_id"], row["currency"]) != ("azure", ACCOUNT, "USD"):
            raise RuntimeError("Unexpected source identity/currency")
        if (not start <= row["usage_date"] <= end or row["export_partition_date"] not in partitions
                or row.get("source_schema_version") or row.get("source_allocation_scope") != "direct"):
            raise RuntimeError("Source row outside default partition/day scope")
        totals([row])
        grouped[row["export_partition_date"], row["usage_date"]].append(row)
    expected = {}
    for control in controls:
        key = (as_date(control["export_partition_date"]), as_date(control["usage_date"]))
        if (key in expected or key[0] not in partitions or not start <= key[1] <= end
                or int(control["n"]) <= 0 or int(control["non_usd"]) != 0
                or int(control["invalid_money"]) != 0):
            raise RuntimeError("Invalid raw control, currency or monetary value")
        totals([control])
        expected[key] = control
    if set(grouped) != set(expected):
        raise RuntimeError("Raw/normalized partition/day coverage differs")
    for key, daily in grouped.items():
        assert_money(expected[key], totals(daily), f"raw -> normalized {key}")
    for day in dates(start, end):
        if not any(key[1] == day for key in grouped):
            raise RuntimeError(f"Empty source day is NOT an authoritative zero: {day}")
    return dict(grouped)


def table_totals(connection, table, day, *, partition=None, outside=None, version=None):
    if table not in (SUMMARY, "cost_attribution_daily", "cost_resource_serving_daily"):
        raise ValueError(table)
    clause = ""
    params = {"account": ACCOUNT, "day": day}
    if partition is not None:
        clause += " AND export_partition_date=:partition"
        params["partition"] = partition
    if outside is not None:
        clause += " AND (export_partition_date < :start OR export_partition_date > :end OR export_partition_date IS NULL)"
        params.update(start=outside[0], end=outside[1])
    if version is not None:
        clause += " AND basis_key='native' AND materialization_version=:version"
        params["version"] = version
    sums = ",".join(f"COALESCE(SUM({m}),0) AS {m}" for m in METRICS)
    nulls = " OR ".join(f"{m} IS NULL" for m in METRICS)
    rows = connection.execute(text(f"""SELECT currency,COUNT(*) AS n,{sums},
        SUM(CASE WHEN {nulls} THEN 1 ELSE 0 END) AS invalid_money FROM {table}
        WHERE vendor='azure' AND account_id=:account AND usage_date=:day {clause}
        GROUP BY currency"""), params).mappings().all()
    if not rows:
        return {"currency": "USD", "n": 0, **totals([])}
    if len(rows) != 1 or rows[0]["currency"] != "USD" or rows[0]["invalid_money"]:
        raise RuntimeError("Missing/mixed currency or null money in " + table)
    totals(rows)
    return dict(rows[0])


def local_preflight(connection, plan):
    start, end = plan["start"], plan["end"]
    validate_registry(connection, start)
    latest = connection.execute(text(f"""SELECT MAX(usage_date) FROM {SUMMARY}
        WHERE vendor='azure' AND account_id=:account AND usage_date <= :end"""),
        {"account": ACCOUNT, "end": end}).scalar_one()
    # A bounded watermark guard, not a historical continuity audit.
    if latest is None or as_date(latest) < start - timedelta(days=1):
        raise RuntimeError("Local backlog exceeds the five-day window")
    bounds = (start.replace(day=1), end.replace(day=1))
    plan["local"], plan["protected"] = {}, {}
    for day in dates(start, end):
        plan["protected"][day] = table_totals(connection, SUMMARY, day, outside=bounds)
        for partition in monthly_tables(start, end):
            key = (partition, day)
            current = table_totals(connection, SUMMARY, day, partition=partition)
            if current["n"] and not plan["groups"].get(key):
                raise RuntimeError(f"Empty queried partition/day has local facts: {key}")
            plan["local"][key] = current
    emit("local_preflight", start=start, end=end,
         queried_counts={f"{p}/{d}": v["n"] for (p, d), v in plan["local"].items()},
         protected_counts={str(d): v["n"] for d, v in plan["protected"].items()})


def prepare(client, engine, today, heartbeat, progress=None):
    with engine.connect() as connection:
        validate_registry(connection)
    yesterday = today - timedelta(days=1)
    discovery_start = yesterday - timedelta(days=13)
    original = snapshot(client, monthly_tables(discovery_start, yesterday).values())
    emit("source_snapshot", tables=original)

    def read(sql, start, end, label):
        assert_snapshot(client, original)
        rows = query_rows(client, sql, parameters(start, end, sql), label, heartbeat)
        assert_snapshot(client, original)
        return rows

    discovery = read(control_query(discovery_start, yesterday), discovery_start, yesterday, "discover")
    if not discovery:
        raise RuntimeError("No available usage date in bounded 14-day discovery")
    end = max(as_date(r["usage_date"]) for r in discovery)
    if not discovery_start <= end <= yesterday:
        raise RuntimeError("Discovery day outside bounded source window")
    if (today - end).days > 7:
        raise RuntimeError("Azure source is stale or has no recent usage")
    start = end - timedelta(days=4)
    if progress is not None:
        # Preserve the resolved window even if collection/validation subsequently fails.
        progress["window"] = {"start": str(start), "end": str(end)}
    heartbeat()
    controls = read(control_query(start, end), start, end, "control")
    raw = read(summary_query(start, end), start, end, "summary")
    rows = normalize_rows(raw)
    plan = dict(start=start, end=end, groups=validate_rows(rows, controls, start, end))
    with engine.connect() as connection:
        local_preflight(connection, plan)
    emit("window_validated", account_id=ACCOUNT, start=start, end=end, rows=len(rows),
         controls=controls, provisional_latest_day=end)
    heartbeat()
    return plan, original


def verify_queried(connection, plan, day):
    for partition in monthly_tables(plan["start"], plan["end"]):
        expected = plan["groups"].get((partition, day), [])
        actual = table_totals(connection, SUMMARY, day, partition=partition)
        if actual["n"] != len(expected):
            raise RuntimeError("Queried summary identity count differs from canonical source")
        assert_money(totals(expected), actual, "source -> queried summary")
    protected = table_totals(connection, SUMMARY, day,
                             outside=(plan["start"].replace(day=1), plan["end"].replace(day=1)))
    if protected["n"] != plan["protected"][day]["n"]:
        raise RuntimeError("Unqueried billing partition count changed")
    assert_money(plan["protected"][day], protected, "unqueried billing partitions")


def verify_publication(connection, day):
    summary = table_totals(connection, SUMMARY, day)
    attribution = table_totals(connection, "cost_attribution_daily", day)
    if not summary["n"] or not attribution["n"]:
        raise RuntimeError("Missing summary or attribution publication input")
    assert_money(summary, attribution, "all summary -> attribution")
    pointer = connection.execute(text("""SELECT * FROM cost_resource_serving_publication
        WHERE basis_key='native' AND vendor='azure' AND account_id=:account AND usage_date=:day"""),
        {"account": ACCOUNT, "day": day}).mappings().one()
    if pointer["currency"] != "USD" or not pointer["active_materialization_version"]:
        raise RuntimeError("Missing native publication version/currency")
    serving = table_totals(connection, "cost_resource_serving_daily", day,
                           version=pointer["active_materialization_version"])
    if not serving["n"]:
        raise RuntimeError("Active native serving version is empty")
    assert_money(attribution, serving, "attribution -> active native serving")
    if abs(amount(pointer["total_list_cost"]) - amount(summary["list_cost"])) > TOLERANCE:
        raise RuntimeError("Native publication pointer list total differs")
    emit("day_verified", account_id=ACCOUNT, usage_date=day,
         summary=summary, attribution=attribution, serving=serving)


def refresh_day(day):
    command = ["cost-insight", "refresh-cost-attribution-from-summary", "--vendor", "azure",
               "--account-id", ACCOUNT, "--start-date", day.isoformat(), "--end-date", day.isoformat(),
               "--split-by-day"]
    result = subprocess.run(command, check=True, text=True, stdout=subprocess.PIPE, timeout=900)
    emit("attribution_refresh", account_id=ACCOUNT, usage_date=day, result=json.loads(result.stdout))


def replace_day(engine, plan, day, before_write):
    # Refuse a conflicting writer after preflight, including protected partitions.
    with engine.connect() as connection:
        protected = table_totals(connection, SUMMARY, day,
                                 outside=(plan["start"].replace(day=1), plan["end"].replace(day=1)))
        if protected["n"] != plan["protected"][day]["n"]:
            raise RuntimeError("Unqueried billing partition count changed before write")
        assert_money(plan["protected"][day], protected, "protected preflight -> write")
        for (partition, usage), previous in plan["local"].items():
            if usage == day:
                current = table_totals(connection, SUMMARY, day, partition=partition)
                if current["n"] != previous["n"]:
                    raise RuntimeError("Local summary changed after preflight")
                assert_money(previous, current, "local preflight -> write")
    for (partition, usage), rows in sorted(plan["groups"].items()):
        if usage != day:
            continue
        before_write()
        written = replace_summary_partition_usage_dates(
            engine, rows, vendor="azure", account_id=ACCOUNT, export_partition_date=partition,
            usage_start_date=day, usage_end_date=day, dry_run=False, batch_size=500)
        emit("summary_scope_replaced", account_id=ACCOUNT, usage_date=day, billing_partition=partition,
             rows_deleted=plan["local"][partition, day]["n"], rows_inserted=written)
    with engine.connect() as connection:
        verify_queried(connection, plan, day)
    refresh_day(day)
    with engine.connect() as connection:
        verify_queried(connection, plan, day)
        verify_publication(connection, day)


def acquire(engine, progress):
    # Inserting first serializes first-use and existing-row acquisition alike.
    with engine.begin() as connection:
        sqlite = connection.dialect.name == "sqlite"
        insert = "INSERT OR IGNORE" if sqlite else "INSERT IGNORE"
        connection.execute(text(f"""{insert} INTO cost_job_state
            (job_name, watermark_json, last_status) VALUES (:name, '{{}}', 'ready')"""), {"name": JOB_NAME})
        status = connection.execute(text("SELECT last_status FROM cost_job_state WHERE job_name=:name" +
                                        ("" if sqlite else " FOR UPDATE")), {"name": JOB_NAME}).scalar_one()
        if status not in ("ready", "succeeded"):
            raise RuntimeError(f"Previous worker is {status}; inspect before explicit recovery")
        state_store.mark_job_started(connection, JOB_NAME, progress)


def checkpoint(engine, progress, status="running", error=None):
    progress["last_update"] = datetime.now(timezone.utc).isoformat()
    with engine.begin() as connection:
        previous = state_store.get_job_state(connection, JOB_NAME)
        if previous is None or previous.watermark.get("run_id") != progress["run_id"] or previous.last_status != "running":
            raise RuntimeError("Lost worker state ownership")
        if status == "succeeded":
            state_store.mark_job_succeeded(connection, JOB_NAME, progress)
        elif status == "failed":
            state_store.mark_job_failed(connection, JOB_NAME, progress, error)
        else:
            state_store.checkpoint_job_watermark(connection, JOB_NAME, progress)
    emit("progress", **progress, status=status)


def run(client, engine, *, dry_run=False, today=None):
    if not dry_run and not Path("/var/run/secrets/kubernetes.io/serviceaccount/token").is_file():
        raise RuntimeError("Write mode is permitted only inside the submitted GKE Job")
    progress = dict(run_id=str(uuid.uuid4()), pod_name=os.environ.get("POD_NAME"), account_id=ACCOUNT,
                    window=None, current_day=None, completed_days=[], percent=0, phase="preflight",
                    last_update=datetime.now(timezone.utc).isoformat())
    # Admission is outside the failure handler: a rejected run cannot overwrite another run's error.
    if not dry_run:
        acquire(engine, progress)
    last_heartbeat = 0.0

    def heartbeat():
        nonlocal last_heartbeat
        if not dry_run and time.monotonic() - last_heartbeat >= 60:
            checkpoint(engine, progress)
            last_heartbeat = time.monotonic()

    try:
        plan, original = prepare(client, engine, today or datetime.now(timezone.utc).date(), heartbeat, progress=progress)
        progress["window"] = {"start": str(plan["start"]), "end": str(plan["end"])}
        emit("plan", dry_run=dry_run, **progress)
        if dry_run:
            return progress
        progress["phase"] = "write"
        checkpoint(engine, progress)
        for day in dates(plan["start"], plan["end"]):
            progress["current_day"] = str(day)
            checkpoint(engine, progress)
            assert_snapshot(client, original)
            with engine.connect() as connection:
                validate_registry(connection, plan["start"])
            replace_day(engine, plan, day, lambda: assert_snapshot(client, original))
            progress["completed_days"].append(str(day))
            progress["percent"] = round(100 * len(progress["completed_days"]) / 5, 2)
            checkpoint(engine, progress)
        progress["phase"] = "complete"
        checkpoint(engine, progress, "succeeded")
        return progress
    except BaseException as exc:
        if not dry_run:
            checkpoint(engine, progress, "failed", repr(exc))
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Read and validate only; no job-state writes")
    args = parser.parse_args()
    settings = get_settings()
    if settings.tcms_allocation.allocation_table != "tcms_cost.resource_allocation":
        raise RuntimeError("Unexpected attribution-rule table")
    engine = build_engine(settings)
    try:
        _validate_tcms_allocation_table(engine, settings.tcms_allocation.allocation_table)
        run(build_billing_bigquery_client(), engine, dry_run=args.dry_run)
    finally:
        engine.dispose()


if __name__ == "__main__":
    main()
