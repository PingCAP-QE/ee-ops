# prod2 External Secrets

This folder deploys and configures the External Secrets Operator (ESO) for the prod2 environment via Flux and Helm, and sets up a ClusterSecretStore pointing to Google Cloud Secret Manager (GCP SM). It also includes a usage example for app teams.

## Repository structure

- `kustomization.yaml`
  - Orchestrates this component in two phases:
    - `release.yaml` — installs ESO via Helm
    - `post.yaml` — applies post-install resources (ClusterSecretStore, etc.)

- `release.yaml`
  - Flux Kustomization that reconciles `./release`.

- `release/`
  - `kustomization.yaml` — wraps the HelmRelease.
  - `release.yaml` — HelmRelease for ESO:
    - Chart: `external-secrets`
    - Version: `0.19.0`
    - Source: HelmRepository named `external-secrets` in `flux-system` namespace (must exist)
    - Values highlights:
      - `replicaCount: 2` for controller
      - Enables and sizes `webhook` and `certController`
      - `serviceAccount.create: true`
      - `crds.enabled: true` and `installCRDs: true`

- `post.yaml`
  - Flux Kustomization that depends on `external-secrets-release` and reconciles `./post`.

- `post/`
  - `css-ee-gcp-sm.yaml` — ClusterSecretStore with GCP Secret Manager:
    - Name: `ee-gcp-sm`
    - Uses a Kubernetes Secret for credentials:
      - Namespace: `flux-system`
      - Secret name: `gcp-sm-sa-secret`
      - Key: `secret-access-credentials`
    - Project ID: `pingcap-testing-account`

- `test.yaml.example`
  - Example `ExternalSecret` resource for consumers.

## Prerequisites

- GCP setup:
  - A GCP Service Account with at least `roles/secretmanager.secretAccessor` for project `pingcap-testing-account`.
  - A JSON key generated for that service account.
- Kubernetes Secret with GCP credentials (needed by ClusterSecretStore):
  - Namespace: `flux-system`
  - Name: `gcp-sm-sa-secret`
  - Key: `secret-access-credentials`
  - Create it (replace `/path/to/sa.json` with your key path):
    ```
    kubectl -n flux-system create secret generic gcp-sm-sa-secret \
      --from-file=secret-access-credentials=/path/to/sa.json
    ```

## How it works

1. Flux applies `release.yaml`, which points to `./release` and installs ESO via Helm.
2. After ESO is healthy, Flux applies `post.yaml`, which points to `./post` and creates the `ClusterSecretStore` (`ee-gcp-sm`) configured for GCP SM.
3. Application teams create `ExternalSecret` resources in their namespaces, referencing `ee-gcp-sm`. ESO reads from GCP SM and materializes Kubernetes Secrets.

## Usage for application teams

1. Ensure your namespace exists and you have permission to create `ExternalSecret` and `Secret`.
2. Create an `ExternalSecret` referencing the pre-created `ClusterSecretStore` `ee-gcp-sm`.

Example (adapt as needed; also see `test.yaml.example`):

```
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: example-es
  namespace: your-namespace
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: ee-gcp-sm
    kind: ClusterSecretStore
  target:
    name: example-secret-from-es
    creationPolicy: Owner
  data:
    - secretKey: secret-key-to-be-managed
      remoteRef:
        key: projects/pingcap-testing-account/secrets/your-secret-name/versions/latest
  # Or import a JSON secret map:
  # dataFrom:
  #   - extract:
  #       key: projects/pingcap-testing-account/secrets/your-json-secret/versions/latest
```

Notes:
- For GCP SM, `remoteRef.key` typically uses the full resource path or the secret name depending on provider config. The example above shows the full path for clarity.
- The operator will create/update the Kubernetes Secret `example-secret-from-es` in your namespace and keep it in sync on the specified `refreshInterval`.

## Upgrades

- Bump the chart version in `release/release.yaml` (`spec.chart.spec.version`).
- Review upstream release notes for breaking changes (CRDs, field changes).
- Flux will reconcile and perform a rolling upgrade.

## Troubleshooting

- ESO not running:
  ```
  kubectl -n infra get pods -l app.kubernetes.io/name=external-secrets
  kubectl -n infra describe helmrelease external-secrets
  kubectl -n infra logs deploy/external-secrets -c external-secrets
  ```

- ClusterSecretStore not ready:
  ```
  kubectl get clustersecretstore ee-gcp-sm -o yaml
  ```
  Check for credentials or permission errors. Ensure the Kubernetes Secret `flux-system/gcp-sm-sa-secret` exists and is valid, and that the GCP SA has `secretmanager.secretAccessor` on the target project.

- ExternalSecret not syncing:
  ```
  kubectl -n your-namespace describe externalsecret your-es
  kubectl -n infra logs deploy/external-secrets -c external-secrets
  ```
  Look for events about access, path, or permission issues.

## Security considerations

- Treat the GCP SA JSON as sensitive. Store and deliver it via secure channels only.
- Scope the SA permissions to the minimum set of secrets and projects needed.
- Prefer `ClusterSecretStore` for shared access patterns; use `SecretStore` per-namespace when isolation is required.

## References

- External Secrets Operator: https://external-secrets.io
- Helm chart: https://artifacthub.io/packages/helm/external-secrets-operator/external-secrets
- GCP Secret Manager: https://cloud.google.com/secret-manager
