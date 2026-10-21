# Tekton Cluster Decommissioning History

This document records the two Tekton consolidation/decommissioning steps:

1. legacy `prod` -> `prod2` (historical);
2. `prod2` -> `gcp` / `tencentcloud` (2026-10).

## Legacy prod -> prod2 (historical)

- Tekton components were migrated to prod2 and removed from prod.
- The legacy prod cluster was later decommissioned and its Flux GitOps
  configuration removed.
- Rationale: consolidate Tekton workloads in prod2 and remove the maintenance
  surface for the retired prod cluster.

## prod2 -> gcp / tencentcloud (2026-10)

- prod2 (`ksy-pingcap-cicd`) Tekton is retired. The `apps/prod2/tekton/`
  directory and its four Flux Kustomizations are removed.
- Remaining prod2 builds were migrated to `env-gcp` triggers:
  - darwin: `build-component-darwin-mac` (gcp macbuild);
  - linux: `build-component-linux` / `build-component-all-platforms-mac`;
  - Harbor image-push triggers moved to the gcp Harbor EventListener.
- `tibuild-v2` in prod2 no longer triggers local Tekton; use the gcp or
  tencentcloud tibuild-v2 instance for devbuilds.
- `cloudevents-server` in prod2 is removed once no non-Tekton consumer remains.

## Verification and validation

- Confirm `apps/prod2/tekton/`, `clusters/prod2` Tekton references, and the
  `tekton-operator` / `tekton-pipelines` namespace policy entries are absent
  from the repository.
- Confirm prod2 Flux no longer reconciles `tekton-*` Kustomizations.
- Confirm gcp/tencentcloud Tekton triggers exist for the migrated builds and
  that a canary build succeeds.
- On cluster: no Tekton CRDs, namespaces, webhooks, APIService, or
  `ee-cd`-scoped Tekton resources remain in prod2.

## Notes

- References to `prod` in other clusters may identify an image registry or
  deployment stage and are unrelated to the retired clusters.
