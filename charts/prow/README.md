Helm Chart for Prow
===

## Pre requirements

1. Register a webhook grateway from [ultrahook](https://www.ultrahook.com/), and download and setup the CLI accroding the mail guide. this a a step for local deploying and debuging.
2. setup you github app for later deployment, see REF [doc](https://github.com/kubernetes/test-infra/blob/master/prow/getting_started_deploy.md#github-app), specially fill the webhook url with above step's url.

## How to install

1. create a file `values.yaml` for install later:
    ```yaml
    prow:
    # you can change it with existed namespace.
    podsNamespace: default

    # you can fill it with dumy domain, such as: `test.io`  
    domainName: <<prow app backend domain with prefix `prow.`>>
    githubAppId: <<prow github app id>
    githubAppCert: |
        -----BEGIN RSA PRIVATE KEY-----
        <<prow github app private key>>
        -----END RSA PRIVATE KEY-----

    # Generate via `openssl rand -hex 20`. This is the secret used in the GitHub webhook configuration
    githubHmacToken: <<prow gitub app hmac token>>

    # github org:
    githubOrg: <<your git org>>
    ```
2. install the chart
    ```bash
    helm install prow
    ```

## Debug

After all the prow pods Are ready, you can do following steps to setup debug env:

1. forward prow hook service to localhost using kubectl: `kubectl port-forward services/<helm release name>-hook 8888:80 -n <helm release namespace>`
2. forward webhook requests to local hook service with ultrahook: `ultrahook github http://localhost:8888/hook`

Now it's ready to test prow features, you can try comment `/test ?` in any opened pull requests in you git org that configured in `values.yaml`