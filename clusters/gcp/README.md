# Staging GitOps

> deploy prow.tidb.net

## Prepare

### Secrets

| namespace   | secret name                | prepare commands                                   | keys                                                                                                                                                                                            | description |
| ----------- | -------------------------- | -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- |
| flux-system | prow                       | `kubectl -n flux-system create secret generic ...` | `DOMAIN_NAME`, `GITHUB_APP_ID`, `GITHUB_APP_CERT`, `GITHUB_APP_WEBHOOK_HMAC`, `GITHUB_TOKEN`,`GITHUB_APP_CLIENT_ID`,`GITHUB_APP_CLIENT_SECRET`, `OAUTH_COOKIE_SECRET`, `GCS_CREDENTIALS_BASE64` |             |
| flux-system | gcs-credentials            | `service-account.json`                             | GCS credentials for prow                                                                                                                                                                        |             |
| apps        | prow-jenkins-operator-auth | `user`, `token`                                    | auth to external jenkins controller                                                                                                                                                             |             |
| apps        | prow-tls                   |                                                    | prow site ingress cert secret                                                                                                                                                                   |             |
