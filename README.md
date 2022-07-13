# EE Ops

GitOps everything for Efficiency Engineering

## How to Setup it in you k8s cluster

Before all please fork it into you personal account or organization.

### Pre require

#### GitOps Tools

- Flux CLI
  > Install by bash or download release binary from [Flux site](https://fluxcd.io/docs/get-started/#install-the-flux-cli)
#### cluster secret data

**required**:

- secrets for jenkins component
  > see [here](apps/staging/jenkins/README.md)
- secrets for prow component
  > `kubectl -n apps create secret generic github-app-prow --from-literal domain-name=<full prow domain> --from-literal app-id=<github app id> --from-file=app-cert=<github cert file path> --from-literal webhook-secret=<github-hmac-token>`
- secrets for tekton component
  > `kubectl -n apps create secret generic tekton-ingress --from-literal domain=<full tekton domain> --from-literal path_for_dashboard=/your-tekton-dashboard-path`
  > `kubectl -n ci-demo create secret generic github-secret --from-literal secretToken=<hmac-token>`
  > `kubectl -n ci-demo create secret generic github-app --from-literal app-id=<github app id> --from-file app-cert=<github app private key file path> --from-file app-cert-pkcs8=<github app private key with pkcs8 file path>`, you can convert from pkcs1 to pkcs8 with command: `openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt -in private-key.pem -out private-key-pkcs8.key`


**optional**:
- secrets `rook-ceph/cluster-release-optional-values`
  > for rook-ceph, [a example value file](./infrastructure/rook-ceph/config/values-nodes.tpl.yaml).
  > you can create with `kubectl -n rook-ceph create secret generic cluster-release-optional-values --from-file values.yaml=<you-values-for-custom-nodes>.yaml`

#### Github private token

Create a github private token with repo permissions, copy and write it.
See [doc](https://fluxcd.io/docs/get-started/#before-you-begin).


### Setup GitOps

```bash
export GITHUB_TOKEN=<github private token>
export GITHUB_REPOSITORY_OWNER=<github org or username>
flux check --pre
flux bootstrap github \
    --owner=${GITHUB_REPOSITORY_OWNER} \
    --repository=<your repo name> \
    --branch=main \
    --path=clusters/staging # or other cluster dir.
```

if you repo in under personal account, you should add cli option `--personal`.

> poc