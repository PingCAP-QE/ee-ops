# Staging GitOps

## Prepare

### Secrets

| namespace   | secret name           | prepare commands                                   | description                                     |
| ----------- | --------------------- | -------------------------------------------------- | ----------------------------------------------- |
| apps        | jenkins-registry-cred | `kubectl create secret docker-registry ...`        | credential for image pulling                    |
| flux-system | prow                  | `kubectl -n flux-system create secret generic ...` | secret configurations to deploy prow github app |
