# Tencent Pod lifecycle watcher

One shared `ci-dashboard-jobs watch-pods` instance in `ee-cd`, on native
`compute-class: ee-application` capacity. No CLS, Cloud Logging sync, Dashboard
server, PVC access, or scheduled reconciliation job is introduced here.

Application change: [ee-apps#752](https://github.com/PingCAP-QE/ee-apps/pull/752),
merge `5b10a0bc5bc6199421d5a2cfd931685180e1a7d9`.

## Rollout prerequisites

1. The jobs image is pinned by immutable multi-platform registry digest in
   `deployment.yaml`. Successful [release attempt 2](https://github.com/PingCAP-QE/ee-apps/actions/runs/40099209456/attempts/2)
   published `v2026.10.18-28-g5b10a0b`; both app/jobs tags and their amd64/arm64
   manifests were verified in GHCR. No `latest` or inferred date-based tag is used.
2. On 2026-10-25, with operator approval, the five DB fields from GCP Kubernetes
   Secret `apps/ci-dashboard-eq-prd-insight-db` were securely copied to version 1 of
   Secret Manager item `tencentcloud_ci_dashboard_db_json` in
   `pingcap-testing-account`. Read-back matched the source; no values were printed,
   put in Git, passed as shell arguments, or saved in local files. The existing
   `ee-gcp-sm` store supplies this item to the Tencent-local Secret after sync.
   JSON fields: `TIDB_HOST`, `TIDB_PORT`, `TIDB_USER`, `TIDB_PASSWORD`, `TIDB_DB`.
3. Verify ExternalSecret readiness after sync. The explicit template emits only
   DB variables and the image's system CA bundle, not unrelated GCP collector
   configuration. The CA path enables certificate and hostname validation in
   the shared PyMySQL connection setup.

Reuse of the existing Dashboard DB account was explicitly approved; no new DB
account or GRANT is introduced. Its existing permissions include global
SELECT/INSERT/UPDATE. This is a credential snapshot, not automatic synchronization
from the GCP Kubernetes Secret: when rotating the shared credentials, update the
Secret Manager version too, wait for ExternalSecret refresh, and roll the watcher
to reload its environment. Do not revoke the shared account when stopping Tencent.

## Collection scope

The initial deployment intentionally watches all eight verified CI namespaces,
not a single-namespace canary:

- `prow-test-pods`
- `jenkins-agents`
- `jenkins-pd`
- `jenkins-ticdc`
- `jenkins-tidb`
- `jenkins-tiflash`
- `jenkins-tiflow`
- `jenkins-tikv`

The `jenkins` controller namespace is excluded. RoleBindings target each listed
namespace; do not add a Kustomize-wide `namespace:` override that would move them
all to `ee-cd`. The ServiceAccount has only namespaced Pod/Event get/list/watch.

Source identity: `tencent:ap-beijing:cls-9zpon9y1`.
The independent state key is `ci-watch-pods:tencent:ap-beijing:cls-9zpon9y1`.

Keep one replica with Recreate. GCP deployments and their RBAC are untouched.
A `minAvailable: 1` PodDisruptionBudget and the pod's Karpenter
`do-not-disrupt` annotation protect against eviction-based voluntary disruption.
Forced/involuntary disruption and Recreate updates can still interrupt collection.

## Preflight evidence (2026-10-24 UTC)

A temporary non-root diagnostic Pod in `ee-cd`, using the same application-node
selector, connected to the existing Dashboard TiDB endpoint with a trusted
previous jobs release used strictly as a DB client, not as a watcher:

- TKE `DescribeClusters` in `ap-beijing` confirmed cluster `cls-9zpon9y1` is
  named `pingcap-ee`, Kubernetes version `1.34.1`.
- DNS and authentication succeeded.
- TLS 1.3 (`TLS_AES_128_GCM_SHA256`), certificate chain and hostname verified.
- SELECT and required columns verified on `ci_l1_builds`, `ci_l1_pod_events`,
  `ci_l1_pod_lifecycle`, and `ci_job_state`.
- INSERT and UPDATE verified on the three collector-owned tables inside one
  transaction, then rolled back and checked: zero persistent probe rows.
- All three writable tables report transactional InnoDB engines.
- Temporary Pod deleted; no watcher was started and no business row was changed.
- Read-only recent-key audit: all 2,598 Tencent Jenkins builds in the preceding
  three days used the expected `do.pingcap.net` key prefix.

This proves network/TLS and the tested profile's table access. It is not a claim
that the new watcher has already run, a different future credential is tested,
or every historical correlation key is valid.

## Published-image verification (2026-10-25 UTC)

A temporary Pod in `ee-cd` pulled the exact pinned jobs image and imported the
jobs CLI as UID 65532 with a read-only root filesystem. Its runtime context
accepted the deployed Tencent environment and returned cloud `TENCENT` and state
key `ci-watch-pods:tencent:ap-beijing:cls-9zpon9y1`; the CA bundle was present.
No DB credentials or watcher loop were used, and the temporary Pod was deleted.

## Observation and shutdown

After deployment, verify all eight Pod/Event streams, readiness, fresh source
rows, real creation timestamps and expected build linkage. Measure actual
Tencent outbound traffic/DB load; do not treat the old traffic placeholder as a
measured budget. Kubernetes Events remain best-effort and first-container start
is not whole-Pod Ready.

Run the agreed observation for 1–2 months from the actual deployment date. Record
that date and the review/stop owner when enabling it. If collection is stable and
startup timings are acceptable, use a reviewed GitOps change to scale only this
Deployment to zero or remove this app. Adjust any source-specific alerts. Do not
stop GCP collection, delete TiDB history, or change retention as a side effect.
The app's removal may prune its Kubernetes resources/Secret, not database rows.
