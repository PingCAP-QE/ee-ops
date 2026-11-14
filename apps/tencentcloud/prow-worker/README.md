# Prow Worker for `tencentcloud` cluster

This directory provisions a dedicated namespace and RBAC for running Prow job
pods from the `gcp` Prow control plane on the `tencentcloud` cluster.

It manages the following resources:

- Namespace: `prow-test-pods`
- ServiceAccount: `k8s-pod-full`
- Role and RoleBinding for basic pod lifecycle operations in `prow-test-pods`
- `NamespacedMutatingPolicy` `inject-prow-tencent-cost-tags`, which applies TKE
  supernode organization-billing tags to eligible Prow Pods
- `Policy` `restrict-prow-job-pod-credentials`, which reports - and once the
  credentials are moved out of the namespace, denies - PR-authored Prow job
  Pods that name `k8s-pod-full` or one of the org-wide Secrets

The namespace is pinned to `amd64` nodes through a namespace annotation.

Job pods land here when their spec sets `cluster: tke-pingcap-cicd` (job configs
live in `prow-jobs/` of PingCAP-QE/ci). That alias is a kubeconfig **context**
name in the `gcp` Prow `prow-kubeconfig` secret, so the credential generated
below must use `tke-pingcap-cicd` as its context name.

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

## Generate a time-limited kubeconfig

Use [gencred.sh](./gencred.sh) after the namespace and RBAC are available on the
`tencentcloud` cluster.

The script assumes your current `kubectl` context points to the target `tencentcloud`
cluster, and that you may create ServiceAccount tokens there (`create` on the
`serviceaccounts/token` subresource in `prow-test-pods`). It will:

1. Ensure the ServiceAccount `k8s-pod-full` exists.
2. Mint a **bound, time-limited** token with `kubectl create token … --duration`
   (the TokenRequest API). No `kubernetes.io/service-account-token` Secret is
   created, and nothing is persisted in the cluster.
3. Write a kubeconfig file for the `prow-test-pods` namespace, with the context
   named after the Prow cluster alias (`tke-pingcap-cicd`).
4. Verify the kubeconfig with `kubectl auth can-i create pods` before you use it,
   and print the exact token expiry.

Run:

```sh
cd apps/tencentcloud/prow-worker
./gencred.sh
```

Default values:

- Namespace: `prow-test-pods`
- ServiceAccount: `k8s-pod-full`
- Output kubeconfig: `prow-test-pods-k8s-pod-full.conf`
- Context (Prow cluster alias): `tke-pingcap-cicd`
- Token lifetime: `2160h` (90 days)

Custom usage:

```sh
./gencred.sh [options] [namespace] [serviceaccount] [output]

Options:
  --duration=DUR              token lifetime, Go duration (default 2160h)
  --context=NAME              kubeconfig context / Prow build-cluster alias
                              (default tke-pingcap-cicd)
  --cleanup-old-secret[=NAME] delete the legacy non-expiring token Secret
                              (default NAME: k8s-pod-full-token)
  -h, --help
```

The 4th and 5th positional arguments the script used to take (`token_secret`,
`context`) are gone: no token Secret is created any more, and the context is now
passed with `--context=NAME`. Passing extra positionals is an error rather than a
silent reinterpretation.

The generated kubeconfig embeds a live bearer token, so the script writes it with
mode `0600`. Do not commit it (it is not in the repo) and do not paste the token
anywhere.

## Install the kubeconfig into `gcp` Prow

The `prow-kubeconfig` Secret in the `apps` namespace of the `gcp` cluster is
owned by the ExternalSecret in `apps/gcp/prow/pre/secrets/prow-kubeconfig.yaml`,
which mirrors the GCP Secret Manager secret
`gcp_prow_external_clusters_kubeconfig`. Do not create or patch that Kubernetes
Secret by hand: ExternalSecrets reconciles it and would overwrite manual edits.

The Secret Manager value is a multi-context kubeconfig. Prow turns every context
other than the in-cluster one into a build cluster named after the context, so
merge the newly generated `tke-pingcap-cicd` context into it and publish a new
version:

```sh
gcloud secrets versions access latest \
  --secret=gcp_prow_external_clusters_kubeconfig \
  --project=<gcp-project> > external.conf

KUBECONFIG=external.conf:prow-test-pods-k8s-pod-full.conf \
  kubectl config view --raw --flatten > merged.conf

gcloud secrets versions add gcp_prow_external_clusters_kubeconfig \
  --project=<gcp-project> --data-file=merged.conf
```

ExternalSecrets refreshes the Secret every hour; force an immediate sync with:

```sh
kubectl --context <gcp-context> -n apps annotate externalsecret prow-kubeconfig \
  force-sync="$(date +%s)" --overwrite
```

## Verify access

Before updating `gcp` Prow, verify that the generated kubeconfig can manage pods
in `prow-test-pods`:

```sh
kubectl --kubeconfig=prow-test-pods-k8s-pod-full.conf --context tke-pingcap-cicd \
  -n prow-test-pods auth can-i create pods
kubectl --kubeconfig=prow-test-pods-k8s-pod-full.conf --context tke-pingcap-cicd \
  -n prow-test-pods auth can-i delete pods
kubectl --kubeconfig=prow-test-pods-k8s-pod-full.conf --context tke-pingcap-cicd \
  -n prow-test-pods auth can-i get pods
```

## Token lifetime and rotation

The token is a TokenRequest-issued (bound) ServiceAccount token: it is bound to
the `k8s-pod-full` ServiceAccount UID, never stored in the cluster, and expires at
a fixed instant. It is not refreshed automatically, and neither `kubelet` nor Prow
can renew it: the kubeconfig has to be regenerated and republished.

### Why 2160h (90 days)

Measured on the `tencentcloud` cluster (`tke-cls-9zpon9y1`, API server
`v1.34.1-tke.6`) on 2026-11-05, `kubectl create token --duration` accepts
**10 minutes … 2^32 seconds (≈136 years)**; the API server imposes no smaller
cloud-specific cap, and honours requests up to that boundary:

| requested | result |
| --- | --- |
| `5m`, `9m` | rejected: `may not specify a duration less than 10 minutes` |
| `10m` | granted, `exp - iat = 600s` |
| `8760h` (1y), `87600h` (10y), `876000h` (100y) | granted, requested lifetime honoured |
| `1193046h` | granted, `exp - iat = 4294965600s` (just under the cap) |
| `1193047h` and above | rejected: `may not specify a duration larger than 2^32 seconds` |

So the ceiling is a Kubernetes API-server bound, not an operational one, and the
lifetime is a policy choice: this credential can create and delete Pods in a
shared CI namespace, and rotating it is a manual, multi-step procedure (new
kubeconfig → new Secret Manager version → ExternalSecret sync → restart the Prow
components). `2160h` keeps the exposure window at one quarter while staying long
enough that rotation is a scheduled quarter-hour job, not a weekly chore. Rotate
with headroom: do it when roughly **two thirds of the lifetime** has elapsed
(≈30 days left), not on the last day.

If you need a different window, pass `--duration`; do not exceed one year, and
keep in mind that a short lifetime means Prow jobs on the `tencentcloud` cluster
start failing at expiry until the kubeconfig is rotated.

### Rotation procedure

Prerequisites: kubectl access to both clusters (`tencentcloud` and `gcp`), and
`gcloud` access to the GCP project holding
`gcp_prow_external_clusters_kubeconfig`.

1. Regenerate the kubeconfig on `tencentcloud` (record the printed expiry; this
   is what you schedule the next rotation against):

   ```sh
   cd apps/tencentcloud/prow-worker
   ./gencred.sh                      # prints "the token expires at …"
   ```

2. Publish it as a new Secret Manager version (the same merge as
   [Install the kubeconfig into `gcp` Prow](#install-the-kubeconfig-into-gcp-prow) —
   the Secret Manager value is a multi-context kubeconfig, so always re-merge
   instead of uploading the single-context file):

   ```sh
   gcloud secrets versions access latest \
     --secret=gcp_prow_external_clusters_kubeconfig \
     --project=<gcp-project> > external.conf

   KUBECONFIG=external.conf:prow-test-pods-k8s-pod-full.conf \
     kubectl config view --raw --flatten > merged.conf

   gcloud secrets versions add gcp_prow_external_clusters_kubeconfig \
     --project=<gcp-project> --data-file=merged.conf
   ```

3. Force the ExternalSecret to pick it up (otherwise it refreshes within an hour):

   ```sh
   kubectl --context <gcp-context> -n apps annotate externalsecret prow-kubeconfig \
     force-sync="$(date +%s)" --overwrite
   ```

4. Restart the Prow components that mount `prow-kubeconfig`, so they load the new
   token instead of the one they cached at startup. Prow components that register
   a kubeconfig watcher exit by themselves when the mounted file changes, but a
   deterministic rollout restart is the supported path:

   ```sh
   kubectl --context <gcp-context> -n apps rollout restart \
     deploy/prow-pcm deploy/prow-sinker deploy/prow-deck deploy/prow-hook \
     deploy/prow-pipeline
   kubectl --context <gcp-context> -n apps rollout status deploy/prow-pcm
   ```

5. Verify: run a Prow job whose spec sets `cluster: tke-pingcap-cicd` (or check
   `kubectl --context <gcp-context> -n apps logs deploy/prow-pcm` for build-cluster
   errors) and confirm Pods are created in `prow-test-pods`.

6. Optionally destroy the previous Secret Manager versions; they still contain the
   previous kubeconfig (and therefore the previous, now-expiring token):

   ```sh
   gcloud secrets versions list gcp_prow_external_clusters_kubeconfig \
     --project=<gcp-project>
   gcloud secrets versions destroy <previous-version> \
     --secret=gcp_prow_external_clusters_kubeconfig --project=<gcp-project>
   ```

### Check remaining lifetime

The expiry is embedded in the token. For the kubeconfig you are about to publish:

```sh
kubectl --kubeconfig=prow-test-pods-k8s-pod-full.conf --context tke-pingcap-cicd \
  config view --raw -o jsonpath='{.users[?(@.name=="k8s-pod-full")].user.token}' |
  cut -d. -f2 | tr '_-' '/+' |
  awk '{l = length($0) % 4; if (l == 2) $0 = $0 "=="; else if (l == 3) $0 = $0 "="; print}' |
  base64 -d | jq -r '.exp | todate'
```

For the copy Prow is currently using, point the same snippet at the
`merged.conf`/`external.conf` you pulled from Secret Manager (or exec into a Prow
pod and read `/etc/kubeconfig/config`).

### Legacy token Secret cleanup

Older revisions of `gencred.sh` created a `kubernetes.io/service-account-token`
Secret named `k8s-pod-full-token` and copied its non-expiring token into the
kubeconfig. That token never expires and stays valid until the Secret is deleted,
so the migration is only complete once the Secret is gone.

Delete it **after** a rotated, time-limited kubeconfig is live in Prow (deleting
the Secret invalidates the old token immediately, and any kubeconfig still
carrying it stops working):

```sh
# either, via the script (it also regenerates the kubeconfig):
./gencred.sh --cleanup-old-secret

# or directly, when the kubeconfig is already rotated:
kubectl -n prow-test-pods delete secret k8s-pod-full-token
```

`gencred.sh` prints a reminder when the legacy Secret still exists. Deleting the
Secret does not touch the ServiceAccount or its Role/RoleBinding — they are the
live consumer of this credential (Prow job specs in PingCAP-QE/ci select it with
`cluster: tke-pingcap-cicd`) and must stay.

### Rollback

If the bound-token flow has to be reverted:

1. `git revert` the gencred commit (the README change goes with it), or restore
   the previous script with `git checkout <previous-sha> -- apps/tencentcloud/prow-worker/gencred.sh`.
2. Re-run the restored script: it re-creates the `k8s-pod-full-token` Secret and
   writes a kubeconfig with the non-expiring token.
3. Publish and restart as in step 2–4 of the rotation procedure.

Rolling back restores the previous behaviour (a non-expiring token readable from
the namespace) — it is a temporary unblock, not a steady state.
