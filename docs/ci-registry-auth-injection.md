# CI Container Registry Auth Injection (Kyverno)

## 1. Background & Goals

PingCAP-QE/ci Jenkins build/test pods need to access multiple OCI registries from inside containers:

- **OCI artifact downloads** (`scripts/artifacts/download_pingcap_oci_artifact.sh`, pulled via oras): `us-docker.pkg.dev/pingcap-testing-account/{hub,internal,dev}` (hub/dev are the script's default sources, internal is for internal components; all switchable via env).
- **In-container `docker pull`** (tiflash IT images, etc.).
- **Pod image pulls** (kubelet): `ghcr.io/pingcap-qe/*`, `us-docker.pkg.dev/pingcap-testing-account/{internal-test,ghcr-remote,dockerhub-remote}`, etc.

Current state: hub/internal/dev are anonymously pullable; **auth is planned for hub/internal/dev**, and CI pods will be **scheduled randomly across clouds** (GCP→AWS/Azure, etc.). Once that happens, anonymous pulls will fail, so auth is needed on both the in-pod side and the kubelet side.

**Cluster scope**: only the Jenkins namespaces of the **gcp** and **tencentcloud** clusters. **prod2 does not participate in Jenkins job scheduling** (its `jenkins-cbg` does not host CI pods) and is out of scope.

**Goal**: Kyverno injects registry auth automatically at pod creation (admission phase), with **zero changes to PingCAP-QE/ci** — all existing and future jobs are covered automatically.

## 2. Design

Two Kyverno policies (can be merged into a single multi-rule policy) targeting Pods in Jenkins namespaces. Whether the policies are namespaced (`Policy`/`NamespacedMutatingPolicy`) or cluster-level (`ClusterPolicy`/`MutatingPolicy`) does not affect the design; pick per the repo's existing conventions at rollout time.

### Policy A: in-pod registry credential injection (oras / docker CLI)

At pod creation, inject **only into the container named `utils`**:

1. `volume`: `ci-registry-auth` (references the Secret, `items` projects `.dockerconfigjson` → `config.json`, read-only)
2. `volumeMount`: `/var/run/ci/registry`
3. `env`: `DOCKER_CONFIG=/var/run/ci/registry` (also compatible with `ORAS_DOCKER_CONFIG`)

Coverage: all 314 current `download_pingcap_oci_artifact.sh` call sites, tiflash IT's docker pulls, and the delegated scripts run inside the `utils` container, so injecting only `utils` covers everything; other containers (default/jnlp/golang) are left untouched to minimize the injection surface and avoid collateral impact.

### Policy B: imagePullSecrets injection (kubelet pulling pod images)

**Only when a pod image matches the target registry prefixes** inject `spec.imagePullSecrets` (referencing `ci-registry-auth`, a `kubernetes.io/dockerconfigjson` Secret), solving auth for cross-cloud pulls of GCP Artifact Registry / ghcr images. The match list is the set of image prefixes that require auth (see #6 in §6); non-matching pods are untouched to avoid needless injection.

> This round's scope: Policy B is **deployed on the tencentcloud cluster only** (which already has cross-cloud pod scheduling); gcp is excluded until tencentcloud validates stably, then extended.

> Key point: the kubelet pulls images using the Pod's `imagePullSecrets`, which is unrelated to the config mounted inside the pod — both are required, hence two rules.

### Secret design (ExternalSecret sync, single Secret dual-use)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: ci-registry-auth
  namespace: <jenkins-*>
type: kubernetes.io/dockerconfigjson   # natively referenceable by imagePullSecrets
data:
  .dockerconfigjson: '<config.json base64>'
```

- Synced by **ExternalSecret** from a single source: **a new dedicated GCP Secret Manager secret `ci_registry_auth_dockerconfig_json`** (its contents include auths for all target registries, covering both the in-pod and imagePullSecrets sides, see next item). One per Jenkins namespace; no manual cross-cluster maintenance.
- For in-pod mounts use the `items: [{key: .dockerconfigjson, path: config.json}]` projection (no need for a duplicate Opaque secret).
- `config.json`'s `auths` must cover: Policy A side `us-docker.pkg.dev` (hub/internal/dev), `ghcr.io` (utils/builders/ci-jenkins); Policy B side `cr-qcloud.pingcap.net`, `cr.pingcap.net`. Per the actual list confirmed by ee-ops.
- **One per Jenkins namespace**; each target cluster's corresponding namespace must also be synced (done automatically by ExternalSecret).

### Kyverno policy skeleton (illustrative, finalized by ee-ops)

```yaml
apiVersion: policies.kyverno.io/v1   # unified with tencentcloud after gcp upgrade; Kyverno 1.12 used kyverno.io/v1
kind: ClusterPolicy                  # or NamespacedMutatingPolicy / Policy — equivalent
metadata:
  name: inject-ci-registry-auth
spec:
  validationFailureAction: Audit
  background: false
  rules:
    - name: inject-registry-config-utils
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces:
                - jenkins-tidb
                - jenkins-tikv
                # ... full namespace list
      mutate:
        patchStrategicMerge:
          spec:
            volumes:
              - name: ci-registry-auth
                secret:
                  secretName: ci-registry-auth
                  items:
                    - key: .dockerconfigjson
                      path: config.json
            containers:
              - name: utils
                volumeMounts:
                  - name: ci-registry-auth
                    mountPath: /var/run/ci/registry
                    readOnly: true
                env:
                  - name: DOCKER_CONFIG
                    value: /var/run/ci/registry
    - name: inject-image-pull-secrets
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [ ...same as A... ]
              images:                # only inject when a pod image matches a target prefix
                - "cr-qcloud.pingcap.net/*"
                - "cr.pingcap.net/*"
      mutate:
        patchStrategicMerge:
          spec:
            imagePullSecrets:
              - name: ci-registry-auth
```

## 3. Compatibility & Technical Notes

- Both `oras` (1.x, via go-containerregistry) and the `docker` CLI honor the `DOCKER_CONFIG` env var, falling back to `~/.docker`. Tekton/kaniko in this repo already use the same pattern.
- Only the `utils` container is injected; other containers are unaffected. All download/pull logic runs in `utils`, so coverage is complete.
- No conflict with the existing 30 `withCredentials('tidbx-docker-config')` `~/.docker/config.json` copy sites; they can remain (cleanup later).
- Secret mounts are read-only; `defaultMode` is recommended as `0444` so non-root containers can read; no fsGroup dependency.
- If the `utils` container already defines `DOCKER_CONFIG`, Kyverno must avoid duplicate injection (mind idempotency in the patch); Policy B must likewise be idempotent for pods that already have `imagePullSecrets`.

## 4. Deliverables (ee-ops repo)

1. Two policies (or one dual-rule policy): inject-registry-config-utils (utils container only) + inject-image-pull-secrets (image-match only; **tencentcloud only this round**)
2. `ExternalSecret` definition (per namespace, single source) + final `Secret` shape confirmation
3. Per-namespace Secret sync mechanism (ExternalSecret + single source, automatic cross-cluster)
4. Migration notes: current `tidbx-docker-config` credential contents → Secret; grayscale validation record
5. gcp cluster Kyverno upgrade (chart 3.4.4 → aligned with tencentcloud 3.8.2, unified on `policies.kyverno.io/v1`)

## 5. Grayscale & Rollback

1. First validate in a **staging/test namespace** (e.g. a small set of jenkins-tidb jobs): manually create a pod → check the utils container volume/env and imagePullSecrets injection → run a real download job (e.g. tidb `pull_integration_realcluster_test_next_gen`). Policy A is active on both gcp and tencentcloud this round (gcp Kyverno upgrade done); Policy B is active on tencentcloud only this round.
2. Confirm that after hub/internal/dev require auth, anonymous pulls fail while injected pulls succeed; then expand namespace by namespace and extend Policy B to gcp.
3. Rollback: just delete the policies and the Secret; pod creation returns to the previous state immediately, and existing pods are unaffected.

## 6. Open Items for ee-ops

| # | Item | Notes |
|---|---|---|
| 1 | Kyverno version / management per CI cluster | Deployed on gcp (chart 3.4.4), tencentcloud (3.8.2), prod2 (3.4.4), all managed via Flux HelmRelease; prod2 excluded (no Jenkins scheduling). **gcp upgraded to 3.8.2 to align with tencentcloud**, unified on `policies.kyverno.io/v1` |
| 2 | Full list of namespaces to inject | Confirmed: `jenkins-tidb`, `jenkins-tikv`, `jenkins-tiflow`, `jenkins-tiflash`, `jenkins-pd` (note: the `post/ticdc` directory actually creates `jenkins-tiflow`); staging/test namespaces TBD |
| 3 | **Matching strategy** | Decided: reuse the existing `kubernetes.jenkins.io/controller` label convention (namespaced MutatingPolicy mounted per jenkins-* namespace, naturally isolated by namespace); Policy B additionally matches image prefixes (see #6). Namespaced vs cluster-level both acceptable |
| 4 | **Secret provisioning** | Decided: ExternalSecret sync from a **new dedicated GCP SM secret `ci_registry_auth_dockerconfig_json`**; confirm its contents cover all target registries and the GAR credential shape (long-lived `_json_key` vs short-lived token with auto-rotation) |
| 5 | **Registry host list covered by config.json** | Policy A side: `us-docker.pkg.dev` (hub/internal/dev), `ghcr.io`; Policy B side: `cr-qcloud.pingcap.net`, `cr.pingcap.net`; whether nextgen's `gcr.io/us.gcr.io` should be included |
| 6 | **Policy B image match list** | **Confirmed**: pods whose images start with `cr-qcloud.pingcap.net/` or `cr.pingcap.net/` get `imagePullSecrets` injected. Policy B is **deployed on tencentcloud only this round**; extend to gcp after validation |
| 7 | How hub/internal/dev are reached from target clouds (AWS/Azure) | Public access to GCP AR, or registry mirrors per cloud? Affects config.json contents and image addresses |
| 8 | Policy owner / approval flow | Who reviews and who approves |
| 9 | Confirm **oras version** in the utils image (≥1.x supporting DOCKER_CONFIG) | If too old, upgrade the utils image (separate change) |
| 10 | Whether to clean up the existing 30 `withCredentials('tidbx-docker-config')` sites | Keep this round; clean up after stability is proven |
