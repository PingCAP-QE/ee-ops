# Production GitOps

Legacy production cluster, managed by FluxCD v2.

> This cluster is being migrated; applications are being moved to the prod2
> cluster and will be deprecated afterwards.

## Prepare

### Secrets

| namespace   | secret name       | prepare commands                                                                                          | description                                  |
| ----------- | ----------------- | --------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| flux-system | lark-token        | `kubectl -n flux-system create secret generic lark-token --from-literal=address=<lark-webhook-url>`       | GitOps notification webhook (info events)    |
| flux-system | lark-token-error  | `kubectl -n flux-system create secret generic lark-token-error --from-literal=address=<lark-webhook-url>` | GitOps alert webhook (error events)          |
| apps        | github            | `kubectl -n apps create secret generic ...`                                                                | keys: `git-private-key`, `git-username`, `bot-token` |
| apps        | codecov-token     | `kubectl -n apps create secret generic ...`                                                                | for codecov.io uploading, keys: `tidb`, `tikv-migration`, `tiflow` |
| apps        | coveralls-token   | `kubectl -n apps create secret generic ...`                                                                | for coveralls uploading, keys: `tiflow`      |
| apps        | tekton-ingress    | `kubectl -n apps create secret generic tekton-ingress ...`                                                 | tekton component, keys: `domain`, `path_for_dashboard` |

> The old `prow` secret entries were removed: prow has been migrated out of this
> cluster. GitOps notifications are managed by
> `clusters/prod/flux-system/notification.yaml`.
