Helm Chart for Prow
===

## Pre requirements

1. Register a webhook grateway from [ultrahook](https://www.ultrahook.com/), and download and setup the CLI accroding the mail guide. this a a step for local deploying and debuging.
2. setup you github app for later deployment, see REF [doc](https://github.com/kubernetes/test-infra/blob/master/prow/getting_started_deploy.md#github-app), specially fill the webhook url with above step's url.
3. install your github app in you repo.

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

      # github org (optional): your first org to take effects, the repo that have prow github app installed must belonged this org. 
      githubOrg: <<your git org>>
    ```
2. install the chart
    ```bash
    helm install prow <chart-dir> -f values.yaml
    ```
3. add or update jobs
   ```bash
   helm upgrade prow <chart-dir> --set-file prow.jobs.your_uniq_job_key=<your-job-yaml-path-to-add-or-update.yaml> --reuse-values
   ```
   > subset of prow jobs config, please do not override with others. schema: https://github.com/kubernetes/test-infra/blob/master/prow/jobs.md

4. update global prow config(store in configmap `prow-config` with key `config.yaml`)
   ```bash
    helm upgrade prow <chart-dir> --set-file prow.config=<your-prow-config.yaml> --reuse-values
   ```

5. update prow plugin config(store in configmap `prow-plugins` with key `plugins.yaml`)
   ```bash
    helm upgrade prow <chart-dir> --set-file prow.plugins=<your-prow-plugins.yaml> --reuse-values
   ```

## Debug

After all the prow pods Are ready, you can do following steps to setup debug env:

1. forward prow hook service to localhost using kubectl: `kubectl port-forward services/<helm release name>-hook 8888:80 -n <helm release namespace>`
2. forward webhook requests to local hook service with ultrahook: `ultrahook github http://localhost:8888/hook`

Now it's ready to test prow features, you can try comment `/test ?` in any opened pull requests in you git org that configured in `values.yaml`