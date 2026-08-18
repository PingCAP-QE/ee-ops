# AGENTS

Guidance for AI agents working in the ee-ops repository.

## Repository Overview

GitOps repository for PingCAP-QE's Efficiency Engineering infrastructure and applications, managed with FluxCD v2 (Helm v3 + Kustomize). PRs to `main` trigger CI validation (kubeconform, kustomize build, kyverno test); after merge, FluxCD reconciles each cluster.

## Critical: Sibling Repo Coupling

Runtime-side config for Jenkins pipelines and Tekton v1 workloads lives in the sibling repo **PingCAP-QE/ci** (usually checked out at `../ci`), NOT here:

- **Jenkins jobs/pipelines** (`.groovy` + `pod.yaml`) live in `ci/pipelines/`, `ci/jobs/`; this repo only defines the Jenkins **instances** (JCasC, credentials, namespaces, agent configs). Changing a pipeline = PR in ci, not ee-ops.
- **Tekton v1 tasks/pipelines/triggers** live in `ci/tekton/v1/` and consume ServiceAccounts defined here in `apps/<cluster>/tekton/configs/rbac/` (e.g. `github-bot`, `image-releaser` — used as `serviceAccountName` in trigger templates to inject git SSH / docker registry credentials via Tekton's creds-init).
- Jenkins **global env vars** are declared per-instance in this repo (see below), then read from pipelines via `env.<NAME>`.

When a change spans both repos (e.g. new Jenkins global variable + pipelines using it), plan two PRs with dependency notes; the instance-side PR must merge and sync first.

## Repository Structure

```
clusters/         # FluxCD bootstrap: flux-system, sources, Kustomization layers per cluster
infrastructure/   # Base infra per cluster: external-secrets, gateways, kyverno, node-pools, operators, storage-classes, nginx...
apps/             # Application deployments per cluster (jenkins, tekton, prow, tibuild, zot, kafka...)
charts/           # Reusable Helm charts: ats, bazel-remote, buildbarn, cla-assistant, git-cdn, greenhouse, mcp-tool, paperclip, prow
scripts/          # validation + ops scripts
docs/             # TEKTON_MIGRATION.md, kyverno-policy-testing.md, gar-controlled-delivery/, github-actions-secrets/
```

## Clusters

- **prod** — legacy, being deprecated (migration to prod2); only `ats` and `greenhouse` remain.
- **prod2** — main production target (tekton, tibuild, zot, publisher, cache, tirelease...).
- **gcp** — GCP cluster: jenkins (beta), jenkins-agents, tekton, prow, tibuild, publisher, kafka...
- **tencentcloud** — Tencent Cloud cluster (newer): jenkins, jenkins-agents, tekton, tibuild, zot, kafka, cache...

Each cluster has a `README.md` under `clusters/<cluster>/` listing required secrets (e.g. tencentcloud needs `lark-token`/`lark-token-error` for Flux notifications) — check it before touching a cluster.

## Jenkins Instances (this repo)

- gcp: `apps/gcp/jenkins/beta/` — **two** instances: main (from `release/values-*.yaml`) and staging (from `release/staging/values-*.yaml`); both are active.
- tencentcloud: `apps/tencentcloud/jenkins/` — only `release/staging/values-*.yaml` is active (non-staging files commented out in kustomization).
- Values files are bundled into a secret via `secretGenerator: jenkins-release-values` in the release kustomization — a values file edit only takes effect after Flux regenerates that secret and the helm release upgrades.
- **Jenkins global env vars**: declared in `values-JCasC.yaml` under the `global-env:` configScript (`jenkins.globalNodeProperties.envVars`). Example: tencentcloud sets `GOPROXY`, `BAZELISK_BASE_URL`; gcp instances each have their own `global-env` block. Pipelines read them via `env.<NAME>`. These are per-cloud — keep cloud-specific values (registries, mirrors) here, not in ci pipelines.
- Instance layouts: `pre/` (secrets/credentials), `post/` (per-repo namespaces + policies), `release/` (helm chart values + JCasC).

## Tekton (this repo)

- Per cluster: `apps/<cluster>/tekton/{configs,setup,configs.yaml,setup.yaml}`; configs include `rbac/` (ServiceAccounts), `secrets/`, `pipelines/`, `tasks/`, `triggers/` policies.
- `setup/` installs the Tekton operator (operator-config, manual-approval gate).
- See `docs/TEKTON_MIGRATION.md` for migration notes (prod Tekton deleted; workloads consolidated in prod2/gcp).

## Validation & CI

Local validation (mirrors CI "CD Test" workflow):

```bash
# yq + kustomize + kubeconform must be installed (see script header for versions)
pushd infrastructure && $PWD/../scripts/validate_k8s_yaml.sh && popd
# repeat for clusters/ and apps/ (clusters also runs scripts/check_gcp_flux_api_versions.sh)
```

- `validate_k8s_yaml.sh` skips `charts/*/templates/` (Go templating), validates yq syntax everywhere, kubeconform for clusters (maxdepth 2) and every `kustomize build` overlay.
- Chart PRs: `ct lint --charts charts/<chart>`; chart release auto-triggers on Chart.yaml version bump on main (chart-releaser); `charts_test-prow.yaml` / `charts_test-bazel-remote.yaml` do in-cluster install tests.
- Kyverno policy changes: CI runs `kyverno_test.yaml`; see `docs/kyverno-policy-testing.md` — policy dirs use `kyverno-test.yaml` fixtures under `tests/`.
- Pre-commit (pre-commit.ci): end-of-file-fixer, trailing-whitespace, gitleaks. Never commit secrets; gitleaks fails the PR.

## Git Conventions

Conventional Commits, scope = path (multiple scopes comma-separated):

```
feat(apps/gcp,apps/tencentcloud): add OCI artifact host global env vars to Jenkins instances
fix(apps/tencentcloud/zot): raise http read/write timeouts to 600s (#2214)
chore(prow): bump issue-triage to v2026.8.11 (#2212)
```

## Troubleshooting

```bash
flux get kustomizations --all-namespaces
flux get helmreleases --all-namespaces
flux logs --all-namespaces
flux reconcile kustomization <name> --namespace=<namespace>
helm template test charts/<chart> --namespace test | kubectl apply --dry-run=server -f -
```

## References

- [FluxCD](https://fluxcd.io/docs/) · [Helm](https://helm.sh/docs/) · [chart-testing](https://github.com/helm/chart-testing) · [kubeconform](https://github.com/yannh/kubeconform)
- Repo docs: `docs/README.md` (index with links to TEKTON_MIGRATION, kyverno-policy-testing, gar-controlled-delivery, github-actions-secrets)
