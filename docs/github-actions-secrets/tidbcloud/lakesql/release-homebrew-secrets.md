# LakeSQL release-homebrew Secrets

This document defines the GitHub Actions secrets required by `tidbcloud/lakesql` environment `release-homebrew`, how they are mapped in `ee-ops`, and the GitHub App permissions required for cross-repo Homebrew PR automation.

## Managed secrets

These GitHub Actions environment secrets are delivered by External Secrets Operator to `tidbcloud/lakesql` environment `release-homebrew`.

The source of truth in GCP Secret Manager is two shared system secrets:

- `gha__system__github_app_id`
- `gha__system__github_app_private_key`

They are pushed into the GitHub environment as:

| GitHub secret name | GCP secret name | Expected value |
| --- | --- | --- |
| `HOMEBREW_TAP_GITHUB_APP_ID` | `gha__system__github_app_id` | decimal GitHub App ID for the shared GitHub App installed on `tidbcloud/homebrew-tap` |
| `HOMEBREW_TAP_GITHUB_APP_PRIVATE_KEY` | `gha__system__github_app_private_key` | PEM-encoded private key for the same shared GitHub App |

## Required GitHub App permissions

The GitHub App referenced by these secrets must be installed on `tidbcloud/homebrew-tap` and have at minimum:

- repository permission `Contents`: `Read and write`
- repository permission `Pull requests`: `Read and write`

This workflow reuses the shared company GitHub App. Confirm that its `tidbcloud/homebrew-tap` installation has those permissions before publishing the secrets.

## Create or update the source of truth in GCP Secret Manager

Set the project first:

```bash
export PROJECT_ID=pingcap-testing-account
```

Create `gha__system__github_app_id` if it does not already exist:

```bash
gcloud secrets create gha__system__github_app_id \
  --project="${PROJECT_ID}" \
  --replication-policy=automatic
```

Add or rotate the shared GitHub App ID:

```bash
printf '%s' '214286' | gcloud secrets versions add \
  gha__system__github_app_id \
  --project="${PROJECT_ID}" \
  --data-file=-
```

`gha__system__github_app_private_key` is reused as-is. The private key payload should remain the original PEM issued by GitHub App settings.

## Delivery mapping in ee-ops

The GitOps objects for this environment live under:

- `infrastructure/gcp/github-actions-secrets/repos/tidbcloud/lakesql/00-target-stores`
- `infrastructure/gcp/github-actions-secrets/repos/tidbcloud/lakesql/01-source-secrets`
- `infrastructure/gcp/github-actions-secrets/repos/tidbcloud/lakesql/02-deliveries`

After the two shared GCP secrets are present in Secret Manager and Flux reconciles the manifests, ESO will:

- extract the two values into cluster-local source secrets: `src-homebrew-tap-github-app-id` and `src-homebrew-tap-github-app-private-key`
- push them into GitHub environment `tidbcloud/lakesql:release-homebrew`

This environment is intended for the release workflow step that opens or updates formula PRs in `tidbcloud/homebrew-tap`.
