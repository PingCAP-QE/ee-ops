# GitHub Actions Secrets Central Management Design

## Summary

This design uses External Secrets Operator (ESO) to keep GitHub Actions secrets centrally managed from a secret store such as GCP Secret Manager.

The selected model is:

1. Keep the source of truth in GCP Secret Manager.
2. Materialize source secrets into a dedicated Kubernetes namespace with `ExternalSecret`.
3. Push those Kubernetes secrets into GitHub Actions secrets with `PushSecret` and the ESO GitHub provider.
4. Use one active writer cluster for all GitHub secret delivery to avoid concurrent writers.

This design fits the current repository because `ee-ops` already deploys ESO and already uses GCP Secret Manager as a shared secret source.

## Goals

- Manage GitHub Actions secrets centrally for multiple GitHub organizations and repositories.
- Keep secret values out of Git.
- Reuse the existing FluxCD + ESO operating model in this repository.
- Support organization, repository, and environment secrets.
- Make the delivery path auditable and GitOps-managed.

## Non-goals

- Reading secret values back from GitHub.
- Using GitHub as a source of truth.
- Managing GitHub Actions variables.
- Allowing manual per-repo secret edits as a normal operating path.

## Constraints That Shape the Design

- The ESO GitHub provider is write-only and is intended for creating and updating GitHub Actions secrets, not reading them back.
- The GitHub provider works with `PushSecret`, so the source secret must first exist as a Kubernetes `Secret`.
- GitHub target scope is part of the `SecretStore` definition:
  - organization secret: `organization`
  - repository secret: `organization` + `repository`
  - environment secret: `organization` + `repository` + `environment`
- In current upstream ESO, organization secret visibility can be declared with `orgSecretVisibility` values `all` or `private`.
- This repository is currently pinned to ESO chart `0.19.0`, and that version does not yet expose `orgSecretVisibility` in the GitHub provider CRD. On that version, new org secrets default to `all`, and updates preserve the visibility of an already existing GitHub org secret.
- The ESO GitHub provider does not expose a `selected` repository visibility model for organization secrets. If a secret must go to only some repositories in an org, use repository secrets instead.

## Selected Architecture

Recommended active writer cluster: `gcp`

This is an inference from the current repo state:

- `prod` is documented as being deprecated after migration.
- `gcp` already has ESO deployed.
- `gcp` is the only cluster that already uses `PushSecret` in this repository today.
- using `gcp` keeps this outbound GitHub-secret delivery path separate from `prod2` application-platform workloads.

Recommended delivery namespace: `github-actions-secrets`

The namespace is separate from `infra`:

- `infra` keeps hosting the ESO controllers.
- `github-actions-secrets` hosts the source `ExternalSecret`, materialized Kubernetes `Secret`, GitHub `SecretStore`, and `PushSecret` objects.

```mermaid
flowchart LR
    A[GCP Secret Manager\nsource of truth]
    B[ClusterSecretStore\nrestricted to github-actions-secrets]
    C[ExternalSecret]
    D[Kubernetes Secret\nin github-actions-secrets]
    E[PushSecret]
    F[GitHub SecretStore\norg/repo/env scoped]
    G[GitHub Actions Secrets\norg / repo / environment]

    A --> B
    B --> C
    C --> D
    D --> E
    E --> F
    F --> G
```

## Key Decisions

### 1. Use one active writer cluster

GitHub is a global external target, not a cluster-local dependency. Running the same GitHub `PushSecret` workload from multiple clusters creates unnecessary race conditions and makes failures harder to reason about.

Recommendation:

- use only one cluster to push to GitHub
- keep other clusters on source-side ESO usage only, unless there is a clear failover design
- if org-level private visibility must be managed declaratively, upgrade ESO before rollout

### 2. Keep GitHub target stores namespaced

Use namespaced `SecretStore` resources for the GitHub provider instead of `ClusterSecretStore`.

Reasons:

- GitHub delivery is a high-exfiltration path
- only one namespace should own GitHub secret delivery
- the GitHub App private key can stay local to that namespace

### 3. Restrict the shared GCP source store

Create a dedicated source `ClusterSecretStore` for GitHub secret delivery, instead of reusing a very broad shared store without restrictions.

Recommendation:

- use a separate GCP service account for GitHub secret delivery
- scope it to only the required GCP secrets or prefixes
- add `ClusterSecretStore.spec.conditions` so only the `github-actions-secrets` namespace can use it

### 4. Use one logical source secret per credential value

Do not model GCP secrets by GitHub target.

Preferred model:

- one GCP secret per logical credential value
- separate GitOps delivery mappings decide where that value is pushed

This scales better when the same credential must be shared across many repositories or orgs.

### 5. Use GitHub secret scope intentionally

Recommended scope selection:

| Need | Recommended GitHub scope | Reason |
| --- | --- | --- |
| Same secret for many repos in one org | organization secret with `private` visibility | lowest object count, but requires an ESO version that can declare org visibility |
| Same secret for public and private repos in one org | organization secret with `all` visibility | explicit broad sharing |
| Same secret for only some repos in one org | repository secrets | ESO does not model org `selected` visibility |
| Deployment credential for one environment | environment secret | narrowest blast radius |
| Repo-specific override of an org secret | repository secret with same name | GitHub repo secret overrides org secret |
| Env-specific override of repo or org secret | environment secret with same name | GitHub env secret overrides repo and org secret |

## GitHub Behavioral Limits To Plan Around

- secret size limit: 48 KB
- organization secrets: up to 1,000
- repository secrets: up to 100
- environment secrets: up to 100
- if a repository can access more than 100 organization secrets, only the first 100 alphabetically are available to workflows
- organization and repository secrets are read when a workflow run is queued
- environment secrets are read when a job referencing the environment starts

Operational consequence:

- keep org-level secrets for broadly shared credentials only
- do not use org secrets as an unbounded dumping ground
- prefer repository or environment secrets for narrow use cases and overrides

## Security Model

### Source of truth

- secret values live in GCP Secret Manager
- Git only stores metadata and delivery mappings

### Materialization in Kubernetes

Because `PushSecret` pushes from a Kubernetes `Secret`, values must exist in the cluster.

Required protections:

- dedicated namespace for GitHub secret delivery
- Kubernetes secret encryption at rest
- strict RBAC on `ExternalSecret`, `PushSecret`, `SecretStore`, and `Secret`
- no application-team write access in the delivery namespace
- egress-restricted NetworkPolicies for ESO

### GitHub authentication

Use a GitHub App, not a PAT.

Recommended permission set:

- organization permission: `Secrets` write
- repository permission: `Secrets` write
- repository permission: `Environments` write if environment secrets are used

Use one company GitHub App installed into each target organization. Each organization installation has its own `installationID`, so each org still needs its own GitHub `SecretStore`.

## Proposed Future Repo Layout

This document does not implement the manifests, but the future structure should look like this:

```text
infrastructure/gcp/github-actions-secrets/
├── kustomization.yaml
├── namespace.yaml
├── source-store/
│   ├── kustomization.yaml
│   └── css-ee-gcp-sm-github-actions.yaml
├── source-secrets/
│   ├── kustomization.yaml
│   ├── es-github-app-private-key.yaml
│   └── es-*.yaml
├── target-stores/
│   ├── kustomization.yaml
│   ├── gh-org-*.yaml
│   ├── gh-repo-*.yaml
│   └── gh-env-*.yaml
└── deliveries/
    ├── kustomization.yaml
    └── ps-*.yaml
```

## Recommended Operating Rules

- Never edit GitHub Actions secrets manually once a secret is under ESO management.
- Rotate by updating the secret in GCP Secret Manager.
- Keep delivery mappings in Git, not in ad hoc scripts.
- Use organization secrets only for broad sharing.
- On the current repo-pinned ESO version, do not create new org secrets unless `all` visibility is acceptable or the target org secret already exists with the desired visibility.
- Use repository secrets for subset targeting because ESO does not model org `selected` repository visibility.
- Use environment secrets only for deployment-scoped credentials.

## References

- External Secrets Operator GitHub provider: https://external-secrets.io/latest/provider/github/
- External Secrets Operator PushSecret API: https://external-secrets.io/latest/api/pushsecret/
- External Secrets Operator security best practices: https://external-secrets.io/latest/guides/security-best-practices/
- GitHub Actions secrets reference: https://docs.github.com/en/actions/reference/security/secrets
- GitHub App permissions for secrets APIs: https://docs.github.com/en/rest/overview/permissions-required-for-github-apps
