# Four-account ordinary AWS warehouse sync

## Scope and reason

The legacy `cost-insight-sync-aws-billing-summary` CronJob is held on account
`946646677266` to prevent stale legacy data from overwriting validated warehouse
imports. Do not remove that hold or globally change `cost_sources.source_table`:
other import, split-cost, F04, and unmatched-resource consumers use those routes.
The legacy sync/attribution commands in GitOps explicitly retain only account
`946646677266`, matching the existing live restriction, so a future reconciliation
cannot accidentally reintroduce the four ordinary accounts into the old route.
The live legacy CronJob and its migration/Flux hold are not changed by this rollout.

`cost-insight-sync-aws-warehouse-summary` separately covers only:

- `131464424160`
- `296171618728`
- `676546228356`
- `986330900858`

It reads the permanent full-detail relation
`warehouse-f80fbbe8e8.raw_aws_billing.cur_line_items`, never a mart or an expiring
`_stage_*` table. It reuses the released `75cb4d7` query, normalization, scoped
replacement and attribution/publication helpers on the pinned image digest.
The standard AWS CLI does **not** yet expose the warehouse-layout switch; the
mounted, versioned worker supplies that missing recurring route.

Azure, split account `946646677266`, F04, IAM, registry identities, and freshness
thresholds are unchanged.

## Daily behavior

- Run at **15:10 Asia/Shanghai**, after the usual warehouse snapshot publication
  and noon pipelines, with `concurrencyPolicy: Forbid`, no automatic write retry,
  and a finite three-hour deadline.
- For each account, find the newest available usage day no later than yesterday
  UTC, then reread its trailing **five inclusive usage days**. Fetch and validate
  every account's window before changing any cost facts.
- Preserve physical billing-month boundaries and transactionally replace only
  fully fetched account/billing-partition/usage-day scopes. Never replace a
  whole billing month from a five-day read or erase unqueried partitions.
- Merge all normalized rows sharing a canonical source hash, summing all four
  monetary fields and retaining the latest source export timestamp.
- Empty source days are not authoritative zeroes. Refuse invalid scope, currency,
  incomplete windows, changed source snapshots, over-budget queries, or a local
  backlog beyond the rolling window instead of deleting or silently skipping.
- Dry-run every query and enforce **2 GiB per query** without auto-increase.
  The exact separate-account query preflight for October 24–28 estimated
  0.36 / 0.87 / 0.27 / 1.36 GB respectively; all fit the existing cap. These are
  natural account-scoped imports, not subdivisions to bypass an oversized query.
- After each replaced account/day, run the source-scoped attribution command and
  verify summary, attribution and the published native serving version conserve
  currency and all four monetary totals. A successful CLI exit alone is not
  accepted as proof of publication.
- Persist progress and a single-writer/failure latch in `cost_job_state`; stop on
  the first uncertain write. A failed or interrupted run requires inspection and
  an explicitly approved recovery, not an automatic replay at the next schedule.
  Recent/provisional source days are revisited by the rolling window; this is not
  a promise of complete settlement or revision coverage outside five days.

## Safe rollout

1. Compile/test the worker and render the component with `kubectl kustomize`.
2. Preserve all existing legacy migration/Flux holds. Apply **only** the new
   worker ConfigMap and new CronJob, initially suspended. Do not apply the whole
   component over live held legacy objects.
3. Run the same worker in a one-off Job with `--dry-run`, the pinned image and
   existing `apps/cost-insight-gcp-billing` Workload Identity. This mode reads only;
   it must not write even job state.
4. With no conflicting maintenance writer active, run one instance of the exact
   normal CronJob command. It coordinates all account/day steps sequentially
   inside GKE; no local loop submits later windows. Inspect its persisted progress
   and stop on any failure.
5. Before concluding the known October 26 revision and missing October 27–28 data
   were repaired, confirm every account's emitted `plan.windows` covers October
   26–28 (newest source day October 28–30, 2026 inclusive), and verify native
   publication for all three dates. If any date is outside its account's window,
   routine success does not prove its repair; obtain approval for a separate
   historical repair. Skip a separate backfill only after confirming all three
   dates were repaired for every account.
6. Unsuspend the daily CronJob only after validation. Keep the immutable worker
   content and this operational configuration under GitOps review; no PR merge is
   implied by the live rollout authorization.

`python .../sync_aws_warehouse_daily.py --dry-run` is the read-only preflight mode.
Run focused tests with the existing Cost Insight Python environment:

```bash
python -m unittest discover \
  -s apps/gcp/cost-insight/scripts \
  -p 'test_sync_aws_warehouse_daily.py'
```

## Initial validation — 2026-10-30

- Existing image digest and direct billing Workload Identity were verified.
- GKE read-only Job `cost-aws-warehouse-preflight-20261030-062748` completed;
  independent before/after SELECTs confirmed no changes to facts, publication
  pointers, registry or routine job state.
- Normal-command Job `cost-aws-warehouse-routine-verify-20261030-064449` completed
  at approximately 14:52 CST, using exactly the daily command with no historical
  date overrides. It discovered October 25–29 for all four accounts and verified
  all **20 account-days** sequentially inside GKE.
- Source/canonical summary, attribution and active native publication conserved
  all four monetary totals. All four local and published watermarks reached
  **October 29**; the known October 26 revision and October 27–28 gaps were repaired.
  No separate historical backfill was needed. October 29 remains provisional and
  is reread by the next rolling run.
- October 24 sibling facts/pointers, registry identities, and the held legacy
  split/F04/Azure CronJob specs/annotations remained unchanged.
- Twenty-eight offline tests passed; worker statement/branch coverage was **98%**.
  Independent DeepSeek adjudication left no open or deferred findings.
- The daily schedule was enabled after these gates passed. No PR was merged by
  the operator; the live rollout and GitOps review are separate authorizations.

## Rollback / failure

Suspend only `cost-insight-sync-aws-warehouse-summary`; do not restore stale legacy
account coverage, delete validated facts, remove a migration hold, or clear the
failure latch without inspecting the exact failed account/day and obtaining a
recovery decision. Preserve Job logs and the progress watermark for diagnosis.
