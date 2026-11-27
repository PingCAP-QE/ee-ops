# Authorization route coverage baseline

Baseline captured from `origin/main` at `ba861d9a` on 2026-11-24. It is a
manifest-level inventory of statically declared non-Prod2 HTTPRoutes in GCP and
TencentCloud. Helm-generated routes and live Gateway status are not represented
and must be added from rendered/runtime evidence before any shadow rollout.

Run `scripts/check_authz_policy_coverage.sh` to regenerate the route-to-policy
mapping. At baseline it finds 13 HTTPRoutes: 4 with a direct `SecurityPolicy`
targetRef and 9 without one. The latter are *coverage gaps for this check*, not
proof that authentication or application authorization is absent. The security
check remains report-only while owners verify each existing contract.

The exact generated static route-to-policy output is saved as
[`route-policy-static-baseline.csv`](route-policy-static-baseline.csv). The
runtime-only routes are listed separately below and were captured from live
Gateway API objects.

The static non-Prod2 manifest inventory also contains 4 Gateways, 5
SecurityPolicies, 2 standalone HTTPRouteFilters, 13 inline URLRewrite filters,
and 12 NetworkPolicies. These counts come from the same script; verify Gateway
attachment and policy status from rendered/live objects before rollout.

| Cluster | Namespace / route | Host and path | Baseline | Existing evidence to verify |
| --- | --- | --- | --- | --- |
| GCP | prow/prow | prow.tidb.net, prow.pingcap.net `/`, `/hook`, `/ti-community-owners`, `/tichi` | gap | Gateway forwarding plus Prow webhook and UI authentication; rendered route/policy attachment required |
| GCP | tekton-pipelines/tekton | prow.tidb.net `/tekton` | mapped | Dashboard SecurityPolicy; application RBAC remains required |
| GCP | default/dl | prow.tidb.net `/dl` | gap | Internal DL route; verify auth and app capability checks |
| GCP | default/dl-public | dl.pingcap.net `/d/` | gap | Anonymous capability URL by design; expiry/revocation/quota remain in DL |
| GCP | jenkins/controller | `${INGRESS_HOST}` `${INGRESS_PATH}` | gap | Helm-generated route; chart auth and generated route must be rendered |
| GCP | tibuild/tibuild-v2-machine | prow.tidb.net `/tibuild` | mapped | Required Google JWT and service-account allowlist |
| GCP | tibuild/tibuild-v2-privileged | prow.tidb.net `/tibuild` and privileged API prefixes | mapped | Machine-only JWT policy; verify exact path/method selection |
| TencentCloud | zot/zot-internal | cr-qcloud.pingcap.net `/` | gap | Internal Gateway route; verify Zot-native authorization and network reachability |
| TencentCloud | jenkins/controller | `${INGRESS_HOST}` `${INGRESS_PATH}` | gap | Helm-generated route; chart auth and generated route must be rendered |
| TencentCloud | jenkins/controller-staging | `${INGRESS_HOST}` `${INGRESS_PATH}-staging` | gap | Helm-generated route; chart auth and generated route must be rendered |
| GCP | default/gke-to-envoy-route | prow.tidb.net, prow.pingcap.net `/` | gap | GKE-to-Envoy forwarding hop, not an application route; verify front-door and Envoy effective route chain |
| GCP | infra/eg-internal-healthz | no hostname `/eg-healthz` | gap | Private controller health route; verify Gateway exposure and source restrictions |
| GCP | apps/ci-dashboard (runtime only) | prow.tidb.net | mapped | Runtime HTTPRoute; `apps/ci-dashboard-oidc` SecurityPolicy Accepted=True |
| GCP | tibuild/v2-tibuild-v2 (runtime only) | prow.tidb.net `/tibuild` | mapped | Runtime browser route; `tibuild-v2-oidc` SecurityPolicy Accepted=True |
| GCP | cla/cla-assistant (runtime only) | cla.pingcap.net | gap | Gateway API route exists at runtime but is generated outside the static HTTPRoute set |
| TencentCloud | zot/zot (runtime only) | cr.pingcap.net | gap | Runtime route is generated outside the static HTTPRoute set; verify registry-native auth and exposure |

The CSV exception register intentionally starts empty. A route may be recorded
there only after its current control and an accountable owner are verified. An
exception is a documented boundary, not an authorization grant.
