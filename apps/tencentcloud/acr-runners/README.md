# ARC runner scale set for `PingCAP-QE/test-infra` and `PingCAP-QE/endless`

GitHub Actions Runner Controller (ARC) scale set in the `tencentcloud` cluster.
It replaces the `arc-runner-set` runners these two repositories currently use
from the `tiworkload-migration` group, once the runner image can carry their
tooling (see [limitations](#limitations)).

The scale set registers at organization scope because one scale set can only
register at a single `githubConfigUrl`, and it serves two repositories. The
runner group `tencentcloud-private-ci` is what limits it to those two.

The KSY (`prod2`) cluster has its own ARC deployment for `pingcap/tiup`; see
[`apps/prod2/acr-runners`](../../prod2/acr-runners/README.md).

## Layout

```text
apps/tencentcloud/acr-runners/
├── kustomization.yaml      # namespaces.yaml, controller/, scale-sets/
├── namespaces.yaml         # arc-systems (controller/listener) + arc-runners (runners), PSA restricted
├── controller/             # ARC controller, chart 0.15.1, CRD upgrades enabled
│   ├── kustomization.yaml
│   └── release.yaml
└── scale-sets/
    ├── kustomization.yaml  # lists the scale sets
    └── pingcap-qe-private/
        ├── kustomization.yaml
        ├── scale-set.yaml          # HelmRelease arc-runner-set-pingcap-qe-private
        └── github-app-secret.yaml  # ExternalSecret for its GitHub App credentials
```

The OCI HelmRepository (`actions-runner-controller-charts`) lives in
`clusters/tencentcloud/sources/helm-repo-actions-runner-controller.yaml`, with
the other upstream chart sources of this cluster.

One directory per scale set keeps the HelmRelease and the ExternalSecret that
must change together next to each other, so a new runner set is a new directory
plus one line in `scale-sets/kustomization.yaml`.

## Dependencies

1. `sources` → `infrastructure` → `apps` (`clusters/tencentcloud/00-sources.yaml`,
   `01-infrastructure.yaml`, `02-apps.yaml`), so the HelmRepository, the
   external-secrets controller and the `ee-gcp-sm` ClusterSecretStore exist
   before this directory is applied.
2. `arc-runners` must stay in the `ee-gcp-sm` namespace allowlist
   (`infrastructure/tencentcloud/external-secrets/post/css-ee-gcp-sm.yaml`),
   otherwise the ExternalSecret cannot read its credentials and the CI
   `inventory` job fails on the drift.
3. The GCP secrets (`gha__system__*`,
   `arc__org__pingcap-qe__github_app_installation_id`) are created out of band
   and must exist before the ExternalSecret can sync.
4. The scale-set HelmRelease `dependsOn` the `arc` HelmRelease in `arc-systems`:
   the chart renders an `AutoscalingRunnerSet`, so the ARC CRDs and the
   `arc-gha-rs-controller` ServiceAccount must exist first.
5. The runner pods mount the Secret produced by the ExternalSecret. If the scale
   set installs before that Secret exists, the pod sits in
   `CreateContainerConfigError` for a few seconds and then starts; the Helm
   release itself does not fail.

## GitHub identity

- The scale set authenticates as the `ti-chi-bot` GitHub App (id `214286`).
  Credentials are managed in GCP Secret Manager and only the `arc-runners`
  namespace can read them through the `ee-gcp-sm` ClusterSecretStore.
- The app is installed per account, so the installation ID is the `PingCAP-QE`
  organization installation (`36729937`), read from
  `arc__org__pingcap-qe__github_app_installation_id`.
- Registration is `https://github.com/PingCAP-QE` with
  `runnerGroup: tencentcloud-private-ci` (group id `6`, `visibility: selected`,
  `allows_public_repositories: false`), whose members are `PingCAP-QE/test-infra`
  and `PingCAP-QE/endless`. **That group is GitHub state, not Git state**: adding
  a repository is an organization-admin action, and a repository outside the
  group cannot use the label at all.
- The label is the HelmRelease name, so workflows select it with
  `runs-on: [arc-runner-set-pingcap-qe-private]`.

## Cluster-specific notes

- **Placement is two-tier.** Runner pods go to the Karpenter pool
  `compute-class: ci-worker`, which scales from zero and caps a single node at
  64 vCPU. The controller and the listener are long-running and only talk to
  GitHub, so they sit on `compute-class: ee-application`; an idle `ci-worker`
  pool can then consolidate to zero without taking the controller with it. The
  virtual-kubelet `eklet` node carries a `NoSchedule` taint, so nothing lands
  there.
- **Runner image is `ghcr.io/pingcap-qe/ci/actions-runner`**, the same public
  GHCR image the `prod2` scale sets use (upstream runner plus make, GNU tar,
  wget, xz and zip), so no `imagePullSecrets` are needed. Nothing is pre-pulled:
  Karpenter nodes are short-lived, and the image layers stay cached on a node
  for as long as it lives.
- **Both namespaces are PSA `restricted`.** The controller, listener and runner
  containers run non-root with a dropped capability set and a `RuntimeDefault`
  seccomp profile.
- **No `NetworkPolicy`.** This cluster does not enforce one for these
  namespaces; the runner group membership is the access boundary instead.

## Adopting it from a workflow

The scale set is the base environment; wiring a repository's workflows to it is
the repository maintainer's call. For a job that qualifies:

```yaml
runs-on: [arc-runner-set-pingcap-qe-private]
```

- The repository must be a member of the `tencentcloud-private-ci` runner group
  (organization admin action, not a Git change).
- The job must not need a Docker daemon (`services:`, `docker/*` with a daemon,
  `docker/setup-buildx-action`), a C compiler, Python 3, `pip`, or `apt-get`
  with root/sudo. Anything it does need must either be in the runner image or be
  installed by an `actions/setup-*` action into the runner's tool cache.
- Jobs that do not qualify yet keep their current label; see
  [limitations](#limitations).

## Limitations

The `test-infra` and `endless` workflows currently expect a runner that also
provides a Docker daemon (`services:` containers, `docker/setup-buildx-action`),
the buildx plugin, `gcc`, `python3` and `pip`, plus root or sudo for `apt-get`.
This runner has none of that: the namespace is PSA `restricted`, the container
runs as uid 1001, and the image ships only the upstream runner plus the basic
build/archive tools.

So until that is addressed, these keep running on `arc-runner-set` in the
`tiworkload-migration` group, and switching a job to
`runs-on: [arc-runner-set-pingcap-qe-private]` would fail at the missing tool or
at `docker`:

- `PingCAP-QE/test-infra`: `pr-check` (`services:` MySQL container);
  `integration-ci`, `dm-caselib-ci`, `dumpling-caselib-ci`,
  `lightning-caselib-ci`, `starter-v2-caselib-ci`, `ticdc-caselib-ci` (`make`
  targets plus `apt-get` tool installation); `brie-caselib-ci`,
  `lightning-specialized-ci` (image publishing through buildx)
- `PingCAP-QE/endless`: `pr-check` and `integration-ci` (buildx with a buildkit
  image, so also a Docker daemon)

Closing the gap needs two changes outside this directory: a runner image with
the toolchain (and Docker/buildx) in `PingCAP-QE/ci`, and a `privileged`
namespace with a Docker-in-Docker sidecar (or a mounted daemon socket) for the
publishing jobs. `integration-ci` and `pr-check` alone could be served by a
fatter image without Docker only if their `services:` block and buildx steps are
split out first.

## Verify

```bash
kubectl --context tke-pingcap-cicd -n arc-systems get hr arc
kubectl --context tke-pingcap-cicd -n arc-runners get hr
kubectl --context tke-pingcap-cicd -n arc-runners get autoscalingrunnerset
kubectl --context tke-pingcap-cicd -n arc-runners get externalsecret
kubectl --context tke-pingcap-cicd -n arc-runners get pod -o wide   # empty when idle
```

The `AutoscalingRunnerSet` must be `Running`, and the listener logs should show
an `actions/scaleset` session. A runner pod must have no projected
service-account token, must run as uid 1001, and must be scheduled on a
`compute-class: ci-worker` node. Confirm the registration in GitHub with
`GET /orgs/PingCAP-QE/actions/runner-groups/6/runners`.

## Rollback

1. In the consuming repository, change the affected job back to
   `runs-on: [arc-runner-set]`.
2. Remove `acr-runners` from `apps/tencentcloud/kustomization.yaml` and merge;
   Flux prunes the HelmReleases, the AutoscalingRunnerSet and the namespaces.
3. Remove `arc-runners` from the `ee-gcp-sm` allowlist in the same PR; the
   inventory job fails otherwise.
4. Delete the `tencentcloud-private-ci` runner group (or remove the
   repositories from it) and confirm the runners are deregistered.

## Upgrades

Renovate does not manage this directory. Bump `controller/release.yaml`, the
scale set and the image digest together, keeping the chart versions equal to the
`prod2` ones where possible. Keep `upgrade.crds: CreateReplace` on the
controller. A cross-minor ARC upgrade deletes the old AutoscalingRunnerSet (the
controller checks the `app.kubernetes.io/version` label), so after upgrading
run:

```bash
flux --context tke-pingcap-cicd reconcile hr arc-runner-set-pingcap-qe-private \
  -n arc-runners --force --reset
```

and verify the AutoscalingRunnerSet exists again; a Ready HelmRelease alone is
not proof.
