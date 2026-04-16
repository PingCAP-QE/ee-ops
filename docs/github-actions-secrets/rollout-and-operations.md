# Rollout And Operations Plan

## Prerequisites

### GitHub

- Create one company GitHub App for Actions secret delivery.
- Install the app into each target GitHub organization.
- Record the `appID` and each organization `installationID`.
- Grant minimum required permissions:
  - organization `Secrets`: write
  - repository `Secrets`: write
  - repository `Environments`: write if environment secrets are needed

### GCP

- Create a dedicated GCP service account for GitHub secret delivery.
- Grant it access only to the GitHub-related secrets.
- Store the GitHub App private key in GCP Secret Manager.
- Store each logical credential in GCP Secret Manager.
- Bind the Kubernetes service account `github-actions-secrets/gcp-sm-github-actions` to that GCP service account through GKE Workload Identity.

### Kubernetes and Flux

- Pick one active writer cluster. Recommendation: `gcp`.
- Create the `github-actions-secrets` namespace.
- Ensure GKE Workload Identity Federation is enabled on the chosen cluster.
- Create the Kubernetes service account `gcp-sm-github-actions` in `github-actions-secrets`.
- Annotate it with `iam.gke.io/gcp-service-account: <gcp-service-account>@<project>.iam.gserviceaccount.com`.
- Ensure Kubernetes secret encryption at rest is enabled on the chosen cluster.
- Ensure ESO is healthy in the chosen cluster.
- If you need declarative org-secret visibility control, upgrade ESO from chart `0.19.0` before implementation.

## Prepare GCP IAM For Workload Identity

The current design uses the Kubernetes-service-account to Google-service-account link pattern for GKE Workload Identity:

- Kubernetes service account: `github-actions-secrets/gcp-sm-github-actions`
- Google service account: `gcp-sm-github-actions@pingcap-testing-account.iam.gserviceaccount.com`
- source store: namespaced `SecretStore` `gcp-sm-github-actions`

The currently selected active writer cluster is the repo's `gcp` cluster. In the local environment used to validate this design, that cluster is:

- cluster: `prow`
- location: `us-central1-c`
- project: `pingcap-testing-account`
- workload pool: `pingcap-testing-account.svc.id.goog`

### Recommended Variables

Use these variables when preparing the environment:

```bash
export PROJECT_ID=pingcap-testing-account
export CLUSTER_NAME=prow
export CLUSTER_LOCATION=us-central1-c

export KSA_NAMESPACE=github-actions-secrets
export KSA_NAME=gcp-sm-github-actions

export GSA_NAME=gcp-sm-github-actions
export GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
```

### 1. Confirm Workload Identity Is Enabled On The Cluster

```bash
gcloud container clusters describe "${CLUSTER_NAME}" \
  --project="${PROJECT_ID}" \
  --location="${CLUSTER_LOCATION}" \
  --format='value(workloadIdentityConfig.workloadPool)'
```

Expected output:

```text
pingcap-testing-account.svc.id.goog
```

If this value is empty, stop here and enable GKE Workload Identity Federation before proceeding.

### 2. Create The Google Service Account

```bash
gcloud iam service-accounts create "${GSA_NAME}" \
  --project="${PROJECT_ID}" \
  --display-name="ESO GitHub Actions Secret Manager access"
```

Verify:

```bash
gcloud iam service-accounts describe "${GSA_EMAIL}" \
  --project="${PROJECT_ID}"
```

### 3. Grant Secret Manager Access To The Google Service Account

Recommended role:

- `roles/secretmanager.secretAccessor`

Preferred grant model:

- grant access at the individual secret level
- only use project-level access if secret-level bindings become operationally unmanageable

#### Option A: Secret-level bindings, preferred

Grant the GSA access to each required secret explicitly.

Example for the GitHub App private key:

```bash
gcloud secrets add-iam-policy-binding gha__system__github_app_private_key \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor"
```

Example for one shared credential:

```bash
gcloud secrets add-iam-policy-binding gha__shared__dockerhub_token \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor"
```

Repeat for every secret that the `gcp-sm-github-actions` `SecretStore` must read.

#### Option B: Project-level binding, broader access

Use this only if secret-level management is too costly for your current rollout stage.

```bash
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${GSA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor"
```

Tradeoff:

- simpler to operate
- significantly broader blast radius

### 4. Create The Kubernetes Namespace And Service Account

```bash
kubectl create namespace "${KSA_NAMESPACE}"

kubectl create serviceaccount "${KSA_NAME}" \
  --namespace "${KSA_NAMESPACE}"
```

If the namespace already exists, only create or reconcile the service account.

### 5. Allow The Kubernetes Service Account To Impersonate The Google Service Account

Grant the Kubernetes service account permission to act as the Google service account:

```bash
gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${KSA_NAMESPACE}/${KSA_NAME}]"
```

This binding is required for the linked KSA-to-GSA Workload Identity model used in this design.

### 6. Annotate The Kubernetes Service Account

```bash
kubectl annotate serviceaccount "${KSA_NAME}" \
  --namespace "${KSA_NAMESPACE}" \
  iam.gke.io/gcp-service-account="${GSA_EMAIL}" \
  --overwrite
```

Optional:

```bash
kubectl annotate serviceaccount "${KSA_NAME}" \
  --namespace "${KSA_NAMESPACE}" \
  iam.gke.io/return-principal-id-as-email="true" \
  --overwrite
```

### 7. Verify The Binding Before Applying ESO Resources

Verify the GSA exists:

```bash
gcloud iam service-accounts describe "${GSA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --format='value(email)'
```

Verify the KSA annotation:

```bash
kubectl get serviceaccount "${KSA_NAME}" \
  --namespace "${KSA_NAMESPACE}" \
  -o yaml
```

Verify the Workload Identity IAM binding:

```bash
gcloud iam service-accounts get-iam-policy "${GSA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --format=json
```

Verify secret-level access for one example secret:

```bash
gcloud secrets get-iam-policy gha__system__github_app_private_key \
  --project="${PROJECT_ID}" \
  --format=json
```

### 8. Roles That Are Not Required For This Design

You do not need:

- a JSON service account key stored in Kubernetes
- `roles/iam.serviceAccountTokenCreator` for the ESO source-read path
- broad owner/editor roles on the project

The minimal intended access pattern is:

- `roles/iam.workloadIdentityUser` on the GSA for `github-actions-secrets/gcp-sm-github-actions`
- `roles/secretmanager.secretAccessor` on only the secrets, or at most the project, that the design needs to read

## Rollout Phases

### Phase 0: Control plane setup

Deliver:

- dedicated namespace
- Workload-Identity-backed Kubernetes service account for GCP Secret Manager access
- namespaced GCP `SecretStore` `gcp-sm-github-actions`
- GitHub App private key `ExternalSecret`
- first GitHub target `SecretStore`

Exit criteria:

- GitHub App private key syncs into the namespace
- GitHub target `SecretStore` is ready
- no other cluster is configured to push to GitHub

### Phase 1: Pilot with one org and low-risk secrets

Pilot shape:

- one GitHub organization
- one or two repositories
- non-production secrets first
- prefer repository or environment secrets for the first pilot unless an ESO upgrade for org visibility has already been done

Suggested pilot examples:

- `CODECOV_TOKEN`
- `NPM_TOKEN`
- `DOCKERHUB_TOKEN`

Exit criteria:

- secrets appear in GitHub with the expected scope
- a test workflow can read them successfully
- updates in GCP Secret Manager are reflected in GitHub after ESO reconciliation

### Phase 2: Migrate broadly shared org secrets

Target secrets that:

- are used by many private repos in the same org
- do not require selected-repository visibility
- fit within the org secret count budget
- are backed by an ESO version that can declare org visibility, or already exist in GitHub with the desired visibility

Exit criteria:

- commonly shared credentials are no longer managed repo by repo
- organization secret count remains comfortably below the practical per-repo usage limit

### Phase 3: Migrate selected repo and environment secrets

Move:

- repo-specific tokens
- per-repo overrides
- deployment environment credentials

Exit criteria:

- manual GitHub secrets are reduced to zero or to an explicitly approved exception list
- all delivery mappings live in Git

### Phase 4: Add guardrails and scale tooling

Add:

- Kyverno policies for namespace and store restrictions
- alerts for failing `PushSecret` resources
- optional catalog generation for large repo inventories

Exit criteria:

- the process is self-service for platform maintainers
- policy prevents accidental sprawl

## Migration Procedure For One Secret

1. Inventory the current GitHub secret:
   - scope
   - secret name
   - owning team
   - current repositories and environments
2. Put the secret value into GCP Secret Manager.
3. Add the source `ExternalSecret`.
4. Add the target GitHub `SecretStore` or reuse an existing one.
5. Add the `PushSecret`.
6. Let Flux apply the manifests.
7. Verify the secret exists in GitHub at the expected scope.
8. Run a workflow that consumes the secret.
9. Mark the GitHub secret as centrally managed and stop manual edits.

## Rotation Procedure

1. Update the secret value in GCP Secret Manager.
2. Wait for the source `ExternalSecret` to refresh the Kubernetes `Secret`.
3. Wait for `PushSecret` to reconcile and update GitHub.
4. Run a verification workflow if the secret is business-critical.

Operational note:

- org and repo secrets are read when the workflow run is queued
- environment secrets are read when the job referencing that environment starts

This means already queued runs may still use the old org or repo secret value.

## Break-Glass Procedure

If a production incident requires an emergency secret change:

1. Update the source value in GCP Secret Manager first.
2. Force reconciliation of the relevant `ExternalSecret` and `PushSecret` if needed.
3. Avoid editing GitHub directly unless the ESO path is unavailable.
4. If a direct GitHub edit is unavoidable, backfill GCP Secret Manager and Git immediately after the incident.

## Observability And Validation

### Kubernetes checks

Use ESO status as the primary health signal.

Recommended checks:

```bash
kubectl -n github-actions-secrets get externalsecret
kubectl -n github-actions-secrets get pushsecret
kubectl -n github-actions-secrets describe externalsecret <name>
kubectl -n github-actions-secrets describe pushsecret <name>
kubectl -n infra logs deploy/external-secrets -c external-secrets
```

### GitHub checks

Validate:

- the secret exists at the expected scope
- the secret name is correct
- the consuming workflow can access it

### Alerts

Alert on:

- `ExternalSecret` not ready
- `PushSecret` not ready
- repeated GitHub API errors
- repeated GCP Secret Manager access failures

## Common Failure Modes

### Wrong `installationID`

Symptoms:

- GitHub `SecretStore` is not ready
- GitHub API returns authorization or not found errors

Fix:

- confirm the app installation exists in the target org
- update the `installationID` in the target `SecretStore`

### Wrong Workload Identity binding

Symptoms:

- source `ExternalSecret` is not ready
- ESO logs show permission denied or token exchange failures against GCP

Fix:

- confirm GKE Workload Identity Federation is enabled on the cluster
- confirm the Kubernetes service account annotation matches the intended GCP service account
- confirm the GCP service account grants `roles/iam.workloadIdentityUser` to the Kubernetes service account
- confirm the GCP service account has `roles/secretmanager.secretAccessor` on the required secrets or project

### Secret pushed to the wrong scope

Cause:

- wrong `SecretStore` reuse

Fix:

- create a separate store for repo or environment scope
- avoid reusing an org store for repo-specific delivery

### Secret should reach only some repos in an org

Cause:

- attempted use of org-level selected visibility

Fix:

- use repo-scoped `SecretStore` plus `PushSecret` fan-out

### Too many organization secrets available to a repo

Cause:

- org-level sprawl

Fix:

- move narrower secrets to repo or environment scope
- keep broad shared secrets only at the org layer

### Drift caused by manual GitHub edits

Cause:

- GitHub changed outside the central pipeline

Fix:

- treat GitHub as projection only
- restore source-of-truth from GCP Secret Manager and Git

## Scale Recommendations

### Up to tens of repos

Plain manifests are fine:

- one source `ExternalSecret` per logical credential
- one `PushSecret` per delivery set
- explicit `SecretStore` inventory

### Beyond that

Introduce a generated inventory model:

- one catalog file that describes targets
- generated `SecretStore` and `PushSecret` manifests from that catalog

Do not start with a generator unless the explicit manifests become hard to review.

## Recommended Initial Scope

Start with:

- one org
- 3 to 5 shared repository secrets
- 1 environment secret

Do not start with:

- every org at once
- production deployment credentials first
- selected-repository org sharing patterns, because the current provider does not model them

## Success Criteria

- secret values exist only in the external secret manager and in the controlled Kubernetes delivery namespace
- GitHub secrets are reproducible from Git and the source store
- there is exactly one active writer cluster for GitHub delivery
- new orgs and repos can be onboarded without manual secret entry in GitHub
- platform maintainers can rotate a secret by changing only the source secret manager entry
