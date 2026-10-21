# ti-chi-bot credential rotation

This document covers the long-lived credentials of the GitHub **machine user**
`ti-chi-bot` used by CI/CD. It does not cover the GitHub App `ti-chi-bot`
(App ID `214286`, bot user `ti-chi-bot[bot]`); its private key is a separate
credential and currently cannot be rotated with two active keys.

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

The PAT is a classic token with these scopes:

```text
admin:org, admin:repo_hook, notifications, project, repo,
user, workflow
```

It is stored under one canonical secret:

| Secret Manager secret | Consumer |
|---|---|
| `github-bot-token` | Tekton `ee-cd/github` and `github-pat-secret`; Jenkins; `tibuild/v2-config`; `prow-test-pods/github-token`; `chatops-lark` MCP GitHub tool; Prow `apps/prow-github` |
| `tidbx-delivery-github-issue` | Tekton `ee-cd/image-delivery-notify-config-tidbx` (`dev_github_token` and `prod_github_token`) |

The former `gcp_prow_github_pat` copy is no longer used; `prow-github` reads
`github-bot-token` directly.

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
  apps/prow-github chatops-lark/github; do
  ns=${item%%/*}; name=${item#*/}
  kubectl -n "$ns" annotate externalsecret "$name" \
    force-sync="$(date +%s)" --overwrite
done
```

TKE: same list without `apps/prow-github`, `chatops-lark/github`, and
`prow-test-pods/github-ssh-secret` (Prow only runs on GCP).

### 4. Restart consumers that cache the value at startup

```bash
kubectl -n apps rollout restart \
  deploy/prow-jenkins-operator-0 deploy/prow-jenkins-operator-1 \
  deploy/prow-ti-community-cherrypicker
kubectl -n chatops-lark rollout restart deploy/chatops-lark-mcp-tool-github
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
