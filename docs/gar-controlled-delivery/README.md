# GAR Controlled Delivery

This document set describes a controlled private-delivery model for product
images using Google Artifact Registry (GAR), Terraform, and FluxCD.

Contents
- `controlled-delivery-repository-design.md`: repository, IAM, lifecycle, and audit design
- `terraform-gcloud-implementation.md`: implementation checklist and operational commands
- `gitops-with-fluxcd-and-terraform.md`: GitOps operating model using FluxCD and Terraform
- `customer-sync-sop.md`: customer-side synchronization procedure
- `terraform-module-skeleton/`: reference Terraform module skeleton

Scope
- Protect PingCAP-owned product content during private delivery.
- Let customers pull from a controlled delivery repository and sync into their
  internal registry themselves.
- Keep repository creation, access control, image publication, and retirement
  auditable and GitOps-managed.
