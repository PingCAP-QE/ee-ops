# Controlled Private Delivery

This document set describes a controlled private-delivery model for product
images.

The default online delivery backend is Google Artifact Registry (GAR). For
customers that can only reach Docker Hub and cannot reach GAR, this document
set also includes a Docker Hub private-repository delivery mode.

## 📘 Overview
- Audience: platform engineers, delivery owners, and reviewers of the private-delivery design.
- Theme: controlled image delivery with repository isolation, managed access,
  auditable publication, and customer-side synchronization.

## 🗂️ Documents
- `controlled-delivery-repository-design.md`: common control-plane, lifecycle,
  backend selection, and audit design
- `dockerhub-private-delivery-design.md`: Docker Hub organization, repository,
  team, and tagging model for private delivery
- `terraform-gcloud-implementation.md`: implementation checklist and operational commands
- `gitops-with-fluxcd-and-terraform.md`: GitOps operating model using FluxCD and Terraform
- `customer-sync-sop.md`: customer-side synchronization procedure for GAR mode
- `customer-dockerhub-private-repo-sync-sop.md`: customer-side synchronization
  procedure for Docker Hub private-repository mode
- `terraform-module-skeleton/`: reference Terraform module skeleton

## 🎯 Scope
- Protect PingCAP-owned product content during private delivery.
- Let customers pull from a controlled delivery repository and sync into their
  internal registry themselves.
- Keep repository creation, access control, image publication, and retirement
  auditable and GitOps-managed.
- Support two online delivery modes:
  - GAR as the default controlled delivery surface
  - Docker Hub private repositories as an exception path for customers that can
    only reach Docker Hub
