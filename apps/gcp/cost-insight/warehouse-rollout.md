# Warehouse billing read canary (staged)

## Scope and boundaries

This prepares a **manual, read-only access/shape canary**, not a multi-vendor
source cutover or a backfill. The CronJob is committed with `suspend: true` and
must remain suspended. Merging this preparation must not automatically run it.
No database secrets, importer commands, attribution writes, resource-serving
refreshes, DML, DDL or temporary tables are involved.

Upstream `main` already contains the dedicated GCP billing KSA and warehouse
GCP source. This change does **not** change existing writer images, sources,
KSAs or schedules, or edit `cronjobs.yaml` / `serviceaccount.yaml`.
[OPS PR #2500](https://github.com/PingCAP-QE/ee-ops/pull/2500) is a separate,
unmerged GCP historical cutover-partition guard. This preparation neither
changes that guard/repair nor removes the live GCP unmatched-resource temporary
Flux hold associated with it. Do not use this canary to bypass either boundary.

Application work is tracked in
[ee-apps PR #760](https://github.com/PingCAP-QE/ee-apps/pull/760), which is
not merged or released. The canary uses only the Python BigQuery SDK already
supplied by the existing published image:

```text
ghcr.io/pingcap-qe/ee-apps/cost-insight-jobs:v2026.9.20-1-gb8abd19
```

It does not require the new application billing-client helper. Any later
writer image pin requires explicit user approval to merge the application PR,
an actual published release artifact, and a separate reviewed rollout. Do not
invent a future tag or roll writers forward as part of this preparation.

## Identity and bounded reads

- KSA: existing `apps/cost-insight-gcp-billing`.
- Direct Workload Identity GSA:
  `hxprog-e5d756e67e8641f386ab0e9@warehouse-f80fbbe8e8.iam.gserviceaccount.com`.
- Query project: `warehouse-f80fbbe8e8`; SDK location: `us-west1`, **not** `US`.
- No impersonation setting or self-impersonation hop. Do not expand the shared
  `ci-dashboard` GSA's token-creation permissions.
- Approved warehouse table access expires on **2027-04-25T06:52:47Z**. This is
  an IAM authorization expiry, not the lifecycle of individual tables.

The container first dry-runs and executes `SELECT SESSION_USER()` and strictly
requires the GSA above before any table reads. It then reads:

| Object in `warehouse-f80fbbe8e8` | Scope / result |
| --- | --- |
| `mart_cloud_cost.aws_member_daily_cost` | Current `billing_period` month; `MAX(usage_date)` for `Usage` / `SavingsPlanCoveredUsage`, excluding dates after `CURRENT_DATE()` |
| `mart_cloud_cost.alibaba_daily_cost` | Current `billing_period` month; `MAX(usage_date)` |
| `mart_cloud_cost.azure_daily_cost` | Current `billing_period` month; `MAX(usage_date)` |
| `raw_gcp_billing.gcp_billing_export_resource_v1_01D088_8F9CF2_8AF1C6` | Today/yesterday UTC `_PARTITIONDATE` only; `MAX(export_time)` |

Each table probe also records `COUNT(*) AS scope_rows`, distinguishing an empty
scope from existing rows whose aggregate date is NULL. Counts are diagnostic;
zero rows remain acceptable for this access/shape canary.

Named-table metadata and bounded SELECTs were checked with the approved SA on
2026-10-27: all three marts have DATE `billing_period` (month-start, monthly
partition) and DATE `usage_date`; AWS also has STRING `charge_type`, including
exact `Usage` and `SavingsPlanCoveredUsage` values. GCP has TIMESTAMP
`export_time` and DATE ingestion `_PARTITIONDATE`. This local schema check does
not replace the pending dedicated-KSA runtime test.

For a first-run `Unrecognized name` or incompatible-type error, compare the
exact named table's schema using BigQuery Tables.get / SDK `get_table().schema`
with an authorized identity before diagnosing IAM. Dataset-wide
`INFORMATION_SCHEMA.COLUMNS` may itself require metadata permissions this SA
does not have; do not broaden IAM merely to troubleshoot a SQL column error.
An actual Access Denied error should instead be triaged by its permission,
principal, project and object. Do not increase scan caps as an auth/schema fix.

Each SELECT has a preceding uncached dry-run and a **512 MiB per-query**
`maximum_bytes_billed` cap. Unknown or over-budget estimates fail before data
execution. Real queries also enforce that cap; errors stop the script without
SDK/job retries or an unbounded fallback. The Job has `backoffLimit: 0` and a
600-second active deadline. Do not widen windows, raise budgets or repeatedly
rerun failed checks without review and authorization.

A successful read may return a NULL date. This is acceptable for access/shape
validation, including inactive Azure production data: no per-subscription
freshness requirement is enforced. AWS fee/EDP rows can have future usage dates
(previously through October 31); those rows must not manufacture apparent usage
freshness. Even filtered MAX dates are diagnostics, **not** proof of ingestion
freshness, importer compatibility, cost conservation or attribution correctness.

## Why the other writers must remain unchanged

The stable marts are comparison sources, **not drop-in detail importer tables**.
Do not point legacy `*_BILLING_TABLE` settings or `cost_sources` at them. They
lack required resource/tag/tenant/workload and split-cost lineage. In the application
change, `warehouse_raw=True` is an explicit query-builder validation flag;
it is not wired into importer fetch, CLI or dispatch and is not a production
import mode.

Readable detail artifacts have short independent table TTLs (UTC):

| Temporary artifact | Expiry verified on 2026-10-27 |
| --- | --- |
| AWS `raw_aws_billing._stage_202610_228e2ed1a4ec4e4c_ecfd2884ae15` | 2026-10-28 05:42:55 |
| AWS `raw_aws_billing._stage_202610_bff5de906b2c03d7_173c5a84bb3e` | 2026-10-29 05:48:37 |
| Alibaba `raw_alibaba_billing._dlt_stage_daily_20261025_40eec796d5e4` | 2026-10-28 12:11:18 |
| Azure `raw_azure_billing._before_202610_warehouse_extract_fdlb7` | 2026-10-28 00:31:31 |

Never bind recurring production writers to these staging/backup tables or UNION
AWS snapshots as incremental data. The source owner must supply exact stable
full-detail table/view names, retention/correction and future-month contracts,
required attribution/resource/split dimensions and read/metadata permissions.
Adapters and complete scoped amount/dimension/deduplication checks must then
pass before a separate vendor-specific writer rollout is considered. No canary
result authorizes changing source registries or automatic historical backfills.

## Manual execution: only after merge and explicit authorization

The following are **operator examples, not actions performed by this change**.
After the user approves/merges the OPS PR and separately authorizes this canary,
confirm Flux has reconciled it, then use an explicit GKE context. Keep the
CronJob suspended; `create job --from=cronjob` is the one-off execution path.

```bash
context='<approved-gke-context>'
cronjob=cost-insight-warehouse-read-canary
kubectl --context "$context" -n apps get cronjob "$cronjob" \
  -o jsonpath='{.spec.suspend}{"\n"}'  # must be true
job="warehouse-read-canary-$(date -u +%Y%m%d%H%M%S)"
kubectl --context "$context" -n apps create job "$job" --from="cronjob/$cronjob"
kubectl --context "$context" -n apps wait --for=condition=complete "job/$job" --timeout=660s
kubectl --context "$context" -n apps logs "job/$job" --all-containers=true
```

Acceptance: exact expected identity, project/location as configured, all five
SELECTs successfully dry-run/executed within their caps, four bounded table
results (NULL allowed), job IDs/processed bytes recorded, final
`warehouse_read_canary=PASS access_and_shape_only=true`, and Job completion.
If the wait fails, inspect logs and `kubectl describe job` with the same context;
do not treat partial results as a pass or launch an importer to compensate.
Runtime identity, SDK availability in the pinned image and real query results
remain unverified until this separately authorized execution.

### Stop / rollback

To stop a manually created canary, delete **only that Job**, using its saved
name (this cancels the pod; an already-submitted BigQuery query may still finish
within its cap):

```bash
kubectl --context "$context" -n apps delete job "$job"
```

Do not unsuspend the CronJob. To withdraw preparation, use a reviewed GitOps
revert removing `warehouse-read-canary.yaml` and its kustomization resource
entry; keep this rollout note as an audit record if useful. No data rollback is
needed because the canary never writes costs. Do not revert existing GCP
writers, alter #2500's guard or remove its temporary Flux hold.
