# Phase B preflight: browser identity handoff with a dedicated OAuth client

Phase B of ADR 0003 proves that `forwardIDToken` actually delivers a browser
identity to `ext_authz`, that the value is bound to the authenticated session,
and that `authzd` decides on the session user. It needs a real browser and an
OAuth client whose redirect URI we control, so it uses a **dedicated client**
rather than the shared `google-oauth2-client-ee-apps` one.

This document is the checklist and the test procedure. Nothing here is applied
yet.

## 1. Create the dedicated client

Google does not expose OAuth client creation through `gcloud`; use the console
(APIs & Services → Credentials → Create credentials → OAuth client ID), in the
project that already owns the consent screen:

| Field | Value |
| --- | --- |
| Application type | Web application |
| Name | `ee-authz-canary` |
| Authorized redirect URI (mode 1) | `http://localhost:18080/authz-canary/oauth2/callback` |
| Authorized redirect URI (mode 2, optional) | `https://prow.tidb.net/authz-canary/oauth2/callback` |
| Authorized JavaScript origins | none (server-side flow) |

Record the client ID; the secret is created once and not shown again.

Store it in Secret Manager, following the existing pattern:

```sh
echo '{"client-id": "<id>", "client-secret": "<secret>"}' | \
  gcloud secrets create google-oauth2-client-authzd-canary --data-file=-
```

The canary `ExternalSecret` extracts that key. Never commit either value.

## 2. Two execution modes

**Mode 1 — isolated Gateway, localhost callback (recommended first).**
The PoC Gateway from `infrastructure/gcp/poc-authz-filter-order/` is
`ClusterIP`-only, so the browser reaches it through a port-forward:

```sh
kubectl -n infra port-forward svc/eg-authz-poc 18080:80
```

Then `http://localhost:18080/...` is the browser-visible origin, and Google
accepts `http://localhost:<port>` as a redirect URI. This proves filter order,
`forwardIDToken` delivery, header overwrite and session binding **without any
change to the shared Gateway**, and without DNS or a load balancer.

**Mode 2 — canary path on the shared Gateway.** Only after the PoC passes and
`filterOrder` is promoted: an additive `/authz-canary` route on `prow.tidb.net`
with its own OIDC policy and distinct cookie names
(`authz-canary-access-token`, `authz-canary-id-token`). Use this to confirm the
behaviour on the exact production proxy. Existing routes are not modified, but
the shared proxy's route set grows, so it needs the same review as any new route.

Neither mode enables enforcement: `authzd` stays in observe mode and returns
allow for every request.

## 3. Canary manifests (mode 1)

```yaml
# ExternalSecret in the canary namespace, mirroring the tibuild pattern
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: authz-canary-oidc
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: ee-gcp-sm
    kind: ClusterSecretStore
  target:
    name: authz-canary-oidc
    creationPolicy: Owner
  dataFrom:
    - extract:
        key: google-oauth2-client-authzd-canary
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: authz-canary-oidc
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: authz-canary
  csrf: {}
  oidc:
    provider:
      issuer: https://accounts.google.com
    clientIDRef:
      name: authz-canary-oidc
    clientSecret:
      name: authz-canary-oidc
    cookieNames:
      accessToken: authz-canary-access-token
      idToken: authz-canary-id-token
    # Must start with the protected route's path, or the callback never matches.
    redirectURL: http://localhost:18080/authz-canary/oauth2/callback
    scopes: [openid, email, profile]
    forwardIDToken:
      header: X-Authzd-ID-Token
  extAuth:
    failOpen: false
    timeout: 1s
    statusOnError: 503
    contextExtensions:
      - name: identity_mode
        value: browser
      - name: route_id
        value: authz-canary
    grpc:
      backendRefs:
        - name: authzd
          namespace: ee-authz
          port: 9002
```

`oidc.forwardIDToken.header` is the field CI Dashboard already uses in
production (`X-CI-Dashboard-ID-Token`), and
`scripts/check_ci_dashboard_auth_config.sh` pins the exact shape in CI; reuse that
shape rather than inventing another.

The HTTPRoute for mode 1 must carry **no hostnames** so `Host: localhost:18080`
matches, and must route `/authz-canary` to a backend that reports identity
(e.g. a read-only TiBuild endpoint).

## 4. `authzd` browser credential mode

Add a `browser` entry beside the existing `machine` one and restart:

```json
{
  "machine": { "...": "unchanged" },
  "browser": {
    "header": "x-authzd-id-token",
    "jwks_url": "https://www.googleapis.com/oauth2/v3/certs",
    "issuer": "https://accounts.google.com",
    "audience": "<dedicated client-id>",
    "principal_prefix": "user:https://accounts.google.com|",
    "subject_claim": "sub"
  }
}
```

Startup validation already enforces what matters here: the browser principal
must start with `user:`, the header must differ from the machine header, and the
audience must differ from `prow.tidb.net`. Using the client ID as the audience is
what makes a token minted for the shared client unusable here.

## 5. Acceptance procedure

Phase B passes only when every step below is observed and recorded.

| # | Step | Pass condition |
| --- | --- | --- |
| 1 | Open the canary URL in a browser, complete Google login | Redirect returns to the callback; page loads |
| 2 | Read the decision log for that request | One decision, `principal=user:https://accounts.google.com|<sub>`, `outcome=allow` |
| 3 | Reload, then let the session age past access-token expiry | Refresh happens transparently; no new login prompt; identity unchanged |
| 4 | Log out, reload | Login is required again; no stale identity decision for an unauthenticated request |
| 5 | **Identity substitution**: keep the user A session, then send a request with `X-Authzd-ID-Token` set to a valid ID token of user B | Decision names **user A**. A decision naming user B fails the phase, even if the request is denied |
| 6 | Send the same request with a duplicated header (`X-Authzd-ID-Token: a, b`) | `identity_invalid`; no fallback to the first value |
| 7 | Send a request with a token minted for the shared client's audience | `identity_invalid` (audience mismatch) |
| 8 | Unsigned or expired cookie, reload | Gateway redirects to login; **no** decision logged for that request |
| 9 | Cross-tenant path probe (`/builds/<id of another project>`) | Decision on the canonical resource; no cross-tenant disclosure |

Also record, for the report: the Envoy image digest, controller version, the
`config_dump` filter order, the `authzd` image tag, and the model ID — the same
evidence set the machine-mode shadow report carries.

## 6. Cleanup and rollback

- Mode 1: delete the canary route, policy, ExternalSecret and the PoC Gateway;
  nothing production changed.
- Mode 2: revert the canary commit; the shared proxy keeps its `filterOrder`, and
  `authzd` stays in observe mode.
- Remove the `browser` credential mode from `AUTHZD_CREDENTIAL_MODES` if the phase
  is abandoned; `authzd` refuses to start with a half-configured mode, so the
  revert must be complete, not partial.

## 7. Blocking items

1. The dedicated client must be created and its secret stored (console only).
2. `filterOrder` must be verified on the PoC Gateway before mode 1 runs, and
   promoted to the shared proxy before mode 2 runs.
3. Browser steps require a human operator; they cannot be scripted from CI.
