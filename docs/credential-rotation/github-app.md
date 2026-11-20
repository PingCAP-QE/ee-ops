# GitHub App private key rotation

This document covers the private keys of the GitHub App `ti-chi-bot`
(App ID `214286`) that the token brokers and the GitHub Actions secret writer
authenticate with. The App's installation tokens are short-lived; the **private
key that signs the token requests is not** and is the credential handled here.

For the machine-user PAT / SSH key see [`github-bot.md`](github-bot.md).

## Where the keys live

GCP Secret Manager in project `pingcap-testing-account` is the source of truth.

| Secret Manager secret | Consumers |
|---|---|
| `gha__system__github_app_private_key` | `apps/gcp/github-token-broker` (`ExternalSecret` `github-app-credentials`, key `privateKey.pem`); `apps/tencentcloud/github-token-broker` (same shape); `infrastructure/gcp/github-actions-secrets` secret writer (`SecretStore` `gcp-sm-github-actions` → Secret `github-app-private-key`) |
| `gcp_prow_github_app_json` | Prow `apps/prow-github` (JSON with `app-id`, `app-private-key`, `secret`) |

The App ID is configured separately in each consumer
(`apps/gcp/github-token-broker/release.yaml`, `.../gh-environments.yaml`).

One key currently serves all of the brokers **and** the Actions secret writer,
because a GitHub App private key is the App's identity and cannot be scoped down
per consumer. Narrowing the blast radius therefore means separate Apps, not
separate keys of the same App; that split is tracked separately and is not part
of this document.

## Rotation

A GitHub App does not give two independent active keys here, so rotation is a
short swap window rather than a staged overlap. Budget a few minutes of broker
unavailability and do it off-peak.

### 1. Generate the new key

In the App settings (`https://github.com/organizations/PingCAP-QE/settings/apps`,
App `214286`) generate a new private key and download the `.pem` file. Keep the
file only until it is stored in Secret Manager; do not commit it (`gitleaks` runs
on every PR).

### 2. Publish to Secret Manager

```bash
gcloud secrets versions add gha__system__github_app_private_key \
  --project=pingcap-testing-account --data-file=./app-214286-$(date +%Y%m%d).pem
```

Prow keeps its own copy, so the JSON blob has to be rebuilt in the same window:

```bash
gcloud secrets versions access latest --secret=gcp_prow_github_app_json \
    --project=pingcap-testing-account \
  | jq --rawfile key ./app-214286-$(date +%Y%m%d).pem \
      '.app-private-key=$key' \
  | gcloud secrets versions add gcp_prow_github_app_json \
      --project=pingcap-testing-account --data-file=-
```

### 3. Force ESO reconciliation and restart the consumers

Both brokers read the key at start-up and cache the parsed key, so a resync
alone is not enough.

```bash
# GCP cluster
for item in github-token-broker/github-app-credentials \
            infra/github-app-private-key \
            apps/prow-github; do
  ns=${item%%/*}; name=${item#*/}
  kubectl -n "$ns" annotate externalsecret "$name" \
    force-sync="$(date +%s)" --overwrite
done
kubectl -n github-token-broker rollout restart deploy/github-token-broker

# TKE cluster: github-token-broker only (no prow, no Actions secret writer)
kubectl -n github-token-broker annotate externalsecret github-app-credentials \
  force-sync="$(date +%s)" --overwrite
kubectl -n github-token-broker rollout restart deploy/github-token-broker
```

### 4. Verify

- `kubectl -n github-token-broker get externalsecret github-app-credentials`
  reports `SecretSynced=True` with a fresh `refreshTime`.
- A token request against the broker returns a token (HTTP 200), and the token
  works for the repository it was asked for.
- Any `PushSecret` that uses the Actions writer still reports `Synced`.
- Prow can still trigger a job and comment on a PR.

### 5. Retire the old key

Delete the superseded private key in the App settings, and disable the
superseded Secret Manager versions:

```bash
gcloud secrets versions disable <old> \
  --secret=gha__system__github_app_private_key \
  --project=pingcap-testing-account
```

## Rollback

If the brokers cannot authenticate with the new key, add the previous Secret
Manager versions back and restart the brokers:

```bash
gcloud secrets versions access <previous> \
    --secret=gha__system__github_app_private_key \
    --project=pingcap-testing-account \
  | gcloud secrets versions add gha__system__github_app_private_key \
      --project=pingcap-testing-account --data-file=-
```

That only helps while the previous key still exists in the App; once it is
deleted in GitHub, the fallback is a fresh key, not the old one.

## Cadence and ownership

GitHub App keys have no expiry, so the trigger is calendar plus event: at least
yearly, on any maintainer change with access to the App settings, and
immediately on suspected exposure. Record the rotation date and the App owner in
the security tracking issue for this repository.
