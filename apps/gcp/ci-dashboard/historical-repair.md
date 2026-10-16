# CI Dashboard: April-onward PR metadata repair

## Status and completion gate

The release was merged as [ee-ops #2469](https://github.com/PingCAP-QE/ee-ops/pull/2469)
on 2026-10-16 at 01:22:38 UTC. The operator also authorized the ad-hoc GKE
repair. It was submitted at approximately 01:36 UTC and runs independently of any
local terminal or agent session.

**Do not merge this schedule-restoration change until the run reports
`state=completed`, all 100 child steps succeeded, and the final read-only
verification passed.** No PR merge is authorized by the repair permission.

### Submitted run and evidence

- Context: `gke_pingcap-testing-account_us-central1-c_prow`; namespace: `apps`.
- Run ID: `ci-prmeta-20260401-20261015-r1`.
- Coordinator Job: `ci-prmeta-20260401-20261015-r1-coordinator`.
- Durable status ConfigMap: `ci-prmeta-20260401-20261015-r1-progress`.
- Immutable assets ConfigMap: `ci-prmeta-20260401-20261015-r1-assets` contains the
  exact worker/coordinator script and compressed frozen scope; no DB credentials.
- Script SHA-256: `7c158b35fb825c052cbd07b9a4d409c4f0a553981bb814d11ad94034b7723bc8`.
- Plan SHA-256: `211d912e661a72d8e19e581e995c4fa912f79f0a1f48d5ea85d7a8a681006453`.
- Frozen scope: 3,300 PRs, 54,773 distinct build IDs; expected 14,574 available
  snapshot/timeline event upserts and 35,607 branch corrections.
- 100 serial steps: 95 with writes (including canary), four empty-window checks,
  and one final full-scope read-only verification. Main windows are at most five
  inclusive dates, at most 50 records per child and 100 build IDs per transaction.
  The canary and subsequent calendar work have disjoint PR/build scopes.
- **Observed canary success:** four snapshots, 10 event upserts, 145 branch
  corrections; all 158 associated builds verified. The other batches were still
  running when this restoration change was prepared.
- 17 local safety tests passed, covering scope/date/repo isolation, idempotence,
  drift rejection, forbidden writes, restart reconciliation and failure stops.
  The coordinator and sample child also passed server-side dry-run.

Only `ci_l1_pr_events` and approved `ci_l1_builds.target_branch` values are written.
The existing flaky/retry-loop computation uses
`REQUIRE_RETEST_FOR_RETRY_LOOP=False`; case evidence also does not depend on PR
metadata. Therefore no manual flag/case/failure-category recomputation is needed.
No `prow_jobs` reimport, source-table repair, schema change or normal-watermark
update is part of this run. Whole-group/out-of-window writes are avoided entirely.

CronJobs have run-owned reconciliation-disable annotations while the repair is
active. On success the coordinator removes its annotations and restores the
pre-run settings, which are **suspended=true** from #2469. This follow-up GitOps
change is needed to resume normal schedules. On failure the holds stay in place;
no later child or uncertain-write retry is launched.

Inspect progress without triggering later batches locally:

```bash
kubectl --context gke_pingcap-testing-account_us-central1-c_prow -n apps \
  get cm ci-prmeta-20260401-20261015-r1-progress -o json
kubectl --context gke_pingcap-testing-account_us-central1-c_prow -n apps \
  logs job/ci-prmeta-20260401-20261015-r1-coordinator --tail=30
```

After resumption, the normal derived job may observe the newly updated PR events;
its existing 5,000-build incremental cap remains unchanged. No generic manual
refresh should be added afterward.

The release updates the application and jobs to `v2026.10.11-12-g35d6248` from
[ee-apps release run 38831184362](https://github.com/PingCAP-QE/ee-apps/actions/runs/38831184362),
commit `35d62488e10ff964cc666b773bd084f762cc3990`, including
[ee-apps #722](https://github.com/PingCAP-QE/ee-apps/pull/722).

Verified multi-architecture index digests:

- `ghcr.io/pingcap-qe/ee-apps/ci-dashboard@sha256:318fe091ac1872fb9f389af51459593a9603985eb38b9511a9dab351719ef17e`
- `ghcr.io/pingcap-qe/ee-apps/ci-dashboard-jobs@sha256:1cc5b3da7751af0a9d5dcb068e3c9ac84374bc59a93c26103498ce7e6b241093`

The normal `sync-pr-events` job now retries every eligible missing snapshot,
independently of its watermarks. Its internal SQL batches are **not** date-window
limits. This release therefore temporarily suspends `ci-dashboard-sync-pr-events`
and `ci-dashboard-refresh-build-derived`. Other ingestion remains enabled.
Suspension does not terminate already-running Jobs; drain those before repair.
Restore both schedules through a follow-up GitOps change after acceptance.

## Read-only inventory

Snapshot: 2026-10-16, starting at 00:55 UTC, configured dashboard database `insight`.
Cluster authentication was renewed before execution. The serving workloads' DB
Secret endpoint, identity and database matched the read-only audited database.

Build-time scope is **[2026-04-01 00:00:00, 2026-10-16 00:00:00)**: complete
calendar dates April 1 through October 15, using stored build timestamps. October
16 is not a complete day and needs a separate closing catch-up.

There are 247,507 build rows, including 234,522 eligible PR builds across 9,406
distinct `(repo, PR)` keys. This is an all-repository inventory, not just TiDB.

| PR metadata status | Distinct PR keys | In-scope builds |
| --- | ---: | ---: |
| Missing snapshot; source pull, branch and timestamp are usable | 3,300 | 54,773 |
| Missing snapshot; no source `github_tickets(type='pull')` row | 3,011 | 21,310 |
| Snapshot branch differs from current source pull branch | 4 | 120 |
| Snapshot present; no source-branch mismatch found | 3,091 | 158,319 |

The directly recoverable 3,300 PRs require 3,300 snapshot upserts, plus available
commit/retest timeline events. Their current timelines contain 70,299 raw items
(about 31.2 MB); **not every raw item becomes an L1 event**. Their 54,773 builds are
associated rows, not all incorrect rows: 35,607 stored `target_branch` values differ
from the source branch (35,577 empty, 30 nonempty). Snapshot recovery also enables
recomputation of retest/flaky/retry-loop signals; count those writes separately.

Those same missing PR keys have 54,775 builds across all history: only two are
outside the audited dates. This is not permission to update outside the approved
scope; record any necessary group expansion in the repair manifest.

For **`pingcap/tidb` alone**:

- 1,220 recoverable missing snapshots, associated with 32,366 builds;
- 127 PRs without a source pull row, associated with 3,655 builds;
- two existing source/snapshot branch mismatches, associated with 84 builds.

### Remaining blockers: not fixed by rerunning the new image

Of the 3,011 source-absent PR keys, 2,401 belong to `pingcap/docs`, `pingcap/docs-cn`
or `PingCAP-QE/ci`, whose PR-event completeness is explicitly outside V1's
requirement (ee-apps business rule BR-05). Do not silently turn these into a new
completeness requirement. The remaining **610 PR keys / 9,065 builds** need source
coverage investigation and upstream repair before they can be reconstructed.
Repeated L1 backfills cannot invent their branch or retest history. Check both
old coverage gaps and recent source freshness; 236 of these keys first appear
in the audited builds on or after October 10.

The four existing branch discrepancies require a separate reviewed repair list:

| Repo / PR | Stored snapshot | Current source branch |
| --- | --- | --- |
| `pingcap/tidb#67525` | `release-7.5` | `test/stabilize-flaky-cases-release-7.5` |
| `pingcap/tidb#70422` | `yiding/statement-ru-terminal-flat-plan-walk` | `master` |
| `pingcap/tidb-operator#6849` | `release-1.4` | `release-1.x` |
| `tidbcloud/cloud-storage-engine#5188` | `cmek-cp-6` | `cloud-engine` |

GitHub's current base refs confirmed the first three. The private fourth PR
returned 404 to the current identity; obtain appropriate verification before
including it. Current PR base metadata is not a point-in-time branch history.

## What does not need rebuilding

The PR/postsubmit eligibility fix and historical case-to-job discovery fix are
read-path changes. They take effect with the API rollout; do not reingest
`prow_jobs` or rewrite `problem_case_runs` for them. Unknown execution denominators
remain N/A. Estimated job-build denominators are **not testcase invocation totals**;
this repair cannot reconstruct uncollected PASS, cache or individual attempt data.

## Small, sequential repair plan

1. **Authorize and verify the target.** Confirm context
   `gke_pingcap-testing-account_us-central1-c_prow`, namespace `apps`, runtime DB
   Secret `ci-dashboard-eq-prd-insight-db`, database endpoint, approved repositories,
   closed date range, source commit and immutable jobs digest above. Re-audit at
   execution time. Renew authentication interactively; never copy credentials into
   the manifest. Do not apply anything before explicit operator authorization.
2. **Freeze the work manifest.** Export only the approved `(repo, PR)` keys and
   build IDs, source branch/timestamp fingerprints, baseline counts and job-state
   watermarks. Keep the 3,300 missing-snapshot keys separate from the four reviewed
   discrepancies and the 610 source-absent blockers. Assign each PR once using its
   first in-scope build date; do not rediscover the same PR in every date window.
3. **Use the reviewed, frozen execution assets.** The released image has neither
   a PR-key-scoped repair CLI nor a durable coordinator. The ad-hoc assets reuse
   released snapshot/timeline parsing and branch enrichment, enforce frozen
   repo/PR/build/date scope and source fingerprints, and reject unrelated writes.
   Do not substitute the ordinary global sync or full backfill command.
4. **Roll out and establish one repair writer.** After authorized merge and Flux
   reconciliation, verify images, API health, both suspended CronJobs and the end
   of their old Jobs. Check for conflicting DB-heavy maintenance. CronJob
   `concurrencyPolicy: Forbid` does not serialize unrelated manual Jobs.
5. **Canary, then proceed automatically in GKE.** Start with TiDB PRs
   `71042`, `71222`, `71289`, `71292` in the September 13–17 selection window:
   158 associated builds, 145 empty target branches at audit time. Verify the four
   snapshots, branch attribution and selected flaky metrics before continuing.
   Partition the full 198-day range into **40 non-overlapping windows of at most
   five inclusive dates**. Initially cap each writing child at 50 frozen PR keys;
   smaller canary and sub-batches are allowed. The current first-build assignment
   has 37 nonempty windows, at most 223 PR keys in one window; a 50-key cap yields
   roughly 85 PR-first-build sub-batches. The actual submitted plan instead enforces
   hard build-date boundaries and a 100-build transaction cap: 95 writing children,
   four empty-window children and one final read-only verification.
6. **Repair only metadata and branch attribution.** Recover snapshots and
   available commit/retest events, then enrich `target_branch` for approved build
   IDs in the child's own date window. No manual signal recomputation is required
   under the released `REQUIRE_RETEST_FOR_RETRY_LOOP=False` policy. Transactions
   have at most 100 build IDs; available events are upserted in chunks of 100.
   Reject more than 1,000 events in a single PR transaction (the frozen maximum
   was 251). Do not reimport build facts or reset normal watermarks.
7. **Stop on failure and reconcile.** A durable in-cluster coordinator creates
   exactly one DB-writing child Job at a time, waits for success, persists the
   completed window/sub-batch and only then creates the next. Use an explicit
   namespace-scoped service account, least-privilege Job/status ConfigMap RBAC,
   deterministic run/child IDs, immutable jobs digest, finite deadlines, resource
   limits, retention and `backoffLimit: 0`. Persist heartbeat/progress at least every
   30 minutes. No local loop, concurrent window fan-out, skipped failures or
   automatic replay of uncertain writes. Review DB effects before an authorized
   restart; reconcile completed Jobs rather than duplicating them.
8. **Verify, repair source gaps, then resume.** Require zero missing snapshots
   among source-ready approved keys, correct branch attribution, no unapproved
   build-fact changes and unchanged normal watermarks. Record actual snapshot,
   timeline, branch and signal write counts, not only selected build counts.
   Recheck the original Subscription/TTL dashboard examples and weekly NULL/N/A
   semantics. Separately repair source coverage for the 610 blocked keys and replay
   their scoped batches. Complete any reviewed branch discrepancies and October 16
   catch-up. Restore both CronJobs in a follow-up GitOps PR and verify incremental
   recovery/freshness. Do not claim all April-onward metadata is complete while
   source-ready or required source-absent exceptions remain.

### Existing CLI limitations and boundary caveats

In the released source (`ci-dashboard/src/ci_dashboard/jobs/`):

- `sync-pr-events` is global and stateful; it has no date or repo/PR CLI options.
- `run_sync_pr_events_for_time_window(...)` is an existing stateless Python helper,
  not a standalone CLI command. Dates choose build-linked PR candidates, not a
  hard date boundary for snapshot/timeline event timestamps. It also processes
  healthy PRs unless a separate approved key scope is enforced.
- `refresh-build-derived-range --start-date ... --end-date ...` exists and is
  stateless, but is not a repo/PR-scoped repair command. Its PR/job-group signal
  recomputation includes the entire group, potentially outside the selected dates.
  Do not truncate the group and thereby change retry/flaky semantics: preflight,
  explicitly approve and record the expanded group scope, or stop.
- `backfill-range` additionally reimports builds; it is unnecessarily broad for
  these defects and must not be used as the shortcut for this repair.
- `render_backfill_job.sh` renders one Job, not a coordinator; its defaults include
  a mutable image, large batches and retries. Do not run its defaults in production
  or invent unsupported `sync-pr-events-range` / `--repo` options.

The run's final verification must pass before schedules are restored. The 610
source-absent non-doc/CI PR keys and four existing branch discrepancies remain
separate unresolved scopes; completing this run is not a claim that those gaps or
uncollected testcase executions have been reconstructed.
