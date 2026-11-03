# Alibaba warehouse cutover — 2026-11-03

## Incident and desired configuration

The legacy `gcp-digital-bi.alibaba_cloud.daily_en_*` export stops at October 12.
The daily importer still returned success for empty export partitions and advanced
its watermark through October 28. Existing summary and attribution stopped at
October 26; the November 3 morning check correctly reported a two-day eligible
import gap. A previous one-off repair did not migrate the recurring importer.

Keep the existing `cost-insight-sync-alibaba-billing-summary` CronJob and its
summary → account-scoped attribution/native publication flow. Change only its
billing connection and image:

- Source: `warehouse-f80fbbe8e8.raw_alibaba_billing.daily_en_*`.
- Query project/location: `warehouse-f80fbbe8e8` / `us-west1`.
- Identity: existing `apps/cost-insight-gcp-billing` KSA, directly bound to the
  warehouse GSA; explicitly disable impersonation. No IAM or secret changes.
- Image: official main release `v2026.10.25-49-ge71fd92`,
  [release run 41154954036](https://github.com/PingCAP-QE/ee-apps/actions/runs/41154954036),
  immutable multi-platform digest
  `sha256:fd11e3b746524bd048f2ce90e181ba85ba0be61a25bd8a1c85f8c8b76a89cd77`.
- Preserve 12:50 Asia/Shanghai, account `5028760335873601`, five-day export lag,
  zero-day overlap, earliest usage June 1, DB secret and resource limits.

Do not route Alibaba through `sync-warehouse-billing-summary`: that command
supports AWS/Azure only. Do not change the dormant Azure subscription, registry,
other importers, freshness thresholds or existing Flux migration holds.

## Read-only preflight — 2026-11-03

GKE Job `apps/cost-alibaba-wh-preflight-20261103` completed with the exact pinned
image and direct warehouse identity. The existing importer query read October
26–29: 540 normalized rows, including 14 each for October 27/28/29. Estimated and
actual scan were both 392,472,337 bytes, below the fixed 2 GiB cap. All 498 October
26 identities and their four monetary fields matched the existing summary.
The importer dry run wrote zero rows; before/after snapshots of scoped facts,
native publications, registry and job state were identical. This validates reads,
not production writer success. The recurring CronJob has not been changed live.

## Deployment and outstanding repair

1. Obtain explicit ops PR merge approval. Before targeted reconciliation, confirm
   no Alibaba writer is active. Do not resume held components or apply the entire
   shared `cronjobs.yaml`; reconcile only the approved Alibaba resource.
2. Verify the live image digest, source, project/location and KSA. A read-only
   preflight must use this exact released image and identity, compile/run the
   existing Alibaba query with a fixed 2 GiB cap, observe nonempty October 27/28
   data, and leave registry, facts and job state unchanged.
3. Explicitly repair export partitions **October 27–28** in a scoped GKE Job,
   followed by the same account-scoped attribution/publication refresh used by
   the CronJob. Preview with `--dry-run`; do not use `--limit` for the writer.
   Use the pinned digest, `backoffLimit: 0`, a finite deadline and no concurrent
   Alibaba writer. Recheck the current watermark immediately before submission:
   explicit-date imports overwrite it, so never run an old repair end date after
   a newer routine run. If it has advanced, include those already-processed export
   dates through the current watermark, in sequential windows of at most five
   days, rather than regressing or manually editing the watermark.
4. Verify nonzero imported rows, daily source/summary/attribution amounts and
   native publication conservation for the repaired dates. Observe the next
   scheduled run writing new rows, not merely exiting successfully. Run the
   freshness collector read-only without notifications. MAX dates alone do not
   establish historical completeness; do not claim all earlier dates are repaired.

Preparing this configuration does not execute the repair or change production.
If rollout fails, suspend only the affected Alibaba CronJob for investigation;
do not restore the stale legacy source or delete validated cost facts.
