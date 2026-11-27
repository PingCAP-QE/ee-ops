# GitInsight broker HTTPS rollout

This is the deployment companion to the native HTTPS listener in
`PingCAP-QE/ee-apps` (`github-token-broker` and its Helm chart) and the verified
HTTPS client in `PingCAP-QE/gitinsight`.

The listener is **enabled on both clusters** (`apps/gcp/github-token-broker` and
`apps/tencentcloud/github-token-broker`). On GCP the `arc-runners` namespace is
the only client it was opened for; on TencentCloud no client uses it yet, so no
namespace is granted the port. Either way that alone does not close the finding:
the GitInsight client switch and one authorized HTTPS crawl are separate steps,
and the TencentCloud consumers still call the plaintext listener.

For the separate public Google-JWT gateway route (Service port 80, not native
HTTPS), see [External access to the GitHub token broker](github-token-broker-external.md).

## What this TLS actually protects

Native HTTPS protects one hop: the ARC runner pod to the broker pod inside the
cluster. That is why the certificate carries an in-cluster DNS name
(`github-token-broker.github-token-broker.svc.cluster.local`), why the client is
handed a CA bundle instead of relying on system trust, and why
`apps/gcp/github-token-broker/networkpolicy-arc-https.yaml` **declares** target
port 8443 for the `arc-runners` namespace only.

Read that NetworkPolicy as intent, not as an enforced boundary: the GCP cluster
runs with `addonsConfig.networkPolicyConfig.disabled: true` and no Calico or
anetd daemon, so none of these policies filter traffic today. Measured
2026-11-25: a pod in `arc-runners` reached the broker's plaintext 8080 as well,
which the policy does not grant. The control that actually keeps unauthorized
callers out is the projected ServiceAccount token plus TokenReview and the
caller policy — it always was. See
[NetworkPolicy enforcement is off on both clusters](#networkpolicy-enforcement-is-off-on-both-clusters).

It is server authentication only, not mutual TLS: callers prove identity with a
projected ServiceAccount token, which the broker validates with TokenReview plus
the caller policy. TLS adds confidentiality for credentials in flight; it does
not authorize anyone.

The public route described in
[External access to the GitHub token broker](github-token-broker-external.md) is a
different path. TLS there terminates at the GKE gateway, its upstream to the
Service stays plaintext, and this certificate is not part of it.

## Scope and ordering

1. The broker/chart implementation is merged in
   [ee-apps PR 899](https://github.com/PingCAP-QE/ee-apps/pull/899), and Chart
   `0.2.2` (which keeps the TLS port out of `networkPolicy.ingressNamespaces`)
   and image `v2026.11.8-19-g04ea8c8` are published. Both releases pin those
   artifacts with `server.tls.enabled: true`
   ([activated configuration](#activated-configuration)); TencentCloud runs the
   same chart and image, and keeps HTTP-only consumers and no TLS client
   ([TencentCloud cluster parity](#tencentcloud-cluster-parity)). The broker's
   existing HTTP 8080, authentication and permissions remain unchanged, so the
   consumers that have not migrated keep working.
2. Certificate issuance and trust distribution are declarative and need no manual
   provisioning: `infrastructure/gcp/cert-manager` installs cert-manager and
   trust-manager, the cluster-internal CA signs
   `apps/gcp/github-token-broker/tls.yaml`, and a trust-manager `Bundle` writes the
   public CA into the `arc-runners` `github-token-broker-ca` ConfigMap. See
   [Certificate issuance (automated)](#certificate-issuance-automated) and
   [Public CA on ARC](#public-ca-on-arc).
3. An operator then verifies the **activated** listener from the actual ARC
   runner network, on every replica, and confirms that wrong CA and wrong
   hostname fail. See [Verifying the activated
   listener](#verifying-the-activated-listener). Untested activation is not a
   completed migration: the change is broker-wide, so observe it.
4. Confirm the approved ARC caller-policy entry below, then merge/enable the
   GitInsight client and run one authorized crawl. Only after this succeeds is
   the deployed Helix finding ready for closure.

Merging code is not permission to mutate production. GitOps activation and the
authorized workflow run require operator approval. The implementation owner
should follow the rollout through rather than hand an untested URL change to the
repository owner as a completed fix.

## Activated configuration

Both releases pin Chart `0.2.2` and image `v2026.11.8-19-g04ea8c8`. The image was
verified against the completed
[image release](https://github.com/PingCAP-QE/ee-apps/actions/runs/43348037966);
its digest is
`sha256:7430bb2d479a78a0314307ba4331119133a1768ab53bc93b00171e34f2b493f5`.
`0.2.1` added `networkPolicy.tlsIngressNamespaces` (so enabling TLS does not
hand the port to every HTTP consumer) and `0.2.2` made both namespace lists
default to empty; `charts-release.yaml` publishes a version on merge to `main`.
Verify the selected artifacts again if updating either one.

`apps/gcp/github-token-broker/release.yaml` and
`apps/tencentcloud/github-token-broker/release.yaml` carry these fields on top of
their unchanged chart source, authentication, policy and HTTP settings:

```yaml
spec:
  chart:
    spec:
      version: 0.2.2
  values:
    image:
      tag: v2026.11.8-19-g04ea8c8
    server:
      tls:
        enabled: true
        port: 8443
        existingSecret: github-token-broker-tls
        certKey: tls.crt
        keyKey: tls.key
    service:
      httpsPort: 443
```

The chart maps these values to runtime `server.tls.enabled: true`,
`server.tls.address: ":8443"`,
`server.tls.cert_file: /etc/github-token-broker/tls/tls.crt` and
`server.tls.key_file: /etc/github-token-broker/tls/tls.key`. It mounts the existing
Secret read-only at `/etc/github-token-broker/tls` without `subPath`, so a renewed
pair is read on the next handshake without a restart, and it renders Service port
443 -> `targetPort: https`. `server.address` stays `:8080` -- the chart refuses any
other value -- and Service port 80, the probes and every existing HTTP consumer
are untouched.

`server.tls.port` must equal the allowed port in
`apps/gcp/github-token-broker/networkpolicy-arc-https.yaml`; update both together
if changing it. The chart keeps the TLS port out of
`networkPolicy.ingressNamespaces` (chart `0.2.1`): that list admits the plaintext
consumers on 8080 only, `networkPolicy.tlsIngressNamespaces` is left empty, and
`arc-runners` is granted 8443 by its own policy. `scripts/test_github_token_broker_https.py`
asserts the activated values, that `server.tls.existingSecret` is the Secret the
internal CA issues (`tls.yaml`), that no namespace gets the TLS port through the
chart's policy, and that the template above still matches the NetworkPolicy:

```bash
uv run --no-project --with pyyaml python3 -m unittest scripts/test_github_token_broker_https.py
```

## Certificate issuance (automated)

Issuance is owned by cert-manager, so no leaf certificate, private key or Secret
Manager object is provisioned by hand:

| Object | File | Purpose |
| :--- | :--- | :--- |
| `ClusterIssuer/internal-ca-selfsigned` | `infrastructure/gcp/cert-manager/post/cluster-issuers.yaml` | Bootstraps the CA certificate only |
| `Certificate/internal-ca` (namespace `cert-manager`) | `infrastructure/gcp/cert-manager/post/internal-ca.yaml` | The cluster-internal CA: 10-year duration, key never rotated implicitly |
| `ClusterIssuer/internal-ca` | `infrastructure/gcp/cert-manager/post/cluster-issuers.yaml` | Signs short-lived in-cluster service certificates |
| `Certificate/github-token-broker-tls` | `apps/gcp/github-token-broker/tls.yaml` | The broker leaf: 90-day duration, renews 30 days before expiry, re-keys on renewal |

Those objects are applied in two stages on purpose. The HelmReleases install
cert-manager's CRDs; the CA, issuers and Bundle are custom resources of those
CRDs. Flux server-side dry-runs a whole kustomization before applying anything, so
the two stages live in separate nested Kustomizations: `cert-manager-release`
(HelmReleases, with `healthChecks` so the stage is only Ready once the charts are)
and `cert-manager-post` (`dependsOn` the release stage). Putting them in one
kustomization deadlocks on `no matches for kind "Certificate" in version
"cert-manager.io/v1"` and also blocks every app that waits for `infrastructure`.

The leaf Secret name is fixed (`github-token-broker-tls`) because it is what the
chart mounts through `server.tls.existingSecret`. Renewal therefore needs no
operator step: cert-manager updates the Secret, kubelet swaps the projected volume
atomically, and the broker re-reads the pair on every handshake.

The earlier design pulled a prepared `github_token_broker_tls_json` object from
Secret Manager through the `ee-gcp-sm` store. That path is gone: nothing lives in
Secret Manager, so there is no certificate material to forget to provision, and a
missing remote object can no longer leave an ExternalSecret permanently unsynced.

Accepted trade-offs to review alongside the CA change:

- The CA private key lives in the `cert-manager` namespace alongside the add-on.
  It is not mounted into workloads, never enters Git, and is not readable from
  `arc-runners`.
- `ClusterIssuer/internal-ca` can sign any `Certificate` in the cluster, but every
  such certificate still lands through a reviewed GitOps change. Keep the issuer
  reserved for in-cluster service TLS.
- The trust anchor only reaches consumers that a reviewed `Bundle` targets.

Verify the issued Secret:

```bash
set -euo pipefail
: "${CONTEXT:?Set CONTEXT to the approved GCP kubeconfig context}"
kubectl --context "$CONTEXT" -n github-token-broker get certificate github-token-broker-tls \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
kubectl --context "$CONTEXT" -n github-token-broker get secret github-token-broker-tls \
  -o jsonpath='{.type}{"\n"}'
```

The first command must print `True` and the second `kubernetes.io/tls`.

## TencentCloud cluster parity

`infrastructure/tencentcloud/cert-manager` installs the same cert-manager release
and the same cluster-internal CA, and
`apps/tencentcloud/github-token-broker/tls.yaml` issues the same leaf Secret name
from it. That broker now runs the same chart (`0.2.2`), the same image, and the
same activated listener (`server.tls.enabled: true`, port 8443, Service 443), so
both clusters are one recipe.

**Jenkins is the first HTTPS client there, and it needs no CA.** The listener is
published on the cluster's own internal gateway
(`github-token-broker-qcloud.pingcap.net`, `apps/tencentcloud/github-token-broker/httproute.yaml`),
which presents the public `*.pingcap.net` certificate and re-encrypts to the
pod's TLS listener through a `BackendTLSPolicy`; the agents therefore verify the
public certificate with the roots their images already ship, and no trust
material is mounted anywhere. `GIT_BROKER_URL` points at that name, and the
shared library passes no `--cacert` at all.

The gateway address is an internal CLB (`10.0.6.5`, RFC1918), so the endpoint is
reachable from the VPC and from nothing outside it — verified by timing out from
a corporate laptop against another route on the same gateway.

The plaintext Service port is gone: the 24h mint log had only `jenkins-tidb` and
`jenkins-tiflash` calling the broker, `ee-cd` has no Tekton any more and
`tibuild` minted nothing, so `networkPolicy.ingressNamespaces` is empty and the
rendered Service publishes `https:443` only. The app still listens on `:8080`
inside the pod for its own probes, which are container-port probes and need no
Service port.

### Who needs the CA on that cluster

trust-manager **is** installed there now, but only to publish the internal CA to
the two namespaces whose gateways verify a pod certificate
(`cache`, `github-token-broker`) — it is not a trust bundle for broker clients.
A client that wants to talk to the broker's in-cluster name
(`github-token-broker.github-token-broker.svc:443`) directly is a different
story and needs its own trust distribution:

1. Extend the `Bundle`'s namespace selector to that client's namespace, and add
   the namespace to `app.targetNamespaces` of the trust-manager release.
2. Mount the resulting ConfigMap into the client and pass it to whatever HTTP
   client it uses. The shared Jenkins library deliberately has no CA option any
   more, so such a client has to bring its own (the GCP ARC runner does this
   with `GITINSIGHT_BROKER_CA_FILE`).
3. Grant that namespace on port 8443 with a NetworkPolicy next to the route it
   serves.
4. Verify the handshake on every replica, as in
   [Verifying the activated listener](#verifying-the-activated-listener), and
   keep the client's HTTP calls until its HTTPS path is proven.

## Public CA on ARC

Consumers need the CA certificate only, never the broker key, and they must not be
able to read it from the broker namespace. Distribution is declarative:
`Bundle/github-token-broker-ca` in
`infrastructure/gcp/cert-manager/post/internal-ca.yaml` reads `ca.crt` from the
`internal-ca` Secret in the trust namespace (`cert-manager`) and writes a ConfigMap
named `github-token-broker-ca` with key `ca.crt` into the namespaces its
`namespaceSelector` matches, currently only `arc-runners`.

trust-manager is installed with `app.targetNamespaces: [arc-runners]` and
`secretTargets.authorizedSecrets: [internal-ca]`, so it can write targets only
there, and its Secret read access is limited to the trust namespace plus that
target namespace. It distributes a public trust anchor, not a credential: never
point a `Bundle` source at a Secret that holds a private key.

The runner mounts that ConfigMap at `/etc/github-token-broker/ca` and exports
`GITINSIGHT_BROKER_CA_FILE` so the GitInsight helper can use the bundle without
replacing trust for GitHub, Pixi or other tools. An explicit action `ca-file`
input takes precedence.

The bundle is live in `arc-runners` (checked 2026-11-25: `CN=pingcap-internal-services-ca`,
SHA256 `03:4F:23:AF:...:BF:1D:0D`), so the listener can be verified from a runner
pod. The volume is still `optional: true` **only because the HTTPS client is not
enabled yet**: runners must start while every consumer still uses HTTP, and an ARC
runner set that never talks to the broker must not fail on a missing ConfigMap. The
HTTPS client does not silently ignore a configured missing/invalid bundle and does
not fall back to HTTP, so drop `optional` in the same reviewed change that enables
the client. Volume mounts are read-only, without `subPath`, so bundle updates
propagate to pods; explicitly verify the new bundle on active runners before
completing a rotation.

Verify the distributed bundle and record its fingerprint:

```bash
set -euo pipefail
: "${CONTEXT:?Set CONTEXT to the approved GCP kubeconfig context}"
kubectl --context "$CONTEXT" -n arc-runners get configmap github-token-broker-ca \
  -o jsonpath='{.data.ca\.crt}' | openssl x509 -noout -subject -fingerprint -sha256
```

## ARC caller authorization (operator only)

TLS, the CA mount and network access do **not** authorize token issuance. Before
enabling GitInsight, have the operator verify its existing ARC caller rule in the
GCP Secret Manager value `github-token-broker-policy`, managed outside GitOps.
GitInsight's current credentials documentation records an existing ARC rule;
HTTPS migration must not blindly add or widen it. Only if a necessary grant is
actually missing should the operator propose and approve a separate policy change.
`apps/gcp/github-token-broker/external-secret-policy.yaml` syncs its raw policy
YAML into Secret `github-token-broker-policy`, key `policy.yaml`. Preserve existing
caller rules; no new Kubernetes RBAC grant is needed.

The policy matches the exact caller `namespace` and `service_account`. Use
`namespace: arc-runners` and the actual runner pod's `spec.serviceAccountName`:

```bash
set -euo pipefail
: "${CONTEXT:?Set CONTEXT to the approved GCP kubeconfig context}"
: "${RUNNER_POD:?Set RUNNER_POD to the actual ARC runner pod name}"
kubectl --context "$CONTEXT" -n arc-runners get pod "$RUNNER_POD" \
  -o jsonpath='{.spec.serviceAccountName}{"\n"}'
```

The controller-created name is in the `arc-runner-set-pingcap-qe-gha-rs-*` family;
record the exact name, not that glob, and recheck it after scale-set recreation.
Verify each `allow` entry against the existing approved use: crawl read scopes
for the approved owners/repositories, and `contents: write` / `pull_requests: write`
only for `PingCAP-QE/gitinsight-data` where the existing publisher needs them.
Do not turn the transport fix into additional owner-wide write access or remove
required publication grants. Keep repository narrowing and permissions no broader
than the approved baseline; policy-scope redesign is outside this TLS change.
The NetworkPolicy admits the
**whole** `arc-runners` namespace: ephemeral pods can run arbitrary workflow code
with automounted SA tokens. Every workflow sharing the authorized SA can request
its grants; this is not a GitInsight-only workflow identity. Review that shared
access and the precise repository/permission scope as part of activation. Verify
that runner group `EE-Group` still admits only the approved GitInsight repositories;
if that audience has expanded, stop for an identity/policy review rather than
implicitly extending the shared ServiceAccount's privileges.

Wait for External Secrets sync (refresh interval **one hour**), projected-volume
propagation and broker policy reload before the workflow run. Confirm the broker
has loaded the approved rule. A missing or mismatched rule yields `403 forbidden`
even with healthy TLS, trusted CA and a successful unauthenticated `/healthz`.

## Verifying the activated listener

Run these checks from the authorized runner network, before switching the client,
and repeat the handshake against **every** broker replica rather than one pod: a
mismatched certificate/key pair or a failed HTTPS bind stops the process from
serving either listener, so a single healthy pod proves nothing about the rest of
the rollout.

```bash
command -v python3
python3 -c 'import ssl, urllib.request'
test -r "$GITINSIGHT_BROKER_CA_FILE"
python3 - <<'PY'
import os
import ssl
import urllib.request

context = ssl.create_default_context(cafile=os.environ['GITINSIGHT_BROKER_CA_FILE'])
with urllib.request.urlopen(
    'https://github-token-broker.github-token-broker.svc.cluster.local/healthz',
    context=context, timeout=10,
) as response:
    assert response.status == 200
PY
```

Also verify the two negative cases fail before any credential is sent: the same
`/healthz` request with a different `cafile` (the GitHub bundle, or an empty file),
and with the hostname replaced by another namespace. Inspect the rendered Service
443 -> 8443, the TLS-enabled Deployment and its certificate mount, plus the
NetworkPolicy objects. The ARC rule declares 8443 and does not declare 8080, but
do not read that as isolation — see
[NetworkPolicy enforcement is off on both clusters](#networkpolicy-enforcement-is-off-on-both-clusters).
A successful `/healthz` does not verify caller authorization either: the scoped ARC
policy onboarding above is a separate prerequisite. Do not weaken TLS verification,
TokenReview or authorization grants to work around a TLS failure.

Then run the explicitly authorized GitInsight workflow with normal policy
checks, verify token outputs remain masked and the crawl succeeds, and attach
the run/commit evidence to Helix. Never use the real SA JWT in diagnostic curl
arguments or copy token values into review comments.

## NetworkPolicy enforcement is off on both clusters

Every `NetworkPolicy` in this document is declarative, not enforced:

- GCP: `gcloud container clusters describe prow --zone us-central1-c` reports
  `addonsConfig.networkPolicyConfig.disabled: true`, and no `calico-node` or
  `anetd` DaemonSet runs there. Measured 2026-11-25 after activation: a pod in
  `arc-runners` reached the broker's plaintext port 8080 with `200`, although
  `NetworkPolicy/github-token-broker-arc-https` grants it only 8443 and the
  chart's own policy lists seven other namespaces for 8080.
- TencentCloud: `DataPlaneV2` is off and only `tke-cni-agent` runs (no
  calico/cilium DaemonSet). Measured 2026-11-25 during the chart upgrade: a pod
  in `default` — a namespace the chart's policy does not list — reached 8080 with
  `200`.

So today:

- Any pod in either cluster can reach the broker's listeners. The policies
  describe the intended topology and are ready for the day enforcement is
  switched on; they are not the control that protects the credentials.
- Caller authorization is the real boundary: a request without a valid projected
  ServiceAccount token for a policy entry gets `403` regardless of source
  address. Keep that policy narrow; do not treat network reachability as
  authorization.
- Verifying "only ARC can reach 8443" is not possible on these clusters yet. The
  HTTPS migration evidence is the handshake itself (trusted CA, expected SAN,
  every replica), not the source namespace. That is also why an activated
  listener with `tlsIngressNamespaces` empty is not isolation — it is simply a
  port nobody has a CA for yet.

Turning enforcement on is a separate, cluster-wide change: it applies every
existing policy at once, so workloads that rely on today's implicit allow-all
start being denied. Audit and fix the whole estate, announce a maintenance
window, then enable it (GKE Dataplane V2 or the `networkPolicy` add-on on GCP;
the VPC-CNI policy path on TKE); do not flip it as part of a TLS rollout.

## Rotation and rollback

Leaf rotation is automatic: cert-manager renews 30 days before expiry, re-keys the
pair, the Secret change propagates through the projected volume, and the server
reloads the certificate/key pair on each new TLS handshake. No pod restart is
required for a valid pair, and no operator step is needed at renewal time.

For an approved early or emergency re-issue:

```bash
set -euo pipefail
: "${CONTEXT:?Set CONTEXT to the approved GCP kubeconfig context}"
cmctl renew --namespace github-token-broker github-token-broker-tls --context "$CONTEXT"
```

Then verify the Secret update and every replica's new handshake rather than
assuming the command itself completes rotation. A healthy old HTTP probe alone
does not demonstrate HTTPS readiness.

Rotating the **CA** is a different, coordinated change. Its key is not rotated
implicitly (`rotationPolicy: Never`), so a CA change means re-keying: distribute
an overlapping bundle that carries both the old and the new CA certificate,
re-issue every leaf, confirm all consumers, and only then retire the old root.
Update the `Bundle` source and the affected `Certificate` resources in the same
reviewed change. Do not add an insecure verifier bypass.

TLS activation is **broker-wide**: missing/malformed/mismatched certificate/key
material or a failed HTTPS bind prevents the process from serving either
listener. A bad activation can therefore interrupt every existing HTTP consumer
and probe, not just GitInsight. So:

- Watch the broker for **5 minutes** after Flux reconciles: every replica `Ready`,
  `/healthz` 200 on both listeners, no restart loop, one fresh handshake per
  replica, and one request from each existing HTTP consumer path that shares this
  broker.
- Keep the pre-activation revision of
  `apps/gcp/github-token-broker/release.yaml` (`server.tls.enabled: false`, no
  `service.httpsPort`) as the rollback target. Revert the activation change and let
  Flux reconcile; the chart then renders without the HTTPS listener, Service 443
  and the TLS mount, exactly as before.
- Do not roll back by deleting `Certificate/github-token-broker-tls` or its Secret:
  they are inert while the listener is disabled and are needed for the retry.

If activation fails, pause the affected crawl. An operator must revert the
activation GitOps change to the reviewed pre-activation HelmRelease and verify
broker recovery; do not try to hide the failure by weakening TLS or changing
broker authorization. Correct and re-review the TLS/trust problem before
retrying. Do not downgrade the HTTPS client to plaintext or mark the finding
fixed. Successful additive activation preserves the existing HTTP interface;
those consumers' later migration is a separate scope.
