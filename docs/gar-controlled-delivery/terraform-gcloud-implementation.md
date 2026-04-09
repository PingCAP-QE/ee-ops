Terraform and gcloud Implementation Checklist
============================================

Purpose
- This document provides a practical implementation checklist for controlled delivery on GAR.
- It includes repository creation, IAM binding, image copy, manifest generation, and retirement actions.

Implementation boundaries
- Terraform is the source of truth for repository and IAM definitions.
- `gcloud` and `crane` are used as operational tools where appropriate.
- Publication and retirement must be triggered by GitOps workflows, not by manual ad hoc console changes.

Implementation checklist
- Create a dedicated delivery project or dedicated repository namespace.
- Create a dedicated `delivery-bot` service account.
- Create a GAR standard Docker repository for each customer batch.
- Apply repository labels and expiration metadata.
- Grant `delivery-bot` writer access.
- Grant the customer identity reader access at repository level.
- Generate `images.lock` and `release-manifest.yaml`.
- Copy images by digest into the delivery repository.
- Record the publication in Git.
- Revoke access and delete expired repositories.

Suggested directory model in Git
```text
docs/gar-controlled-delivery/
docs/gar-controlled-delivery/terraform-module-skeleton/
infrastructure/gcp/delivery-repositories/
  customer-a-r2026q2/
    main.tf
    repo.auto.tfvars.json
```

Terraform resources to manage
- `google_artifact_registry_repository`
- `google_artifact_registry_repository_iam_member`
- `google_service_account`
- optional IAM customizations for delivery automation

Operational tools
- `gcloud`:
  bootstrap, inspection, and emergency operations
- `crane`:
  digest-preserving image copy
- `flux`:
  reconciles Git state into the management cluster

Example bootstrap commands
```bash
gcloud artifacts repositories create customer-a-r2026q2 \
  --project="${PROJECT_ID}" \
  --location="${LOCATION}" \
  --repository-format=docker \
  --description="Controlled delivery repository for customer-a batch r2026q2"

gcloud artifacts repositories add-iam-policy-binding customer-a-r2026q2 \
  --project="${PROJECT_ID}" \
  --location="${LOCATION}" \
  --member="serviceAccount:delivery-bot@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.writer"

gcloud artifacts repositories add-iam-policy-binding customer-a-r2026q2 \
  --project="${PROJECT_ID}" \
  --location="${LOCATION}" \
  --member="serviceAccount:customer-a-sync@customer-project.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.reader"
```

Example image publication commands
```bash
crane copy \
  asia-east1-docker.pkg.dev/prod-release/tidb/tidb@sha256:1111 \
  asia-east1-docker.pkg.dev/delivery-project/customer-a-r2026q2/tidb:v8.5.0

crane digest \
  asia-east1-docker.pkg.dev/delivery-project/customer-a-r2026q2/tidb:v8.5.0
```

Example retirement commands
```bash
gcloud artifacts repositories remove-iam-policy-binding customer-a-r2026q2 \
  --project="${PROJECT_ID}" \
  --location="${LOCATION}" \
  --member="serviceAccount:customer-a-sync@customer-project.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.reader"

gcloud artifacts repositories delete customer-a-r2026q2 \
  --project="${PROJECT_ID}" \
  --location="${LOCATION}" \
  --quiet
```

Minimal delivery automation commands
- `create-delivery-repo`
- `grant-delivery-reader`
- `publish-images-by-digest`
- `generate-images-lock`
- `revoke-delivery-reader`
- `cleanup-expired-delivery-repos`

Recommended validations
- Validate repository labels and IAM after Terraform apply.
- Validate every copied image digest after publication.
- Validate that customer identities cannot access repositories outside their own batch.
- Validate expiration workflow in a dry-run environment before enabling automatic deletion.

Operational note
- Manual `gcloud` commands may be used during bootstrap or break-glass events.
- The desired steady state is still Git-declared and Git-reconciled, with `gcloud` used as an execution tool behind automation.
