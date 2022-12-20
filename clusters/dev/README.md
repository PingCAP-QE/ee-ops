# Staging GitOps

> deploy prow-dev.tidb.net

## Prepare

### Secrets

| namespace   | secret name | prepare commands                                   | description                                     |
| ----------- | ----------- | -------------------------------------------------- | ----------------------------------------------- |
| flux-system | prow        | `kubectl -n flux-system create secret generic ...` | secret configurations to deploy prow github app |
