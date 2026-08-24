# jenkins-cbg Helm release (prod2 / new-ksyun)

Layout mirrors `apps/tencentcloud/jenkins/release/staging` and the legacy
`ci-ops/apps/prod/jenkins` pingkai controller, but uses **prod2-compatible**
`helm.toolkit.fluxcd.io/v2beta1` (prod2 Flux does not serve `/v2`).

## Files

| File | Purpose |
|------|---------|
| `values-controller.yaml` | Image, resources, URI prefix, JVM |
| `values-controller-plugins.yaml` | Plugin pin list (non-destructive for hot-copy) |
| `values-persistence.yaml` | Reuse existing `jenkins-cbg` PVC |
| `values-agent.yaml` | K8s agent namespace / capacity |
| `values-JCasC.yaml` | Kubernetes cloud + pipeline-cache (no default securityRealm) |
| `values-rbac.yaml` / `values-service-account.yaml` | Agent RBAC |

## First-time adoption (required)

Cluster still has a **manually applied** `StatefulSet/jenkins-cbg` whose pod
selector (`app.kubernetes.io/name=jenkins-cbg`) differs from the Jenkins chart
selector (`app.kubernetes.io/instance` + `component`). StatefulSet selectors are
immutable, so Helm cannot adopt the existing STS in place.

Before Flux can install the HelmRelease successfully:

```bash
# 1. Confirm PVC will be kept
kubectl -n jenkins-cbg get pvc jenkins-cbg

# 2. Scale down and delete ONLY the StatefulSet (PVC stays Bound)
kubectl -n jenkins-cbg scale sts/jenkins-cbg --replicas=0
kubectl -n jenkins-cbg delete sts jenkins-cbg --cascade=orphan
# or: delete sts and let pods terminate; do NOT delete pvc/jenkins-cbg

# 3. Optional: remove the old single Service if Helm fails on immutable fields
#    Chart creates jenkins-cbg (http) + jenkins-cbg-agent (JNLP :50000)
kubectl -n jenkins-cbg delete svc jenkins-cbg --ignore-not-found

# 4. Reconcile
flux reconcile helmrelease jenkins-cbg -n jenkins-cbg --with-source
```

HTTPRoute already points at Service `jenkins-cbg:8080` (HTTP only) — matches chart.

After adopt, agent tunnel is `jenkins-cbg-agent.jenkins-cbg.svc:50000` (set in JCasC).

## K8s cloud (architecture)

Hot-copied `JENKINS_HOME` carries **three** stale layers that GitOps cannot override
while the controller keeps running:

| Stale layer | Symptom |
|-------------|---------|
| `config.xml` `<clouds>` | Wrong `jenkinsUrl` (`/jenkins-cbg/`) and `jenkinsTunnel` (pre-Helm Service) |
| `init.groovy.d/00-cbg-manual-verify.groovy` | **Every startup** removes all clouds and recreates `jenkins-cbg-k8s` with manual-migration URLs |
| `casc_configs/` on PVC | jenkins-gitee-era CasC (hidden at runtime by chart emptyDir, but confusing on disk) |

With `JCasC.defaultConfig: false`, CasC `configScripts` declare the desired cloud in
`values-JCasC.yaml`, but they **lose** if init.groovy or stale XML rewrites the cloud
on every boot. Per-pod shell sed on `config.xml` only masked this race.

**Correct model after migration:**

| Concern | Owner |
|---------|--------|
| Kubernetes cloud `jenkins-cbg-k8s` | **`values-JCasC.yaml` only** |
| Admin / security realm | Hot-copied PVC (`defaultConfig: false`) |
| Jobs / credentials / plugins | Hot-copied PVC |

Do **not** reintroduce init shell patches or init.groovy that manage clouds.

### One-time PVC finalize (required once per hot-copy)

Removes stale `<clouds>`, legacy init.groovy, and PVC `casc_configs/`. Then JCasC
creates the cloud on next controller start.

```bash
bash apps/prod2/jenkins-cbg/release/files/run-finalize-hotcopy-jenkins-home.sh
```

Verify after controller is up:

```bash
kubectl -n jenkins-cbg exec jenkins-cbg-0 -c jenkins -- sh -c '
  test ! -f init.groovy.d/00-cbg-manual-verify.groovy
  grep -E "jenkinsUrl|jenkinsTunnel" config.xml
'
# expect .../jenkins-pingkai/ and jenkins-cbg-agent...:50000
```

Restarting the pod must **not** revert URLs. If it does, check that the legacy groovy
file is gone and only one cloud `jenkins-cbg-k8s` exists.

## Namespace secrets (manual migration)

These are **not** in GitOps; copy once from old `jenkins-gitee` namespace:

| Secret | Used by |
|--------|---------|
| `hub-pingcap-net` | release/kaniko pod templates |
| `loop-acr-dockerconfig` | loop release |
| `ks3utilconfig` | offline-packages release |

```bash
for s in hub-pingcap-net loop-acr-dockerconfig ks3utilconfig; do
  kubectl --context old -n jenkins-gitee get secret "$s" -o yaml \
    | sed 's/namespace: jenkins-gitee/namespace: jenkins-cbg/' \
    | kubectl --context new apply -f -
done
```

## Safety choices vs tencentcloud staging

| Setting | Value | Why |
|---------|-------|-----|
| HelmRelease API | `v2beta1` | prod2 cluster APIs |
| Chart version | `5.8.43` | matches prod2 Flux / jenkins repo pin |
| `fullnameOverride` | chart **root** value in `release.yaml` | not `controller.fullnameOverride` |
| `JCasC.defaultConfig` | `false` | keep hot-copied admin/security |
| K8s cloud | `values-JCasC.yaml` only | after one-time `<clouds>` strip on PVC |
| `admin.createSecret` | `false` | do not invent chart admin password |
| `overwritePlugins` / `installLatestPlugins` | `false` | do not wipe plugins on start |
| `test.enable` | `false` | avoid false-negative Ready on adopt |
