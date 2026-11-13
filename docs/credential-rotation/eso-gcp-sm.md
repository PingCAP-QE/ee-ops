# `ee-gcp-sm` credential rotation (External Secrets → GCP Secret Manager)

This document covers the credential that lets External Secrets Operator (ESO)
read from GCP Secret Manager in project `pingcap-testing-account`: the service
account key stored in the `gcp-sm-sa-secret` Kubernetes Secret. It does not cover
GitHub credentials (`github-bot.md`) or GitHub App keys (`github-app.md`).

## What it is

`ClusterSecretStore` `ee-gcp-sm` exists in all three clusters:

| Cluster | Manifest | Key Secret |
|---|---|---|
| gcp | `infrastructure/gcp/external-secrets/post/css-ee-gcp-sm.yaml` | `infra/gcp-sm-sa-secret` |
| tencentcloud | `infrastructure/tencentcloud/external-secrets/post/css-ee-gcp-sm.yaml` | `flux-system/gcp-sm-sa-secret` |
| prod2 | `infrastructure/prod2/external-secrets/post/css-ee-gcp-sm.yaml` | `flux-system/gcp-sm-sa-secret` |

In every case the store authenticates with `provider.gcpsm.auth.secretRef` →
key `secret-access-credentials` of that Secret, i.e. a **static service account
JSON key**. The Secret is prepared manually; nothing in Git or Secret Manager
manages it. ESO itself runs in the `infra` namespace
(`infrastructure/<cluster>/external-secrets/release/release.yaml`).

## Blast radius

The key decides what *everything* pointed at this store can read. A namespace
listed in `spec.conditions[].namespaceSelector` can create an `ExternalSecret`
for **any secret of the GCP project** — the permission is not per-secret, it is
per-store. Consequences:

- Adding a namespace to that list is a security decision, not a plumbing change.
  It needs the owner of the namespace and the security reviewer to agree.
- `prow-test-pods` is the namespace that runs untrusted PR code and it is in the
  gcp and tencentcloud lists today. Isolating it onto a narrower, secret-scoped
  store is tracked separately and is the highest-value fix in this area; do not
  "simplify" it back into `ee-gcp-sm`.
- `apps/gcp/chatops-lark` has no `ExternalSecret` against this store beyond its
  own credentials, and its GitHub PAT no longer comes from the org-wide
  `github-bot-token`.

## Rotation

Cadence: every 90 days on gcp/tencentcloud/prod2 while the static key is in use.
The key has no expiry of its own, so the trigger is a calendar, and the named
owner in the security tracking issue is responsible for it.

### 1. Create the new key

```bash
gcloud iam service-accounts keys create ./eso-gcp-sm-$(date +%Y%m%d).json \
  --iam-account="${SA_EMAIL}" \
  --project=pingcap-testing-account
```

The service account is the one the existing key was issued for (see the current
Secret) and it has project-level `roles/secretmanager.secretAccessor` on
`pingcap-testing-account`. Do not widen it: if a narrower, per-secret grant is
workable, prefer that (see
`docs/github-actions-secrets/rollout-and-operations.md` for the secret-level
grant pattern).

### 2. Replace the Secret

gcp cluster (Secret in `infra`):

```bash
kubectl -n infra create secret generic gcp-sm-sa-secret \
  --from-file=secret-access-credentials=./eso-gcp-sm-$(date +%Y%m%d).json \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n infra rollout restart deploy/external-secrets
```

tencentcloud / prod2 (Secret in `flux-system`) use `-n flux-system`.

The Secret key name must stay `secret-access-credentials`; the store references
that key literally.

### 3. Verify

```bash
# Every cluster you touched.
kubectl get clustersecretstore ee-gcp-sm \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")]}'

# A sample consumer on the same cluster.
kubectl -n <namespace> get externalsecret <name> \
  -o jsonpath='{.status.conditions[?(@.type=="SecretSynced")]}'
```

A `Ready=False` store means every `ExternalSecret` on that cluster is stale;
roll back by writing the previous key back (see below) before continuing.

### 4. Retire the old key

```bash
gcloud iam service-accounts keys list --iam-account="${SA_EMAIL}" \
  --project=pingcap-testing-account
gcloud iam service-accounts keys delete <old-key-id> \
  --iam-account="${SA_EMAIL}" --project=pingcap-testing-account
rm ./eso-gcp-sm-$(date +%Y%m%d).json
```

Never leave the JSON key in a checkout; `gitleaks` runs on every PR.

### Rollback

Key Secrets are not versioned. Keep the previous JSON outside the repository
(secret manager of the operator's choice) or re-issue a key and update the
Secret again. Either way the recovery path is: write a working key into
`gcp-sm-sa-secret`, restart the ESO controller in `infra`, confirm the store is
`Ready`.

## Target state

The gcp cluster should stop using a static key: `gcpsm.auth.workloadIdentity`
with a KSA in `infra` and a GSA bound through
`roles/iam.workloadIdentityUser` removes the long-lived key entirely. The keyless
pattern already exists in this repository in
`infrastructure/gcp/github-actions-secrets/` (`SecretStore` +
`workloadIdentity` ServiceAccount). The switch is tracked separately and is not
part of a rotation.

tencentcloud and prod2 have no GKE metadata server, so `workloadIdentity` cannot
be used there; they keep a static key with the 90-day cadence above and a named
rotation owner.
