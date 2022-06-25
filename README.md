## GitOps everything for Efficiency Engineering

You can use the [editor on GitHub](https://github.com/PingCAP-QE/ee-ops/edit/gh-pages/README.md) to maintain and preview the content for your website in Markdown files.

## How to Setup it in you k8s cluster

Before all please fork it into you personal account or organization.

### Pre require

#### GitOps Tools

- Flux CLI
  > Install by bash or download release binary from [Flux site](https://fluxcd.io/docs/get-started/#install-the-flux-cli)
#### cluster secret data

- secrets for jenkins component
  > see [here](apps/staging/jenkins/README.md)
- secrets for prow component
  > first copy and update with the [tpl](apps/staging/prow/values.yaml) to file `values.yaml`, then create secret `prow-secret` with kubectl:
  > `kubectl -n apps create secret generic prow-secret --from-file=values.yaml=values.yaml`
- other `WIP`


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
