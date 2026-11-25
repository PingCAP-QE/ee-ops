# ARC runner set for `pingcap/tiup` releases

Repository-level GitHub Actions Runner Controller (ARC) scale set in the KSY
(`prod2`) cluster. It serves only the `release` job of `pingcap/tiup`'s
`release-tiup` workflow; `brew-upgrade` stays on GitHub-hosted runners.

## Layout

| File | Purpose |
| --- | --- |
| `source.yaml` | OCI HelmRepository for the ARC charts |
| `namespaces.yaml` | `arc-systems` (controller/listener) and `arc-runners` (runner pods), both PSA `restricted` |
| `release-1-controller.yaml` | ARC controller, chart 0.15.1, CRD upgrades enabled |
| `release-2-runners-tiup.yaml` | the `arc-runner-set-tiup-release` scale set |
| `external-secret-github-app.yaml` | GitHub App credentials from GCP Secret Manager |

## GitHub identity

- A GitHub App installed on the `pingcap` organization; credentials are managed
  in GCP Secret Manager and only the `arc-runners` namespace can read them
  through the `ee-gcp-sm` ClusterSecretStore.
- The scale set registers at `https://github.com/pingcap/tiup`, so the runner
  label is `arc-runner-set-tiup-release`.

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

The listener logs should show an `actions/scaleset` session. A runner pod must
have no projected service-account token and must run as uid 1001.

## Rollback

1. In `pingcap/tiup`, change the `release` job back to `runs-on: ubuntu-22.04`.
2. Remove `acr-runners` from `apps/prod2/kustomization.yaml` and merge; Flux
   prunes the HelmReleases, the AutoscalingRunnerSet and the namespaces.
3. Confirm the runner is deregistered in GitHub.

## Upgrades

Renovate tracks both charts and the runner image. Keep `upgrade.crds:
CreateReplace` on the controller. A cross-minor ARC upgrade deletes the old
AutoscalingRunnerSet (the controller checks the `app.kubernetes.io/version`
label), so after upgrading run:

```bash
flux --context ksy-pingcap-cicd reconcile hr arc-runner-set-tiup-release \
  -n arc-runners --force --reset
```

and verify the AutoscalingRunnerSet exists again; a Ready HelmRelease alone is
not proof.
