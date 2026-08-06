# Staging GitOps

## Prepare

### Secrets

| namespace   | secret name                | prepare commands                                                       | description                                                                                                                                                                                     |
| ----------- | -------------------------- | ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| flux-system | prow                       | `kubectl -n flux-system create secret generic ...`                     | `DOMAIN_NAME`, `GITHUB_APP_ID`, `GITHUB_APP_CERT`, `GITHUB_APP_WEBHOOK_HMAC`, `GITHUB_TOKEN`,`GITHUB_APP_CLIENT_ID`,`GITHUB_APP_CLIENT_SECRET`, `OAUTH_COOKIE_SECRET`, `GCS_CREDENTIALS_BASE64` |  |
| apps        | github                     | `kubectl -n apps create secret generic ...`                            | keys: `git-private-key`, `git-username`, `bot-token`                                                                                                                                            |
| apps        | codecov-token              | `kubectl -n apps create secret generic ...`                            | for codecov.io uploading, keys: `tidb`, `tikv-migration`, `tiflow`                                                                                                                              |
| apps        | coveralls-token            | `kubectl -n apps create secret generic ...`                            | for coveralls uploading, keys: `tiflow`                                                                                                                                                         |
| apps        | tekton-ingress             | `kubectl -n apps create secret generic tekton-ingress ...`             | tekton component, keys: `domain`, `path_for_dashboard`                                                                                                                                          |
| flux-system | prow                       | `kubectl -n flux-system create secret generic ...`                     | secret configurations to deploy prow github app                                                                                                                                                 |
