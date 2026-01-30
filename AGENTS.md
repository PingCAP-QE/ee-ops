# AGENTS

This document provides guidance for AI agents working with the ee-ops repository.

## Repository Overview

ee-ops is a GitOps repository for managing Efficiency Engineering infrastructure and applications using FluxCD on Kubernetes. It's maintained by PingCAP-QE and uses a GitOps workflow to deploy and manage clusters, infrastructure, and applications.

## Repository Structure

```
ee-ops/
├── .github/               # GitHub Actions workflows and custom actions
├── charts/                # Helm charts for reusable applications
├── clusters/              # Cluster-specific GitOps configurations
│   ├── prod/             # Production cluster
│   ├── prod2/            # Production cluster 2
│   └── gcp/              # GCP cluster
├── apps/                 # Application deployments per cluster
├── infrastructure/       # Base infrastructure components per cluster
├── docs/                 # Documentation
└── scripts/              # Utility scripts
```

## Technology Stack

- **GitOps Tool**: FluxCD v2
- **Package Manager**: Helm v3
- **Configuration**: Kustomize
- **CI/CD**: GitHub Actions
- **Chart Testing**: chart-testing (ct)
- **Validation**: kubeconform, yq, kustomize

## Key Workflows

### CI/CD Pipelines

1. **Chart Lint Test** (`.github/workflows/charts_lint-test.yaml`)
   - Triggers on PR to main branch when charts change
   - Runs helm lint on modified charts

2. **Chart Test - Prow** (`.github/workflows/charts_test-prow.yaml`)
   - Tests prow chart with Kind (Kubernetes in Docker)
   - Creates required secrets and configmaps
   - Installs chart in test environment

3. **Chart Release** (`.github/workflows/charts_release.yaml`)
   - Auto-releases charts when Chart.yaml changes on main
   - Uses chart-releaser action

4. **CD Test** (`.github/workflows/gitops_test.yaml`)
   - Validates K8s manifests in infrastructure, clusters, and apps
   - Runs kubeconform with Flux CRD schemas
   - Validates kustomization files

### Pre-commit Hooks

- End-of-file fixer
- Trailing whitespace removal
- Gitleaks (secret detection)

## Helm Charts

Available charts in `charts/`:

- **prow** - CI/CD system for GitHub PR/Issue automation (v0.10.2)
- **git-cdn** - Git content delivery network
- **greenhouse** - Application management
- **mcp-tool** - MCP tooling
- **ats** - Application Traffic Service
- **cla-assistant** - CLA management
- **bazel-remote** - Bazel remote caching
- **buildbarn** - Build system for remote execution

### Chart Testing Commands

```bash
# Lint a chart
ct lint --charts charts/<chart-name>

# Install a chart locally
ct install --charts charts/<chart-name>
```

## Cluster Configurations

### Clusters

- **prod** - Primary production cluster (in migration - will be deprecated after apps move to prod2)
- **prod2** - Secondary production cluster (primary for Tekton workloads; migration target)
- **gcp** - GCP-based cluster

### Cluster Secrets

Each cluster requires specific secrets (see cluster README.md for details):

- **flux-system namespace**: prow configuration (GitHub app credentials, tokens)
- **apps namespace**: Jenkins registry credentials, GitHub auth, codecov tokens, etc.

## Applications

### Production Cluster Apps

- jenkins - CI/CD automation
- prow-worker - Prow job execution
- greenhouse - Application management
- harbor - Container registry
- kafka - Event streaming
- redis - Cache
- mongodb - Database
- boskos - Resource management
- chatops-lark - Chat integration
- ats - Application Traffic Service
- dl - Download service
- goproxy - Go module proxy
- cloudevents-server - CloudEvents handling

### Production 2 Cluster Apps

- buildbarn - Remote build system
- tekton - Kubernetes-native CI/CD
- coder - Cloud development environment
- publisher - Publishing service
- tibuild - TiDB build system
- zot - OCI registry
- brc - ???
- cluster-policies - Kubernetes policies
- cache - Caching layer

## Infrastructure Components

Common infrastructure includes:

- **nfs-pvc-provisioner** - NFS persistent volume provisioning
- **rook-ceph** - Ceph storage system
- **nginx** - Ingress controller
- **secret-generator** - Secret management
- **external-secrets** - External secret integration
- **gateways** - API/network gateways
- **kyverno** - Kubernetes policy engine
- **openebs** - Container attached storage
- **operators** - Kubernetes operators (e.g., Kafka)

## Common Commands

### FluxCD Operations

```bash
# Bootstrap a cluster
flux bootstrap github \
    --owner=<org> \
    --repository=<repo> \
    --branch=main \
    --path=clusters/<cluster-name>

# Check Flux status
flux check --pre
flux get all --all-namespaces

# Sync changes
flux reconcile kustomization flux-system --with-source
```

### Validation

```bash
# Validate K8s manifests
./scripts/validate_k8s_yaml.sh

# Run from specific directory
pushd <path> && $PWD/../scripts/validate_k8s_yaml.sh && popd
```

### GitOps Workflow

1. Make changes to manifests in `apps/`, `infrastructure/`, or `clusters/`
2. Commit and push to feature branch
3. Create PR to main
4. CI validates manifests with kubeconform
5. After merge, FluxCD syncs changes to cluster
6. Monitor reconciliation with `flux get kustomization --all-namespaces`

## Development Guidelines

### Git Commit Convention

Follow the Conventional Commits specification for commit messages:

**Format:**
```
type(scope): description (#PR-number)
```

**Types:**
- `feat` - New feature
- `fix` - Bug fix
- `chore` - Maintenance tasks, dependency updates
- `docs` - Documentation changes
- `refactor` - Code refactoring
- `revert` - Revert previous commit

**Scopes:**
- `apps/<cluster>/` - Application deployments (e.g., `apps/prod/jenkins`)
- `infrastructure/<cluster>/` - Infrastructure components (e.g., `infrastructure/gcp`)
- `charts/<chart-name>` - Helm chart changes (e.g., `charts/prow`)
- Multiple scopes separated by commas: `apps/prod2/jenkins,apps/gcp/jenkins`

**Examples:**
```
feat(apps/prod2/tibuild): add basic auth to v2 ingress
fix(apps/prod2/tekton/configs): update storage class for RWO volumes
chore(deps): update helm release zot to v0.1.97
refactor(apps/prod,apps/prod2): move tibuild to prod2 env
```

### Making Changes

1. **Chart Changes**: Update chart version in Chart.yaml; auto-release will publish
2. **App Deployments**: Modify kustomization in `apps/<cluster>/`
3. **Infrastructure**: Update kustomization in `infrastructure/<cluster>/`
4. **Cluster Config**: Modify FluxCD manifests in `clusters/<cluster>/`

### Secret Management

- Never commit secrets to repository (gitleaks will detect)
- Use Kubernetes secrets created manually or via external-secrets
- Document required secrets in cluster README.md

### Code Style

- Follow existing naming conventions
- Use semantic versioning for charts
- Keep kustomization organized with clear structure
- Document non-obvious configurations in comments or docs/

### Testing

- Test charts locally with `ct install` before PR
- Validate manifests with validation script
- Review FluxCD logs if reconciliation fails

## Troubleshooting

### FluxCD Issues

```bash
# Check reconciliation status
flux get kustomizations --all-namespaces
flux get helmreleases --all-namespaces

# View logs
flux logs --all-namespaces

# Force reconciliation
flux reconcile kustomization <name> --namespace=<namespace>
```

### Chart Installation Issues

```bash
# Test chart locally
helm install test charts/<chart> --namespace test --debug
helm template test charts/<chart> --namespace test | kubectl apply --dry-run=server -f -
```

### Validation Failures

- Check kubeconform output for schema violations
- Ensure FluxCD CRD schemas are up-to-date
- Verify YAML syntax with `yq e 'true' <file>`

## References

- [FluxCD Documentation](https://fluxcd.io/docs/)
- [Helm Documentation](https://helm.sh/docs/)
- [Kustomize Documentation](https://kustomize.io/)
- [chart-testing Documentation](https://github.com/helm/chart-testing)
- [kubeconform Documentation](https://github.com/yannh/kubeconform)
