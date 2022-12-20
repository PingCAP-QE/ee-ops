# Staging GitOps

> deploy prow-dev.tidb.net

## Prepare

### Secrets

| namespace   | secret name                | prepare commands                                   | keys                                                                                         | description |
| ----------- | -------------------------- | -------------------------------------------------- | -------------------------------------------------------------------------------------------- | ----------- |
| flux-system | prow                       | `kubectl -n flux-system create secret generic ...` | `DOMAIN_NAME`, `GITHUB_APP_ID`, `GITHUB_APP_CERT`, `GITHUB_APP_WEBHOOK_HMAC`, `GITHUB_TOKEN` |             |
| flux-system | gcs-credentials            | `service-account.json`                             | GCS credentials for prow                                                                     |             |
| apps        | prow-jenkins-operator-auth | `user`, `token`                                    | auth to external jenkins controller                                                          |             |
