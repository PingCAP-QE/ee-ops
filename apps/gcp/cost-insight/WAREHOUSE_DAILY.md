# AWS / Azure warehouse daily jobs

## Application image, not mounted workers

Both CronJobs use `cost-insight sync-warehouse-billing-summary` from the application
image. Query adaptation, validation, scoped replacement, attribution and native
publication live in `ee-apps/cost-insight`, not an ops ConfigMap.

- Application: [ee-apps #804](https://github.com/PingCAP-QE/ee-apps/pull/804),
  commit `22d4063cf63c274740947a57e226c559d9ba2466`.
- Published before this ops change by
  [official release run 41051780499](https://github.com/PingCAP-QE/ee-apps/actions/runs/41051780499).
- Multi-platform digest (amd64 + arm64):
  `sha256:48ed49f38d58be3c0ac6b40d15ad96424e88d79c9cdc0a0ecb76f8c8dde40cee`.
- The application PR remains a separate review/merge gate; publishing its reviewed
  branch image does not imply that the application or ops PR has been merged.

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

## Migration checks — 2026-10-30

- Application tests: 693 passed / 91.83% full line coverage; 141 new source/runner
  tests / 96.67% combined statement+branch coverage. DeepSeek review CLEAN.
- New-image **read-only** GKE Jobs completed successfully:
  `cost-wh-image-preflight-aws-20261030-1204` and
  `cost-wh-image-preflight-azure-20261030-1204`.
- All five identities validated October 25–29. Maximum query estimates/actuals:
  AWS 991,309,371 bytes, Azure 132,416,142 bytes; both below 2 GiB.
- Independent before/after SELECT snapshots were identical for summary facts,
  attribution, native publication pointers, registry and both routine job states.
  These are dry-run results, **not** new-image writer/publication validation.
- Existing mounted-worker routes remain enabled and successful during PR review.
  Earlier normal runs repaired all five identities through October 29 without a
  separate backfill. No new-image writer or CronJob switch is implied here.

## Switch and recovery

1. Complete application/ops review and obtain explicit merge authorization.
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
