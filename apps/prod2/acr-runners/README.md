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
| `networkpolicy-egress.yaml` | outbound-only policy: DNS, public Internet, internal TiUP mirror |

## GitHub identity

- App `214286` (`ti-chi-bot`), installation `36729905` on the `pingcap`
  organization (`repository_selection: all`).
- The private key is the shared `gha__system__github_app_private_key`; the
  installation id lives in `arc__repo__pingcap__tiup__github_app_installation_id`.
- The scale set registers at `https://github.com/pingcap/tiup`, so the runner
  label is `arc-runner-set-tiup-release`.

## KSY-specific workarounds

- **`github.com` is currently unreachable** (its Asian edge 20.205.243.x /
  20.27.x is blackholed from KSY). Do not enable the workflow until the
  cluster's DNS/routing to `github.com` is fixed; `actions/checkout` will time
  out. Pinning US IPs via `hostAliases` was evaluated and intentionally not
  used.
- **The runner image has no `wget`.** `release-tiup` therefore uses `curl` to
  download the TiUP bootstrap tarball.
- **Cold image pulls are slow** (~950 KiB/s, roughly 5–10 minutes). Pre-pull the
  pinned image on healthy nodes before enabling the workflow; never run
  concurrent `ctr pull` for the same image (containerd ingest lock).
- **`10.2.15.75` cannot pull non-KCE images.** Runner pods are scheduled away
  from it until the node is repaired.
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
