# Delivery approval service (prerequisites)

This directory holds the approval service prerequisites (namespace,
NetworkPolicy, ExternalSecrets), the one-shot schema migration and the
HelmRelease/route/OIDC policy. Flux reconciles them in this order:

```
prereq -> migrate -> app (HelmRelease + HTTPRoute + SecurityPolicy)
```

The service is described in
`conductor/projects/PingCAP-QE/ee-apps/tracks/delivery_approval_service_20261123/spec.md`
in the agents vault. This README is the operator runbook for the cloud resources
that GitOps cannot create (TiDB database/users, GSM values, Google OAuth, Lark
app).

## What GitOps creates

| Resource | Path |
| --- | --- |
| namespace `dl-approval` | `prereq/namespace.yaml` |
| NetworkPolicy (ingress `infra` only; egress DNS/`dl`/public 443/4000) | `prereq/networkpolicy.yaml` |
| `ExternalSecret/dl-approval-oidc` | `prereq/external-secrets/oidc.yaml` |
| `ExternalSecret/dl-approval-tidb` | `prereq/external-secrets/tidb.yaml` |
| `ExternalSecret/dl-approval-config` | `prereq/external-secrets/config.yaml` |
| migration Job | `migrate/job.yaml` |
| HelmRelease + HTTPRoute + OIDC policy | `app/release.yaml`, `app/route.yaml`, `app/security-policy.yaml` |
| Flux Kustomizations | `apps/gcp/dl-approval/flux.yaml` (applied by the cluster-level `apps` Kustomization) |

`infrastructure/gcp/external-secrets/post/css-ee-gcp-sm.yaml` must allow the new
namespace; it does. These resources are GitOps-managed: merge the Phase 0/6 PR and
let Flux reconcile `infrastructure` and `dl-approval` (or `dl-approval-prereq`
after the Phase 6 split). Do not keep `kubectl apply` as the owner; a manual apply
is only a pre-merge dry-run/bootstrap.

Re-run the scope inventory after changing ExternalSecrets:

```bash
scripts/eso-scope-inventory.sh --write   # updates docs/external-secrets-scope.md
scripts/eso-scope-inventory.sh --check   # what CI runs
```

## 1. TiDB database and roles

Run once with an admin identity against the shared TiDB primary SQL endpoint
(the same cluster that backs `dl`; do **not** use a stale-read/replica endpoint).
TiDB Cloud usernames must carry the cluster prefix. Use your own
`<cluster-prefix>.<short-name>` values below; do not commit them to this file:

```sql
CREATE DATABASE IF NOT EXISTS delivery_approval
  CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;

-- Migration identity: DDL on this database only.
CREATE USER IF NOT EXISTS '<migrate-user>'@'%' IDENTIFIED BY '<random-1>';
GRANT ALL PRIVILEGES ON delivery_approval.* TO '<migrate-user>'@'%';

-- Runtime identity: no DDL, no DELETE; events are append-only.
CREATE USER IF NOT EXISTS '<runtime-user>'@'%' IDENTIFIED BY '<random-2>';
GRANT SELECT, INSERT, UPDATE ON delivery_approval.* TO '<runtime-user>'@'%';

FLUSH PRIVILEGES;
```

Use TLS in both DSNs (`tls=true`) and `parseTime=true&loc=UTC`. The app never
runs DDL; the migration Job uses `migrate_dsn`.

## 2. GCP Secret Manager

Create the two JSON keys referenced by the ExternalSecrets. Keep the values out
of the repository and shell history where possible.

### `gcp_dl_approval_tidb_json`

```json
{
  "migrate_dsn": "<migrate-user>:<pw>@tcp(<host>:4000)/delivery_approval?parseTime=true&loc=UTC&charset=utf8mb4&collation=utf8mb4_bin&tls=true",
  "runtime_dsn": "<runtime-user>:<pw>@tcp(<host>:4000)/delivery_approval?parseTime=true&loc=UTC&charset=utf8mb4&collation=utf8mb4_bin&tls=true"
}
```

```bash
printf '%s' "$JSON" | gcloud secrets create gcp_dl_approval_tidb_json \
  --project=pingcap-testing-account --data-file=-
```

### `gcp_dl_approval_config_json`

```json
{
  "lark_app_id": "<dedicated Lark app id>",
  "lark_app_secret": "<dedicated Lark app secret>",
  "url_encryption_key": "<base64 of 32 random bytes>",
  "dl_issuer_secret": "<separate random secret, >=32 bytes>"
}
```

```bash
# 32 random bytes for AES-256-GCM; keep the key version/id alongside it for rotation.
openssl rand -base64 32
# A separate issuer bearer secret; never reuse the Lark or download token.
openssl rand -base64 48

printf '%s' "$JSON" | gcloud secrets create gcp_dl_approval_config_json \
  --project=pingcap-testing-account --data-file=-
```

`dl_issuer_secret` is the plaintext bearer credential the approval service sends
to `dl-management`. Only its SHA-256 hash goes into the dl delivery policy.

## 3. dl delivery policy: add the `delivery-approval` issuer

The existing `gcp_dl_delivery_policy_json` contains a `policy.yaml` string with
the `release-service` issuer. Add a second issuer scoped to the delivery
repositories. Do not reuse `release-service`, and do not put the plaintext
secret in the policy.

Current scope (read it before editing):

```bash
gcloud secrets versions access latest --secret=gcp_dl_delivery_policy_json \
  --project=pingcap-testing-account | yq -r '.["policy.yaml"]'
```

Add (adjust `max_ttl_seconds` if the approval form should be shorter than 7d):

```yaml
  - id: delivery-approval
    # printf '%s' "$DL_ISSUER_SECRET" | shasum -a 256
    token_sha256: "<64-hex-sha256-of-dl_issuer_secret>"
    repositories:
      - us-docker.pkg.dev/pingcap-testing-account/tidbx/
      - us-docker.pkg.dev/pingcap-testing-account/hub/
      - us-docker.pkg.dev/pingcap-testing-account/hotfix/
    allowed_tags: '.+_linux_(amd64|arm64)'
    max_ttl_seconds: 604800
```

Write a new secret version (keep the previous version for rollback):

```bash
gcloud secrets versions add gcp_dl_delivery_policy_json \
  --project=pingcap-testing-account --data-file=<updated-json>
```

Both `dl-management` and `dl-public` hot-reload the policy only after the image
contains ee-apps #920 (`a33843f`); the currently pinned delivery image is older.
Until that image bump, treat policy changes as requiring a rollout.

## 4. Google OAuth

The existing internal client `google-oauth2-client-ee-apps` must allow:

```text
https://prow.tidb.net/dl/grants/oauth2/callback
```

Add it in the Google Cloud console (APIs & Services → Credentials → the OAuth
2.0 Client used by `prow.tidb.net`). The gateway route/SecurityPolicy is added in
Phase 6; adding the redirect URI early is harmless.

## 5. Lark app

Create a **dedicated** Lark app for this service; do not reuse the `chatops-lark`
bot app. It needs outbound permissions only:

- send messages / interactive cards as the bot;
- app-level urgent (`urgent_app`);
- contact lookup by email (`batch_get_id`).

It must **not** subscribe to message/event callbacks, and the approval service
must not start a WebSocket client. Put `app_id`/`app_secret` into
`gcp_dl_approval_config_json`; the app itself is not in this repo.

## Verify Phase 0

```bash
kubectl kustomize apps/gcp/dl-approval >/tmp/dl-approval.yaml
kubeconform -strict -ignore-missing-schemas -summary /tmp/dl-approval.yaml

kubectl -n dl-approval get externalsecret
# All three should be SecretSynced=True after the GSM keys and OAuth secret exist.
kubectl -n dl-approval get secret dl-approval-oidc dl-approval-tidb dl-approval-config

# The management NetworkPolicy now admits the approval namespace on :80.
kubectl -n dl get networkpolicy dl-management-delivery -o yaml
```

Do not print Secret values. If an ExternalSecret is `SecretSynced=False`, check
the GSM key name and the `ee-gcp-sm` namespace allowlist first.

## Rollback

- Suspend/remove `dl-approval-prereq`, `dl-approval-migrate` and `dl-approval`
  (or remove `dl-approval` from `apps/gcp/kustomization.yaml`) to stop
  reconciling; the namespace and Secrets are pruned according to Flux/prune policy.
- Delete the GSM keys only after the namespace is gone. Keeping them is harmless
  and avoids losing the URL encryption key.
- The dl policy change is additive; removing the `delivery-approval` issuer
  denies new issuance but does not invalidate already-issued shares. Revoke
  individual shares or disable the issuer in `download_issuers` for immediate
  cross-replica denial.
