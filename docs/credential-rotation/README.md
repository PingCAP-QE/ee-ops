# Credential rotation

Long-lived credentials are the recurring finding in this repository's security
reviews, so every one of them has a named document here with four things in it:
where the credential lives, who reads it, how to rotate it, and how to revoke it.

Use this page as the index. Nothing here is a wiki copy of a runbook: if a
credential is added or a consumer changes, the matching document changes in the
same PR.

## Index

| Credential class | Document | Source of truth | Cadence |
|---|---|---|---|
| GitHub bot machine user: classic PAT + SSH key, and the chatops MCP fine-grained token | [`github-bot.md`](github-bot.md) | GCP Secret Manager `pingcap-testing-account` | yearly / at token expiry |
| GitHub App private keys (App `214286`) | [`github-app.md`](github-app.md) | GCP Secret Manager `pingcap-testing-account` | yearly or on exposure |
| GCP service account key behind the `ee-gcp-sm` ClusterSecretStore | [`eso-gcp-sm.md`](eso-gcp-sm.md) | manual Secret `gcp-sm-sa-secret`, key issued in `pingcap-testing-account` | 90 days |
| In-cluster generated secrets (CLA MongoDB password, session secret) | this page, [below](#in-cluster-generated-secrets) | the Kubernetes Secret itself | install-time; rotate deliberately |

## Conventions

- **Secret Manager is the source of truth** for every credential that ESO can
  sync. Kubernetes Secrets are projections; do not edit them by hand unless the
  document says the Secret is manual.
- **Force a resync after a change** instead of waiting for the one-hour refresh:

  ```bash
  kubectl -n <namespace> annotate externalsecret <name> \
    force-sync="$(date +%s)" --overwrite
  ```

- **Never commit a credential.** `gitleaks` runs as a pre-commit hook and on CI;
  a PR that trips it is rejected. Keep downloaded key files outside the checkout
  and delete them after the Secret is updated.
- **Rotation is a PR-reviewed change only when it changes Git.** Most rotations
  change Secret Manager and a Kubernetes Secret, not this repository; record the
  rotation date and operator in the security tracking issue for this repository.
- **Rotate on exposure first, on schedule second.** Every document below has a
  revoke step; use it before investigating.

## In-cluster generated secrets

Two Secrets in `apps/gcp/cla-assistant/` are generated in-cluster by the
`kubernetes-secret-generator` (mittwald chart, `infrastructure/gcp/secret-generator/`):

| Secret | Key | Annotations |
|---|---|---|
| `mongodb-credentials` | `password` | `autogenerate: password`, `encoding: hex`, `length: 32` |
| `cla-session` | `SESSION_SECRET` | `autogenerate: SESSION_SECRET`, `encoding: hex`, `length: 64` |

`mongodb-credentials` also pins `username: cla` and `database: cla`, and is
consumed by the `mongodb` HelmRelease through `valuesFrom` →
`auth.username` / `auth.password` / `auth.database`.

The generator only fills a key when the Secret (or that key) is absent. Changing
`length` in Git therefore does **not** rotate a running password — it only sets
the strength of the next generated value. The running value has to be rotated
deliberately:

1. Generate the new password and change it in MongoDB **first**, because the
   chart does not rewrite the password of an existing MongoDB user:

   ```bash
   NEW_PASSWORD="$(openssl rand -hex 32)"
   kubectl -n cla exec -i mongodb-0 -- mongosh \
     -u cla -p "$OLD_PASSWORD" --authenticationDatabase admin \
     --eval "db.changeUserPassword('cla', '$NEW_PASSWORD')"
   ```

2. Write the same value into the Secret, keeping the generator annotations
   untouched:

   ```bash
   kubectl -n cla patch secret mongodb-credentials --type merge \
     -p "{\"stringData\":{\"password\":\"${NEW_PASSWORD}\"}}"
   ```

3. Verify `kubectl -n cla get secret mongodb-credentials -o jsonpath='{.data.password}'`
   decodes to the new value and that the CLA workload can still reach MongoDB.

The Window between steps 1 and 2 is a short authentication failure for anything
holding the old value — do it off-peak. Do not delete the Secret to "force"
regeneration: the generator would write a new password that MongoDB does not
know, and the deployment would stay broken.

`cla-credentials` (referenced by the CLA HelmRelease) is a separate Secret in the
same namespace, not managed by this repository. If it carries the same MongoDB
user, rotate it in the same window.

## Known gaps

These credentials are long-lived and do not have a rotation document yet; each is
tracked as its own piece of security work rather than silently accepted:

- The `github-token-broker` Deployment authenticates its public gateway route
  with a never-expiring ServiceAccount token Secret
  (`apps/gcp/github-token-broker/serviceaccount.yaml`), which is copied into
  Secret Manager and injected as a `Bearer` credential. Removing it changes the
  broker's authentication path.
- Jenkins stores the bot PAT and SSH key as `GLOBAL`-scoped credentials
  (`apps/gcp/jenkins/beta/pre/credential-github.yaml`), so every agent can read
  them. Narrowing that scope breaks the jobs that look credentials up by ID.
- `apps/prod2/tirelease/external-secret.yaml` mounts a static service account key
  file; prod2 has no GKE metadata server, so Workload Identity is not available
  there and the key stays until the deployment moves.
