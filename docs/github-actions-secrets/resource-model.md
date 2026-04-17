# Resource Model And Manifest Patterns

## Design Principles

- Keep secret values in GCP Secret Manager.
- Materialize only the minimum required Kubernetes secrets in one dedicated namespace.
- Use namespaced GitHub `SecretStore` objects so only the central delivery namespace can push to GitHub.
- Keep the source contract stable even if the secret backend changes later.

## Namespace

Recommended namespace:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: github-actions-secrets
```

## Naming Conventions

### Kubernetes resources

| Resource | Convention | Example |
| --- | --- | --- |
| source `ServiceAccount` | `gcp-sm-github-actions` | `gcp-sm-github-actions` |
| source `SecretStore` | `gcp-sm-github-actions` | `gcp-sm-github-actions` |
| source `ExternalSecret` | `es-src-<logical-secret>` | `es-src-dockerhub-token` |
| source materialized `Secret` | `src-<logical-secret>` | `src-dockerhub-token` |
| GitHub App key `ExternalSecret` | `es-github-app-private-key` | `es-github-app-private-key` |
| GitHub App key `Secret` | `github-app-private-key` | `github-app-private-key` |
| org `SecretStore` | `gh-org-<org>` on current ESO, `gh-org-<org>-<visibility>` after visibility support is available | `gh-org-pingcap-qe` |
| repo `SecretStore` | `gh-repo-<org>-<repo>` | `gh-repo-pingcap-qe-ci` |
| env `SecretStore` | `gh-env-<org>-<repo>-<env>` | `gh-env-pingcap-qe-ci-production` |
| `PushSecret` | `ps-<logical-secret>-<delivery>` | `ps-dockerhub-token-repo-fanout` |

### GCP Secret Manager

Use a format that is valid for GCP secret IDs and easy to search.

Recommended pattern:

- `gha__shared__<logical-secret>`
- `gha__repo__<org>__<repo>__<logical-secret>`
- `gha__env__<org>__<repo>__<environment>__<logical-secret>`
- `gha__system__github_app_private_key`

Examples:

- `gha__shared__dockerhub_token`
- `gha__repo__pingcap-qe__ci__codecov_token`
- `gha__env__pingcap-qe__ci__production__aws_role`
- `gha__system__github_app_private_key`

## Source Store Pattern

Use a dedicated namespaced `SecretStore` named `gcp-sm-github-actions`.

The source-side authentication model is:

- one Kubernetes service account in `github-actions-secrets`
- that service account is annotated for GKE Workload Identity
- the namespaced `SecretStore` references that service account through `auth.workloadIdentity.serviceAccountRef`
- no static `secret-access-credentials` secret is used

Recommended service account:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gcp-sm-github-actions
  namespace: github-actions-secrets
  annotations:
    iam.gke.io/gcp-service-account: __REPLACE_WITH_GCP_GSA_EMAIL__
```

Recommended source store:

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: gcp-sm-github-actions
  namespace: github-actions-secrets
spec:
  provider:
    gcpsm:
      auth:
        workloadIdentity:
          serviceAccountRef:
            name: gcp-sm-github-actions
      projectID: __REPLACE_WITH_GCP_PROJECT_ID__
```

Notes:

- This uses the same GKE annotation pattern already present elsewhere in the repo, for example `iam.gke.io/gcp-service-account`.
- `gcp` is also the only cluster in this repo that already uses `PushSecret` today, so it is the least-surprise default for outbound secret sync.
- Prefer a dedicated GCP service account for this store with access limited to GitHub-related secrets only.
- ESO `v0.19.0` supports `gcpsm.auth.workloadIdentity.serviceAccountRef` for GKE Workload Identity.

## GitHub App Private Key Pattern

Store the GitHub App private key in GCP Secret Manager and pull it into the delivery namespace.

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: es-github-app-private-key
  namespace: github-actions-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: gcp-sm-github-actions
    kind: SecretStore
  target:
    name: github-app-private-key
    creationPolicy: Owner
  data:
    - secretKey: privateKey.pem
      remoteRef:
        key: gha__system__github_app_private_key
```

## Source Secret Pattern

Each logical credential becomes one source `ExternalSecret` and one materialized Kubernetes `Secret`.

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: es-src-dockerhub-token
  namespace: github-actions-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: gcp-sm-github-actions
    kind: SecretStore
  target:
    name: src-dockerhub-token
    creationPolicy: Owner
  data:
    - secretKey: value
      remoteRef:
        key: gha__shared__dockerhub_token
```

## GitHub Target Store Patterns

### Organization secret store

Use this for secrets shared broadly within one org.

Compatibility note:

- with the repo-pinned ESO chart `0.19.0`, the GitHub provider does not expose `orgSecretVisibility`
- on that version, newly created org secrets default to `all`
- if the org secret already exists in GitHub, ESO preserves its existing visibility when updating the value
- if you need declarative `private` vs `all` control in Git, upgrade ESO before implementation

Current repo-compatible org store:

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: gh-org-pingcap-qe
  namespace: github-actions-secrets
spec:
  provider:
    github:
      appID: "123456"
      installationID: "10000001"
      organization: pingcap-qe
      auth:
        privateKey:
          name: github-app-private-key
          key: privateKey.pem
```

Post-upgrade org store with explicit visibility:

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: gh-org-pingcap-qe-private
  namespace: github-actions-secrets
spec:
  provider:
    github:
      appID: "123456"
      installationID: "10000001"
      organization: pingcap-qe
      orgSecretVisibility: private
      auth:
        privateKey:
          name: github-app-private-key
          key: privateKey.pem
```

### Repository secret store

Use this for subset targeting or repo-specific overrides.

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: gh-repo-pingcap-qe-ci
  namespace: github-actions-secrets
spec:
  provider:
    github:
      appID: "123456"
      installationID: "10000001"
      organization: pingcap-qe
      repository: ci
      auth:
        privateKey:
          name: github-app-private-key
          key: privateKey.pem
```

### Environment secret store

Use this only for environment-scoped deployment credentials.

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: gh-env-pingcap-qe-ci-production
  namespace: github-actions-secrets
spec:
  provider:
    github:
      appID: "123456"
      installationID: "10000001"
      organization: pingcap-qe
      repository: ci
      environment: production
      auth:
        privateKey:
          name: github-app-private-key
          key: privateKey.pem
```

## PushSecret Patterns

`PushSecret` is still `external-secrets.io/v1alpha1` with the current ESO chart version used in this repo.

### One secret to one org

```yaml
apiVersion: external-secrets.io/v1alpha1
kind: PushSecret
metadata:
  name: ps-dockerhub-token-org
  namespace: github-actions-secrets
spec:
  deletionPolicy: Delete
  refreshInterval: 1h
  secretStoreRefs:
    - name: gh-org-pingcap-qe
      kind: SecretStore
  selector:
    secret:
      name: src-dockerhub-token
  data:
    - match:
        secretKey: value
        remoteRef:
          remoteKey: DOCKERHUB_TOKEN
```

If you stay on the current repo-pinned ESO version, use org-level `PushSecret` only when one of these is true:

- `all` visibility is acceptable for the new org secret
- the org secret already exists in GitHub with the desired visibility and ESO is only updating the value

### One secret to a selected set of repositories

This is the recommended replacement for org `selected` visibility, because the current ESO GitHub provider does not model selected-repository org secrets.

```yaml
apiVersion: external-secrets.io/v1alpha1
kind: PushSecret
metadata:
  name: ps-codecov-token-repo-fanout
  namespace: github-actions-secrets
spec:
  deletionPolicy: Delete
  refreshInterval: 1h
  secretStoreRefs:
    - name: gh-repo-pingcap-qe-ci
      kind: SecretStore
    - name: gh-repo-pingcap-qe-artifacts
      kind: SecretStore
  selector:
    secret:
      name: src-codecov-token
  data:
    - match:
        secretKey: value
        remoteRef:
          remoteKey: CODECOV_TOKEN
```

### One secret to one environment

```yaml
apiVersion: external-secrets.io/v1alpha1
kind: PushSecret
metadata:
  name: ps-aws-role-production
  namespace: github-actions-secrets
spec:
  deletionPolicy: Delete
  refreshInterval: 1h
  secretStoreRefs:
    - name: gh-env-pingcap-qe-ci-production
      kind: SecretStore
  selector:
    secret:
      name: src-aws-role-production
  data:
    - match:
        secretKey: value
        remoteRef:
          remoteKey: AWS_ROLE_ARN
```

## Ownership Metadata

Add labels or annotations so ownership is obvious in Git and in the cluster.

Recommended labels:

```yaml
metadata:
  labels:
    ee.pingcap.com/owner-team: platform
    ee.pingcap.com/github-org: pingcap-qe
    ee.pingcap.com/managed-by: fluxcd
```

Recommended annotations:

```yaml
metadata:
  annotations:
    ee.pingcap.com/source-secret-id: gha__shared__dockerhub_token
    ee.pingcap.com/github-secret-name: DOCKERHUB_TOKEN
```

## When To Create A New Target Store

Create a new GitHub `SecretStore` when any of the following changes:

- target organization
- target repository
- target environment
- org secret visibility (`all` vs `private`)
- GitHub Enterprise base URL

## When To Reuse A Target Store

Reuse a GitHub `SecretStore` when all of the following are the same:

- same GitHub instance
- same GitHub App and org installation
- same target organization
- same target repository, or both are org-scoped
- same target environment, or both are not env-scoped
- same org visibility requirement

## Recommended Policy Guardrails

- deny `PushSecret` creation outside `github-actions-secrets`
- deny source GCP `SecretStore` creation outside `github-actions-secrets`
- deny GitHub `SecretStore` creation outside `github-actions-secrets`
- deny `ExternalSecret` creation in `github-actions-secrets` unless it references `gcp-sm-github-actions`
- deny cross-team write access to the delivery namespace

These controls fit well with the Kyverno footprint already present in this repository.
