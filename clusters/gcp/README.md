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
| flux-system | tf-runner-gcp-sa         | `kubectl -n flux-system create secret generic ...` | GCP service account JSON key (alternative to Workload Identity)                                                                                                                                 |             |

## Terraform GitOps (tofu-controller)

This cluster uses [tofu-controller](https://flux-iac.github.io/tofu-controller/) to manage GCP resources via GitOps.

### Prerequisites

- FluxCD installed and bootstrapped on the cluster
- `kubectl` configured with cluster access
- `gcloud` CLI installed and authenticated
- GCP project with required APIs enabled (IAM, GKE, DNS, Storage, etc.)

### Namespace Convention

| Namespace    | Purpose                                                              |
| ------------ | -------------------------------------------------------------------- |
| `flux-system`| tofu-controller deployment, runner SA with Workload Identity         |

### Setup

1. **Create GCP Service Account** (if not already exists):

```bash
gcloud iam service-accounts create tf-runner \
    --project=pingcap-testing-account \
    --display-name="Tofu Controller Runner"

# Grant necessary roles (adjust as needed):
gcloud projects add-iam-policy-binding pingcap-testing-account \
    --member="serviceAccount:tf-runner@pingcap-testing-account.iam.gserviceaccount.com" \
    --role="roles/dns.admin"

gcloud projects add-iam-policy-binding pingcap-testing-account \
    --member="serviceAccount:tf-runner@pingcap-testing-account.iam.gserviceaccount.com" \
    --role="roles/storage.admin"
```

2. **Configure Workload Identity** (optional, recommended for GKE):

```bash
# Create IAM policy binding between KSA (in flux-system namespace) and GCP SA
gcloud iam service-accounts add-iam-policy-binding \
    tf-runner@pingcap-testing-account.iam.gserviceaccount.com \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:pingcap-testing-account.svc.id.goog[flux-system/tf-runner]"
```

3. **Deploy**: After the above prerequisites are met, push changes to main. FluxCD will
   automatically reconcile and deploy tofu-controller. Key resources:
   - `HelmRepository` → defines the tofu-controller Helm chart source
   - `HelmRelease` → deploys tofu-controller to `flux-system` namespace
   - `ServiceAccount` → runner SA (`tf-runner`) with Workload Identity annotation in `flux-system` namespace

### Usage

Terraform resources are defined as Kubernetes CRDs in the infrastructure/gcp/terraform/ directory:

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
3. Create a `terraform.yaml` with the `Terraform` CRD (set `metadata.namespace: terraform`)
4. Add the resource to `kustomization.yaml`

### Workflow

1. Make changes to Terraform CRs in the infrastructure/gcp/terraform/ directory
2. Commit and push to feature branch
3. Create PR to main
4. After merge, tofu-controller will reconcile the Terraform resources
5. Check status: `kubectl get terraform -n flux-system`
6. Check runner logs if Terraform apply fails: `kubectl logs -n flux-system -l app.kubernetes.io/name=tofu-runner`
7. Check controller logs: `kubectl logs -n flux-system deployment/tofu-controller`

### Manual Approval

For production resources, set `spec.approvePlan` explicitly instead of `auto`:

```yaml
# First, let the controller generate a plan:
kubectl get terraform <resource-name> -n flux-system -o jsonpath='{.status.plan}'
# Then set the plan name to apply (under spec.approvePlan):
#   approvePlan: plan-main-<generated-id>
```

This ensures a human reviews the plan before Terraform applies changes.

### Troubleshooting

| Symptom                              | Likely Cause                                   | Check                                                           |
| ------------------------------------ | ---------------------------------------------- | --------------------------------------------------------------- |
| Controller pod not starting          | Missing HelmRepository or chart version        | `kubectl get helmrelease -n flux-system tofu-controller`       |
| Terraform CR not reconciling         | Namespace mismatch or RBAC issue               | `kubectl describe terraform -n flux-system <name>`              |
| Runner pod fails with auth error     | Workload Identity not configured correctly     | `kubectl describe sa -n flux-system tf-runner`                |
| Terraform plan stuck in "pending"    | Concurrency limit reached or plan in progress  | Check `tofu-controller` logs and runner status                  |

For further investigation, check:
- `kubectl get kustomizations -n flux-system` to verify FluxCD reconciliation
- `flux logs --all-namespaces` for FluxCD reconciliation logs

## Flux Upgrade Preflight

Before bumping `clusters/gcp/flux-system/gotk-components.yaml` in the next upgrade phase, run the repo-side and cluster-side checks below:

```bash
./scripts/check_gcp_flux_api_versions.sh
./scripts/flux_gcp_preflight.sh --context <gke-context> --min-k8s <major.minor> --max-k8s <major.minor>
```

The first check verifies that all GCP Flux `GitRepository` / `HelmRepository`, Flux `Kustomization`, `Alert` / `Provider`, and `HelmRelease` manifests have already moved to the PR1 API targets.

The second check verifies two live-cluster prerequisites:
- the GKE control plane version is inside the support window for the target Flux release
- `status.storedVersions` no longer contains the deprecated Flux API versions removed by the next phase

Set `--min-k8s` and `--max-k8s` from the target Flux release notes before upgrading `flux-system`. Use `--allow-non-gke` only when testing the script against a non-GKE cluster.

## Flux v2.7 Upgrade

PR2 upgrades GCP `flux-system` from Flux `v2.2.3` to Flux `v2.7.5`, which is the latest `v2.7.x` patch as of 2026-04-30.

Before applying the new `clusters/gcp/flux-system/gotk-components.yaml` to the live cluster:

```bash
flux --version
./scripts/flux_gcp_preflight.sh --context <gke-context> --min-k8s <major.minor> --max-k8s <major.minor>
flux --context <gke-context> migrate
```

After the new manifests are applied and reconciled, verify the live upgrade result with:

```bash
./scripts/flux_gcp_post_upgrade_verify.sh --context <gke-context>
```

The post-upgrade verification asserts that:
- all Flux controller deployments in `flux-system` are available
- Flux CRD `status.storedVersions` have migrated to the current storage versions, including `helmreleases=v2`
- `flux check` succeeds and `flux get all --all-namespaces --status-selector=ready=false` returns no resources
