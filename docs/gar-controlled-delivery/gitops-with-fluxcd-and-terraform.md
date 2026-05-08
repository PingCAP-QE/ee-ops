# GitOps Design with FluxCD and Terraform

## 📘 Purpose
- This document describes how controlled delivery repositories are managed through GitOps.
- The key rule is that repository creation, IAM grants, publication intent, and retirement are all declared in Git and reconciled by automation.

## Why GitOps Is Required
- A platform or a script may initiate a delivery request, but neither should become the source of truth.
- Git provides:
  - change review
  - audit trail
  - rollback history
  - policy enforcement
  - stable reconciliation semantics

## Source-of-truth Model
- Git is the source of truth for:
  - delivery repository definitions
  - customer reader identities
  - expiration metadata
  - desired image manifests
  - retirement state
- Runtime automation is responsible for:
  - applying Terraform
  - publishing images by digest
  - enforcing cleanup

## 🏗️ Control Plane Model
- FluxCD watches this repository.
- FluxCD reconciles Kubernetes resources that describe delivery intents and automation jobs.
- Terraform is executed by a controller or runner that is itself driven by Git state.
- Image copy and manifest publication are executed by a delivery job triggered from the same Git change.

## Recommended Git Repository Model
```text
docs/gar-controlled-delivery/
infrastructure/gcp/delivery-repositories/
  customer-a-r2026q2/
    repo.auto.tfvars.json
    README.md
clusters/prod2/apps/delivery/
  kustomization.yaml
  terraform-runner/
  delivery-publisher/
```

## 🔄 GitOps Flow
1. A delivery request is approved by the business owner.
2. A PR adds or updates:
   - Terraform input for the GAR repository
   - customer reader IAM binding
   - batch expiration metadata
   - desired image manifest
3. PR review approves the controlled delivery change.
4. Merge to main updates the desired state.
5. FluxCD reconciles:
   - Terraform runner configuration
   - delivery publisher job configuration
6. Terraform applies the repository and IAM state.
7. Delivery publisher copies images by digest and publishes `images.lock`.
8. FluxCD or scheduled automation enforces retirement when the batch expires.

## Separation of Responsibilities
- FluxCD:
  owns cluster-side reconciliation and automation orchestration
- Terraform:
  owns external cloud resources such as GAR repositories and IAM bindings
- Delivery publisher:
  owns image copy, manifest generation, and publication status

## Suggested Kubernetes-side Components
- `Kustomization`:
  defines delivery automation deployment
- `Terraform` runner:
  applies GAR repository and IAM state
- `CronJob` or `Job`:
  publishes images and runs expiration cleanup
- `ExternalSecret`:
  injects cloud credentials where needed

## GitOps Object Model
- Repository spec:
  defines GAR repository id, region, labels, and retention class
- Access spec:
  defines customer reader principals
- Publication spec:
  defines source images, destination images, and required digests
- Retirement spec:
  defines expiration date and cleanup policy

## Publication Reconciliation Rules
- Publication must only proceed after Terraform has created the repository and IAM.
- Publication must fail closed if the digest in Git does not match the source artifact.
- Publication must write a status artifact or status commit for auditability.

## Retirement Reconciliation Rules
- Expired repositories must first revoke customer reader IAM.
- Repository deletion should happen only after a configurable grace period.
- Long-lived repositories use retention cleanup instead of immediate repository deletion.

## Audit Design
- Every delivery batch must map to one merged PR.
- That PR must include:
  - business context
  - repository scope
  - reader scope
  - expiration date
  - image manifest
- Operational jobs must emit logs keyed by batch id.

## 🚧 Policy Recommendations
- Require code review for every delivery batch change.
- Require owner and expiration metadata in every Terraform input.
- Prevent publication jobs from accepting mutable tag-only input.
- Prevent customer access grants without a matching repository definition.

## Failure Handling
- If Terraform fails:
  stop publication and keep the batch in pending state.
- If image publication fails:
  do not mark the batch as deliverable.
- If expiration cleanup fails:
  retry automatically and raise an alert before the grace window ends.

## Recommended Phase Plan
- Phase 1:
  Git drives Terraform apply and a delivery publication job.
- Phase 2:
  Git also drives scheduled retirement and cleanup enforcement.
- Phase 3:
  a platform UI or service opens PRs automatically, but the merged PR remains the source of truth.

## ✅ Decision
- Regardless of whether requests come from a platform or scripts, the final operating model is GitOps.
- FluxCD plus Terraform provides the right separation between cloud resource management and cluster-native reconciliation.
