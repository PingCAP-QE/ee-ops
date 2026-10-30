"""Fail-closed recurring ordinary AWS import using the released warehouse helpers."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
import uuid
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

from google.cloud import bigquery
from sqlalchemy import text

from cost_insight.common.bigquery import build_billing_bigquery_client
from cost_insight.common.config import get_settings
from cost_insight.common.db import build_engine
from cost_insight.jobs import state_store
from cost_insight.jobs.cost_sources import get_cost_source
from cost_insight.jobs.refresh_attribution_daily import _validate_tcms_allocation_table
from cost_insight.jobs.sync_gcp_billing_summary import (
    _normalize_summary_row,
    replace_summary_partition_usage_dates,
)
from cost_insight.sources.aws_billing_export import build_aws_billing_summary_query

ACCOUNTS = ("131464424160", "296171618728", "676546228356", "986330900858")
TABLE = "warehouse-f80fbbe8e8.raw_aws_billing.cur_line_items"
JOB_NAME = "sync_aws_warehouse_daily"
METRICS = ("list_cost", "effective_cost", "credit_amount", "net_cost")
SUMMARY = "cost_bq_export_summary_daily"
MAX_BYTES = 2 * 1024**3
TOLERANCE = Decimal("0.00001")


def emit(event, **fields):
    print(json.dumps({"event": event, **fields}, default=str, sort_keys=True), flush=True)


def dates(start, end):
    while start <= end:
        yield start
        start += timedelta(days=1)


def as_date(value):
    return value if isinstance(value, date) else date.fromisoformat(str(value))


def amount(value):
    result = Decimal(str(value or 0))
    if not result.is_finite():
        raise RuntimeError("Non-finite monetary value")
    return result


def totals(rows):
    return {m: sum((amount(r.get(m)) for r in rows), Decimal(0)) for m in METRICS}


def assert_money(expected, actual, label):
    for metric in METRICS:
        if abs(amount(expected.get(metric)) - amount(actual.get(metric))) > TOLERANCE:
            raise RuntimeError(f"{label}: {metric}: {expected.get(metric)} != {actual.get(metric)}")


def merge_rows(rows):
    """Merge the complete result, including canonical tag collisions across pages."""
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


def parameters(account, start, end):
    return [bigquery.ScalarQueryParameter(n, t, v) for n, t, v in (
        ("account_id", "STRING", account),
        ("export_partition_start", "DATE", start.replace(day=1)),
        ("export_partition_end", "DATE", end.replace(day=1)),
        ("earliest_usage_date", "DATE", start),
        ("usage_end_date", "DATE", end),
    )]


def query_rows(client, sql, params, label, heartbeat):
    """Every read has an independent dry-run and an immutable execution cap."""
    heartbeat()
    options = dict(query_parameters=params, maximum_bytes_billed=MAX_BYTES, use_query_cache=False)
    preview = client.query(sql, job_config=bigquery.QueryJobConfig(dry_run=True, **options),
                           timeout=30, retry=None, job_retry=None)
    estimate = preview.total_bytes_processed
    emit("query_preflight", query=label, estimated_bytes=estimate, maximum_bytes_billed=MAX_BYTES)
    if estimate is None or estimate < 0 or estimate > MAX_BYTES:
        raise RuntimeError(f"Query {label} has unknown/over-budget estimate: {estimate}")
    job = client.query(sql, job_config=bigquery.QueryJobConfig(**options),
                       timeout=30, retry=None, job_retry=None)
    # result() bounds query completion; the guard also bounds row collection.
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
    if job.total_bytes_processed is None or job.total_bytes_processed > MAX_BYTES:
        raise RuntimeError(f"Unknown/over-budget actual bytes for {label}")
    emit("query_fetched", query=label, rows=len(rows), bytes_processed=job.total_bytes_processed,
         job_id=job.job_id)
    return rows


CONTROL_SQL = f"""
SELECT DATE(bill_billing_period_start_date) AS export_partition_date,
       DATE(line_item_usage_start_date) AS usage_date,
       COUNT(*) AS n,
       COUNTIF(line_item_currency_code IS NULL OR line_item_currency_code != 'USD') AS non_usd,
       SUM(CASE WHEN line_item_line_item_type IN ('Usage', 'SavingsPlanCoveredUsage')
                THEN COALESCE(line_item_unblended_cost, 0) ELSE 0 END) AS list_cost
FROM `{TABLE}`
WHERE bill_billing_period_start_date >= TIMESTAMP(@export_partition_start)
  AND bill_billing_period_start_date < TIMESTAMP(DATE_ADD(@export_partition_end, INTERVAL 1 DAY))
  AND line_item_usage_account_id = @account_id
  AND DATE(line_item_usage_start_date) BETWEEN @earliest_usage_date AND @usage_end_date
GROUP BY export_partition_date, usage_date
""".strip()


def summary_query(end):
    sql = build_aws_billing_summary_query(billing_table=TABLE, usage_end_date=end, warehouse_raw=True)
    needle = "WHERE line_item_usage_account_id = @account_id"
    if sql.count(needle) != 1:
        raise RuntimeError("Released AWS query-builder contract changed")
    return sql.replace(needle, needle + " AND line_item_currency_code = 'USD'", 1)


def snapshot(client):
    table = client.get_table(TABLE, timeout=30, retry=None)
    if (table.table_type != "TABLE" or table.expires is not None
            or (table.time_partitioning and table.time_partitioning.expiration_ms)):
        raise RuntimeError("AWS source must be a permanent, non-expiring physical table")
    if table.modified is None:
        raise RuntimeError("AWS source has no modification watermark")
    return (table.modified.isoformat(), table.num_rows, table.etag)


def validate_registry(connection, starts=None):
    for account in ACCOUNTS:
        source = get_cost_source(connection, vendor="aws", account_id=account)
        if (source is None or not source.is_active
                or source.source_schema_version not in (None, "", "aws_cur_legacy_v1")
                or source.source_table not in (None, "", TABLE)):
            raise RuntimeError(f"Refusing inactive/custom/nonordinary AWS source: {account}")
        if (starts and account in starts and source.source_available_from is not None
                and source.source_available_from > starts[account]):
            raise RuntimeError(f"Usage window predates AWS source availability: {account}")


def validate_rows(rows, controls, account, start, end):
    grouped = defaultdict(list)
    for row in rows:
        if (row["vendor"], row["account_id"], row["currency"]) != ("aws", account, "USD"):
            raise RuntimeError("Unexpected source identity/currency")
        if (not start <= row["usage_date"] <= end
                or not start.replace(day=1) <= row["export_partition_date"] <= end.replace(day=1)
                or row["export_partition_date"].day != 1
                or row.get("source_schema_version")
                or row.get("source_allocation_scope") != "direct"):
            raise RuntimeError("Source row outside ordinary partition/day scope")
        grouped[row["export_partition_date"], row["usage_date"]].append(row)
    expected = {}
    for control in controls:
        key = (as_date(control["export_partition_date"]), as_date(control["usage_date"]))
        if (key in expected or not start <= key[1] <= end
                or not start.replace(day=1) <= key[0] <= end.replace(day=1)
                or key[0].day != 1 or int(control["n"]) <= 0 or int(control["non_usd"]) != 0):
            raise RuntimeError("Invalid raw daily control or non-USD source")
        expected[key] = control
    if set(grouped) != set(expected):
        raise RuntimeError("Raw/normalized partition/day coverage differs")
    for key, daily in grouped.items():
        if abs(totals(daily)["list_cost"] - amount(expected[key]["list_cost"])) > TOLERANCE:
            raise RuntimeError(f"Raw/normalized list-cost mismatch: {account}/{key}")
    for day in dates(start, end):
        if not any(key[1] == day for key in grouped):
            raise RuntimeError(f"Empty source day is NOT an authoritative zero: {account}/{day}")
    return dict(grouped)


def table_totals(connection, table, account, day, *, partition=None, outside=None, version=None):
    if table not in (SUMMARY, "cost_attribution_daily", "cost_resource_serving_daily"):
        raise ValueError(table)
    clause = ""
    params = {"account": account, "day": day}
    if partition is not None:
        clause += " AND export_partition_date=:partition"
        params["partition"] = partition
    if outside is not None:
        clause += " AND (export_partition_date < :start OR export_partition_date > :end)"
        params.update(start=outside[0], end=outside[1])
    if version is not None:
        clause += " AND basis_key='native' AND materialization_version=:version"
        params["version"] = version
    sums = ",".join(f"COALESCE(SUM({m}),0) AS {m}" for m in METRICS)
    rows = connection.execute(text(f"""SELECT currency,COUNT(*) AS n,{sums} FROM {table}
        WHERE vendor='aws' AND account_id=:account AND usage_date=:day {clause}
        GROUP BY currency"""), params).mappings().all()
    if not rows:
        return {"currency": "USD", "n": 0, **totals([])}
    if len(rows) != 1 or rows[0]["currency"] != "USD":
        raise RuntimeError("Missing or mixed-currency data in " + table)
    return dict(rows[0])


def local_preflight(connection, plan):
    account, start, end = plan["account"], plan["start"], plan["end"]
    validate_registry(connection, {account: start})
    latest = connection.execute(text(f"""SELECT MAX(usage_date) FROM {SUMMARY}
        WHERE vendor='aws' AND account_id=:account AND usage_date <= :end"""),
        {"account": account, "end": end}).scalar_one()
    # Historical empty days may mean no usage; only reject a watermark backlog
    # which this bounded window cannot catch up. This is not a continuity audit.
    if latest is None or as_date(latest) < start - timedelta(days=1):
        raise RuntimeError(f"Local backlog exceeds the five-day window: {account}")
    bounds = (start.replace(day=1), end.replace(day=1))
    partitions = sorted(set(bounds))
    plan["local"] = {}
    plan["protected"] = {}
    for day in dates(start, end):
        plan["protected"][day] = table_totals(connection, SUMMARY, account, day, outside=bounds)
        for partition in partitions:
            key = (partition, day)
            current = table_totals(connection, SUMMARY, account, day, partition=partition)
            if current["n"] and not plan["groups"].get(key):
                raise RuntimeError(f"Empty queried partition/day has local facts: {account}/{key}")
            plan["local"][key] = current
    emit("local_preflight", account_id=account, start=start, end=end,
         queried_counts={f"{p}/{d}": v["n"] for (p, d), v in plan["local"].items()},
         protected_counts={str(d): v["n"] for d, v in plan["protected"].items()})


def prepare(client, engine, today, heartbeat):
    original = snapshot(client)
    with engine.connect() as connection:
        validate_registry(connection)
    plans = []
    yesterday = today - timedelta(days=1)
    for account in ACCOUNTS:
        discovery = query_rows(client, CONTROL_SQL, parameters(account, yesterday - timedelta(days=13), yesterday),
                               account + "/discover", heartbeat)
        if not discovery:
            raise RuntimeError(f"No available usage date in bounded 14-day discovery: {account}")
        end = max(as_date(r["usage_date"]) for r in discovery)
        if not yesterday - timedelta(days=13) <= end <= yesterday:
            raise RuntimeError("Discovery day outside bounded source window")
        if (today - end).days > 7:
            raise RuntimeError(f"AWS source is stale or has no recent usage: {account}")
        start = end - timedelta(days=4)
        controls = query_rows(client, CONTROL_SQL, parameters(account, start, end), account + "/control", heartbeat)
        raw = query_rows(client, summary_query(end), parameters(account, start, end), account + "/summary", heartbeat)
        rows = merge_rows(_normalize_summary_row(r) for r in raw)
        groups = validate_rows(rows, controls, account, start, end)
        plan = dict(account=account, start=start, end=end, groups=groups)
        with engine.connect() as connection:
            local_preflight(connection, plan)
        plans.append(plan)
        emit("window_validated", account_id=account, start=start, end=end, rows=len(rows),
             controls=controls, provisional_latest_day=end)
        heartbeat()
    if snapshot(client) != original:
        raise RuntimeError("Source snapshot changed while reading all four account windows")
    return plans, original


def verify_queried(connection, plan, day):
    for partition in sorted(set((plan["start"].replace(day=1), plan["end"].replace(day=1)))):
        expected = plan["groups"].get((partition, day), [])
        actual = table_totals(connection, SUMMARY, plan["account"], day, partition=partition)
        if actual["n"] != len(expected):
            raise RuntimeError("Queried partition summary identity count differs from canonical source")
        assert_money(totals(expected), actual, "source -> queried summary")
    protected = table_totals(connection, SUMMARY, plan["account"], day,
                             outside=(plan["start"].replace(day=1), plan["end"].replace(day=1)))
    if protected["n"] != plan["protected"][day]["n"]:
        raise RuntimeError("Unqueried billing partition count changed")
    assert_money(plan["protected"][day], protected, "unqueried billing partitions")


def verify_publication(connection, account, day):
    summary = table_totals(connection, SUMMARY, account, day)
    attribution = table_totals(connection, "cost_attribution_daily", account, day)
    if not summary["n"] or not attribution["n"]:
        raise RuntimeError("Missing summary or attribution publication input")
    assert_money(summary, attribution, "all summary -> attribution")
    pointer = connection.execute(text("""SELECT * FROM cost_resource_serving_publication
        WHERE basis_key='native' AND vendor='aws' AND account_id=:account AND usage_date=:day"""),
        {"account": account, "day": day}).mappings().one()
    if pointer["currency"] != "USD" or not pointer["active_materialization_version"]:
        raise RuntimeError("Missing native publication version/currency")
    serving = table_totals(connection, "cost_resource_serving_daily", account, day,
                           version=pointer["active_materialization_version"])
    if not serving["n"]:
        raise RuntimeError("Active native serving version is empty")
    assert_money(attribution, serving, "attribution -> active native serving")
    if abs(amount(pointer["total_list_cost"]) - amount(summary["list_cost"])) > TOLERANCE:
        raise RuntimeError("Native publication pointer list total differs")
    emit("day_verified", account_id=account, usage_date=day,
         summary=summary, attribution=attribution, serving=serving)


def refresh_day(account, day):
    command = ["cost-insight", "refresh-cost-attribution-from-summary", "--vendor", "aws",
               "--account-id", account, "--start-date", day.isoformat(), "--end-date", day.isoformat(),
               "--split-by-day"]
    result = subprocess.run(command, check=True, text=True, stdout=subprocess.PIPE, timeout=900)
    emit("attribution_refresh", account_id=account, usage_date=day, result=json.loads(result.stdout))


def replace_day(engine, plan, day):
    account = plan["account"]
    # Refuse a conflicting writer after preflight, including protected partitions.
    with engine.connect() as connection:
        protected = table_totals(connection, SUMMARY, account, day,
                                 outside=(plan["start"].replace(day=1), plan["end"].replace(day=1)))
        if protected["n"] != plan["protected"][day]["n"]:
            raise RuntimeError("Unqueried billing partition count changed before write")
        assert_money(plan["protected"][day], protected, "protected preflight -> write")
        for (partition, usage), previous in plan["local"].items():
            if usage == day:
                current = table_totals(connection, SUMMARY, account, day, partition=partition)
                if current["n"] != previous["n"]:
                    raise RuntimeError("Local summary changed after preflight")
                assert_money(previous, current, "local preflight -> write")
    for (partition, usage), rows in sorted(plan["groups"].items()):
        if usage != day:
            continue
        written = replace_summary_partition_usage_dates(
            engine, rows, vendor="aws", account_id=account, export_partition_date=partition,
            usage_start_date=day, usage_end_date=day, dry_run=False, batch_size=500)
        emit("summary_scope_replaced", account_id=account, usage_date=day, billing_partition=partition,
             rows_deleted=plan["local"][partition, day]["n"], rows_inserted=written)
    with engine.connect() as connection:
        verify_queried(connection, plan, day)
    refresh_day(account, day)
    with engine.connect() as connection:
        verify_queried(connection, plan, day)
        verify_publication(connection, account, day)


def acquire(engine, progress):
    # Insert first makes both first-use and established-row acquisition atomic.
    with engine.begin() as connection:
        sqlite = connection.dialect.name == "sqlite"
        insert = "INSERT OR IGNORE" if sqlite else "INSERT IGNORE"
        connection.execute(text(f"""{insert} INTO cost_job_state
            (job_name, watermark_json, last_status) VALUES (:name, '{{}}', 'ready')"""), {"name": JOB_NAME})
        # Read status from the locking/current read, not a stale repeatable-read snapshot.
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
    progress = dict(run_id=os.environ.get("POD_NAME") or str(uuid.uuid4()), windows=[],
                    completed_account_days=[], percent=0, phase="preflight")
    # Acquire outside the failure handler: a rejected run must not checkpoint another run.
    if not dry_run:
        acquire(engine, progress)
    last_heartbeat = 0.0

    def heartbeat():
        nonlocal last_heartbeat
        if not dry_run and time.monotonic() - last_heartbeat >= 60:
            checkpoint(engine, progress)
            last_heartbeat = time.monotonic()

    try:
        plans, original = prepare(client, engine, today or datetime.now(timezone.utc).date(), heartbeat)
        progress["windows"] = [{"account_id": p["account"], "start": str(p["start"]), "end": str(p["end"])} for p in plans]
        emit("plan", dry_run=dry_run, **progress)
        if dry_run:
            return progress
        progress["phase"] = "write"
        checkpoint(engine, progress)
        total = sum(len(list(dates(p["start"], p["end"]))) for p in plans)
        for plan in plans:
            for day in dates(plan["start"], plan["end"]):
                progress["current_account_day"] = f"{plan['account']}/{day}"
                checkpoint(engine, progress)
                if snapshot(client) != original:
                    raise RuntimeError("Source snapshot changed before next write")
                with engine.connect() as connection:
                    validate_registry(connection, {p["account"]: p["start"] for p in plans})
                replace_day(engine, plan, day)
                progress["completed_account_days"].append(progress["current_account_day"])
                progress["percent"] = round(100 * len(progress["completed_account_days"]) / total, 2)
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
    parser.add_argument("--dry-run", action="store_true", help="Read and validate only; do not write even job state")
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
