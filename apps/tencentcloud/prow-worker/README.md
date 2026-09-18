# Prow Worker for `tencentcloud` cluster

This directory provisions a dedicated namespace and RBAC for running Prow job
pods from the `gcp` Prow control plane on the `tencentcloud` cluster.

It manages the following resources:

- Namespace: `prow-test-pods`
- ServiceAccount: `k8s-pod-full`
- Role and RoleBinding for basic pod lifecycle operations in `prow-test-pods`
- `NamespacedMutatingPolicy` `inject-prow-tencent-cost-tags`, which applies TKE
  supernode organization-billing tags to eligible Prow Pods

The namespace is pinned to `amd64` nodes through a namespace annotation.

## TKE supernode cost tags

On Pod `CREATE`, `inject-prow-tencent-cost-tags` best-effort adds missing
`eks.tke.cloud.tencent.com/eks-id: "true"`, generic `author`/`org`/`repo` Pod
labels, and a `resource-tag` JSON object with `org`, `repo`, optional `author`,
and optional `target_branch` (from `prow.k8s.io/refs.base_ref`). The generic
labels mirror the authoritative, Prow-validated refs for Pod-level queries and
intentionally replace conflicting generic labels; Tencent billing uses only
`resource-tag`. Existing `resource-tag` and `eks-id` annotations are preserved
because they may contain explicit workload attribution or cloud scheduling.

The policy only matches Pods marked `created-by-prow=true` with nonempty
`prow.k8s.io/refs.org` and `prow.k8s.io/refs.repo`; periodic jobs without
repository refs remain intentionally untagged rather than being attributed to
an invented repository. `failurePolicy: Ignore` ensures a cost-tagging failure
does not block a Prow job.

For bill day 2026-09-17, the pre-rollout supernode tag gate was confirmed at T+1
on 2026-09-18: the Tencent organization bill for TKE supernode resource
`eks-5xvh1q35` contained the direct canary's expected `author`, `org`, and
`repo` tags, and Cost Insight expanded those tags into direct attribution. This
verifies Pod annotations can reach the bill; it does not establish
admission-webhook ordering.

The policy deliberately has no `UPDATE` or `mutateExisting` behavior. It does
not backfill existing Pods or their historical Tencent bill rows. After rollout,
verify an actual Prow presubmit on a TKE supernode: its organization-billing row
must contain the expected tags after Tencent's T+1 tag propagation window.

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
