# Terraform Module Skeleton for GAR Controlled Delivery

This skeleton demonstrates the minimum Terraform shape for managing a
customer-batch GAR repository with repository-level IAM.

## Overview
- This is a reference skeleton, not yet a production module.
- It demonstrates the minimum structure for repository creation and repository-level IAM bindings.

## What It Covers
- GAR standard Docker repository
- repository labels
- `delivery-bot` writer binding
- customer reader binding

## What It Does Not Cover Yet
- cleanup policy resources, because provider support and rollout policy may vary
- publication jobs
- expiration automation

## Suggested Usage
```hcl
module "customer_a_r2026q2" {
  source = "./docs/gar-controlled-delivery/terraform-module-skeleton"

  project_id                = "delivery-project"
  location                  = "asia-east1"
  repository_id             = "customer-a-r2026q2"
  description               = "Controlled delivery repository for customer-a batch r2026q2"
  delivery_bot_member       = "serviceAccount:delivery-bot@delivery-project.iam.gserviceaccount.com"
  customer_reader_members   = ["serviceAccount:customer-a-sync@customer-project.iam.gserviceaccount.com"]
  labels = {
    customer      = "customer-a"
    owner         = "delivery-team"
    delivery_mode = "temp"
    expire_at     = "2026-05-01"
    ticket        = "ticket1234"
  }
}
```
