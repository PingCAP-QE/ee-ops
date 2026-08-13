# Prow Worker for `tencentcloud` cluster

This directory provisions a dedicated namespace and RBAC for running Prow job
pods from the `gcp` Prow control plane on the `tencentcloud` cluster.

It manages the following resources:

- Namespace: `prow-test-pods`
- ServiceAccount: `k8s-pod-full`
- Role and RoleBinding for basic pod lifecycle operations in `prow-test-pods`

The namespace is pinned to `amd64` nodes through a namespace annotation.

## Apply with GitOps

This directory is included from [../kustomization.yaml](../kustomization.yaml).
After merging the change, let Flux reconcile `apps/tencentcloud`.

For manual validation, you can render the manifests locally:

```sh
kubectl kustomize apps/tencentcloud/prow-worker
```

## Generate a long-lived kubeconfig

Use [gencred.sh](./gencred.sh) after the namespace and RBAC are available on the
`tencentcloud` cluster.

The script assumes your current `kubectl` context points to the target `tencentcloud`
cluster. It will:

1. Ensure the ServiceAccount `k8s-pod-full` exists.
2. Create a `kubernetes.io/service-account-token` Secret if needed.
3. Wait for Kubernetes to populate the token.
4. Write a kubeconfig file for the `prow-test-pods` namespace.

Run:

```sh
cd apps/tencentcloud/prow-worker
./gencred.sh
```

Default values:

- Namespace: `prow-test-pods`
- ServiceAccount: `k8s-pod-full`
- Output kubeconfig: `prow-test-pods-k8s-pod-full.conf`
- Token Secret: `k8s-pod-full-token`

Custom usage:

```sh
./gencred.sh [namespace] [serviceaccount] [output] [token_secret]
```

## Install the kubeconfig into `gcp` Prow

After generating the kubeconfig, update the `prow-kubeconfig` Secret in the
`apps` namespace of the `gcp` cluster:

```sh
kubectl --context <gcp-context> -n apps create secret generic prow-kubeconfig \
  --from-file=config=prow-test-pods-k8s-pod-full.conf \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Verify access

Before updating `gcp` Prow, verify that the generated kubeconfig can manage pods
in `prow-test-pods`:

```sh
kubectl --kubeconfig=prow-test-pods-k8s-pod-full.conf -n prow-test-pods auth can-i create pods
kubectl --kubeconfig=prow-test-pods-k8s-pod-full.conf -n prow-test-pods auth can-i delete pods
kubectl --kubeconfig=prow-test-pods-k8s-pod-full.conf -n prow-test-pods auth can-i get pods
```

## Token Secret lifecycle

The generated kubeconfig embeds the ServiceAccount token value. After the
kubeconfig has been created and verified, the intermediate token Secret can be
deleted from `tencentcloud` if you do not need it anymore:

```sh
kubectl -n prow-test-pods delete secret k8s-pod-full-token
```

If you need to regenerate the kubeconfig later, run `./gencred.sh` again.
