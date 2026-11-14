# GitHub bot credentials (`github-bot-*`) rotation

This document covers the long-lived GitHub credentials of the **machine user**
`ti-chi-bot` used by CI/CD, and the fine-grained token the Lark chatops MCP tool
runs with. Both are bearer tokens stored in GCP Secret Manager and both are
rotated the same way.

It does not cover the GitHub **App** `ti-chi-bot` (App ID `214286`): its private
key is a different credential class with a different rotation shape, see
[`github-app.md`](github-app.md).

## Source of truth

GCP Secret Manager in project `pingcap-testing-account` is the source of truth.
External Secrets Operator (ESO) syncs the values into Kubernetes. Do not edit
the Kubernetes Secrets directly unless the secret is explicitly documented as
manual.

After changing a Secret Manager value, force the relevant `ExternalSecret` to
reconcile instead of waiting for the one-hour refresh:

```bash
kubectl -n <namespace> annotate externalsecret <name> \
  force-sync="$(date +%s)" --overwrite
```

## PAT

The org-wide bot PAT is a classic token with these scopes:

```text
admin:org, admin:repo_hook, notifications, project, repo,
user, workflow
```

It is stored under these canonical secrets:

| Secret Manager secret | Consumer |
|---|---|
| `github-bot-token` | Tekton `ee-cd/github` and `github-pat-secret`; Jenkins; `tibuild/v2-config`; `prow-test-pods/github-token`; Prow `apps/prow-github` |
| `tidbx-delivery-github-issue` | Tekton `ee-cd/image-delivery-notify-config-tidbx` (`dev_github_token` and `prod_github_token`) |

The former `gcp_prow_github_pat` copy is no longer used; `prow-github` reads
`github-bot-token` directly.

The org-wide PAT must not be mounted into namespaces that run untrusted or
unauthenticated code. `chatops-lark` used to hold a copy as the `github` Secret;
it now uses its own narrow token (below). If a `github` Secret shows up in
`chatops-lark` again, that is a regression, not a fix.

## MCP tool token (`chatops-lark-mcp-github-token`)

The chatops-lark GitHub MCP server runs with its token in the environment and has
no inbound authentication of its own, so it must not carry the org-wide bot PAT.
It reads a dedicated fine-grained token instead:

- Secret Manager key: `chatops-lark-mcp-github-token`
- `ExternalSecret` `chatops-lark/mcp-github-token` → Secret `mcp-github-token`,
  key `token`
- consumed by the `chatops-lark-mcp-tool-github` HelmRelease as
  `GITHUB_PERSONAL_ACCESS_TOKEN`

Issuance is a manual, org-admin step (a fine-grained token cannot be minted by
automation). All four requirements are load-bearing:

1. Fine-grained PAT with **read-only** repository permissions the tool needs:
   `contents`, `issues`, `pull requests`, `metadata`.
2. **Selected repositories only** — not "all repositories in the org".
3. An **expiry date**. Record it next to the GSM key when the version is added;
   a token without an expiry is the same problem in a smaller box.
4. No organisation permissions, no administration scope.

Rotation:

```bash
printf '%s' "$NEW_FINE_GRAINED_PAT" \
  | gcloud secrets versions add chatops-lark-mcp-github-token \
      --project=pingcap-testing-account --data-file=-

kubectl -n chatops-lark annotate externalsecret mcp-github-token \
  force-sync="$(date +%s)" --overwrite

# The MCP server reads the token from its environment at process start.
kubectl -n chatops-lark rollout restart deploy/chatops-lark-mcp-tool-github
kubectl -n chatops-lark rollout status deploy/chatops-lark-mcp-tool-github
```

Verify that a read tool answers through the bot before revoking the old token,
then revoke it in the GitHub UI (fine-grained tokens can also be deleted from
the account's developer settings). Disable the superseded Secret Manager version
with `gcloud secrets versions disable`.

## SSH key

The canonical secret is `github-bot-ssh-rsa-json`. Despite the name, its
current value is an Ed25519 key. The JSON object must keep the keys
`ssh-privatekey` and `ssh-publickey`.

Consumers:

- Tekton `ee-cd/github-ssh-secret` (both clusters)
- Jenkins `github-bot-ssh` and `github-sre-bot-ssh`
- Prow `prow-test-pods/github-ssh-secret`

`prow-test-pods/github-ssh-secret` is managed by an `ExternalSecret` in
`apps/gcp/prow/post/job-ns/secrets/github-ssh-secret.yaml`. Prow's `clonerefs`
runs `ssh-add` on every file in the mounted secret directory, so the target
secret must contain private keys only, never `ssh-publickey`.

## Rotation procedure

Cadence: yearly, or immediately on any suspicion of exposure. The PAT carries an
expiry, so start two weeks before it lapses; the SSH key has no expiry and is
rotated on the same yearly slot.

### 1. Create the new credentials

Create a new classic PAT in the `ti-chi-bot` account with the same scopes and
a one-year expiry. Keep the old token active.

```bash
ssh-keygen -t ed25519 -C "ti-chi-bot@github.com" \
  -f ~/.ssh/ti-chi-bot-$(date +%Y%m%d) -N ""
```

Add the public key to the account, then verify both new credentials:

```bash
curl -s -H "Authorization: Bearer $NEW_PAT" https://api.github.com/user \
  | jq '{login,type}'
ssh -T -i ~/.ssh/ti-chi-bot-$(date +%Y%m%d) \
  -o IdentitiesOnly=yes -o BatchMode=yes git@github.com
```

### 2. Update Secret Manager

```bash
printf '%s' "$NEW_PAT" \
  | gcloud secrets versions add github-bot-token \
      --project=pingcap-testing-account --data-file=-

gcloud secrets versions access latest --secret=tidbx-delivery-github-issue \
    --project=pingcap-testing-account \
  | jq --arg t "$NEW_PAT" '.dev_github_token=$t | .prod_github_token=$t' \
  | gcloud secrets versions add tidbx-delivery-github-issue \
      --project=pingcap-testing-account --data-file=-

jq -n --rawfile priv ~/.ssh/ti-chi-bot-$(date +%Y%m%d) \
      --rawfile pub ~/.ssh/ti-chi-bot-$(date +%Y%m%d).pub \
  '{ "ssh-privatekey": $priv, "ssh-publickey": $pub }' \
  | gcloud secrets versions add github-bot-ssh-rsa-json \
      --project=pingcap-testing-account --data-file=-
```

### 3. Force ESO reconciliation

GCP cluster:

```bash
for item in \
  ee-cd/github ee-cd/github-pat-secret ee-cd/github-ssh-secret \
  ee-cd/image-delivery-notify-config-tidbx \
  jenkins/github-bot-https jenkins/github-bot-token \
  jenkins/github-pr-diff-token jenkins/github-bot-ssh \
  jenkins/github-sre-bot-ssh prow-test-pods/github-token \
  prow-test-pods/github-ssh-secret tibuild/v2-config \
  apps/prow-github; do
  ns=${item%%/*}; name=${item#*/}
  kubectl -n "$ns" annotate externalsecret "$name" \
    force-sync="$(date +%s)" --overwrite
done
```

TKE: same list without `apps/prow-github` and `prow-test-pods/github-ssh-secret`
(Prow only runs on GCP).

The chatops-lark MCP token is a separate credential and is not part of this
loop; see its own section above.

### 4. Restart consumers that cache the value at startup

```bash
kubectl -n apps rollout restart \
  deploy/prow-jenkins-operator-0 deploy/prow-jenkins-operator-1 \
  deploy/prow-ti-community-cherrypicker
```

`tibuild-v2` reloads its config (including the GitHub client) every 30 seconds;
Jenkins uses the Kubernetes credentials provider; Tekton reads the Secret when a
new PipelineRun starts. None of them require a restart.

### 5. Verify

- ESO reports `Ready=True` with a fresh `refreshTime`.
- The token hash in `ee-cd/github` matches the new PAT.
- The SSH fingerprint in `ee-cd/github-ssh-secret` and
  `prow-test-pods/github-ssh-secret` matches the new key.
- Prow can trigger a small Jenkins job and a cherry-pick on a canary PR.
- `tibuild-v2` can run a devbuild or hotfix without 401s.
- A Tekton canary PipelineRun can clone/push through
  `github-pat-secret` / `github-ssh-secret`.

### 6. Revoke the old credentials

After the verification window:

1. Delete the old PAT in GitHub.
2. Delete the old SSH keys from the account. Verify with `ssh -T` that they
   return `Permission denied (publickey)`.
3. Disable the old Secret Manager versions:

   ```bash
   gcloud secrets versions disable <old> --secret=github-bot-token \
     --project=pingcap-testing-account
   gcloud secrets versions disable <old> --secret=github-bot-ssh-rsa-json \
     --project=pingcap-testing-account
   ```

4. Remove any local OAuth session for the bot account:

   ```bash
   gh auth logout -u ti-chi-bot
   ```

## Cleanup notes

- `prod2_tibuild_v1_config_yaml` is no longer used after the prod2 tibuild v1
  deployment is removed. Delete the Secret Manager secret after Flux prunes the
  deployment.
- `gcp_prow_github_pat` can be deleted after `prow-github` has reconciled from
  `github-bot-token`.
- `prod2_jenkins_beta_github_json` and `prod2_tibuild_v2_config_yaml` were
  stale copies and have been deleted.
