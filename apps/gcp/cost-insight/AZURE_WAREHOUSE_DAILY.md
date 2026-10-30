# Active Azure subscription warehouse sync

## Scope

Restore daily coverage only for `aaa5414d-7537-4e24-99bd-a7a841221810`.
The existing `cost-insight-sync-azure-billing-summary` remains suspended under
its stale-source migration/Flux hold. Its GitOps `suspend: true` mirrors the
existing live safety state. The manual rollout applies only the two new objects,
not that old object. The GitOps component still includes legacy resources: before
merge/reconciliation, confirm their declared states match the intended live
holds, and preserve the old object's `reconcile: disabled` annotation. Do not
mistake the narrow manual apply for a promise that the component contains only
new resources.

Subscription `abd27163-b965-4217-8cba-2a4c799579fe` remains active in the registry
but has no observed consumption after June 24. Do not backfill, deactivate or
exclude it without owner confirmation. This worker never writes that identity.
AWS/split/F04 routing, registry, IAM and freshness thresholds remain unchanged.

## Source and normal daily behavior

- Use only the permanent numeric MCA month tables in
  `warehouse-f80fbbe8e8.raw_azure_billing`, such as
  `azure_billing_cost_20261001`. Do not query the mixed-schema wildcard directly:
  BigQuery may resolve its schema against an EA `cn_`/`us_` table even with a
  numeric suffix filter. Generate explicit numeric monthly relations from dates
  and synthesize `_TABLE_SUFFIX` for the released Azure query builder.
- Reuse the immutable released `75cb4d7` image's Azure-specific normalization,
  tenant/tag/hash rules, partition/day replacement, and scoped attribution/native
  publication helpers. No new warehouse table/view, IAM or container release.
- Daily schedule: **16:10 Asia/Shanghai**, after the 15:10 AWS writer. The committed
  manifest is enabled after the October 30 verification. A fresh rollout must
  override it to suspended before repeating the gates below.
  `Forbid`, `backoffLimit: 0`, finite 90-minute deadline, existing billing KSA.
- Find the latest actual usage date no later than yesterday UTC, within a bounded
  14-day discovery. Reread its trailing five inclusive days; recent billings are
  provisional and must be revisited. This is not a settlement audit outside the
  window. Reject a local watermark backlog the window cannot cover.
- Every BigQuery read is dry-run first and has the unchanged **2 GiB/query** cap,
  finite timeouts and no unbounded retries. The exact October 25–29 normalized
  query estimated **132,416,142 bytes**. Never auto-increase the cap.
- Fetch and validate the complete window before changing cost facts. Validate
  permanent table metadata/snapshot stability, exact subscription, USD, numeric
  money, source controls and daily coverage. Empty data is not authoritative zero.
- Merge canonical source-hash collisions across the complete result, summing all
  four monetary fields. Transactionally replace only the fetched subscription /
  billing-partition / usage-day scopes, preserving sibling days and unqueried
  billing partitions. Run the exact subscription/day attribution command and
  verify summary, attribution and active native publication conserve currency,
  canonical source counts and all four monetary totals.
- One GKE Job owns sequential day execution. Persist progress and an atomic
  single-writer/failure latch in the existing `cost_job_state`. Stop on the first
  uncertain write; do not replay a failed/interrupted run at the next schedule.

## Rollout and validation

1. Run offline tests and independent review; render Kustomize and server dry-run.
2. For a fresh rollout, render only the new ConfigMap and new CronJob, explicitly
   set `spec.suspend: true` in that temporary rollout payload (the committed
   manifest is already enabled), and verify the override before applying. Preserve
   all legacy migration/Flux holds; never apply the whole component over held live
   objects. Proceed with the enabled committed state only after re-passing gates.
3. Run the exact worker in GKE with `--dry-run`: it must not write even job state.
   Independently compare before/after fact, pointer, registry and state snapshots.
4. Check no conflicting cost maintenance writer is active, then run the normal
   CronJob command once without historical date overrides. All days execute
   sequentially inside GKE, not by local scheduling.
5. Confirm the actual emitted window includes October 27–29 and independently
   verify source/summary/attribution/native publication. The October 27 revision
   and missing October 28–29 are repaired only if all these dates pass, regardless
   of a Job's exit code. Do not create a separate backfill if the normal reread
   catches up. If any date falls outside the window, obtain a separate repair
   decision instead of silently claiming completion.
6. Enable the daily schedule only after validation, setting `spec.suspend: false`
   in `apps/gcp/cost-insight/azure-warehouse-cronjob.yaml` as well as applying the
   verified new runtime resources. Never leave the reviewed manifest suspended
   while enabling only live. Submit the matching GitOps PR; durable Flux ownership
   requires its separately authorized merge and reconciliation. Confirm both the
   merged manifest and live CronJob are enabled afterward. Live deployment
   authorization is not PR merge authorization; leave PRs unmerged without
   explicit approval.

Focused offline tests use the existing Cost Insight Python environment:

```bash
python -m unittest discover -s apps/gcp/cost-insight/scripts \
  -p 'test_sync_azure_warehouse_daily.py'
```

## Initial rollout verification — 2026-10-30

- All 31 focused offline tests passed; worker line coverage **99.72%**, combined
  statement/branch coverage **99.40%**. Seventy-two existing source/replacement/
  attribution/publication helper tests also passed.
- Independent DeepSeek review/adjudication left no unresolved correctness issues.
  The fail-closed latch on preflight errors is deliberate and documented below.
- Final-code read-only Job `cost-azure-wh-final-preflight-20261030-081614` completed.
  Independent before/after SELECTs confirmed no fact, publication, registry,
  dormant-subscription or routine-state changes.
- Exact normal-command Job `cost-azure-wh-routine-verify-20261030-081659` completed
  at approximately **16:18 CST**. It discovered **October 25–29** and verified
  all five days sequentially in GKE, without historical date overrides.
- Source controls, canonical summary, attribution and active native publication
  conserved USD and all four monetary totals. October 27's partial-day deficit
  and missing October 28–29 were repaired by the normal rolling reread; **no
  separate historical backfill was needed**. October 29 remains provisional.
- The dormant subscription's historical facts and native pointers, both registry
  identities, October 24 sibling data, and all pre-existing cost CronJob specs/
  holds remained unchanged.
- Daily enablement is persisted in this change as well as applied live only after
  these gates passed. The matching GitOps PR still requires separate merge
  authorization; do not describe an open PR as merged/Flux-reconciled.

## Rollback / uncertain write

Any exception after write-mode admission sets `cost_job_state.last_status` to
`failed`, even during read-only preflight before any cost facts change (for
example, a transient BigQuery error, stale/empty source, a missing month table or
an excessive backlog). Subsequent scheduled runs refuse admission until explicit
operator recovery; source recovery alone does not clear the latch. `--dry-run`
remains available without changing the latched state. A process/pod interruption
or the 90-minute Job deadline can instead leave `last_status='running'`; this also
blocks admission and requires inspection. The Job deadline is an intentional
outer resource limit, not a guarantee that every internal operation can consume
its individual maximum timeout in one run.

Suspend only `cost-insight-sync-azure-warehouse-summary`, persisting
`spec.suspend: true` in its GitOps manifest so Flux does not undo the hold. Inspect
the persisted phase/window/day, source controls, database effects and progress
before any explicitly approved recovery. Do not clear a failure latch, resume the
old source, mutate registry identities or delete validated data as an automatic
rollback.
