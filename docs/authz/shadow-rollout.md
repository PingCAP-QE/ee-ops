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

### Filter order on the live listener

Read from the Envoy config dump after the attachment:

```text
1. csrf
2. ext_authz   (securitypolicy/tibuild/tibuild-v2-machine-jwt, disabled: true
                at chain level, enabled per route)
3. oauth2
4. jwt_authn
5. rbac
6. local_ratelimit
7. credential_injector (github-token-broker)
8. router
```

Three consequences, all confirmed against this deployment:

1. **`ext_authz` runs before authentication.** Requests that JWT or OIDC will
   later reject still reach `authzd`, which is why the observe period records
   `identity_invalid` rather than "no decision". Nothing is relaxed by this: a
   later filter still rejects them, and `authzd` verifies tokens itself.
2. **`forwardIDToken` cannot deliver a browser identity to `authzd`.** The OIDC
   and JWT filters that attach the forwarded token run *after* `ext_authz`, so a
   browser fragment would never see it. Browser mode therefore needs either
   `authzd` validating the OIDC ID-token cookie itself, or the browser route
   staying on OIDC without `extAuth` — the current state. Do not enable browser
   `extAuth` on the assumption that the forwarded header arrives.
3. **The GitHub token broker case works.** Its upstream credential replacement
   (`credential_injector`, position 7) runs after `ext_authz`, so `authzd` sees
   the caller's original `Authorization` header, which is what the broker
   contract requires.

## 2. Preconditions before attaching `extAuth`

| # | Precondition | Why |
| --- | --- | --- |
| 1 | `AUTHZD_DECISION_MODE=observe` on the deployment, from a released image | With the default `enforce`, any path the registry does not list is denied. Attaching first would 403 the unlisted routes. Set in `apps/gcp/authzd/workload.yaml`; inert until a route is attached. |
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

Isolation is verified with `scripts/check_authz_isolation.sh`, not by reading
manifests: it runs a throwaway pod in `ee-authz` with no labels, so no policy
selector matches it, and probes each Service listener.

```sh
scripts/check_authz_isolation.sh --mode open       # before enforcement: all reachable
scripts/check_authz_isolation.sh --mode enforced   # after: none reachable
```

2026-11-25, `--mode open`: `openfga:8080`, `openfga-check:8080` and
`authzd:9002` are all reachable from an unlabelled pod, which is the gap Phase 3
is waiting on. `authzd:9003` is deliberately not probed: it is a pod port scraped
by PodMonitoring, not a Service port.

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

**Attach the machine and privileged routes first, not the browser route.** The
deployed `AUTHZD_CREDENTIAL_MODES` contains only `machine`, and the filter order
above shows the OIDC filter attaches `forwardIDToken` after `ext_authz`. A browser
fragment would therefore record `identity_mode_unconfigured` for every browser
request and never see a forwarded token. Browser reads keep their existing OIDC
policy until `authzd` can validate the browser credential itself; see
`docs/adr/0003-browser-identity-handoff.md` in `ee-apps`.

### Deployed registry drift

The `registry.json` in the `ee-authzd-config` secret is **not** the committed
sample: its three TiBuild rules carry `mode: off` (the sample says `observe`).
Under `off` a rule returns allow without verifying identity or checking tuples,
so those paths record `mode_off` and produce no observation signal. Flipping them
to `observe` is a Secret Manager change, not a Git change; it is the next step
before the observe period can measure rerun, create and get.

## 4. Synthetic test matrix for the observe period

`scripts/check_authz_shadow_probe.sh` implements this matrix. It sends a fresh
`X-Request-Id` per case, which `authzd` records as `correlation_id`, so every
decision can be attributed to one case. Requests are chosen so nothing mutates
state: unauthenticated probes are rejected before the backend, path variants are
reads, and the authenticated mutation targets a build id that cannot exist.

Baseline captured on 2026-11-25 against `https://prow.tidb.net`, before any
`extAuth` attachment. These are the statuses the observe period must not change:

| Case | Request | Baseline | Expected decision once attached |
| --- | --- | --- | --- |
| unauth list | `GET /tibuild/api/v2/devbuilds` | 302 (OIDC redirect) | none: browser route has no filter |
| malformed bearer | same, `Authorization: Bearer not-a-jwt` | 401 | none on the browser route; `identity_invalid` once the machine rule matches |
| unsupported scheme | same, `Authorization: Basic …` | 302 | none |
| privileged publish | `POST /tibuild/api/v2/publish/images` | 401 | `route_not_registered` (no publish rule yet) |
| rerun without token | `POST /tibuild/api/v2/devbuilds/000000/rerun` | 401 | the rerun rule's mode decides: `mode_off` today, `identity_invalid` once it is `observe` |
| double slash | `GET //tibuild/api/v2/devbuilds` | 302 | none: browser route |
| dot segment | `GET /tibuild/api/v2/../api/v2/devbuilds` | 302 | none: browser route |
| unregistered path | `GET /tibuild/__authz_shadow_probe__` | 302 | none: browser route |

The probe fails on any 5xx, and on any 200 for a case the existing authn layer is
supposed to reject. `--expect-decisions` still requires `--id-token` or
`--cookie`: `ext_authz` runs before authentication, so rejected requests do
produce decisions, but only an authenticated request exercises identity
verification and the tuple checks that the observe period is meant to measure.

Authenticated cases, run by an operator with a valid machine token and/or browser
session:

| Case | Request | Expected during observe |
| --- | --- | --- |
| machine read | `GET /tibuild/api/v2/devbuilds` with an allowlisted ID token | `authorized` or `relationship_denied` once the rule exists |
| machine mutation | `POST /tibuild/api/v2/devbuilds/__authz_shadow_probe__/rerun` with the same token | `resource_not_found` (ADR 0005); backend returns not-found |

```sh
scripts/check_authz_shadow_probe.sh                       # unauthenticated baseline
scripts/check_authz_shadow_probe.sh --expect-decisions \
  --id-token "$(gcloud auth print-identity-token --audiences=prow.tidb.net)" \
  --project pingcap-testing-account
```

`--expect-decisions` reads Cloud Logging with the filter in the query template
below; override it with `--log-filter` when the collector renames the stream.
`scripts/check_authz_shadow_probe_test.sh` exercises the assertions against a
local stub and runs in CI, so the probe's own logic cannot rot silently.

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
   enforcement is enabled: `check_authz_isolation.sh --mode enforced` proves the
   gap closed from an unlabelled pod, but not that the allowed path still works.
4. Browser identity handoff: confirm `forwardIDToken` reaches `ext_authz` and
   that a client-supplied copy of the header cannot.
5. Agree the p95 latency budget for the added hop.
