# GitInsight broker HTTPS rollout

This is the deployment companion to the optional native HTTPS listener in
`PingCAP-QE/ee-apps` (`github-token-broker` and its Helm chart) and the verified
HTTPS client in `PingCAP-QE/gitinsight`. It is **not a record of a completed
production rollout**: the listener is still disabled, and enabling it remains a
separate reviewed change.

For the separate public Google-JWT gateway route (Service port 80, not native
HTTPS), see [External access to the GitHub token broker](github-token-broker-external.md).

## What this TLS actually protects

Native HTTPS protects one hop: the ARC runner pod to the broker pod inside the
cluster. That is why the certificate carries an in-cluster DNS name
(`github-token-broker.github-token-broker.svc.cluster.local`), why
`apps/gcp/github-token-broker/networkpolicy-arc-https.yaml` grants target port
8443 to the `arc-runners` namespace only, and why the client is handed a CA
bundle instead of relying on system trust.

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
   [ee-apps PR 899](https://github.com/PingCAP-QE/ee-apps/pull/899), and its
   Chart `0.2.0` and image `v2026.11.8-19-g04ea8c8` are published. This ee-ops
   change pins those releases with **`server.tls.enabled: false`**: upgrade and
   verify the existing HTTP service and new ARC runners first. The broker's
   existing HTTP 8080, authentication and permissions remain unchanged.
2. Certificate issuance and trust distribution are declarative and need no manual
   provisioning: `infrastructure/gcp/cert-manager` installs cert-manager and
   trust-manager, the cluster-internal CA signs
   `apps/gcp/github-token-broker/tls.yaml`, and a trust-manager `Bundle` writes the
   public CA into the `arc-runners` `github-token-broker-ca` ConfigMap. See
   [Certificate issuance (automated)](#certificate-issuance-automated) and
   [Public CA on ARC](#public-ca-on-arc).
3. In a **separate reviewed activation change**, enable HTTPS using the template
   below only after the certificate and runner trust are verified. The additional
   HTTPS listener uses 8443 and Service port 443. Do not merge the GitInsight
   HTTPS-only client merely because the HTTP-only upgrade succeeded.
4. Confirm the approved ARC caller-policy entry below is loaded, check HTTPS
   identity and Python availability from the actual ARC runner network, then
   merge/enable the GitInsight client and run one authorized crawl. Only after
   this succeeds is the deployed Helix finding ready for closure.

Merging code is not permission to mutate production. GitOps activation and the
authorized workflow run require operator approval. The implementation owner
should follow the rollout through rather than hand an untested URL change to the
repository owner as a completed fix.

## Published-artifact activation (operator only)

The HTTP-only stage pins Chart `0.2.0` and image `v2026.11.8-19-g04ea8c8`,
verified against the completed [chart release](https://github.com/PingCAP-QE/ee-apps/actions/runs/43348037974)
and [image release](https://github.com/PingCAP-QE/ee-apps/actions/runs/43348037966).
The image digest is
`sha256:7430bb2d479a78a0314307ba4331119133a1768ab53bc93b00171e34f2b493f5`.
These published versions are used below; verify the selected artifacts again if
updating either version in the later activation change.

Merge these fields into the existing HelmRelease in
`apps/gcp/github-token-broker/release.yaml`, preserving all other chart/source,
image repository, authentication, policy and HTTP settings. This is a future
activation template, not a complete replacement manifest or an instruction to
activate the current release:

```yaml
spec:
  chart:
    spec:
      version: 0.2.0
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
Secret read-only at `/etc/github-token-broker/tls` without `subPath`. Inspect the
published chart's rendered output to confirm this wiring and Service 443 -> 8443
before approval. Its `server.tls.port` must also equal the allowed port in
`apps/gcp/github-token-broker/networkpolicy-arc-https.yaml`; update both together
if changing it. In the same activation change, update
`test_resources_are_wired_without_premature_tls_activation` in
`scripts/test_github_token_broker_https.py` to assert the enabled TLS configuration
instead of its explicitly disabled HTTP-only stage. Run
`python3 scripts/test_github_token_broker_https.py` to check the activation template
against that NetworkPolicy. HTTP 8080 and existing probes remain enabled.

## Certificate issuance (automated)

Issuance is owned by cert-manager, so no leaf certificate, private key or Secret
Manager object is provisioned by hand:

| Object | File | Purpose |
| :--- | :--- | :--- |
| `ClusterIssuer/internal-ca-selfsigned` | `infrastructure/gcp/cert-manager/cluster-issuers/issuers.yaml` | Bootstraps the CA certificate only |
| `Certificate/internal-ca` (namespace `cert-manager`) | `infrastructure/gcp/cert-manager/internal-ca.yaml` | The cluster-internal CA: 10-year duration, key never rotated implicitly |
| `ClusterIssuer/internal-ca` | `infrastructure/gcp/cert-manager/cluster-issuers/issuers.yaml` | Signs short-lived in-cluster service certificates |
| `Certificate/github-token-broker-tls` | `apps/gcp/github-token-broker/tls.yaml` | The broker leaf: 90-day duration, renews 30 days before expiry, re-keys on renewal |

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
`apps/tencentcloud/github-token-broker/tls.yaml` stages the same leaf Secret name,
so activation there only needs that cluster's chart upgrade plus
`server.tls.enabled: true`.

That cluster has no in-cluster trust-bundle consumer yet, so trust-manager and a
`Bundle` are intentionally not installed: add them together with the first
consumer instead of pre-wiring an unused distributor. Its broker still runs Chart
`0.1.0`, which has no HTTPS listener at all; do not enable TLS there before the
chart/image upgrade for that cluster is reviewed.

## Public CA on ARC

Consumers need the CA certificate only, never the broker key, and they must not be
able to read it from the broker namespace. Distribution is declarative:
`Bundle/github-token-broker-ca` in
`infrastructure/gcp/cert-manager/internal-ca.yaml` reads `ca.crt` from the
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

The volume is `optional: true` **only for staging compatibility**: runners must
still start while the existing HTTP consumers operate, even if the Bundle has not
converged yet. The HTTPS client does not silently ignore a configured
missing/invalid bundle and does not fall back to HTTP, so the bundle must be
present at `ca.crt` before the client is enabled. Volume mounts are read-only,
without `subPath`, so bundle updates propagate to pods; explicitly verify the new
bundle on active runners before completing a rotation.

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

## Validation and activation

Before activating the consumer, use the authorized runner network and synthetic
or no-auth health requests only:

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

Also verify wrong-CA and wrong-hostname requests fail before any credential is
sent. Inspect the rendered Service 443 -> 8443, the TLS-enabled Deployment and
its certificate mount, plus effective NetworkPolicies. The standalone ARC rule
allows 8443 only; it does not grant ARC access to legacy HTTP 8080. A successful
`/healthz` does not verify caller authorization: the scoped ARC policy onboarding
above is a separate prerequisite. Do not weaken TLS verification, TokenReview or
authorization grants to work around a TLS failure.

Then run the explicitly authorized GitInsight workflow with normal policy
checks, verify token outputs remain masked and the crawl succeeds, and attach
the run/commit evidence to Helix. Never use the real SA JWT in diagnostic curl
arguments or copy token values into review comments.

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
and probe, not just GitInsight. Observe the rollout and fresh HTTPS handshakes on
**every** replica, and retain the pre-activation HelmRelease/chart/image revision
for rollback.

If activation fails, pause the affected crawl. An operator must revert the
activation GitOps change to the reviewed pre-activation HelmRelease and verify
broker recovery; do not try to hide the failure by weakening TLS or changing
broker authorization. Correct and re-review the TLS/trust problem before
retrying. Do not downgrade the HTTPS client to plaintext or mark the finding
fixed. Successful additive activation preserves the existing HTTP interface;
those consumers' later migration is a separate scope.
