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

## Safety choices vs tencentcloud staging

| Setting | Value | Why |
|---------|-------|-----|
| HelmRelease API | `v2beta1` | prod2 cluster APIs |
| `JCasC.defaultConfig` | `false` | keep hot-copied admin/security |
| `admin.createSecret` | `false` | do not invent chart admin password |
| `overwritePlugins` / `installLatestPlugins` | `false` | do not wipe plugins on start |
| `test.enable` | `false` | avoid false-negative Ready on adopt |
