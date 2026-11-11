# GCP Gateway authentication and authorization model

This document defines where authentication and authorization live for services
exposed through the GCP Envoy Gateway. It is the reference for new HTTPRoutes
and for security findings that ask for "authentication" on an internal service.

## Scope

Applies to `apps/gcp/**` and `infrastructure/gcp/**`. The TencentCloud and prod2
clusters follow the same pattern, but their route inventory is maintained
separately.

## Principles

1. **Authentication is a Gateway concern.** Validate Google OIDC sessions for
   browser traffic and Google ID tokens (JWT) for machine traffic in
   `SecurityPolicy`. Do not add OIDC/JWT validation middleware to each service.
2. **Authorization is layered.** The Gateway enforces route-level principal
   allowlists. A service enforces object-level ownership, tenant isolation and
   business roles that the Gateway cannot see.
3. **Two credential modes, never mixed.** A browser route is OIDC-only. A
   machine route is JWT-only and selected by an `Authorization: Bearer ...`
   header match. Do not put optional JWT or `passThroughAuthHeader` on a
   browser route: a non-canonical Authorization header must not skip OIDC.
4. **Identity comes from the Gateway.** A service may trust `X-User-*` only if
   the Gateway stripped client-supplied values and injected verified claims.
   Until that normalizer exists, a service must not treat request headers as an
   authenticated identity.
5. **Public routes are explicit.** A route is public only when listed in
   "Public allowlist" below. Every other public HTTPRoute needs a
   `SecurityPolicy`.

## Current inventory (GCP)

| Route | Auth | Notes |
| --- | --- | --- |
| `prow.tidb.net/` (`prow` HTTPRoute) | Public allowlist | Prow Deck UI; upstream parity |
| `prow.tidb.net/hook` | Public + Prow HMAC | GitHub webhook |
| `prow.tidb.net/ti-community-owners`, `/tichi` | Public allowlist | Prow plugins |
| `prow.tidb.net/tibuild` (browser) | OIDC + CSRF | `tibuild-v2-oidc`; no JWT, no `passThroughAuthHeader`. Privileged prefixes (`/api/v2/publish|hotfix|artifact`) are carved out to the machine policy |
| `prow.tidb.net/tibuild` (`Authorization: Bearer`) | JWT + allowlist | `tibuild-v2-machine-jwt`; service accounts only |
| `prow.tidb.net/dashboard/` | OIDC + CSRF | CI Dashboard |
| `prow.tidb.net/tekton` | OIDC + CSRF | Tekton Dashboard |
| `prow.pingcap.net/gh-broker/v1/token` | JWT + allowlist | GitHub token broker |
| `prow.tidb.net/dl` | Public allowlist | Public artifact downloads; target allowlist in `dl` |
| `prow.tidb.net/jenkins` | Public allowlist | Community read-only Jenkins |
| `cla.pingcap.net/` | Public app auth | CLA signature flow |
| `prow.tidb.net/*` catch-all | Public allowlist | GKE → Envoy forwarder; host/path routing only |
| `*/eg-healthz` | Internal | Envoy health check |

No public HTTPRoute exists for `publisher` (removed), `cloudevents-server`,
`mac-builder-operator` log API or `vector_search`. Those services are
ClusterIP-only; Gateway policy does not apply. If one is exposed later, add a
route and a policy in the same change.

## Public allowlist

These are intentionally reachable without Gateway authentication:

- Prow Deck `/`, `/hook`, `/ti-community-owners`, `/tichi` (open-source CI).
- `/config`, `/prowjobs.js`, `/tide-history.js` (upstream Prow parity; accepted
  risk, no credential values).
- `/jenkins` (community read-only).
- `/dl` downloads (target allowlist bounds what can be fetched).
- `cla.pingcap.net` signature flow.
- `eg-healthz`.

Everything else needs OIDC or JWT.

## Gaps that are not Gateway-only

- **`b8720cf0` privileged operations.** `tibuild-v2` publish/hotfix/artifact
  endpoints share the browser route today; a company user can call them.
  Gateway can split those paths into a JWT-only route and allowlist only the
  automation service accounts. `chatops-lark` sender authorization and the
  token broker's fail-open policy are service-side checks and cannot be
  expressed by an HTTP SecurityPolicy.
- **`615a8b6d` client-supplied identity.** `tibuild-v2` reads `X-User-*`
  headers, but the Gateway does not currently set or strip them. A Gateway
  claim-to-header normalizer is required; see "Identity normalizer" below.
  Object-level ownership checks remain in the service.
- **`ci-dashboard` row-level authorization.** The Gateway verifies the user, but
  which repositories/jobs/spend rows a user may see is application
  authorization.
- **`dl` KS3/OCI/GCS target scope.** The Gateway can require authentication, but
  bucket/registry allowlists remain in `dl` (and are already enforced for OCI
  and GCS).

## Identity normalizer

Envoy Gateway OIDC can forward the ID token (`forwardIDToken.header`) but cannot
map claims to `X-User-*` headers. Recommended design:

1. Add an `ext_proc` identity normalizer in front of the protected routes.
2. It strips every inbound `X-User-*` header.
3. It validates the forwarded ID token (or consumes the verified JWT claims)
   and injects `X-User-Id`, `X-User-Email`, `X-User-Name` from verified claims.
4. Services keep only the existing `identity.Middleware` and never trust
   headers that did not come from the normalizer.

Alternative: standardize on a single `X-User-Id-Token` header and a shared
library that validates it in each service. This still puts token handling in
service code and is therefore the fallback, not the preferred design.

## Phased rollout

1. **Done:** browser `/tibuild` is OIDC-only; machine route is JWT-only;
   publisher/tibuild-v1 findings are closed as removed code.
2. **Done:** the EE Portal route (`prow.tidb.net/ee`, including its
   `/ee/api/tibuild` proxy to the whole TiBuild API) is removed from this repo —
   it authorized any OIDC employee with no principal allowlist. It comes back only
   with an authorization model of its own. Privileged TiBuild paths are served by a
   dedicated JWT-only route (`tibuild-v2-privileged`). Path-specific JWT-only routes for privileged `tibuild-v2`
   operations (`/api/v2/publish/*`, `/api/v2/hotfix/*`,
   `/api/v2/artifact/sync-images*`, `/api/v2/tidbcloud/*`), and the
   `hd=pingcap.com` fallback is gone from the machine route as well: both
   privileged machine routes (this one and the token broker) now allow only the
   service accounts listed in their policy. Read-only UI endpoints stay on the
   OIDC route.
3. **Then:** deploy the identity normalizer, strip client `X-User-*`, and make
   `b8720cf0`/`615a8b6d` service authorization use trusted identity.
4. **Separately:** fix service-side authorization for `chatops-lark`, the token
   broker's fail-open policy, `ci-dashboard` row-level access and `dl` KS3
   allowlists. These are not Gateway policy work.

## Regression guard

`scripts/check_gcp_route_csrf.sh` asserts that the TiBuild browser policy stays
OIDC-only (no JWT provider, no `passThroughAuthHeader`) and that the machine
route still requires a verified JWT. Extend that script when a new protected
route is added.
