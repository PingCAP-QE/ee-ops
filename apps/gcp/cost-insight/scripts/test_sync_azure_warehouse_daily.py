"""Offline checks against released helpers, mocked BQ and in-memory SQLite."""
import contextlib
import io
import re
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from types import SimpleNamespace
from unittest.mock import Mock, patch

from sqlalchemy import create_engine, event, text

import sync_azure_warehouse_daily as worker
from cost_insight.jobs import state_store
from cost_insight.jobs.sync_gcp_billing_summary import write_summary_rows

DAY = date(2026, 10, 29)
DORMANT = "abd27163-b965-4217-8cba-2a4c799579fe"


def source_row(day=DAY, **extra):
    return dict(vendor="azure", account_id=worker.ACCOUNT, billing_account_id="billing",
                export_partition_date=day.replace(day=1), usage_date=day, currency="USD",
                service_name="Microsoft.Compute", sku_name="instance", usage_type="Usage",
                list_cost=Decimal("10"), effective_cost=Decimal("8"), credit_amount=Decimal("0"),
                net_cost=Decimal("8"), source_export_time=datetime(2026, 10, 30), **extra)


def normalized(day=DAY, **extra):
    return worker._normalize_summary_row({**source_row(day), **extra})


def control(day=DAY, **extra):
    return {**dict(export_partition_date=day.replace(day=1), usage_date=day, n=1, non_usd=0,
                   invalid_money=0, list_cost=Decimal("10"), effective_cost=Decimal("8"),
                   credit_amount=Decimal("0"), net_cost=Decimal("8")), **extra}


def make_engine(start=DAY - timedelta(days=4), url="sqlite+pysqlite:///:memory:"):
    engine = create_engine(url)
    template = normalized()
    columns = ",".join(f'"{name}" ' + ("REAL" if name in worker.METRICS else "TEXT") for name in template)
    with engine.begin() as connection:
        connection.execute(text(f"""CREATE TABLE {worker.SUMMARY} ({columns}, updated_at TEXT,
            UNIQUE(vendor,account_id,export_partition_date,source_row_hash))"""))
        connection.execute(text("""CREATE TABLE cost_sources (vendor TEXT, account_id TEXT,
            billing_account_id TEXT, display_name TEXT, is_active INTEGER, source_table TEXT,
            source_schema_version TEXT, source_available_from TEXT, UNIQUE(vendor,account_id))"""))
        connection.execute(text("""CREATE TABLE cost_job_state (job_name TEXT PRIMARY KEY,
            watermark_json TEXT, last_started_at TEXT, last_succeeded_at TEXT,
            last_status TEXT, last_error TEXT, updated_at TEXT)"""))
        connection.execute(text("""CREATE TABLE cost_resource_serving_publication (basis_key TEXT,
            vendor TEXT, account_id TEXT, usage_date TEXT, currency TEXT,
            active_materialization_version TEXT, total_list_cost REAL)"""))
        for table in ("cost_attribution_daily", "cost_resource_serving_daily"):
            connection.execute(text(f"""CREATE TABLE {table} (vendor TEXT, account_id TEXT,
                usage_date TEXT, currency TEXT, basis_key TEXT, materialization_version TEXT,
                list_cost REAL,effective_cost REAL,credit_amount REAL,net_cost REAL)"""))
        for account in (worker.ACCOUNT, DORMANT):
            connection.execute(text("INSERT INTO cost_sources(vendor,account_id,is_active) VALUES ('azure',:a,1)"),
                               {"a": account})
    write_summary_rows(engine, [normalized(start - timedelta(days=1)),
                               normalized(date(2026, 6, 24), account_id=DORMANT)], dry_run=False)
    return engine


class FakeJob:
    total_bytes_processed = 1024
    job_id = "offline"

    def __init__(self, rows=()):
        self.rows = rows
        self.result_options = None

    def result(self, **kwargs):
        self.result_options = kwargs
        return iter(self.rows)

    def cancel(self, **kwargs):
        pass


class FakeClient:
    def __init__(self, end=DAY):
        self.end = end
        self.calls = []
        self.table_calls = []
        self.table = SimpleNamespace(table_type="TABLE", expires=None, time_partitioning=None,
                                     modified=datetime(2026, 10, 30, tzinfo=timezone.utc), num_rows=100, etag="fixed")

    def get_table(self, table, **kwargs):
        self.table_calls.append((table, kwargs))
        return self.table

    def query(self, sql, **kwargs):
        self.calls.append((sql, kwargs))
        config = kwargs["job_config"]
        if config.dry_run:
            return FakeJob()
        values = {p.name: p.value for p in config.query_parameters}
        end = min(self.end, values["usage_end_date"])
        start = values["earliest_usage_date"]
        if " AS invalid_money" in sql:
            return FakeJob([control(d) for d in worker.dates(start, end)])
        return FakeJob([source_row(d) for d in worker.dates(start, end)])


class WorkerTests(unittest.TestCase):
    def setUp(self):
        silence = contextlib.redirect_stdout(io.StringIO())
        silence.__enter__()
        self.addCleanup(silence.__exit__, None, None, None)
        self.engine = make_engine()
        self.addCleanup(self.engine.dispose)

    def prepare(self, client=None):
        return worker.prepare(client or FakeClient(), self.engine, DAY + timedelta(days=1), lambda: None)[0]

    def state(self):
        with self.engine.connect() as connection:
            return state_store.get_job_state(connection, worker.JOB_NAME)

    def test_azure_tenant_hash_and_complete_canonical_collision_merge(self):
        first = source_row(vendor_tags_json='{"tenant":"QE","owner":"a"}')
        second = source_row(vendor_tags_json='{"owner":"a","tenant":"QE"}')
        second["source_export_time"] += timedelta(hours=1)
        first["credit_amount"] = second["credit_amount"] = Decimal("-0.25")
        self.assertEqual(normalized(vendor_tags_json=first["vendor_tags_json"])["org"], "QE")
        rows = worker.normalize_rows(iter((first, second)))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["org"], "QE")
        self.assertEqual(rows[0]["source_row_hash"], worker._normalize_summary_row(first)["source_row_hash"])
        self.assertEqual([rows[0][m] for m in worker.METRICS], list(map(Decimal, ("20", "16", "-0.50", "16"))))
        self.assertEqual(rows[0]["source_export_time"], second["source_export_time"])
        # The collector completes before normalizing: collisions separated by pages still meet here.
        client = Mock()
        client.query.side_effect = [FakeJob(), FakeJob(iter((first, *[source_row(DAY - timedelta(days=1)) for _ in range(1000)], second)))]
        fetched = worker.query_rows(client, "sql", [], "pages", lambda: None)
        merged = worker.normalize_rows(fetched)
        self.assertEqual(len(merged), 2)
        self.assertEqual(next(r for r in merged if r["usage_date"] == DAY)["list_cost"], Decimal("20"))

    def test_five_day_month_rollover_and_numeric_physical_relations_only(self):
        end = date(2026, 11, 2)
        engine = make_engine(end - timedelta(days=4))
        self.addCleanup(engine.dispose)
        client = FakeClient(end)
        plan, original = worker.prepare(client, engine, end + timedelta(days=1), lambda: None)
        self.assertEqual(plan["start"], date(2026, 10, 29))
        self.assertEqual(len({d for p, d in plan["groups"]}), 5)
        self.assertEqual({p for p, d in plan["groups"]}, {date(2026, 10, 1), date(2026, 11, 1)})
        expected = {worker.TABLE[:-1] + suffix for suffix in ("20261001", "20261101")}
        self.assertEqual(set(original), expected)
        for sql, options in client.calls:
            identifiers = re.findall(r"FROM `([^`]+)`", sql)
            self.assertEqual(set(identifiers), expected)
            self.assertTrue(all(re.fullmatch(re.escape(worker.TABLE[:-1]) + r"[0-9]{6}01", t) for t in identifiers))
            self.assertNotRegex(sql, r"FROM\s+`[^`]*\*`")
            self.assertIn("UNION ALL", sql)
            self.assertIn("'20261001' AS _TABLE_SUFFIX", sql)
            self.assertIn("'20261101' AS _TABLE_SUFFIX", sql)
            self.assertIn("BETWEEN @earliest_usage_date AND @usage_end_date", sql)
        self.assertTrue(all(table in expected for table, _ in client.table_calls))
        self.assertTrue(all(options == {"timeout": 30, "retry": None} for _, options in client.table_calls))
        self.assertEqual(worker.monthly_tables(date(2026, 12, 30), date(2027, 1, 2)),
                         {date(2026, 12, 1): worker.TABLE[:-1] + "20261201", date(2027, 1, 1): worker.TABLE[:-1] + "20270101"})
        for start, finish in ((end, DAY), ("20261001", end), (datetime(2026, 10, 1), end)):
            with self.assertRaises(ValueError):
                worker.monthly_tables(start, finish)

    def test_each_query_receives_only_its_referenced_parameters(self):
        client = FakeClient()
        self.prepare(client)
        self.assertEqual(len(client.calls), 6)
        for sql, options in client.calls:
            with self.subTest(sql=sql, dry_run=options["job_config"].dry_run):
                params = options["job_config"].query_parameters
                self.assertEqual({p.name for p in params}, set(re.findall(r"@(\w+)", sql)))

    def test_builder_contract_and_raw_control_expressions(self):
        sql = worker.control_query(DAY, DAY)
        for expression in ("SAFE_CAST(paygCostInBillingCurrency AS NUMERIC)",
                           "SAFE_CAST(costInBillingCurrency AS NUMERIC)",
                           "billingCurrency IS NULL OR billingCurrency != 'USD'",
                           "CAST(0 AS NUMERIC) AS credit_amount", "AS invalid_money"):
            self.assertIn(expression, sql)
        self.assertIn("CAST(SubscriptionId AS STRING) = @account_id", sql)
        params = {p.name: p.value for p in worker.parameters(DAY, DAY, worker.summary_query(DAY, DAY))}
        self.assertEqual(params["account_id"], worker.ACCOUNT)
        self.assertEqual(params["export_partition_start"], date(2026, 10, 1))
        with patch.object(worker, "build_azure_billing_summary_query", return_value="changed"):
            with self.assertRaisesRegex(RuntimeError, "contract"):
                worker.summary_query(DAY, DAY)

    def test_strict_raw_identity_and_money_before_azure_normalization(self):
        for field, value in (("vendor", "aws"), ("account_id", DORMANT), ("currency", "EUR"),
                             ("source_allocation_scope", "split"), ("source_schema_version", "custom")):
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                worker.normalize_rows([{**source_row(), field: value}])
        for metric in worker.METRICS:
            for value in (None, "", "invalid", "NaN", "Infinity", "-Infinity"):
                with self.subTest(metric=metric, value=value), self.assertRaises(RuntimeError):
                    worker.normalize_rows([{**source_row(), metric: value}])
        self.assertEqual(worker.amount(0), Decimal(0))
        self.assertEqual(worker.amount("-0.00001"), Decimal("-0.00001"))

    def test_scope_currency_empty_null_and_all_four_raw_control_guards(self):
        valid = normalized()
        for bad in ({**valid, "vendor": "aws"}, {**valid, "account_id": DORMANT}, {**valid, "currency": None},
                    {**valid, "usage_date": DAY + timedelta(days=1)},
                    {**valid, "export_partition_date": date(2026, 10, 2)},
                    {**valid, "source_allocation_scope": "split"}, {**valid, "source_schema_version": "custom"}):
            with self.subTest(bad=bad), self.assertRaises(RuntimeError):
                worker.validate_rows([bad], [control()], DAY, DAY)
        for rows, controls in (([], []), ([valid], []), ([], [control()]), ([valid], [control(), control()]),
                               ([valid], [control(non_usd=1)]), ([valid], [control(invalid_money=1)]),
                               ([valid], [control(n=0)]), ([valid], [control(usage_date=DAY + timedelta(days=1))])):
            with self.subTest(controls=controls), self.assertRaises(RuntimeError):
                worker.validate_rows(rows, controls, DAY, DAY)
        for metric in worker.METRICS:
            for value in (None, Decimal("123")):
                with self.subTest(metric=metric, value=value), self.assertRaises(RuntimeError):
                    worker.validate_rows([valid], [control(**{metric: value})], DAY, DAY)
        with self.assertRaisesRegex(RuntimeError, "Empty source day"):
            worker.validate_rows([valid], [control()], DAY - timedelta(days=1), DAY)
        worker.assert_money(control(), control(list_cost=Decimal("10.00001")), "tolerance")

    def test_bad_final_source_day_prevents_every_fact_write(self):
        client = FakeClient()
        original = client.query
        def query(sql, **kwargs):
            result = original(sql, **kwargs)
            if not kwargs["job_config"].dry_run and " AS invalid_money" not in sql:
                result.rows[-1]["net_cost"] = None
            return result
        client.query = query
        with patch.object(worker.Path, "is_file", return_value=True), patch.object(worker, "replace_day") as replace:
            with self.assertRaisesRegex(RuntimeError, "monetary"):
                worker.run(client, self.engine, today=DAY + timedelta(days=1))
        replace.assert_not_called()
        self.assertEqual(self.state().last_status, "failed")
        self.assertEqual(self.state().watermark["window"], {"start": "2026-10-25", "end": "2026-10-29"})

    def test_query_caps_timeouts_and_no_retries(self):
        job = FakeJob([source_row()])
        client = Mock()
        client.query.side_effect = [FakeJob(), job]
        heartbeat = Mock()
        worker.query_rows(client, "sql", [], "read", heartbeat)
        self.assertEqual(heartbeat.call_count, 3)
        for call in client.query.call_args_list:
            kwargs = call.kwargs
            self.assertEqual(kwargs["job_config"].maximum_bytes_billed, 2 * 1024**3)
            self.assertFalse(kwargs["job_config"].use_query_cache)
            self.assertIsNone(kwargs["retry"])
            self.assertIsNone(kwargs["job_retry"])
            self.assertEqual(kwargs["timeout"], 30)
        self.assertTrue(client.query.call_args_list[0].kwargs["job_config"].dry_run)
        self.assertEqual(job.result_options, dict(page_size=1000, timeout=900, retry=None, job_retry=None))
        for estimate in (None, worker.MAX_BYTES + 1, -1, float("nan"), "1024"):
            blocked = Mock()
            blocked.query.return_value.total_bytes_processed = estimate
            with self.subTest(estimate=estimate), self.assertRaisesRegex(RuntimeError, "estimate"):
                worker.query_rows(blocked, "sql", [], "cap", lambda: None)
            self.assertEqual(blocked.query.call_count, 1)

    def test_actual_byte_cap_and_result_failure_cancel(self):
        for actual in (None, -1, worker.MAX_BYTES + 1, float("nan"), "1024"):
            client = Mock()
            job = FakeJob()
            job.total_bytes_processed = actual
            client.query.side_effect = [FakeJob(), job]
            with self.subTest(actual=actual), self.assertRaisesRegex(RuntimeError, "actual bytes"):
                worker.query_rows(client, "sql", [], "actual", lambda: None)
        job = Mock()
        job.result.side_effect = TimeoutError("timeout")
        client.query.side_effect = [FakeJob(), job]
        with self.assertRaises(TimeoutError):
            worker.query_rows(client, "sql", [], "timeout", lambda: None)
        job.cancel.assert_called_once_with(timeout=30, retry=None)
        job = Mock()
        job.result.return_value = iter([source_row()])
        client.query.side_effect = [FakeJob(), job]
        with patch.object(worker.time, "monotonic", side_effect=[0, 901]), self.assertRaisesRegex(TimeoutError, "collection"):
            worker.query_rows(client, "sql", [], "collection", lambda: None)
        job.cancel.assert_called_once_with(timeout=30, retry=None)

    def test_permanent_tables_complete_watermarks_and_torn_snapshot_guards(self):
        for attribute, value in (("expires", datetime.now()), ("table_type", "VIEW"),
                                  ("time_partitioning", SimpleNamespace(expiration_ms=1000)),
                                  ("modified", None), ("num_rows", None), ("num_rows", -1), ("etag", None)):
            client = FakeClient()
            setattr(client.table, attribute, value)
            with self.subTest(attribute=attribute), self.assertRaises(RuntimeError):
                worker.snapshot(client, [worker.TABLE[:-1] + "20261001"])
        for attribute, value in (("modified", datetime(2026, 11, 1)), ("num_rows", 101), ("etag", "changed")):
            client = FakeClient()
            original = worker.snapshot(client, [worker.TABLE[:-1] + "20261001"])
            setattr(client.table, attribute, value)
            with self.subTest(attribute=attribute), self.assertRaisesRegex(RuntimeError, "snapshot changed"):
                worker.assert_snapshot(client, original)
        with patch.object(worker, "snapshot", side_effect=[{"table": "old"}, {"table": "old"}, {"table": "new"}]):
            with self.assertRaisesRegex(RuntimeError, "snapshot changed"):
                self.prepare()

    def test_registry_accepts_only_active_aaa_default_permanent_routes(self):
        for table in (None, "", worker.TABLE):
            with self.subTest(table=table), self.engine.begin() as connection:
                connection.execute(text("UPDATE cost_sources SET source_table=:table WHERE account_id=:a"),
                                   {"table": table, "a": worker.ACCOUNT})
                worker.validate_registry(connection)
        for column, value in (("is_active", 0), ("source_schema_version", "custom"),
                              ("source_table", "gcp-digital-bi.azure_billing.azure_billing_cost_*"),
                              ("source_table", "other.raw.table"), ("source_table", worker.TABLE[:-1] + "20261001")):
            with self.subTest(column=column, value=value):
                with self.engine.begin() as connection:
                    connection.execute(text(f"UPDATE cost_sources SET {column}=:v WHERE account_id=:a"),
                                       {"v": value, "a": worker.ACCOUNT})
                with self.engine.connect() as connection, self.assertRaises(RuntimeError):
                    worker.validate_registry(connection)
                with self.engine.begin() as connection:
                    connection.execute(text(f"UPDATE cost_sources SET {column}=:v WHERE account_id=:a"),
                                       {"v": 1 if column == "is_active" else None, "a": worker.ACCOUNT})
        with self.engine.begin() as connection:
            connection.execute(text("DELETE FROM cost_sources WHERE account_id=:a"), {"a": worker.ACCOUNT})
        with self.engine.connect() as connection, self.assertRaises(RuntimeError):
            worker.validate_registry(connection)

    def test_source_availability_and_local_watermark_not_historical_audit(self):
        with self.engine.begin() as connection:
            connection.execute(text("UPDATE cost_sources SET source_available_from='2026-06-01' WHERE account_id=:a"),
                               {"a": worker.ACCOUNT})
        write_summary_rows(self.engine, [normalized(DAY - timedelta(days=10))], dry_run=False)
        self.assertEqual(self.prepare()["start"], DAY - timedelta(days=4))
        with self.engine.begin() as connection:
            connection.execute(text("UPDATE cost_sources SET source_available_from='2026-10-26' WHERE account_id=:a"),
                               {"a": worker.ACCOUNT})
        with self.assertRaisesRegex(RuntimeError, "predates Azure source availability"):
            self.prepare()
        with self.engine.begin() as connection:
            connection.execute(text("UPDATE cost_sources SET source_available_from=NULL WHERE account_id=:a"), {"a": worker.ACCOUNT})
            connection.execute(text(f"DELETE FROM {worker.SUMMARY} WHERE account_id=:a"), {"a": worker.ACCOUNT})
        with self.assertRaisesRegex(RuntimeError, "backlog"):
            self.prepare()
        write_summary_rows(self.engine, [normalized(DAY - timedelta(days=7))], dry_run=False)
        with self.assertRaisesRegex(RuntimeError, "backlog"):
            self.prepare()

    def test_stale_empty_and_future_discovery_refuse(self):
        with self.assertRaisesRegex(RuntimeError, "stale"):
            self.prepare(FakeClient(DAY - timedelta(days=8)))
        for rows in ([], [control(DAY + timedelta(days=1))], [control(DAY - timedelta(days=15))]):
            with patch.object(worker, "query_rows", return_value=rows), self.assertRaises(RuntimeError):
                self.prepare()

    def test_dry_run_is_select_only_without_state_or_refresh_and_ignores_dormant_lag(self):
        statements = []
        event.listen(self.engine, "before_cursor_execute",
                     lambda connection, cursor, statement, params, context, many: statements.append(statement.strip().upper()))
        with patch.object(worker, "replace_summary_partition_usage_dates") as replace, patch.object(worker, "refresh_day") as refresh:
            result = worker.run(FakeClient(), self.engine, dry_run=True, today=DAY + timedelta(days=1))
        self.assertEqual(result["account_id"], worker.ACCOUNT)
        self.assertEqual(result["window"], {"start": "2026-10-25", "end": "2026-10-29"})
        self.assertTrue(statements)
        self.assertTrue(all(s.startswith("SELECT") for s in statements))
        replace.assert_not_called()
        refresh.assert_not_called()
        self.assertIsNone(self.state())
        with self.engine.connect() as connection:
            self.assertEqual(connection.execute(text("SELECT is_active FROM cost_sources WHERE account_id=:a"), {"a": DORMANT}).scalar_one(), 1)
            self.assertEqual(connection.execute(text(f"SELECT MAX(usage_date) FROM {worker.SUMMARY} WHERE account_id=:a"), {"a": DORMANT}).scalar_one(), "2026-06-24")

    def test_empty_queried_partition_with_local_facts_refuses_before_deletion(self):
        plan = self.prepare()
        write_summary_rows(self.engine, [normalized()], dry_run=False)
        plan["groups"].pop((DAY.replace(day=1), DAY))
        with self.engine.connect() as connection, self.assertRaisesRegex(RuntimeError, "Empty queried partition"):
            worker.local_preflight(connection, plan)

    def test_released_replacement_preserves_sibling_day_partition_and_dormant_subscription(self):
        sibling = normalized(export_partition_date=date(2026, 9, 1))
        old = normalized(list_cost=Decimal("999"))
        sibling_day = normalized(DAY + timedelta(days=1))
        write_summary_rows(self.engine, [sibling, old, sibling_day], dry_run=False)
        plan = self.prepare()
        guard = Mock()
        with patch.object(worker, "refresh_day") as refresh, patch.object(worker, "verify_publication"):
            worker.replace_day(self.engine, plan, DAY, guard)
        guard.assert_called_once_with()
        refresh.assert_called_once_with(DAY)
        with self.engine.connect() as connection:
            september = worker.table_totals(connection, worker.SUMMARY, DAY, partition=date(2026, 9, 1))
            october = worker.table_totals(connection, worker.SUMMARY, DAY, partition=date(2026, 10, 1))
            total = worker.table_totals(connection, worker.SUMMARY, DAY)
            tomorrow = worker.table_totals(connection, worker.SUMMARY, DAY + timedelta(days=1))
            dormant = connection.execute(text(f"SELECT COUNT(*) FROM {worker.SUMMARY} WHERE account_id=:a"), {"a": DORMANT}).scalar_one()
        self.assertEqual((september["n"], october["n"], tomorrow["n"], dormant), (1, 1, 1, 1))
        worker.assert_money(worker.totals([sibling]), september, "sibling")
        worker.assert_money(worker.totals([sibling, normalized()]), total, "all partitions")
        worker.assert_money(worker.totals([sibling_day]), tomorrow, "sibling day")

    def test_rollover_replaces_both_queried_months_for_same_usage_day(self):
        start, end = date(2026, 10, 29), date(2026, 11, 2)
        engine = make_engine(start)
        self.addCleanup(engine.dispose)
        plan = worker.prepare(FakeClient(end), engine, end + timedelta(days=1), lambda: None)[0]
        # Late correction exported in November for an October usage day.
        key = (date(2026, 11, 1), start)
        plan["groups"][key] = [normalized(start, export_partition_date=key[0])]
        with engine.connect() as connection:
            worker.local_preflight(connection, plan)
        guard = Mock()
        with patch.object(worker, "refresh_day"), patch.object(worker, "verify_publication"):
            worker.replace_day(engine, plan, start, guard)
        self.assertEqual(guard.call_count, 2)
        with engine.connect() as connection:
            worker.verify_queried(connection, plan, start)
            actual = worker.table_totals(connection, worker.SUMMARY, start)
        self.assertEqual(actual["n"], 2)
        worker.assert_money(worker.totals([normalized(start), normalized(start)]), actual, "both months")

    def test_cli_success_without_native_publication_stops_after_first_uncertain_day(self):
        start = DAY - timedelta(days=4)
        with patch.object(worker.Path, "is_file", return_value=True), patch.object(worker, "refresh_day") as refresh:
            with self.assertRaisesRegex(RuntimeError, "Missing summary or attribution"):
                worker.run(FakeClient(), self.engine, today=DAY + timedelta(days=1))
        refresh.assert_called_once_with(start)
        self.assertEqual(self.state().last_status, "failed")
        self.assertEqual(self.state().watermark["current_day"], str(start))
        self.assertEqual(self.state().watermark["completed_days"], [])
        with self.engine.connect() as connection:
            self.assertEqual(worker.table_totals(connection, worker.SUMMARY, start)["n"], 1)
            self.assertEqual(worker.table_totals(connection, worker.SUMMARY, start + timedelta(days=1))["n"], 0)

    def test_dry_run_preserves_an_existing_failure_latch(self):
        progress = {"run_id": "failed-run"}
        worker.acquire(self.engine, progress)
        worker.checkpoint(self.engine, progress, "failed", "inspect uncertain writes")
        before = self.state()
        worker.run(FakeClient(), self.engine, dry_run=True, today=DAY + timedelta(days=1))
        self.assertEqual(self.state(), before)

    def test_conflicting_local_writer_stops_before_replacement(self):
        for partition in (date(2026, 10, 1), date(2026, 9, 1)):
            with self.subTest(partition=partition):
                engine = make_engine()
                self.addCleanup(engine.dispose)
                plan = worker.prepare(FakeClient(), engine, DAY + timedelta(days=1), lambda: None)[0]
                write_summary_rows(engine, [normalized(export_partition_date=partition)], dry_run=False)
                with patch.object(worker, "replace_summary_partition_usage_dates") as replace, self.assertRaises(RuntimeError):
                    worker.replace_day(engine, plan, DAY, lambda: None)
                replace.assert_not_called()

    def test_publication_all_four_fields_currency_active_version_pointer_and_all_partitions(self):
        write_summary_rows(self.engine, [normalized(), normalized(export_partition_date=date(2026, 9, 1))], dry_run=False)
        with self.engine.begin() as connection:
            for table in ("cost_attribution_daily", "cost_resource_serving_daily"):
                connection.execute(text(f"""INSERT INTO {table} VALUES
                    ('azure',:account,:day,'USD','native','active',20,16,0,16)"""), {"account": worker.ACCOUNT, "day": DAY})
            connection.execute(text("""INSERT INTO cost_resource_serving_publication VALUES
                ('native','azure',:account,:day,'USD','active',20)"""), {"account": worker.ACCOUNT, "day": DAY})
            worker.verify_publication(connection, DAY)
        for table in ("cost_attribution_daily", "cost_resource_serving_daily"):
            for metric in worker.METRICS:
                with self.subTest(table=table, metric=metric), self.engine.begin() as connection:
                    connection.execute(text(f"UPDATE {table} SET {metric}={metric}+1"))
                    with self.assertRaises(RuntimeError):
                        worker.verify_publication(connection, DAY)
                    connection.execute(text(f"UPDATE {table} SET {metric}={metric}-1"))
            with self.engine.begin() as connection:
                connection.execute(text(f"UPDATE {table} SET currency='EUR'"))
                with self.assertRaises(RuntimeError):
                    worker.verify_publication(connection, DAY)
                connection.execute(text(f"UPDATE {table} SET currency='USD'"))
        for column, value in (("currency", "EUR"), ("active_materialization_version", "missing"),
                              ("active_materialization_version", ""), ("total_list_cost", 99), ("total_list_cost", None)):
            with self.subTest(column=column, value=value), self.engine.begin() as connection:
                connection.execute(text(f"UPDATE cost_resource_serving_publication SET {column}=:v"), {"v": value})
                with self.assertRaises(RuntimeError):
                    worker.verify_publication(connection, DAY)
                connection.execute(text(f"UPDATE cost_resource_serving_publication SET {column}=:v"),
                                   {"v": {"currency": "USD", "active_materialization_version": "active", "total_list_cost": 20}[column]})

    def test_queried_summary_count_money_protected_and_null_currency_guards(self):
        plan = self.prepare()
        with self.engine.connect() as connection:
            with self.assertRaisesRegex(RuntimeError, "identity count"):
                worker.verify_queried(connection, plan, DAY)
            with self.assertRaisesRegex(RuntimeError, "Missing summary"):
                worker.verify_publication(connection, DAY)
            with self.assertRaises(ValueError):
                worker.table_totals(connection, "bad_table", DAY)
        write_summary_rows(self.engine, [normalized()], dry_run=False)
        with self.engine.begin() as connection:
            connection.execute(text(f"UPDATE {worker.SUMMARY} SET net_cost=NULL WHERE usage_date=:day"), {"day": DAY})
            with self.assertRaisesRegex(RuntimeError, "null money"):
                worker.table_totals(connection, worker.SUMMARY, DAY)
            connection.execute(text(f"UPDATE {worker.SUMMARY} SET net_cost=8,currency='EUR' WHERE usage_date=:day"), {"day": DAY})
            with self.assertRaisesRegex(RuntimeError, "currency"):
                worker.table_totals(connection, worker.SUMMARY, DAY)
            connection.execute(text(f"UPDATE {worker.SUMMARY} SET currency='USD',list_cost=11 WHERE usage_date=:day"), {"day": DAY})
            with self.assertRaisesRegex(RuntimeError, "source -> queried"):
                worker.verify_queried(connection, plan, DAY)
        write_summary_rows(self.engine, [normalized(), normalized(export_partition_date=date(2026, 9, 1))], dry_run=False)
        with self.engine.connect() as connection, self.assertRaisesRegex(RuntimeError, "Unqueried billing partition count"):
            worker.verify_queried(connection, plan, DAY)

    def test_uncertain_second_day_latches_error_stops_later_days_and_replay(self):
        plan = self.prepare()
        effects = []
        def replace(engine, plan, day, before_write):
            before_write()
            effects.append(day)
            if len(effects) == 2:
                raise RuntimeError("uncertain write")
        with patch.object(worker.Path, "is_file", return_value=True), patch.object(worker, "prepare", return_value=(plan, "snapshot")), \
                patch.object(worker, "assert_snapshot"), patch.object(worker, "replace_day", side_effect=replace):
            with self.assertRaisesRegex(RuntimeError, "uncertain"):
                worker.run(FakeClient(), self.engine)
        self.assertEqual(len(effects), 2)
        state = self.state()
        self.assertEqual(state.last_status, "failed")
        self.assertEqual(state.watermark["completed_days"], [str(plan["start"])])
        self.assertEqual(state.watermark["percent"], 20)
        self.assertIn("uncertain write", state.last_error)
        self.assertEqual(state.watermark["current_day"], str(plan["start"] + timedelta(days=1)))
        self.assertIsNotNone(state.watermark["last_update"])
        with self.assertRaisesRegex(RuntimeError, "inspect before explicit recovery"):
            worker.acquire(self.engine, {"run_id": "replay"})
        self.assertEqual(self.state(), state)

    def test_run_admission_rejection_never_clobbers_running_or_failed_state(self):
        progress = {"run_id": "first"}
        worker.acquire(self.engine, progress)
        for status in ("running", "failed"):
            with self.subTest(status=status):
                if status == "failed":
                    worker.checkpoint(self.engine, progress, "failed", "original write failure")
                before = self.state()
                with patch.object(worker.Path, "is_file", return_value=True), \
                        patch.object(worker, "prepare") as prepare, patch.object(worker, "checkpoint") as checkpoint, \
                        self.assertRaisesRegex(RuntimeError, f"Previous worker is {status}; inspect before explicit recovery"):
                    worker.run(FakeClient(), self.engine)
                prepare.assert_not_called()
                checkpoint.assert_not_called()
                self.assertEqual(self.state(), before)

    def test_atomic_sqlite_admission_with_two_concurrent_workers(self):
        with tempfile.TemporaryDirectory() as directory:
            engine = make_engine(url="sqlite+pysqlite:///" + directory + "/state.db")
            self.addCleanup(engine.dispose)
            barrier = threading.Barrier(2)
            def admit(run_id):
                barrier.wait()
                try:
                    worker.acquire(engine, {"run_id": run_id})
                    return "admitted"
                except RuntimeError as exc:
                    return str(exc)
            with ThreadPoolExecutor(max_workers=2) as executor:
                results = list(executor.map(admit, ("one", "two")))
            self.assertEqual(results.count("admitted"), 1)
            self.assertTrue(any("Previous worker is running" in result for result in results))

    def test_mysql_admission_uses_current_locking_read(self):
        connection = Mock()
        connection.dialect.name = "mysql"
        connection.execute.return_value.scalar_one.return_value = "running"
        engine = Mock()
        engine.begin.return_value.__enter__ = Mock(return_value=connection)
        engine.begin.return_value.__exit__ = Mock(return_value=False)
        with patch.object(worker.state_store, "mark_job_started") as started, self.assertRaisesRegex(RuntimeError, "running"):
            worker.acquire(engine, {"run_id": "two"})
        statements = [str(c.args[0]) for c in connection.execute.call_args_list]
        self.assertIn("INSERT IGNORE", statements[0])
        self.assertTrue(statements[1].endswith("FOR UPDATE"))
        started.assert_not_called()

    def test_successful_progress_heartbeats_and_lost_ownership(self):
        progress = {"run_id": "first"}
        worker.acquire(self.engine, progress)
        with self.assertRaisesRegex(RuntimeError, "ownership"):
            worker.checkpoint(self.engine, {"run_id": "second"})
        worker.checkpoint(self.engine, progress, "succeeded")
        plan = self.prepare()
        def prepare(client, engine, today, heartbeat, progress=None):
            heartbeat()
            heartbeat()
            return plan, "snapshot"
        with patch.object(worker.Path, "is_file", return_value=True), patch.object(worker, "prepare", side_effect=prepare), \
                patch.object(worker, "assert_snapshot"), patch.object(worker, "replace_day") as replace, \
                patch.object(worker.time, "monotonic", side_effect=[60, 60, 61]), patch.dict(worker.os.environ, {"POD_NAME": "test-pod"}):
            result = worker.run(FakeClient(), self.engine)
        self.assertEqual(replace.call_count, 5)
        self.assertEqual(result["percent"], 100)
        self.assertEqual(len(result["completed_days"]), 5)
        self.assertEqual(result["pod_name"], "test-pod")
        self.assertEqual(self.state().last_status, "succeeded")

    def test_source_change_before_first_write_and_each_scope_guard(self):
        plan = self.prepare()
        with patch.object(worker.Path, "is_file", return_value=True), patch.object(worker, "prepare", return_value=(plan, "old")), \
                patch.object(worker, "assert_snapshot", side_effect=RuntimeError("snapshot changed")), patch.object(worker, "replace_day") as replace:
            with self.assertRaisesRegex(RuntimeError, "snapshot changed"):
                worker.run(FakeClient(), self.engine)
        replace.assert_not_called()
        self.assertEqual(self.state().last_status, "failed")
        with patch.object(worker, "replace_summary_partition_usage_dates") as replace:
            with self.assertRaisesRegex(RuntimeError, "changed"):
                worker.replace_day(self.engine, plan, DAY, Mock(side_effect=RuntimeError("changed")))
        replace.assert_not_called()

    def test_write_refuses_outside_kubernetes_before_state_change(self):
        with patch.object(worker.Path, "is_file", return_value=False), self.assertRaisesRegex(RuntimeError, "GKE Job"):
            worker.run(FakeClient(), self.engine)
        self.assertIsNone(self.state())
        with self.assertRaisesRegex(RuntimeError, "timestamp"):
            worker.as_date(datetime.now())

    def test_refresh_is_exact_account_day_and_has_deadline(self):
        with patch.object(worker.subprocess, "run", return_value=SimpleNamespace(stdout="[]")) as command:
            worker.refresh_day(DAY)
        self.assertEqual(command.call_args.args[0], ["cost-insight", "refresh-cost-attribution-from-summary", "--vendor", "azure",
                         "--account-id", worker.ACCOUNT, "--start-date", str(DAY), "--end-date", str(DAY), "--split-by-day"])
        self.assertEqual(command.call_args.kwargs["timeout"], 900)
        self.assertTrue(command.call_args.kwargs["check"])

    def test_main_read_only_wiring_and_rule_guard(self):
        settings = SimpleNamespace(tcms_allocation=SimpleNamespace(allocation_table="tcms_cost.resource_allocation"))
        engine = Mock()
        with patch.object(worker, "get_settings", return_value=settings), patch.object(worker, "build_engine", return_value=engine), \
                patch.object(worker, "build_billing_bigquery_client", return_value="client"), \
                patch.object(worker, "_validate_tcms_allocation_table") as validate, patch.object(worker, "run") as run, \
                patch("sys.argv", ["worker", "--dry-run"]):
            worker.main()
        run.assert_called_once_with("client", engine, dry_run=True)
        validate.assert_called_once_with(engine, "tcms_cost.resource_allocation")
        engine.dispose.assert_called_once()
        settings.tcms_allocation.allocation_table = "other.rules"
        with patch.object(worker, "get_settings", return_value=settings), patch("sys.argv", ["worker"]), self.assertRaisesRegex(RuntimeError, "rule table"):
            worker.main()


if __name__ == "__main__":
    unittest.main()
