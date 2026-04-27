# Staging GitOps

> deploy prow.tidb.net

## Prepare

### Secrets

| namespace   | secret name                | prepare commands                                   | keys                                                                                                                                                                                            | description |
| ----------- | -------------------------- | -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- |
| flux-system | prow                       | `kubectl -n flux-system create secret generic ...` | `DOMAIN_NAME`, `GITHUB_APP_ID`, `GITHUB_APP_CERT`, `GITHUB_APP_WEBHOOK_HMAC`, `GITHUB_TOKEN`,`GITHUB_APP_CLIENT_ID`,`GITHUB_APP_CLIENT_SECRET`, `OAUTH_COOKIE_SECRET`, `GCS_CREDENTIALS_BASE64` |             |
| flux-system | gcs-credentials            | `service-account.json`                             | GCS credentials for prow                                                                                                                                                                        |             |
| apps        | prow-jenkins-operator-auth | `user`, `token`                                    | auth to external jenkins controller                                                                                                                                                             |             |
| apps        | prow-tls                   |                                                    | prow site ingress cert secret                                                                                                                                                                   |             |
| infra       | tf-controller-gcp-sa       | `kubectl -n infra create secret generic ...`       | GCP service account JSON key (alternative to Workload Identity)                                                                                                                                 |             |

## Terraform GitOps (tofu-controller)

This cluster uses [tofu-controller](https://flux-iac.github.io/tofu-controller/) to manage GCP resources via GitOps.

### Setup

1. **Create GCP Service Account** (if not already exists):

```bash
gcloud iam service-accounts create tf-controller \
    --project=pingcap-testing-account \
    --display-name="Terraform Controller Runner"

# Grant necessary roles (adjust as needed):
gcloud projects add-iam-policy-binding pingcap-testing-account \
    --member="serviceAccount:tf-controller@pingcap-testing-account.iam.gserviceaccount.com" \
    --role="roles/dns.admin"

gcloud projects add-iam-policy-binding pingcap-testing-account \
    --member="serviceAccount:tf-controller@pingcap-testing-account.iam.gserviceaccount.com" \
    --role="roles/storage.admin"
```

2. **Configure Workload Identity** (optional, recommended for GKE):

```bash
# Get the GKE cluster name
gcloud container clusters list --project=pingcap-testing-account

# Create IAM policy binding between KSA and GCP SA
gcloud iam service-accounts add-iam-policy-binding \
    tf-controller@pingcap-testing-account.iam.gserviceaccount.com \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:pingcap-testing-account.svc.id.goog[terraform/tofu-controller-runner]"
```

3. **Deploy**: After the above prerequisites are met, tofu-controller will be deployed automatically via FluxCD.

### Usage

Terraform resources are defined as Kubernetes CRDs in `infrastructure/gcp/terraform/`:

```
infrastructure/gcp/terraform/
├── kustomization.yaml
├── gcp-dns/                  # Example: DNS zone management
│   ├── main.tf
│   └── terraform.yaml
└── gcp-storage-bucket/        # Example: GCS bucket management
    ├── main.tf
    └── terraform.yaml
```

To add new GCP resources managed by Terraform:
1. Create a new directory under `infrastructure/gcp/terraform/`
2. Add Terraform HCL files (e.g., `main.tf`, `variables.tf`, `outputs.tf`)
3. Create a `terraform.yaml` with the `Terraform` CRD
4. Add the resource to `kustomization.yaml`

### Workflow

1. Make changes to Terraform modules or CRs in `infrastructure/gcp/terraform/`
2. Commit and push to feature branch
3. Create PR to main
4. After merge, tofu-controller will reconcile the Terraform resources
5. Check status: `kubectl get terraform -n terraform`
6. View logs: `kubectl logs -n infra deployment/tofu-controller`

### Manual Approval

For production resources, set `spec.approvePlan` explicitly instead of `auto`:
```yaml
# First, let the controller generate a plan
# Then find the plan name:
kubectl get terraform gcp-dns-example -n terraform -o jsonpath='{.status.plan}'
# Finally, set the plan name to apply:
# approvePlan: plan-main-<generated-id>
```
