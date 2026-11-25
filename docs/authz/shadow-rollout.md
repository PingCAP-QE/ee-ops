# TiBuild external authorization: shadow rollout plan

Status: preparation only. No HTTPRoute has `extAuth` attached, and `authzd` has
no Gateway attachment in either cluster. This document records the verified route
graph, the preconditions that must hold before any route is attached, the test
matrix for the observe period, and the rollback switches.

Evidence below was read from the live GCP cluster on 2026-11-25 and from the
manifests in `apps/gcp/tibuild/v2/`.

## 1. Current route graph

| HTTPRoute | Created | Methods | Rewrite | SecurityPolicy | Identity |
| --- | --- | --- | --- | --- | --- |
| `v2-tibuild-v2` | 2026-08-16 | GET, HEAD, OPTIONS | `/tibuild` → `/` | `tibuild-v2-oidc` | Google OIDC session + CSRF |
| `tibuild-v2-machine` | 2026-10-29 | any, requires `Authorization: ^Bearer .+$` | `/tibuild` → `/` | `tibuild-v2-machine-jwt` | Google JWT, audience `prow.tidb.net`, service-account allowlist |
| `tibuild-v2-privileged` | 2026-11-11 | `publish`/`hotfix`/`artifact`/`tidbcloud` prefixes; POST, PUT, PATCH, DELETE on `/tibuild` | prefix-preserving | `tibuild-v2-machine-jwt` | same as machine |

`tibuild-v2-machine-jwt` targets both the machine and privileged routes.

### Findings that shape the rollout

1. **Every mutating request under `/tibuild` is machine-only.** The browser route
   matches reads only, so `POST /tibuild/api/v2/devbuilds/{id}/rerun` today
   requires a Google JWT from an allowlisted service account. There is no
   browser session that can reach rerun.
2. **POST with a Bearer token matches two rules.** It matches the machine rule
   (path + `Authorization`) and the privileged POST rule (path + method). Equal
   path length and one header match each means the tie breaks on creation time,
   so the request lands on `tibuild-v2-machine`. Both routes share one
   SecurityPolicy, so this is currently invisible.
3. **Do not split `tibuild-v2-machine-jwt` per route.** Splitting would give each
   route its own `route_id` context extension, and the tie-break in finding 2
   would then become an authorization difference: the same request would be
   evaluated against a different route identity depending on rule ordering.
   Keep one policy and one `route_id` for both routes; the registry already
   distinguishes them by path.
4. **Shadow measures identity handoff and route coverage, not owner semantics.**
   `devbuild` parent/creator tuples are blocked by
   [ADR 0005](../../../ee-apps/docs/adr/0005-tibuild-resource-ownership.md), so
   every rerun decision during shadow reports `resource_not_found` and is
   recorded as a would-deny. That is expected; do not read it as a policy defect.

## 2. Preconditions before attaching `extAuth`

| # | Precondition | Why |
| --- | --- | --- |
| 1 | `AUTHZD_DECISION_MODE=observe` on the deployment, from a released image | With the default `enforce`, any path the registry does not list is denied. Attaching first would 403 the unlisted routes. |
| 2 | NetworkPolicy ingress from the Envoy dataplane to `authzd:9002` | `apps/gcp/authzd/network.yaml` currently allows only the GMP collector on 9003. Once GKE NetworkPolicy enforcement is on, `failOpen: false` turns an unreachable authzd into a 403 outage. This change adds the rule; it is inert until a route is attached. |
| 3 | ReferenceGrant in `ee-authz` for a `SecurityPolicy` in `tibuild` | The policies live in `tibuild` and the backend in `ee-authz`. Envoy Gateway rejects a cross-namespace extAuth backend reference that no ReferenceGrant permits (`not permitted by any ReferenceGrant`). This change adds the grant, scoped to `Service`; it is inert until a policy references it. |
| 4 | Context extensions: `identity_mode` and `route_id` | `authzd` selects one verifier per credential mode and refuses to infer route identity from client headers. Both values are static per SecurityPolicy. |
| 5 | `timeout: 1s`, `failOpen: false`, `statusOnError: 503` | Bounded latency, no fail-open, and a distinguishable status for dependency failure. The 1s value is provisional until the p95 budget is agreed. |

Recorded evidence for the fragment shape: both policies below were submitted with
`kubectl apply --dry-run=server` against the live v1.9.3 CRDs and were accepted,
and the ReferenceGrant and NetworkPolicy render and validate with
`kubeconform -strict`. Dry-run acceptance proves schema compatibility only; the
`Accepted`/`Programmed` conditions still need a real apply inside the rollout
window.

The Envoy dataplane pods run in namespace `infra` with
`app.kubernetes.io/name=envoy` and
`gateway.envoyproxy.io/owning-gateway-name=eg-internal`.

## 3. Attach shape (not applied yet)

Browser policy (`tibuild-v2-oidc`), additive to the existing `csrf` and `oidc`
fields:

```yaml
  extAuth:
    failOpen: false
    timeout: 1s
    statusOnError: 503
    contextExtensions:
      - name: identity_mode
        value: browser
      - name: route_id
        value: v2-tibuild-v2
    grpc:
      backendRefs:
        - name: authzd
          namespace: ee-authz
          port: 9002
```

Machine + privileged policy (`tibuild-v2-machine-jwt`), additive to `jwt` and
`authorization`:

```yaml
  extAuth:
    failOpen: false
    timeout: 1s
    statusOnError: 503
    contextExtensions:
      - name: identity_mode
        value: machine
      - name: route_id
        value: tibuild-v2-machine
    grpc:
      backendRefs:
        - name: authzd
          namespace: ee-authz
          port: 9002
```

Do not add `contextExtensions` for `upstream_path`: the registry matches the
external path, which is what arrives at the filter before the URL rewrite.

Browser mode also needs the ID token forwarded to a dedicated header
(`forwardIDToken`) and a matching `browser` entry in `AUTHZD_CREDENTIAL_MODES`.
Whether the filter order delivers that header to `ext_authz` is unverified and
must be observed before browser mode is trusted; see
`docs/adr/0003-browser-identity-handoff.md` in `ee-apps`.

## 4. Synthetic test matrix for the observe period

Every case must reach the backend unchanged, because observe only records:

| Case | Request | Recorded decision |
| --- | --- | --- |
| Browser read | OIDC cookie, `GET /tibuild/api/v2/devbuilds` | `authorized` if the registry covers the path, otherwise `route_not_registered` |
| Machine read | valid allowlisted Bearer, `GET /tibuild/api/v2/devbuilds` | `authorized` or `relationship_denied` once the read rule exists |
| Machine mutation | valid allowlisted Bearer, `POST /tibuild/api/v2/devbuilds/{id}/rerun` | `resource_not_found` (ADR 0005) |
| Privileged mutation | valid allowlisted Bearer, `POST /tibuild/api/v2/publish/images` | `route_not_registered` until a rule exists |
| Expired / other-audience / malformed Bearer | same paths | `identity_invalid`; the request is still rejected by the Gateway JWT layer, not by authzd |
| Path variants | `//tibuild/...`, `%2e%2e`, casing, trailing slash | decision recorded for the unmatched route; no 5xx |
| In-cluster direct call | `POST v2-tibuild-v2.tibuild.svc/api/v2/devbuilds/{id}/rerun` | no decision at all; the existing application checks still run |
| Unregistered path | `GET /tibuild/anything-else` | `route_not_registered` |

## 5. Divergence observation

`authzd` writes one structured JSON line per decision to stdout, so the log
fields are the observation surface: `decision_id`, `principal`, `capability`,
`resource_type`, `resource_id`, `outcome`, `would_deny`, `reason_code`,
`model_id`, `registry_version`, `resolver_version`, `correlation_id`.

Query template (Cloud Logging; adjust the log name to the collector):

```
resource.type="k8s_container"
resource.labels.namespace_name="ee-authz"
jsonPayload.would_deny=true
```

Classify every would-deny bucket before enforcement is considered:

| `reason_code` | Meaning | Owner action |
| --- | --- | --- |
| `route_not_registered` | Registry gap | Add the rule, or record an approved exception |
| `resource_not_found` | No trusted ownership data (ADR 0005) | TiBuild owner decision; do not invent a mapping |
| `relationship_denied` | Tuples missing or genuinely denied | Confirm against the reviewed grants |
| `identity_invalid` | Handoff broken (header, audience, issuer) | Fix the handoff before any enforce step |
| `openfga_error` / `resource_resolution_error` | Dependency failure | Treat as blocking; enforce must not be enabled |

Exit criteria for shadow: zero `identity_invalid` for the machine route, every
`route_not_registered` either mapped or excepted, and a written classification of
each remaining would-deny signed off by the TiBuild owner. Requests that were
already rejected by the Gateway (`401`/`403` from JWT or OIDC) never reach the
filter, so they are not part of the comparison.

## 6. Rollback

Two independent switches, neither of which weakens authentication:

1. `AUTHZD_DECISION_MODE=off` on the deployment — every request is allowed while
   the Gateway keeps enforcing OIDC/JWT/CSRF.
2. Revert the commit that added the `extAuth` fragment — the route keeps its
   original `oidc`/`jwt`/`authorization`/`csrf` policy.

Removing the `extAuth` fragment never requires touching the existing authn
settings, and reverting the NetworkPolicy ingress rule is inert once no route
references `authzd`.

## 7. Open items

1. Release and pin an `authzd` image that supports `AUTHZD_DECISION_MODE`.
2. TiBuild owner decision on `devbuild` ownership, or an accepted exception
   (ADR 0005).
3. Verify the Envoy dataplane → `authzd:9002` path after GKE NetworkPolicy
   enforcement is enabled.
4. Browser identity handoff: confirm `forwardIDToken` reaches `ext_authz` and
   that a client-supplied copy of the header cannot.
5. Agree the p95 latency budget for the added hop.
