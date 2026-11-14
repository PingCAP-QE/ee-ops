# Static service-account key register

GCP service-account keys never expire and carry no owner: neither the key, nor
Secret Manager, nor Kubernetes records when it was created or who is supposed to
rotate it. Rotating a static key therefore depends on a register kept in Git.

This file is that register. Every static service-account key that a workload in
this repository authenticates with has a row here, and
`scripts/check-sa-key-inventory.sh` enforces the rules below in CI.

## Rules

- **One row per key.** One JSON key = one `private_key_id`. A key copied into
  three clusters' Secrets is still one row, with three consumers.
- **`Created` is the key's creation date**, not the date the workload was
  deployed. Read it from
  `gcloud iam service-accounts keys list --iam-account=<sa> --project=pingcap-testing-account --format='table(name,validAfterTime)'`.
  Never write an approximate date: a wrong date makes the age check useless.
- **`Max age (days)` is a deadline, not a wish.** CI fails once a key is older
  than its own limit. If a key is due, rotate it — do not raise the limit.
- **`Owner` is the team accountable for rotating the key.** `sig-root-approvers`
  is the default from `OWNERS`; narrow it to the owning team or person when one
  exists, because "the repository" is not someone who can rotate at 3am.
- **Rotating** = create the new key, update the consumer (Secret Manager key or
  the Kubernetes Secret), verify the consumer still works, delete the old key in
  GCP, then update this row with the new key id and creation date.
- **No placeholder may reach `main`.** `TBD` is allowed only in a change that is
  explicitly waiting for the real value; the guard fails on it.

## Register

> The two rows below are skeletons: `Key ID`, `Service account` (for the store
> key) and `Created` are `TBD` until the key holder reads them out of GCP. The
> guard fails while they are pending. That failure is the intended signal that
> the register is not yet enforceable — it is not a code defect, and it must not
> be silenced by inventing values.

| Key ID | Service account | Used by | Owner | Created | Max age (days) |
| :--- | :--- | :--- | :--- | :--- | ---: |
| TBD | TBD | gcp/infra/gcp-sm-sa-secret, tencentcloud/flux-system/gcp-sm-sa-secret, prod2/flux-system/gcp-sm-sa-secret | sig-root-approvers | TBD | 90 |
| TBD | gh-broker-client-macos@pingcap-testing-account.iam.gserviceaccount.com | github-token-broker external endpoint, macOS worker client | sig-root-approvers | TBD | 90 |

### Reading the values for the first row

The `ee-gcp-sm` stores on all three clusters authenticate with a key that was
prepared by hand (see the comment in `infrastructure/<cluster>/external-secrets/post/css-ee-gcp-sm.yaml`).
Its service account is only visible from the Secret itself:

```bash
# gcp cluster
kubectl -n infra get secret gcp-sm-sa-secret \
  -o jsonpath='{.data.secret-access-credentials}' | base64 -d | jq -r .client_email
# tencentcloud and prod2
kubectl -n flux-system get secret gcp-sm-sa-secret \
  -o jsonpath='{.data.secret-access-credentials}' | base64 -d | jq -r .client_email
```

Then list that account's keys and copy the `private_key_id` and the UTC date of
`validAfterTime` into the row.

## What CI cross-checks

The guard does not trust the table alone; it derives two requirements from the
repository, so deleting a row cannot make it pass:

1. **Every static-key GCP store.** Any `ClusterSecretStore` or `SecretStore`
   with `spec.provider.gcpsm.auth.secretRef.secretAccessKeySecretRef` must
   appear as `<cluster>/<namespace>/<secret>` in a row's `Used by` cell. Today
   that is the three `ee-gcp-sm` stores.
2. **Every broker client.** Each identity in the `broker-clients` claim values
   of `apps/gcp/github-token-broker/security-policy.yaml` holds a key and must
   appear as a row's `Service account`.

It also fails on a missing `Owner` or `Created`, on a duplicate `Key ID`, on a
key older than its `Max age`, and on a malformed row.

**What the guard cannot do:** CI has no GCP credentials, so it cannot prove that a
recorded date is true or that a listed key still exists. It enforces that every
consumer is registered, that the fields are filled, and that the register is
refreshed before a key goes stale. Proving a date means reading it where it is
authoritative: the key itself, with the commands above.

The form mirrors the credential-boundary guard added with
`PingCAP-QE/ee-infra#184`
(`terraform/tencentcloud/tidb-cicd/scripts/check-credential-hygiene.sh`): a
document that states the boundary plus a script that fails when reality drifts
from it.

```bash
bash scripts/check-sa-key-inventory.sh
bash scripts/check-sa-key-inventory_test.sh   # proves the guard fails when it should
```

## Not in this register

- **Workload Identity consumers have no key** and must not be listed: the
  `gcp-sm-github-actions` store, the prow job service accounts and the
  ci-dashboard/hotfix readers authenticate through the GKE metadata server.
- **Keys held outside this repository.** The GitHub App private key
  (`gha__system__github_app_private_key`) and the bot PAT/SSH key are GitHub
  credentials, not GCP service-account keys: the bot ones are documented in
  [`ti-chi-bot.md`](ti-chi-bot.md), and the App key is tracked with the
  per-consumer App split (one key per consumer cannot be expressed here).
- **The tencentcloud and prod2 stores cannot use Workload Identity** (no GKE
  metadata server), so their key stays until that changes; its rotation
  responsibility is the one recorded in this row.
