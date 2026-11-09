# AWS / Azure warehouse daily jobs

## Application image, not mounted workers

Both CronJobs use `cost-insight sync-warehouse-billing-summary` from the application
image. Query adaptation, validation, scoped replacement, attribution and native
publication live in `ee-apps/cost-insight`, not an ops ConfigMap.

The following is the initial migration baseline; the Azure-only update is recorded below.

- Application: [ee-apps #804](https://github.com/PingCAP-QE/ee-apps/pull/804),
  merged on 2026-10-31 as `e71fd9245fd3084d198cbfb1b3ea91053da67847`.
- Official main release:
  [run 41154954036](https://github.com/PingCAP-QE/ee-apps/actions/runs/41154954036),
  tag `v2026.10.25-49-ge71fd92`.
- Multi-platform digest (amd64 + arm64):
  `sha256:fd11e3b746524bd048f2ce90e181ba85ba0be61a25bd8a1c85f8c8b76a89cd77`.
- The `cost-insight/` source tree is identical to preflighted branch commit
  `7e7ccd86d09b4e472fab2af57043b8f2c697dbe4`. This pin uses the merged main
  release, not the earlier branch image. The ops PR still requires its own merge
  authorization; source equivalence is not runtime validation of the new digest.

| CronJob suffix | Schedule (Asia/Shanghai) | Explicit source identities |
| --- | --- | --- |
| `sync-aws-warehouse-summary` | 15:10 daily | `131464424160`, `296171618728`, `676546228356`, `986330900858` |
| `sync-azure-warehouse-summary` | 16:10 daily | `aaa5414d-7537-4e24-99bd-a7a841221810` |

Source project/location are explicit env settings; credentials reuse
`apps/cost-insight-gcp-billing` Workload Identity. There are no new secrets or IAM
changes. Split account `946646677266`, F04, dormant Azure
`abd27163-b965-4217-8cba-2a4c799579fe`, registry identities and freshness thresholds
remain unchanged. The legacy AWS restriction and existing live legacy Azure
suspension are retained; never resume stale importers to restore coverage.

The application rereads five usage days ending at the latest actual source date
no later than UTC yesterday. It uses permanent raw sources, a fixed 2 GiB/query
cap, stable snapshots, canonical aggregation and exact billing-partition/day
replacement. Empty days and oversized backlogs fail closed. Each day verifies
summary → attribution → active native publication before continuing. Recent dates
remain provisional; revisions older than five days require a separate repair.
See the application README for the complete command contract and its tests.

## Azure account-default release — 2026-11-09

Only `sync-azure-warehouse-summary` advances to application
[ee-apps #875](https://github.com/PingCAP-QE/ee-apps/pull/875), merged as
`20e7d9e7042d12eea0268889066fd03e0fca33ab`. AWS and every other CronJob retain
their existing images, schedules, source identities and suspension/Flux holds.

- Release: [run 42588674762, attempt 2](https://github.com/PingCAP-QE/ee-apps/actions/runs/42588674762/attempts/2).
- Verified tag: `v2026.11.8-1-g20e7d9e`.
- Verified amd64 + arm64 manifest digest:
  `sha256:d1df62338074852d0c8b828ee1835a4f69d6b22b5e6dda37f7a1feeebc7a4694`.
- Attempt 1 was green but its push was canceled and neither release tag existed;
  attempt 2 completed both platform pushes and published the verified manifest.
- This enables explicit same-account `{}` TCMS default allocations with non-NULL
  owners, including allocation `1030863` for the Azure subscription above.
- Application validation: 742 tests passed, 91.82% total coverage; the independent
  DeepSeek review/fix/verification loop has no open issues.
- This image-only release does not backfill history. After rollout, the approved
  account-scoped historical refresh from 2026-09-01 must run separately through
  the latest imported usage date, in sequential in-GKE batches, preserving all
  four monetary fields and verifying owner/service/project and native publication.

## Migration checks — 2026-10-30

- Application tests: 705 passed / 91.82% full line coverage; 168 focused
  source/runner/vendor tests / 95.51% combined statement+branch coverage across
  four affected runtime modules. The requested Codex → pi-DeepSeek review loop
  finished round 1 CLEAN with no findings. Source-freeze/failure policies unchanged.
- Pre-merge branch-image (`7e7ccd86`) **read-only** GKE Jobs completed successfully:
  `cost-wh-simple-preflight-aws-20261030-1336` and
  `cost-wh-simple-preflight-azure-20261030-1336`.
- The discovery raw controls are reused for the five-day window: actual source
  queries decreased from 15 to 10 across all five accounts (AWS 8, Azure 2).
  Duplicate guard/audit calls and SQL text replacement were removed without
  removing per-write snapshot checks or active-publication verification.
- All five identities validated October 25–29. Maximum query estimates/actuals:
  AWS 991,309,371 bytes, Azure 132,416,142 bytes; both below 2 GiB.
- Independent before/after SELECT snapshots were identical for summary facts,
  attribution, native publication pointers, registry and both routine job states.
  These are branch-image dry-run results, **not** runtime validation of the merged
  main-release digest or writer/publication validation.
- At the 2026-10-30 checks, the mounted-worker routes were enabled and successful.
  Earlier normal runs repaired all five identities through October 29 without a
  separate backfill. No new-image writer or CronJob switch is implied here.

## Switch and recovery

1. The application PR is merged; complete ops review and obtain explicit merge
   authorization before deployment.
2. Before reconciliation, verify neither old warehouse job is active and preserve
   every legacy-source migration/Flux hold. Do not overlap old/new writers. Any
   manual cutover must target only these two CronJobs, not the held component.
3. Verify the live templates use the pinned image and application command. The
   Azure template's old mounts are owned by `kubectl-client-side-apply`, not Flux:
   a server-side adoption dry run **retains** them even though this manifest has
   none. After the image/command switch is approved and no old pod is active,
   remove only those legacy fields (check they still refer solely to `worker`):

   ```bash
   kubectl --context gke_pingcap-testing-account_us-central1-c_prow -n apps \
     patch cronjob cost-insight-sync-azure-warehouse-summary --type=json \
     -p='[{"op":"remove","path":"/spec/jobTemplate/spec/template/spec/containers/0/volumeMounts"},{"op":"remove","path":"/spec/jobTemplate/spec/template/spec/volumes"}]'
   ```

   This is a one-time adoption step, not a new scheduler/worker. AWS mounts are
   already Flux-owned and their removal was verified by server-side dry run.
   Confirm both templates have no mounts, then remove the leftover manually
   deployed Azure worker ConfigMap only when no live/running pod references it.
   No cleanup patch or ConfigMap deletion has been executed during PR preparation.
4. Inspect the first normal application run: five sequential verified days per
   account, final 100% state, and all-four-money native publication conservation.
   Do not assume read-only preflight proves writer success or launch a backfill
   merely because the implementation moved into the image.

Existing `cost_job_state` keys `sync_aws_warehouse_daily` and
`sync_azure_warehouse_daily` preserve admission/failure protection across migration.
A running/failed state blocks another writer without automatic replay. Inspect
its exact account/day and uncertain effects before an explicitly approved repair
or latch release. Retain Job logs and state evidence.

Rollback means suspending only the affected warehouse CronJob while investigating;
do not undo validated facts, broaden old-source coverage, or clear its latch.
Simply pinning the old image cannot work: it does not contain the new CLI.
