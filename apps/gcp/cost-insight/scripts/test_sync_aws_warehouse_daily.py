"""Offline regression checks; stdlib unittest, released Cost Insight dependencies."""
import contextlib
import io
import unittest
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from types import SimpleNamespace
from unittest.mock import Mock, patch

from sqlalchemy import create_engine, event, text

import sync_aws_warehouse_daily as worker
from cost_insight.common.config import DEFAULT_AWS_BILLING_TABLE
from cost_insight.jobs import state_store
from cost_insight.jobs.sync_gcp_billing_summary import _normalize_summary_row, write_summary_rows

DAY = date(2026, 10, 28)
ACCOUNT = worker.ACCOUNTS[0]


def source_row(day=DAY, account=ACCOUNT, partition=None, **extra):
    return dict(vendor="aws", account_id=account, export_partition_date=partition or day.replace(day=1),
                usage_date=day, currency="USD", service_name="AmazonEC2", sku_name="instance",
                list_cost=Decimal("10"), effective_cost=Decimal("8"), credit_amount=Decimal("-1"),
                net_cost=Decimal("7"), source_export_time=datetime(2026, 10, 29), **extra)


def control(day=DAY, **extra):
    return dict(export_partition_date=day.replace(day=1), usage_date=day, n=1, non_usd=0,
                list_cost=Decimal("10"), **extra)


def make_engine(start=DAY - timedelta(days=4)):
    engine = create_engine("sqlite+pysqlite:///:memory:")
    template = _normalize_summary_row(source_row())
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
        for account in worker.ACCOUNTS:
            connection.execute(text("INSERT INTO cost_sources(vendor,account_id,is_active) VALUES ('aws',:a,1)"),
                               {"a": account})
    # A known complete day directly before the routine window establishes no older backlog.
    for account in worker.ACCOUNTS:
        write_summary_rows(engine, [_normalize_summary_row(source_row(start - timedelta(days=1), account))], dry_run=False)
    return engine


class FakeJob:
    total_bytes_processed = 1024
    job_id = "offline"

    def __init__(self, rows=()):
        self.rows = rows

    def result(self, **kwargs):
        return iter(self.rows)

    def cancel(self, **kwargs):
        pass


class FakeClient:
    def __init__(self, end=DAY):
        self.end = end
        self.calls = []
        self.table = SimpleNamespace(table_type="TABLE", expires=None, time_partitioning=None,
                                     modified=datetime(2026, 10, 30, tzinfo=timezone.utc), num_rows=100, etag="fixed")

    def get_table(self, *args, **kwargs):
        return self.table

    def query(self, sql, **kwargs):
        self.calls.append((sql, kwargs))
        config = kwargs["job_config"]
        if config.dry_run:
            return FakeJob()
        values = {p.name: p.value for p in config.query_parameters}
        end = min(self.end, values["usage_end_date"])
        start = values["earliest_usage_date"]
        if sql == worker.CONTROL_SQL:
            return FakeJob([control(d) for d in worker.dates(start, end)])
        return FakeJob([source_row(d, values["account_id"]) for d in worker.dates(start, end)])


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.silence = contextlib.redirect_stdout(io.StringIO())
        self.silence.__enter__()
        self.engine = make_engine()
        self.addCleanup(self.engine.dispose)

    def tearDown(self):
        self.silence.__exit__(None, None, None)

    def prepare(self, client=None):
        return worker.prepare(client or FakeClient(), self.engine, DAY + timedelta(days=2), lambda: None)[0]

    def test_complete_canonical_collision_sums_all_money_and_latest_timestamp(self):
        first = _normalize_summary_row(source_row(vendor_tags_json='{"cluster":"c","usedby":"u"}'))
        second = _normalize_summary_row(source_row(vendor_tags_json='{"usedby":"u","cluster":"c"}'))
        second["source_export_time"] += timedelta(hours=1)
        self.assertEqual(first["source_row_hash"], second["source_row_hash"])
        rows = worker.merge_rows(iter((first, second)))
        self.assertEqual(len(rows), 1)
        self.assertEqual([rows[0][m] for m in worker.METRICS], list(map(Decimal, ("20", "16", "-2", "14"))))
        self.assertEqual(rows[0]["source_export_time"], second["source_export_time"])
        with self.assertRaisesRegex(RuntimeError, "Non-finite"):
            worker.merge_rows([{**first, "net_cost": "NaN"}])

    def test_five_day_window_crosses_billing_month(self):
        end = date(2026, 11, 2)
        engine = make_engine(end - timedelta(days=4))
        self.addCleanup(engine.dispose)
        plans, _ = worker.prepare(FakeClient(end), engine, end + timedelta(days=1), lambda: None)
        for plan in plans:
            self.assertEqual(plan["start"], date(2026, 10, 29))
            self.assertEqual(len({d for p, d in plan["groups"]}), 5)
            self.assertEqual({p for p, d in plan["groups"]}, {date(2026, 10, 1), date(2026, 11, 1)})
        params = {p.name: p.value for p in worker.parameters(ACCOUNT, date(2026, 10, 29), end)}
        self.assertEqual(params["export_partition_end"], date(2026, 11, 1))

    def test_scope_currency_empty_and_raw_control_guards(self):
        valid = _normalize_summary_row(source_row())
        for bad in ({**valid, "vendor": "azure"}, {**valid, "account_id": "946646677266"},
                    {**valid, "currency": "EUR"}, {**valid, "usage_date": DAY + timedelta(days=1)},
                    {**valid, "export_partition_date": date(2026, 9, 1)},
                    {**valid, "source_allocation_scope": "split"}):
            with self.subTest(bad=bad), self.assertRaises(RuntimeError):
                worker.validate_rows([bad], [control()], ACCOUNT, DAY, DAY)
        for rows, controls in (([], []), ([valid], []), ([valid], [{**control(), "non_usd": 1}]),
                               ([valid], [{**control(), "list_cost": "11"}])):
            with self.subTest(controls=controls), self.assertRaises(RuntimeError):
                worker.validate_rows(rows, controls, ACCOUNT, DAY, DAY)

    def test_query_caps_and_no_retries_on_preview_and_execution(self):
        client = FakeClient()
        worker.query_rows(client, worker.CONTROL_SQL, worker.parameters(ACCOUNT, DAY, DAY), "check", lambda: None)
        self.assertEqual(len(client.calls), 2)
        for sql, kwargs in client.calls:
            self.assertEqual(kwargs["job_config"].maximum_bytes_billed, 2 * 1024**3)
            self.assertFalse(kwargs["job_config"].use_query_cache)
            self.assertIsNone(kwargs["retry"])
            self.assertIsNone(kwargs["job_retry"])
            self.assertEqual(kwargs["timeout"], 30)
        self.assertTrue(client.calls[0][1]["job_config"].dry_run)
        for estimate in (None, worker.MAX_BYTES + 1, -1):
            blocked = Mock()
            blocked.query.return_value.total_bytes_processed = estimate
            with self.subTest(estimate=estimate), self.assertRaises(RuntimeError):
                worker.query_rows(blocked, "sql", [], "over-cap", lambda: None)
            self.assertEqual(blocked.query.call_count, 1)

    def test_actual_byte_cap_and_result_timeout(self):
        client = Mock()
        oversized = FakeJob()
        oversized.total_bytes_processed = worker.MAX_BYTES + 1
        client.query.side_effect = (FakeJob(), oversized)
        with self.assertRaisesRegex(RuntimeError, "actual bytes"):
            worker.query_rows(client, "sql", [], "actual", lambda: None)
        failing = Mock()
        failing.result.side_effect = TimeoutError("query timed out")
        client.query.side_effect = (FakeJob(), failing)
        with self.assertRaises(TimeoutError):
            worker.query_rows(client, "sql", [], "timeout", lambda: None)
        failing.cancel.assert_called_once_with(timeout=30, retry=None)
        failing.result.assert_called_once_with(page_size=1000, timeout=900, retry=None, job_retry=None)

    def test_query_builder_uses_permanent_raw_and_exact_usd_filter(self):
        sql = worker.summary_query(DAY)
        self.assertIn("`" + worker.TABLE + "`", sql)
        self.assertIn("AND line_item_currency_code = 'USD'", sql)
        self.assertIn("raw.bill_billing_period_start_date >= TIMESTAMP(@export_partition_start)", sql)
        with patch.object(worker, "build_aws_billing_summary_query", return_value="changed"):
            with self.assertRaisesRegex(RuntimeError, "contract"):
                worker.summary_query(DAY)

    def test_registry_accepts_unset_or_permanent_warehouse_table(self):
        for table in (None, "", worker.TABLE):
            with self.subTest(table=table), self.engine.begin() as connection:
                connection.execute(text("UPDATE cost_sources SET source_table=:table"), {"table": table})
                worker.validate_registry(connection)

    def test_registry_rejects_inactive_legacy_custom_split_and_f04(self):
        for column, value in (("is_active", 0), ("source_schema_version", "aws_split_cost_v1"),
                              ("source_schema_version", "aws_tidb_cloud_f04_v1"),
                              ("source_table", DEFAULT_AWS_BILLING_TABLE), ("source_table", "other.raw.table")):
            with self.subTest(column=column, value=value):
                with self.engine.begin() as connection:
                    connection.execute(text(f"UPDATE cost_sources SET {column}=:v WHERE account_id=:a"),
                                       {"v": value, "a": ACCOUNT})
                with self.engine.connect() as connection, self.assertRaises(RuntimeError):
                    worker.validate_registry(connection)
                with self.engine.begin() as connection:
                    connection.execute(text(f"UPDATE cost_sources SET {column}=:v WHERE account_id=:a"),
                                       {"v": 1 if column == "is_active" else None, "a": ACCOUNT})

    def test_ordinary_availability_allows_existing_source_but_bounds_usage_window(self):
        with self.engine.begin() as connection:
            connection.execute(text("UPDATE cost_sources SET source_available_from='2026-06-01' WHERE account_id=:a"),
                               {"a": ACCOUNT})
        self.assertEqual(self.prepare()[0]["start"], DAY - timedelta(days=4))
        with self.engine.begin() as connection:
            connection.execute(text("UPDATE cost_sources SET source_available_from='2026-10-25' WHERE account_id=:a"),
                               {"a": ACCOUNT})
        with self.assertRaisesRegex(RuntimeError, "predates AWS source availability"):
            self.prepare()

    def test_older_empty_days_do_not_imply_a_current_watermark_backlog(self):
        write_summary_rows(self.engine, [_normalize_summary_row(source_row(DAY - timedelta(days=7)))], dry_run=False)
        self.assertEqual(len(self.prepare()), 4)

    def test_stale_source_refuses_even_within_discovery_lookback(self):
        with self.assertRaisesRegex(RuntimeError, "stale or has no recent usage"):
            self.prepare(FakeClient(DAY - timedelta(days=10)))

    def test_permanent_snapshot_and_changed_snapshot_guards(self):
        for attribute, value in (("expires", datetime.now()), ("table_type", "VIEW"),
                                  ("time_partitioning", SimpleNamespace(expiration_ms=1000)), ("modified", None)):
            client = FakeClient()
            setattr(client.table, attribute, value)
            with self.subTest(attribute=attribute), self.assertRaises(RuntimeError):
                worker.snapshot(client)
        with patch.object(worker, "snapshot", side_effect=("before", "after")):
            with self.assertRaisesRegex(RuntimeError, "snapshot changed"):
                self.prepare()

    def test_dry_run_has_zero_database_writes_or_refreshes(self):
        statements = []
        def record(connection, cursor, statement, params, context, many):
            statements.append(statement.strip().upper())
        event.listen(self.engine, "before_cursor_execute", record)
        with patch.object(worker, "replace_summary_partition_usage_dates") as replace, patch.object(worker, "refresh_day") as refresh:
            result = worker.run(FakeClient(), self.engine, dry_run=True, today=DAY + timedelta(days=2))
        self.assertEqual(len(result["windows"]), 4)
        self.assertTrue(statements)
        self.assertTrue(all(s.startswith("SELECT") for s in statements))
        replace.assert_not_called()
        refresh.assert_not_called()
        with self.engine.connect() as connection:
            self.assertIsNone(state_store.get_job_state(connection, worker.JOB_NAME))

    def test_all_four_fetched_before_writes_and_bad_last_account_stops_everything(self):
        original = worker.validate_rows
        def validate(rows, controls, account, start, end):
            if account == worker.ACCOUNTS[-1]:
                raise RuntimeError("bad final account")
            return original(rows, controls, account, start, end)
        with patch.object(worker.Path, "is_file", return_value=True), patch.object(worker, "validate_rows", side_effect=validate), \
                patch.object(worker, "replace_day") as replace:
            with self.assertRaisesRegex(RuntimeError, "bad final"):
                worker.run(FakeClient(), self.engine, today=DAY + timedelta(days=2))
        replace.assert_not_called()
        with self.engine.connect() as connection:
            self.assertEqual(state_store.get_job_state(connection, worker.JOB_NAME).last_status, "failed")

    def test_backlog_and_empty_partition_local_facts_refuse_before_writes(self):
        plan = self.prepare()[0]
        with self.engine.begin() as connection:
            connection.execute(text(f"DELETE FROM {worker.SUMMARY} WHERE account_id=:a"), {"a": ACCOUNT})
        write_summary_rows(self.engine, [_normalize_summary_row(source_row(DAY - timedelta(days=7)))], dry_run=False)
        with self.engine.connect() as connection, self.assertRaisesRegex(RuntimeError, "backlog"):
            worker.local_preflight(connection, plan)
        # Existing facts in a queried partition/day with no source rows are uncertain, not zero.
        engine = make_engine()
        self.addCleanup(engine.dispose)
        write_summary_rows(engine, [_normalize_summary_row(source_row())], dry_run=False)
        plan["groups"].pop((DAY.replace(day=1), DAY))
        with engine.connect() as connection, self.assertRaisesRegex(RuntimeError, "Empty queried partition"):
            worker.local_preflight(connection, plan)

    def test_sibling_billing_partition_survives_real_released_replacement(self):
        sibling = _normalize_summary_row(source_row(partition=date(2026, 9, 1)))
        write_summary_rows(self.engine, [sibling], dry_run=False)
        # Replace an existing queried October row, retaining the September contribution to the same day.
        old = _normalize_summary_row(source_row())
        old["list_cost"] = Decimal("999")
        write_summary_rows(self.engine, [old], dry_run=False)
        plan = self.prepare()[0]
        with patch.object(worker, "refresh_day"), patch.object(worker, "verify_publication"):
            worker.replace_day(self.engine, plan, DAY)
        with self.engine.connect() as connection:
            september = worker.table_totals(connection, worker.SUMMARY, ACCOUNT, DAY, partition=date(2026, 9, 1))
            october = worker.table_totals(connection, worker.SUMMARY, ACCOUNT, DAY, partition=date(2026, 10, 1))
            total = worker.table_totals(connection, worker.SUMMARY, ACCOUNT, DAY)
            preserved = connection.execute(text(f"SELECT source_row_hash FROM {worker.SUMMARY} WHERE export_partition_date='2026-09-01'" )).scalar_one()
        self.assertEqual(preserved, sibling["source_row_hash"])
        self.assertEqual(september["n"], 1)
        self.assertEqual(october["n"], 1)
        worker.assert_money(worker.totals([sibling]), september, "sibling")
        worker.assert_money(worker.totals([sibling, _normalize_summary_row(source_row())]), total, "all partitions")

    def test_publication_checks_all_four_metrics_active_version_and_currency(self):
        write_summary_rows(self.engine, [_normalize_summary_row(source_row())], dry_run=False)
        with self.engine.begin() as connection:
            for table in ("cost_attribution_daily", "cost_resource_serving_daily"):
                connection.execute(text(f"""INSERT INTO {table} VALUES
                    ('aws',:account,:day,'USD','native','active',10,8,-1,7)"""), {"account": ACCOUNT, "day": DAY})
            connection.execute(text("""INSERT INTO cost_resource_serving_publication VALUES
                ('native','aws',:account,:day,'USD','active',10)"""), {"account": ACCOUNT, "day": DAY})
            worker.verify_publication(connection, ACCOUNT, DAY)
        for table in ("cost_attribution_daily", "cost_resource_serving_daily"):
            for metric in worker.METRICS:
                with self.subTest(table=table, metric=metric), self.engine.begin() as connection:
                    connection.execute(text(f"UPDATE {table} SET {metric}={metric}+1"))
                    with self.assertRaises(RuntimeError):
                        worker.verify_publication(connection, ACCOUNT, DAY)
                    connection.execute(text(f"UPDATE {table} SET {metric}={metric}-1"))
        for column, value in (("currency", "EUR"), ("active_materialization_version", "missing"), ("total_list_cost", 99)):
            with self.subTest(column=column), self.engine.begin() as connection:
                connection.execute(text(f"UPDATE cost_resource_serving_publication SET {column}=:v"), {"v": value})
                with self.assertRaises(RuntimeError):
                    worker.verify_publication(connection, ACCOUNT, DAY)
                connection.execute(text(f"UPDATE cost_resource_serving_publication SET {column}=:v"),
                                   {"v": {"currency": "USD", "active_materialization_version": "active", "total_list_cost": 10}[column]})

    def test_single_writer_latch_failure_stops_later_days_and_replay(self):
        plans = self.prepare()
        effects = []
        def replace(engine, plan, day):
            effects.append((plan["account"], day))
            if len(effects) == 2:
                raise RuntimeError("uncertain write")
        with patch.object(worker.Path, "is_file", return_value=True), patch.object(worker, "prepare", return_value=(plans, "snapshot")), \
                patch.object(worker, "snapshot", return_value="snapshot"), patch.object(worker, "replace_day", side_effect=replace):
            with self.assertRaisesRegex(RuntimeError, "uncertain"):
                worker.run(FakeClient(), self.engine)
        self.assertEqual(len(effects), 2)
        with self.engine.connect() as connection:
            state = state_store.get_job_state(connection, worker.JOB_NAME)
        self.assertEqual(state.last_status, "failed")
        self.assertEqual(len(state.watermark["completed_account_days"]), 1)
        self.assertEqual(state.watermark["percent"], 5)
        self.assertIn("uncertain write", state.last_error)
        self.assertIn(str(plans[0]["start"] + timedelta(days=1)), state.watermark["current_account_day"])
        with self.assertRaisesRegex(RuntimeError, "inspect before explicit recovery"):
            worker.acquire(self.engine, {"run_id": "replay"})
        with self.engine.connect() as connection:
            self.assertEqual(state_store.get_job_state(connection, worker.JOB_NAME).watermark, state.watermark)

    def test_run_preserves_recovery_gate_and_existing_state_when_not_acquired(self):
        progress = {"run_id": "first"}
        worker.acquire(self.engine, progress)
        for status in ("running", "failed"):
            with self.subTest(status=status):
                if status == "failed":
                    worker.checkpoint(self.engine, progress, "failed", "original write failure")
                with self.engine.connect() as connection:
                    before = state_store.get_job_state(connection, worker.JOB_NAME)
                with patch.object(worker.Path, "is_file", return_value=True), \
                        patch.object(worker, "prepare") as prepare, patch.object(worker, "checkpoint") as checkpoint, \
                        self.assertRaisesRegex(RuntimeError, f"Previous worker is {status}; inspect before explicit recovery"):
                    worker.run(FakeClient(), self.engine)
                prepare.assert_not_called()
                checkpoint.assert_not_called()
                with self.engine.connect() as connection:
                    self.assertEqual(state_store.get_job_state(connection, worker.JOB_NAME), before)

    def test_running_latch_and_successful_progress(self):
        progress = {"run_id": "first"}
        worker.acquire(self.engine, progress)
        with self.assertRaisesRegex(RuntimeError, "running"):
            worker.acquire(self.engine, {"run_id": "second"})
        with self.assertRaisesRegex(RuntimeError, "ownership"):
            worker.checkpoint(self.engine, {"run_id": "second"})
        worker.checkpoint(self.engine, progress, "succeeded")
        plans = self.prepare()
        with patch.object(worker.Path, "is_file", return_value=True), patch.object(worker, "prepare", return_value=(plans, "s")), \
                patch.object(worker, "snapshot", return_value="s"), patch.object(worker, "replace_day") as replace:
            result = worker.run(FakeClient(), self.engine)
        self.assertEqual(replace.call_count, 20)
        self.assertEqual(result["percent"], 100)
        self.assertEqual(len(result["completed_account_days"]), 20)
        with self.engine.connect() as connection:
            self.assertEqual(state_store.get_job_state(connection, worker.JOB_NAME).last_status, "succeeded")

    def test_write_refuses_outside_kubernetes_before_state_change(self):
        with patch.object(worker.Path, "is_file", return_value=False):
            with self.assertRaisesRegex(RuntimeError, "GKE Job"):
                worker.run(FakeClient(), self.engine)
        with self.engine.connect() as connection:
            self.assertIsNone(state_store.get_job_state(connection, worker.JOB_NAME))

    def test_empty_discovery_and_future_discovery_are_rejected(self):
        for rows in ([], [control(DAY + timedelta(days=4))]):
            with patch.object(worker, "query_rows", return_value=rows):
                with self.assertRaises(RuntimeError):
                    self.prepare()

    def test_source_change_before_first_write_latches_without_facts(self):
        plans = self.prepare()
        with patch.object(worker.Path, "is_file", return_value=True), patch.object(worker, "prepare", return_value=(plans, "old")), \
                patch.object(worker, "snapshot", return_value="new"), patch.object(worker, "replace_day") as replace:
            with self.assertRaisesRegex(RuntimeError, "snapshot changed"):
                worker.run(FakeClient(), self.engine)
        replace.assert_not_called()
        with self.engine.connect() as connection:
            self.assertEqual(state_store.get_job_state(connection, worker.JOB_NAME).last_status, "failed")

    def test_conflicting_local_writer_stops_before_any_scope_replacement(self):
        for partition in (date(2026, 10, 1), date(2026, 9, 1)):
            with self.subTest(partition=partition):
                engine = make_engine()
                self.addCleanup(engine.dispose)
                plan = worker.prepare(FakeClient(), engine, DAY + timedelta(days=2), lambda: None)[0][0]
                write_summary_rows(engine, [_normalize_summary_row(source_row(partition=partition))], dry_run=False)
                with patch.object(worker, "replace_summary_partition_usage_dates") as replace:
                    with self.assertRaises(RuntimeError):
                        worker.replace_day(engine, plan, DAY)
                replace.assert_not_called()

    def test_summary_currency_missing_attribution_and_queried_count_guards(self):
        plan = self.prepare()[0]
        with self.engine.connect() as connection:
            with self.assertRaisesRegex(RuntimeError, "identity count"):
                worker.verify_queried(connection, plan, DAY)
            with self.assertRaisesRegex(RuntimeError, "Missing summary"):
                worker.verify_publication(connection, ACCOUNT, DAY)
        write_summary_rows(self.engine, [_normalize_summary_row(source_row())], dry_run=False)
        with self.engine.begin() as connection:
            connection.execute(text(f"UPDATE {worker.SUMMARY} SET currency='EUR' WHERE usage_date=:day"), {"day": DAY})
            with self.assertRaisesRegex(RuntimeError, "mixed-currency"):
                worker.table_totals(connection, worker.SUMMARY, ACCOUNT, DAY)

    def test_mysql_acquisition_uses_status_from_current_locking_read(self):
        connection = Mock()
        connection.dialect.name = "mysql"
        connection.execute.return_value.scalar_one.return_value = "running"
        engine = Mock()
        engine.begin.return_value.__enter__ = Mock(return_value=connection)
        engine.begin.return_value.__exit__ = Mock(return_value=False)
        with patch.object(worker.state_store, "mark_job_started") as started:
            with self.assertRaisesRegex(RuntimeError, "running"):
                worker.acquire(engine, {"run_id": "second"})
        statements = [str(c.args[0]) for c in connection.execute.call_args_list]
        self.assertIn("INSERT IGNORE", statements[0])
        self.assertIn("SELECT last_status", statements[1])
        self.assertTrue(statements[1].endswith("FOR UPDATE"))
        started.assert_not_called()

    def test_main_read_only_wiring_and_rule_table_guard(self):
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
        with patch.object(worker, "get_settings", return_value=settings), patch("sys.argv", ["worker"]):
            with self.assertRaisesRegex(RuntimeError, "rule table"):
                worker.main()

    def test_refresh_is_exact_source_scoped_day_and_has_deadline(self):
        with patch.object(worker.subprocess, "run", return_value=SimpleNamespace(stdout="[]")) as command:
            worker.refresh_day(ACCOUNT, DAY)
        args = command.call_args.args[0]
        self.assertEqual(args, ["cost-insight", "refresh-cost-attribution-from-summary", "--vendor", "aws",
                                "--account-id", ACCOUNT, "--start-date", str(DAY), "--end-date", str(DAY), "--split-by-day"])
        self.assertEqual(command.call_args.kwargs["timeout"], 900)
        self.assertTrue(command.call_args.kwargs["check"])


if __name__ == "__main__":
    unittest.main()
