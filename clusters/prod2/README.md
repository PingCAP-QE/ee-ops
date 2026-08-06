# Production 2 GitOps

Production cluster for Tekton CI/CD workloads, managed by FluxCD v2.

## Layers

| Layer | Path | Description |
| ----- | ---- | ----------- |
| flux-system | `./clusters/prod2/flux-system` | Flux components, sync, notifications |
| sources | `./clusters/prod2` (`sources.yaml`) | `GitRepository` sources (ci, artifacts) |
| infrastructure | `./infrastructure/prod2` | external-secrets, gateways, kyverno, openebs, secret-generator, etc. |
| apps | `./apps/prod2` | tekton, tibuild, publisher, zot, harbor, prow-worker, chatops-lark, etc. |

## Prepare

### Secrets

| namespace   | secret name       | prepare commands                                                                                          | description                                  |
| ----------- | ----------------- | --------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| flux-system | lark-token        | `kubectl -n flux-system create secret generic lark-token --from-literal=address=<lark-webhook-url>`       | GitOps notification webhook (info events)    |
| flux-system | lark-token-error  | `kubectl -n flux-system create secret generic lark-token-error --from-literal=address=<lark-webhook-url>` | GitOps alert webhook (error events)          |

## Notification

`clusters/prod2/flux-system/notification.yaml` defines `Provider`/`Alert` resources
that send Flux reconciliation events to Lark. The `Provider` reads the `address`
key (Lark bot webhook URL) from the secrets above. Create the secrets before or
right after bootstrapping, otherwise reconciliation succeeds but notifications
are silently dropped.

## GitOps Workflow

1. Make changes under `infrastructure/prod2` or `apps/prod2`
2. Commit and push to a feature branch, create a PR to `main`
3. After merge, FluxCD reconciles the cluster

## Troubleshooting

```bash
flux get kustomizations --all-namespaces
flux logs --all-namespaces
kubectl -n flux-system get secrets lark-token
```
