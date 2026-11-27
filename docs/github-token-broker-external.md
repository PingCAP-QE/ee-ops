# External access to the GitHub token broker (retired)

The broker used to be reachable from the public internet at:

```text
POST https://prow.pingcap.net/gh-broker/v1/token
```

**It is retired as of 2026-11-27.** The route never carried traffic: the broker
mint log has no `external-reader` entries, no code in PingCAP-QE references the
URL, and the `gh-broker-client-macos@pingcap-testing-account` service account the
design depended on has no user-managed key, so the documented `key.json` client
flow could not have authenticated at all.

The macOS build fleet does not need it: the `MacBuild` agent runs the checkout on
the Mac with a `source.gitSecretRef` Secret it reads through the Kubernetes API,
and the planned replacement is for the in-cluster operator to mint broker tokens
and materialise them into a per-build Secret. Nothing on the Mac talks to the
broker directly.

## What was removed

| Object | Purpose |
| --- | --- |
| `HTTPRoute/github-token-broker-external` | exact `POST /gh-broker/v1/token`, URLRewrite to `/v1/token` |
| `SecurityPolicy/github-token-broker-jwt` | Google ID token (issuer, audience, per-client allowlist) |
| `HTTPRouteFilter/github-token-broker-upstream-credential` | replaced `Authorization` with the injected SA token |
| `BackendTrafficPolicy/github-token-broker-external-limit` | 300 req/min coarse limit |
| `ServiceAccount/external-reader` + its token Secret + PushSecret | the identity injected into the upstream request |
| `ExternalSecret/github-token-broker-upstream` | read that token back with the `Bearer ` prefix |
| `BackendTLSPolicy/github-token-broker-external` + `NetworkPolicy/…-gateway-https` | re-encryption and the `infra` grant added for it |
| broker policy rule `github-token-broker/external-reader` | authorization for the injected identity |

The broker itself is unchanged: it still serves `/v1/token` on its TLS listener
inside the cluster, and the runners keep their own HTTPS hop
(`GITINSIGHT_BROKER_CA_FILE`).

## Restoring it

If an out-of-cluster client ever needs the broker, restore the pieces above from
git history (`git log -- apps/gcp/github-token-broker/`), and in the same change:

1. re-add the `external-reader` rule to `github-token-broker-policy` (GCP Secret
   Manager, managed outside this repository);
2. issue a user-managed key for the client service account, or replace the
   Google ID token flow with an identity the client can actually obtain — a
   physical Mac has no metadata server, so a key file is a long-lived credential
   on the machine and should be weighed against the operator-mints alternative;
3. keep the `BackendTLSPolicy`: the upstream of that route must never fall back
   to plaintext port 80, because the response carries a freshly minted App token.

Prefer the in-cluster alternative first: the `mac-builder-operator` can mint
per-build tokens with its own ServiceAccount and hand them to the Mac through the
`gitSecretRef` Secret it already reads.
