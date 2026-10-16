# CI Dashboard: April-onward PR metadata repair

## Status and release gate

**Preparation only. No production repair has been submitted.** Do not merge this
maintenance release until the scoped worker and in-cluster coordinator described
below are reviewed and ready, and an operator approves the maintenance window.
Merging the release does not itself approve launching a repair.

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
The serving workloads' Secret/endpoint must still be matched before execution;
cluster inspection was blocked by expired gcloud authentication.

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
3. **Prepare the missing execution assets before merging this release.** The
   existing image has neither a PR-key-scoped repair CLI nor a durable coordinator.
   Add/review a small worker that reuses snapshot/timeline parsing and idempotent
   upserts, accepts the frozen repo/PR/build scope, avoids `ci_job_state` writes,
   and rejects source/scope drift. Add regression and restart/failure tests. Do not
   substitute the ordinary global sync command.
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
   roughly 85 writing sub-batches before any derived-group subdivision.
6. **Repair metadata before dependent derived fields.** Recover snapshots and
   available commit/retest events for each approved key batch, then refresh branch
   and dependent signals for approved build IDs. Reuse released parsing/upsert
   logic; do not reimport build facts, rebuild unrelated domains or reset normal
   watermarks. Use small transaction chunks (start at 100 rows) and one PR/job
   group at a time for signal recomputation. Preflight group sizes and event counts
   as well as PR counts; split oversized batches before launching them.
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

Only local rendering/validation and SELECT-only inventory have occurred so far.
Server-side dry-run, live rollout checks, worker/coordinator implementation and all
production execution remain pending explicit approval and readiness.
