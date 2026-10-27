# External access to the GitHub token broker

The cluster-internal `github-token-broker` is also reachable from the public
internet at:

```text
POST https://prow.pingcap.net/gh-broker/v1/token
```

This document describes the deployment-only design: the broker image, chart and
code are unchanged.

## Topology

```text
client
  Authorization: Bearer <api-key>
    -> GKE external HTTPS (TLS terminated)
    -> eg-internal Envoy
         HTTPRoute: exact /gh-broker/v1/token, POST
         URLRewrite: /v1/token
         SecurityPolicy: apiKeyAuth (Secret reference)
    -> Service github-token-broker:80
    -> broker: TokenReview + policy (unchanged)
```

Only the token path is routed. `/metrics`, `/healthz` and `/readyz` stay
cluster-internal.

## Authentication model

- `ServiceAccount/external-reader` in the `github-token-broker` namespace has
  **no RoleBindings or ClusterRoleBindings**. The token can authenticate to the
  API server but cannot read cluster resources.
- The API key is that ServiceAccount token. The gateway validates it with
  `apiKeyAuth` and keeps the `Authorization` header (`sanitize: false`), so the
  broker performs the normal Kubernetes `TokenReview`.
- The API key Secret contains exactly one key (`external-client`). Never point
  `apiKeyAuth` at the raw ServiceAccount token Secret: its `ca.crt` and
  `namespace` keys would become valid API keys.

### Why not OIDC

A deployment-only gateway can validate a Google ID token, but the token
audience is not an authorization control: any Google account can mint an ID
token for the same audience. Restricting subjects would require an allowlist of
internal identities in this public repository. The API key is secret-managed
and does not expose internal identifiers.

## Key lifecycle

```text
Secret/external-reader-token (SA token, controller-managed)
  -> PushSecret -> GCP Secret Manager
  -> ExternalSecret -> Secret/github-token-broker-apikey (key: external-client)
  -> SecurityPolicy/apiKeyAuth
```

- Both the push and the pull refresh hourly.
- **Revoke**: delete `Secret/github-token-broker-apikey` (or the
  `external-reader` ServiceAccount). New requests fail with `401`.
- **Rotate**: delete `Secret/external-reader-token`; the controller recreates
  the token, the push/pull chain republishes it, and clients receive the new
  key through the normal distribution channel.

## Authorization

The allowlist lives in the GCP Secret Manager secret
`github-token-broker-policy` (not in this repository). A minimal rule:

```yaml
  - caller:
      namespace: github-token-broker
      service_account: external-reader
    allow:
      - owner: example-org
        repositories: ["example-repo"]
        max_permissions:
          contents: read
```

The broker reloads the policy within seconds; no restart is needed. Keep the
external rule read-only: there is no additional code-level ceiling in the
deployment-only design.

## Verification

```bash
# 401 without a key
curl -sS -o /dev/null -w '%{http_code}\n' -X POST \
  https://prow.pingcap.net/gh-broker/v1/token \
  -H 'Content-Type: application/json' \
  -d '{"repo":"example-org/example-repo","repositories":["example-repo"]}'

# 200 with a valid key (do not echo the key)
curl -sS -o /dev/null -w '%{http_code}\n' -X POST \
  https://prow.pingcap.net/gh-broker/v1/token \
  -H "Authorization: Bearer ${BROKER_API_KEY}" \
  -H 'Content-Type: application/json' \
  -d '{"repo":"example-org/example-repo","repositories":["example-repo"],"permissions":{"contents":"read"}}'

# The ServiceAccount must not have RBAC permissions
kubectl auth can-i --list \
  --as=system:serviceaccount:github-token-broker:external-reader
```

## Residual risks

1. **Installation-wide token.** When a request omits `repositories` and asks for
   no write permission, the broker mints a token for the whole installation.
   The gateway cannot inspect or rewrite the JSON body. External callers can
   therefore obtain read access to every repository the GitHub App is installed
   on, not only the allowlist. Detect it by alerting on broker log entries for
   `external-reader` with `"repositories":[]`. A code guard or a dedicated
   GitHub App would close this gap.
2. **Shared identity.** Every external caller shares `external-reader`; broker
   audit logs and rate limits cannot distinguish callers.
3. **Static credential.** The API key is long-lived. It is a namespace-scoped
   ServiceAccount token with no RBAC, but it is still a cluster credential.
4. **Header pass-through.** `apiKeyAuth` must forward the original
   `Authorization` header. This is verified during rollout; if a future Envoy
   Gateway version changes the behavior, use `HTTPRouteFilter.credentialInjection`
   with a single-key `credential` Secret instead.
5. **PAT fallback.** Keep `github.fallback.enabled=false`. If a PAT is
   configured, external callers could receive it for owners where the App is not
   installed.

## Rollback

- Remove the `github-token-broker-external` HTTPRoute: the public endpoint
  returns 404 and the broker stays available in-cluster.
- Delete `Secret/github-token-broker-apikey`: all external requests fail with
  `401`.
- Remove the `external-reader` policy rule from the policy secret to revoke
  authorization independently of the key.

None of these steps affects in-cluster callers.
