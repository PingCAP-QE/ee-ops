Prod Tekton Removal and Migration to prod2
=========================================

Overview
- Tekton components have been migrated to prod2 and removed from prod.
- This document records the change, references the affected files, and provides verification steps.

What changed
- prod: Tekton removed from kustomization (apps/prod/kustomization.yaml).
- prod: Tekton manifests directory deleted (apps/prod/tekton/).
- Documentation added (docs/TEKTON_MIGRATION.md).

Rationale
- Align with the migration plan to consolidate Tekton workloads in prod2, reducing maintenance surface in prod.

Verification and validation
- Ensure prod kustomization no longer references Tekton.
- Confirm the apps/prod/tekton directory is removed from the repository.
- On cluster: Tekton-related resources should no longer be reconciled in prod namespace.

Impact
- No changes required for prod2 workloads.
- CI/CD pipelines should continue to function against prod2 Tekton configurations.

Notes
- There may be residual comments mentioning Tekton in prod boskos resources; these are non-functional and can be updated later if desired.
