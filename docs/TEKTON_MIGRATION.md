Prod Cluster Decommissioning and Tekton Migration to prod2
=========================================

Overview
- Tekton components have been migrated to prod2 and removed from prod.
- The legacy prod cluster has since been decommissioned and its Flux GitOps configuration removed.
- This document records the migration and decommissioning context and provides verification steps.

What changed
- prod: Tekton manifests and kustomization were removed during the migration.
- prod: Flux bootstrap, application, and infrastructure configuration were removed when the cluster was decommissioned.

Rationale
- Consolidate Tekton workloads in prod2 and remove the maintenance surface for the retired prod cluster.

Verification and validation
- Confirm the clusters/prod, apps/prod, and infrastructure/prod directories are absent from the repository.
- Confirm prod2 Flux kustomizations and workloads remain intact.
- On cluster: prod resources should no longer be reconciled by Flux.

Impact
- No changes required for prod2 workloads.
- CI/CD pipelines should continue to function against prod2 Tekton configurations.

Notes
- References to `prod` in other clusters may identify an image registry or deployment stage and are unrelated to the retired cluster.
