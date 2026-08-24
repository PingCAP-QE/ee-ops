# jenkins-cbg Helm release (prod2 / new-ksyun)

Layout mirrors `apps/tencentcloud/jenkins/release/staging` and the legacy
`ci-ops/apps/prod/jenkins` pingkai controller.

## Files

| File | Purpose |
|------|---------|
| `values-controller.yaml` | Image, resources, URI prefix, JVM |
| `values-controller-plugins.yaml` | Plugin pin list + upgrade policy |
| `values-persistence.yaml` | Reuse existing `jenkins-cbg` PVC |
| `values-agent.yaml` | K8s agent namespace / capacity |
| `values-JCasC.yaml` | Kubernetes cloud + pipeline-cache |
| `values-rbac.yaml` / `values-service-account.yaml` | Agent RBAC |

## Merge note

Cluster still has the manually applied `StatefulSet/jenkins-cbg`. Before or
during the first Flux reconcile, adopt or replace it with the Helm release
(`releaseName: jenkins-cbg`, `fullnameOverride: jenkins-cbg`) so Service /
HTTPRoute names stay compatible.
