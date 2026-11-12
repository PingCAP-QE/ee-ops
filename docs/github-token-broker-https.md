# GitInsight broker HTTPS rollout

This is the deployment companion to the optional native HTTPS listener in
`PingCAP-QE/ee-apps` (`github-token-broker` and its Helm chart) and the verified
HTTPS client in `PingCAP-QE/gitinsight`. It is **not** a record of a completed
production rollout. No commands in this document have been run against production.

For the separate public Google-JWT gateway route (Service port 80, not native
HTTPS), see [External access to the GitHub token broker](github-token-broker-external.md).

## Scope and ordering

1. Review/merge the ee-apps broker/chart implementation and wait for its image
   and chart release. The server retains HTTP 8080 for existing callers/probes;
   optional native TLS listens on 8443 and is exposed as Service port 443.
2. Provision the leaf certificate/key and distribute the public CA as below.
   This ee-ops change prepares the TLS Secret, HTTPS-only ARC NetworkPolicy and
   runner mount. It deliberately does **not** switch the live HelmRelease to an
   unpublished chart/image or enable a listener the current image cannot serve.
3. Update `apps/gcp/github-token-broker/release.yaml` to the **published, verified**
   TLS-capable chart and immutable image using the activation template below,
   enabling TLS with Secret `github-token-broker-tls`.
   Do not reuse `v2026.10.25-1-g930f405`, which has no TLS listener. Review that
   version/activation change before merging it; never guess a future image tag.
4. Confirm the approved ARC caller-policy entry below is loaded, check HTTPS
   identity and Python availability from the actual ARC runner network, then
   merge/enable the GitInsight client and run one authorized crawl. Only after
   this succeeds is the deployed Helix finding ready for closure.

Merging code is not permission to mutate production. Certificate provisioning,
GitOps activation and the authorized workflow run require operator approval.
The implementation owner should follow the rollout through rather than hand an
untested URL change to the repository owner as a completed fix.

## Published-artifact activation (operator only)

After the TLS-capable chart and image are actually published, an operator must
populate `$TLS_CHART_VERSION` with the verified published chart version and
`$TLS_IMAGE_TAG` with the verified published immutable TLS image tag. No concrete
TLS release version is assumed here. Replace both placeholders with those actual
values before reviewing the activation change; they are **not** automatic Flux
or shell substitutions inside a YAML file.

Merge these fields into the existing HelmRelease in
`apps/gcp/github-token-broker/release.yaml`, preserving all other chart/source,
image repository, authentication, policy and HTTP settings. This is a future
activation template, not a complete replacement manifest or an instruction to
activate the current release:

```yaml
spec:
  chart:
    spec:
      version: "$TLS_CHART_VERSION"
  values:
    image:
      tag: "$TLS_IMAGE_TAG"
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
instead of its preparatory absence. Run
`python3 scripts/test_github_token_broker_https.py` to check the activation template
against that NetworkPolicy. HTTP 8080 and existing probes remain enabled.

## Certificate material

Use the organisation's approved issuer. Its leaf certificate must include
`github-token-broker.github-token-broker.svc.cluster.local` as a DNS SAN, have
server-auth usage, be unexpired, and match its private key. `tls.crt` must contain
the PEM leaf followed by required intermediates. The public CA bundle is not a
credential, but is a trust anchor: obtain it through trusted deployment channels,
not by downloading and trusting whatever the broker currently serves.

The root/issuer private key must never enter Git, Kubernetes runner mounts, logs,
or the broker TLS Secret. Protect the leaf key using the existing Secret Manager
and External Secrets mechanism, not a plaintext file in the repository.

After approval, with pre-existing secure local files `CERT_FILE`, `KEY_FILE` and
`CA_FILE`, an operator verifies the chain and key using the approved PKI procedure
and checks the hostname, for example:

```bash
set -euo pipefail
# Do not shell-trace these steps or print key contents.
BROKER_HOST=github-token-broker.github-token-broker.svc.cluster.local
umask 077
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
# Verify the leaf identity while supplying the full chain as intermediates.
openssl x509 -in "$CERT_FILE" -out "$check_dir/leaf.pem"
openssl verify -CAfile "$CA_FILE" -untrusted "$CERT_FILE" -purpose sslserver \
  -verify_hostname "$BROKER_HOST" "$check_dir/leaf.pem"
# Compare only public keys; these commands do not emit the private key.
openssl x509 -in "$CERT_FILE" -noout -pubkey > "$check_dir/cert.pub"
openssl pkey -in "$KEY_FILE" -pubout > "$check_dir/key.pub"
cmp "$check_dir/cert.pub" "$check_dir/key.pub"
```

Store a JSON object with `tls.crt` and `tls.key` in GCP Secret Manager secret
`github_token_broker_tls_json` in `pingcap-testing-account`. The existing
`ee-gcp-sm` store is already restricted to approved namespaces, including
`github-token-broker`. `external-secret-tls.yaml` extracts the object into a
`kubernetes.io/tls` Secret. Do not broaden that store to `arc-runners` just to
read public CA material: that would grant access to unrelated project secrets.
If the preparatory ExternalSecret is merged before its remote object exists, it
will report a sync error and create no TLS Secret. Existing TLS-disabled pods
continue running; this is not evidence that TLS is ready. Provision the remote
object and confirm a successful sync before approving TLS activation.

## Public CA on ARC

The runner mounts public ConfigMap `github-token-broker-ca` in namespace
`arc-runners` at `/etc/github-token-broker/ca` and reads its `ca.crt` key at
`/etc/github-token-broker/ca/ca.crt`. It exports
`GITINSIGHT_BROKER_CA_FILE` so the GitInsight helper can use the bundle without
replacing trust for GitHub, Pixi or other tools. An explicit action `ca-file`
input takes precedence.

The bundle is environment-specific public data, seeded from the verified issuer
bundle after operator approval (never include a private key). Set `CONTEXT` to the
approved GCP kubeconfig context and `CA_FILE` to the verified local public bundle
path before running:

```bash
set -euo pipefail
: "${CONTEXT:?Set CONTEXT to the approved GCP kubeconfig context}"
: "${CA_FILE:?Set CA_FILE to the verified public CA bundle path}"
test -f "$CA_FILE"
test -r "$CA_FILE"
if grep -q 'PRIVATE KEY' "$CA_FILE"; then
  echo 'refusing a CA bundle containing a private key' >&2
  exit 1
fi
kubectl --context "$CONTEXT" -n arc-runners create configmap github-token-broker-ca \
  --from-file=ca.crt="$CA_FILE" --dry-run=client -o yaml | \
  kubectl --context "$CONTEXT" apply -f -
```

This public ConfigMap is operator-owned; it is not generated from the broker's
private-key Secret and must be updated through the same trusted PKI change
process. Record its certificate fingerprints and rotation owner in that change.
No Secret Manager access or new RBAC permission is granted to runner pods.

The ConfigMap mount is optional **only for staging compatibility**: runners must
still start while the existing HTTP consumers operate, even if the ConfigMap or
its `ca.crt` key is absent. The whole ConfigMap is mounted without a required-key
projection; keep its contents public CA material only. The HTTPS client does not
silently ignore a configured missing/invalid bundle and does not fall back to
HTTP. The public bundle must be present at `ca.crt` before enabling it. Volume
mounts are read-only, without `subPath`, so bundle updates can propagate to pods;
explicitly verify the new bundle on active runners before completing a rotation.

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

Rotate the leaf/key together via the existing Secret Manager secret and wait for
External Secrets refresh and projected Secret volume propagation. The server
reloads the certificate/key pair on each new TLS handshake; no pod restart is
required for a valid pair. The ExternalSecret's refresh interval is **one hour**;
plan rotations with that delay plus projected-volume propagation in mind. During
an approved rotation window, an operator may request an earlier sync:

```bash
set -euo pipefail
: "${CONTEXT:?Set CONTEXT to the approved GCP kubeconfig context}"
kubectl --context "$CONTEXT" -n github-token-broker annotate externalsecret \
  github-token-broker-tls force-sync="$(date +%s)" --overwrite
```

Then verify the Secret update and every replica's new handshake rather than
assuming the annotation itself completes rotation. A healthy old HTTP probe alone
does not demonstrate HTTPS readiness. For a root change, distribute a temporary
old+new **public** trust bundle before rotating the leaf, confirm all consumers,
then retire the old root. Do not add an insecure verifier bypass.

TLS activation is **broker-wide**: missing/malformed/mismatched certificate/key
material or a failed HTTPS bind prevents the process from serving either
listener. A bad activation can therefore interrupt every existing HTTP consumer
and probe, not just GitInsight. Verify the pair before approving activation,
observe the rollout and fresh HTTPS handshakes on **every replica**, and retain
the pre-activation HelmRelease/chart/image revision for rollback.

If activation fails, pause the affected crawl. An operator must revert the
activation GitOps change to the reviewed pre-activation HelmRelease and verify
broker recovery; do not try to hide the failure by weakening TLS or changing
broker authorization. Correct and re-review the TLS/trust problem before
retrying. Do not downgrade the HTTPS client to plaintext or mark the finding
fixed. Successful additive activation preserves the existing HTTP interface;
those consumers' later migration is a separate scope.
