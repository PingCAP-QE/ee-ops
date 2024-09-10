# Staging GitOps

## Prepare

### Secrets

| namespace   | secret name                | prepare commands                                                       | description                                                                                                                                                                                     |
| ----------- | -------------------------- | ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| flux-system | prow                       | `kubectl -n flux-system create secret generic ...`                     | `DOMAIN_NAME`, `GITHUB_APP_ID`, `GITHUB_APP_CERT`, `GITHUB_APP_WEBHOOK_HMAC`, `GITHUB_TOKEN`,`GITHUB_APP_CLIENT_ID`,`GITHUB_APP_CLIENT_SECRET`, `OAUTH_COOKIE_SECRET`, `GCS_CREDENTIALS_BASE64` |  |
| apps        | jenkins-registry-cred      | `kubectl create secret docker-registry ...`                            | credential for image pulling                                                                                                                                                                    |
| apps        | github                     | `kubectl -n apps create secret generic ...`                            | keys: `git-private-key`, `git-username`, `bot-token`                                                                                                                                            |
| apps        | codecov-token              | `kubectl -n apps create secret generic ...`                            | for codecov.io uploading, keys: `tidb`, `tikv-migration`, `tiflow`                                                                                                                              |
| apps        | coveralls-token            | `kubectl -n apps create secret generic ...`                            | for coveralls uploading, keys: `tiflow`                                                                                                                                                         |
| apps        | tekton-ingress             | `kubectl -n apps create secret generic tekton-ingress ...`             | tekton component, keys: `domain`, `path_for_dashboard`                                                                                                                                          |
| flux-system | prow                       | `kubectl -n flux-system create secret generic ...`                     | secret configurations to deploy prow github app                                                                                                                                                 |
| apps        | prow-jenkins-operator-auth | `kubectl -n apps create secret generic prow-jenkins-operator-auth ...` | auth to external jenkins controller, keys: `user`, `token`                                                                                                                                      |

- How to create jenkins api token?
   > 
    ```bash
    #!/usr/bin/env bash

    # Change the following appropriately
    JENKINS_URL="https://<jenkins-base-url>"
    JENKINS_USER=admin
    JENKINS_USER_PASS="<password>"
    JENKINS_CRUMB=$(curl -u "$JENKINS_USER:$JENKINS_USER_PASS" -s --cookie-jar /tmp/cookies $JENKINS_URL'/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,":",//crumb)')
    ACCESS_TOKEN=$(curl -u "$JENKINS_USER:$JENKINS_USER_PASS" -H "$JENKINS_CRUMB" -s \
        --cookie /tmp/cookies $JENKINS_URL'/me/descriptorByName/jenkins.security.ApiTokenProperty/generateNewToken' \
        --data 'newTokenName=GlobalToken' | jq -r '.data.tokenValue')

    echo "$ACCESS_TOKEN"
    curl -u "$JENKINS_USER:$ACCESS_TOKEN" \
        -H "$JENKINS_CRUMB" \
        "${JENKINS_URL}/api/json?pretty=true"
    ```

## TODO

- [ ] make the jenkins api token generating automatic in GitOps. 
