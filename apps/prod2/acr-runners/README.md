# ARC runner scale set for `pingcap/tiup` releases

GitHub Actions Runner Controller (ARC) scale set in the KSY (`prod2`) cluster.
It serves only the `release` job of `pingcap/tiup`'s `release-tiup` workflow;
`brew-upgrade` stays on GitHub-hosted runners.

The scale set that serves `PingCAP-QE/test-infra` and `PingCAP-QE/endless` lives
in [`apps/tencentcloud/acr-runners`](../../tencentcloud/acr-runners/README.md).

## Layout

```text
apps/prod2/acr-runners/
├── kustomization.yaml      # source.yaml, namespaces.yaml, controller/, scale-sets/
├── source.yaml             # HelmRepository, shared by the controller and the scale set
├── namespaces.yaml         # arc-systems (controller/listener) + arc-runners (runners)
├── controller/             # ARC controller, chart 0.15.1, CRD upgrades enabled
│   ├── kustomization.yaml
│   └── release.yaml
└── scale-sets/
    ├── kustomization.yaml  # lists the scale sets
    └── tiup/
        ├── kustomization.yaml
        ├── scale-set.yaml          # HelmRelease arc-runner-set-tiup-release
        └── github-app-secret.yaml  # ExternalSecret for its GitHub App credentials
```

One directory per scale set keeps the HelmRelease and the ExternalSecret that
must change together next to each other, so a new runner set is a new directory
plus one line in `scale-sets/kustomization.yaml`. The old `release-1-`,
`release-2-` prefixes are gone: everything is applied by a single Flux
Kustomization, so a numeric prefix never enforced an order.

## Dependencies

Everything here is rendered by one Flux Kustomization, so ordering that matters
is declared explicitly:

1. `clusters/prod2/apps.yaml` `dependsOn` `infrastructure`, so the
   external-secrets controller and the `ee-gcp-sm` ClusterSecretStore already
   exist when this directory is applied.
2. The GCP secrets (`gha__system__*`, `arc__repo__pingcap__tiup__*`) are created
   out of band and must exist before the ExternalSecret can sync; a missing one
   shows as an `ExternalSecret` that never becomes `SecretSynced`.
3. The scale-set HelmRelease `dependsOn` the `arc` HelmRelease in `arc-systems`.
   The chart renders an `AutoscalingRunnerSet`, so the ARC CRDs and the
   `arc-gha-rs-controller` ServiceAccount have to be there first.
4. The runner pods mount the Secret produced by the ExternalSecret. If the scale
   set installs before that Secret exists, the pod sits in
   `CreateContainerConfigError` for a few seconds and then starts; the Helm
   release itself does not fail.
5. `namespaces.yaml` stays at the top level: Flux applies `Namespace` objects
   before other kinds in the same Kustomization.

## GitHub identity

- The scale set authenticates as the `ti-chi-bot` GitHub App (id `214286`).
  Credentials are managed in GCP Secret Manager and only the `arc-runners`
  namespace can read them through the `ee-gcp-sm` ClusterSecretStore.
- The app is installed per account, so the installation ID is the `pingcap`
  organization installation (`36729905`), read from
  `arc__repo__pingcap__tiup__github_app_installation_id`.
- It registers at repository scope at `https://github.com/pingcap/tiup`, so the
  label is the HelmRelease name, `arc-runner-set-tiup-release`. Workflows select
  it with `runs-on: [arc-runner-set-tiup-release]`.

## KSY-specific notes

- **Runner image is `ghcr.io/pingcap-qe/ci/actions-runner`.** It extends the
  same upstream `2.338.2` runner with make, GNU tar, wget, xz and zip (see
  `PingCAP-QE/ci` `dockerfiles/ci/actions-runner`), so `release-tiup` no longer
  has to work around a missing `wget`. It is a public GHCR package, so the
  scale set needs no `imagePullSecrets`.
- **Cold image pulls are slow.** Only the previous upstream image is pre-pulled
  on the three amd64 nodes. The new image reuses all ten of its base layers, so
  the first pull only fetches the extra ~1 MB tools layer; if you pre-pull it
  explicitly, never run concurrent `ctr pull` for the same image (containerd
  ingest lock).
- **The runner pool is the three amd64 nodes.** The other four nodes are arm64;
  `maxRunners: 4` can place two runners on one node.
- **No egress isolation.** The cluster's Calico deployment ships only the CNI
  plugin, so `NetworkPolicy` is not enforced. This is an accepted risk; the
  approval requirement for outside-collaborator PR workflows is the gate.
- **Public repository + self-hosted runner:** `pingcap/tiup` must require
  approval for workflows from all outside collaborators
  (`fork-pr-contributor-approval = all_outside_collaborators`). Do not enable
  the scale set for PR workflows without that setting.

## Verify

```bash
kubectl --context ksy-pingcap-cicd -n arc-systems get hr arc
kubectl --context ksy-pingcap-cicd -n arc-runners get hr
kubectl --context ksy-pingcap-cicd -n arc-runners get autoscalingrunnerset
kubectl --context ksy-pingcap-cicd -n arc-runners get pod   # empty when idle
kubectl --context ksy-pingcap-cicd -n arc-runners get externalsecret
```

The `AutoscalingRunnerSet` must be `Running`. The listener logs should show an
`actions/scaleset` session. A runner pod must have no projected service-account
token and must run as uid 1001.

## Rollback

1. In `pingcap/tiup`, change the `release` job back to `runs-on: ubuntu-22.04`.
2. Remove `acr-runners` from `apps/prod2/kustomization.yaml` and merge; Flux
   prunes the HelmRelease, the AutoscalingRunnerSet and the namespaces.
3. Confirm the runner is deregistered in GitHub.

## Upgrades

Renovate tracks both charts and the runner image in `apps/gcp/acr-runners`; the
`prod2` copies are maintained by hand, so bump `controller/release.yaml`, the
scale set and the image digest together. Keep `upgrade.crds: CreateReplace` on
the controller. A cross-minor ARC upgrade deletes the old
AutoscalingRunnerSet (the controller checks the `app.kubernetes.io/version`
label), so after upgrading run:

```bash
flux --context ksy-pingcap-cicd reconcile hr arc-runner-set-tiup-release \
  -n arc-runners --force --reset
```

and verify the AutoscalingRunnerSet exists again; a Ready HelmRelease alone is
not proof.
