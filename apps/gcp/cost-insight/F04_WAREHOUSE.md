# F04 warehouse release and recovery hold

## Release provenance

This release pairs two separately published application images:

| Component | Application PR | Release run | Verified tag |
| --- | --- | --- | --- |
| CI Dashboard app/jobs, including local cost-freshness safeguards | [ee-apps #876](https://github.com/PingCAP-QE/ee-apps/pull/876) | [42621145003](https://github.com/PingCAP-QE/ee-apps/actions/runs/42621145003) | `v2026.11.8-3-gd7cde2f` |
| Dedicated F04 warehouse worker | [ee-apps #878](https://github.com/PingCAP-QE/ee-apps/pull/878) | [42621120435](https://github.com/PingCAP-QE/ee-apps/actions/runs/42621120435) | `v2026.11.8-2-g462f651` |

The later CI-only release contains both commits but did **not** publish a new
Cost Insight image. Do not invent a `cost-insight-jobs` tag from that run.
All three image tags were verified in GHCR with linux/amd64 and linux/arm64
manifests. F04 uses the immutable multi-platform digest:

`sha256:e2b633b85f3dd814a0227ce2fe7fc70ed0b8b84339e7851f742562db1e36c92a`

The CI Dashboard HelmRelease tag propagates to the existing CronJobs, Jenkins
worker and pod watcher through its existing Kustomize replacements. This includes
`ci-dashboard-data-freshness-check`; its existing BQ enablement, 14-day lookback,
2 GiB budget, exclusions, DB/Lark settings and 09:10 schedule remain unchanged.

## F04 canonical route and separate live hold

The dedicated `cost-insight-sync-aws-f04-billing-summary` has `suspend: false`
in the **new canonical manifest**, after successful historical recovery. Its
existing live repair hold remains untouched by PR preparation and must not be
removed before the controlled adoption below. The old shell/flat-CUR writer is
replaced by the released application's source-scoped warehouse command, direct
`cost-insight-gcp-billing` Workload Identity, explicit warehouse project/us-west1,
and empty impersonation. The application already refreshes attribution and
native publication per day; do not add a second generic attribution refresh.

Preserve the exact specialized identity:

- AWS account `380838443567`, profile `aws_tidb_cloud_f04_v1`;
- `source_table=warehouse-f80fbbe8e8.raw_aws_billing.cur_line_items`;
- tag `user_usedby=prod-us-west-2-f04`, USD, Usage/SavingsPlanCoveredUsage;
- complete products/SKUs, not an EC2-only or account-wide approximation;
- separate failure latch `sync_aws_f04_warehouse_daily`, no automatic failed-run replay.

The F04 reader has a **32 GiB per-query** cap, unlike ordinary AWS/Azure's 2 GiB
cap. Complete monthly controls and summary can be billed separately; the cap is
not a total-run budget. Explicitly accept this application-defined budget before
enabling recurring writes. The freshness check's budget is not increased.

The separately authorized repair run
`f04-380838443567-20261026-20261108-r1` completed at **2026-11-09 21:24:29
Asia/Shanghai**. Its four writing windows, final SELECT-only verifier and
coordinator all succeeded, with zero active/failed Jobs. Full-SKU exact-F04 raw
controls passed for 14/14 usage days (10/26..11/08); summary, attribution and
active serving conserved all four monetary fields. Protected 86-day history
and allocation-rule hashes were unchanged. The active registry source was
migrated to the warehouse while preserving profile and identity metadata.

This OPS PR neither started nor controls that run or changes database rows.
Its completion is evidence for the new routine route, not permission to clear
live holds or merge this PR without operator authorization.

## Live adoption and enablement gates

The existing live F04 CronJob has a temporary
`kustomize.toolkit.fluxcd.io/reconcile=disabled` annotation and `suspend=true`
from the approved repair. **A Git merge alone may not update this held resource.**
Do not remove that hold while an old desired template could be reapplied.

1. After the explicitly approved OPS merge, verify Flux's source artifact contains
   the merged commit and its desired F04 manifest is the reviewed new route.
   While the F04 hold remains intact, wait for `flux-system/apps` Kustomization
   `Ready=True`, `lastAppliedRevision` equal to that verified artifact revision,
   and no `Reconciling=True` condition. A new GitRepository artifact alone does
   not prove the downstream old reconciliation has finished.
   Keep the live CronJob suspended and confirm no old F04 or repair writer is
   active. Accept the F04-specific query budget above.
2. Confirm the registry is the exact active warehouse-routed F04 profile above;
   preserve payer, display/category and available-from. If migration is still
   needed, use the guarded [application SQL](https://github.com/PingCAP-QE/ee-apps/blob/462f6518c4078b6636793000633e0b2a6fd591b5/cost-insight/sql/030_move_aws_f04_to_warehouse.sql)
   only under separate execution approval, never by weakening the profile.
3. Under separate cutover authorization, stage only the reviewed F04 resource's
   **complete new template** into the live CronJob, overriding `suspend: true`
   and explicitly retaining `reconcile=disabled` during staging. Do not stage a
   manifest derived from an old CronJob or clear the hold first. Verify pinned
   image, new command/args, direct-WI SA, BQ project/location/empty impersonation,
   TCMS env, `backoffLimit: 0`, the 23:30 Asia/Shanghai schedule and suspension.
4. Reconfirm complete recovery/publication, exact F04 scope, a clean/non-running
   F04 failure latch and no active old/new/repair writer. Immediately before
   clearing the hold, recheck that the verified artifact includes this OPS
   revision and `flux-system/apps` is Ready, has applied that exact artifact
   revision and is not Reconciling. An older in-flight downstream reconciliation
   must not restore the legacy route.
5. Only then remove this exact CronJob's temporary Flux hold. Let Flux apply the
   already reviewed canonical `suspend: false` route. Preserve `Forbid`, the
   schedule and all other holds; verify the live template and inspect the first
   regular run before declaring normal operation.

The full repair command, per-query bounds, rounding semantics and rollback rules
are in the [application recovery runbook](https://github.com/PingCAP-QE/ee-apps/blob/462f6518c4078b6636793000633e0b2a6fd591b5/cost-insight/docs/f04-warehouse-recovery.md).
If any gate fails, keep F04 held; never roll back by resuming the stale legacy
source, resetting the latch automatically, or deleting validated billing facts.
