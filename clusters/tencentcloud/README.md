# Tencentcloud GitOps

Tencentcloud-based cluster for CI/CD workloads (jenkins, tekton, kafka, etc.), managed by FluxCD v2.

## Layers

| Layer | Path | Description |
| ----- | ---- | ----------- |
| flux-system | `./clusters/tencentcloud/flux-system` | Flux components, sync, notifications |
| sources | `./clusters/tencentcloud/sources` | Helm repositories (bitnami, ee-apps, ee-ops, external-secrets, kyverno, etc.) and `GitRepository` sources |
| infrastructure | `./infrastructure/tencentcloud` | external-secrets, gateways, kyverno, node-pools, operators, etc. |
| apps | `./apps/tencentcloud` | jenkins, jenkins-agents, tekton, tibuild, publisher, kafka, cloudevents-server, cache, etc. |

## Prepare

### Secrets

| namespace   | secret name       | prepare commands                                                                                          | description                                  |
| ----------- | ----------------- | --------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| flux-system | lark-token        | `kubectl -n flux-system create secret generic lark-token --from-literal=address=<lark-webhook-url>`       | GitOps notification webhook (info events)    |
| flux-system | lark-token-error  | `kubectl -n flux-system create secret generic lark-token-error --from-literal=address=<lark-webhook-url>` | GitOps alert webhook (error events)          |

Other application secrets (e.g. publisher, cloudevents-server) are synced from
external secret stores via `external-secrets`, see the corresponding app
directories.

## Notification

`clusters/tencentcloud/flux-system/notification.yaml` defines `Provider`/`Alert`
resources that send Flux reconciliation events to Lark. The `Provider` reads the
`address` key (Lark bot webhook URL) from the secrets above. Create the secrets
before or right after bootstrapping, otherwise reconciliation succeeds but
notifications are silently dropped.

## GitOps Workflow

1. Make changes under `infrastructure/tencentcloud` or `apps/tencentcloud`
2. Commit and push to a feature branch, create a PR to `main`
3. After merge, FluxCD reconciles the cluster

## Troubleshooting

```bash
flux get kustomizations --all-namespaces
flux logs --all-namespaces
kubectl -n flux-system get secrets lark-token
```
