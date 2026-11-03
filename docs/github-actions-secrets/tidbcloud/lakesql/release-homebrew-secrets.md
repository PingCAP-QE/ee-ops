# LakeSQL release-homebrew Secrets

This document defines the GitHub Actions secrets required by `tidbcloud/lakesql` environment `release-homebrew`, how they are mapped in `ee-ops`, and the GitHub App permissions required for cross-repo Homebrew PR automation.

## Managed secrets

These GitHub Actions environment secrets are delivered by External Secrets Operator to `tidbcloud/lakesql` environment `release-homebrew`.

The source of truth in GCP Secret Manager is the dedicated GitHub App **`lakesql-homebrew-tap`** (App ID `5594134`, owned by `PingCAP-QE`), installed on `tidbcloud/homebrew-tap` only:

- `gha__repo__tidbcloud__lakesql__homebrew_tap_github_app_client_id`
- `gha__repo__tidbcloud__lakesql__homebrew_tap_github_app_private_key`

They are pushed into the GitHub environment as:

| GitHub secret name | GCP secret name | Expected value |
| --- | --- | --- |
| `HOMEBREW_TAP_GITHUB_APP_CLIENT_ID` | `gha__repo__tidbcloud__lakesql__homebrew_tap_github_app_client_id` | client ID of the `lakesql-homebrew-tap` App |
| `HOMEBREW_TAP_GITHUB_APP_PRIVATE_KEY` | `gha__repo__tidbcloud__lakesql__homebrew_tap_github_app_private_key` | PEM-encoded private key of the same App |

Although the value is a client ID rather than a sensitive credential, this repo still delivers it through a GitHub Actions environment secret because the current centralized `ee-ops` delivery path manages GitHub Actions secrets, not variables.

> **Keep system credentials in the cluster.** `gha__system__*` secrets are shared by several services (including the token broker and this delivery system itself) and must not be delivered into GitHub Actions secrets. A GitHub App private key cannot be narrowed by permission settings — use a dedicated App per consumer instead.

## Required GitHub App permissions

The GitHub App referenced by these secrets must be installed on `tidbcloud/homebrew-tap` and have exactly:

- repository permission `Contents`: `Read and write`
- repository permission `Pull requests`: `Read and write`
- everything else: `No access`

`lakesql-homebrew-tap` is dedicated to this workflow and installed on that single repository. The workflow additionally narrows the installation token it mints (`repositories: homebrew-tap`, `contents: write`, `pull_requests: write`), so the credential's blast radius is `tidbcloud/homebrew-tap` alone.

## Source of truth in GCP Secret Manager

The two secrets above may be created and rotated from this runbook — they are repository-scoped and affect only this environment.

Rotate by adding a new version in Secret Manager, then forcing the source `ExternalSecret` to reconcile. The `PushSecret` copies the new value to GitHub under the same remote key, so the workflow does not change:

```bash
export PROJECT_ID=pingcap-testing-account
gcloud secrets versions add gha__repo__tidbcloud__lakesql__homebrew_tap_github_app_private_key \
  --project="${PROJECT_ID}" --data-file=/secure/path/lakesql-homebrew-tap.private-key.pem

kubectl -n github-actions-secrets annotate externalsecret es-src-homebrew-tap-github-app-private-key \
  force-sync="$(date +%s)" --overwrite
```

Then delete the superseded key in the App settings:
`https://github.com/organizations/PingCAP-QE/settings/apps/lakesql-homebrew-tap`.
## Delivery mapping in ee-ops

The GitOps objects for this environment live under:

- `infrastructure/gcp/github-actions-secrets/repos/tidbcloud/lakesql/00-target-stores`
- `infrastructure/gcp/github-actions-secrets/repos/tidbcloud/lakesql/01-source-secrets`
- `infrastructure/gcp/github-actions-secrets/repos/tidbcloud/lakesql/02-deliveries`

After the two repository-scoped GCP secrets are present in Secret Manager and Flux reconciles the manifests, ESO will:

- extract the two values into cluster-local source secrets: `src-homebrew-tap-github-app-client-id` and `src-homebrew-tap-github-app-private-key`
- push them into GitHub environment `tidbcloud/lakesql:release-homebrew`

This environment is intended for the release workflow step that opens or updates formula PRs in `tidbcloud/homebrew-tap`.
