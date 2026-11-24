# Gateway runtime baseline

Read-only cluster evidence collected 2026-11-24 from the configured non-Prod2
contexts `gke_prow` and `tke-pingcap-cicd`. No cluster objects were changed.

## Controller and CRD state

| Environment | Context | Controller image | Controller Available | Gateway state | Gateway API CRD served versions |
| --- | --- | --- | --- | --- | --- |
| GCP | `gke_prow` | `envoyproxy/gateway:v1.9.3` | True | `infra/eg-internal` and `infra/external-https`: Accepted=True, Programmed=True | Gateway/HTTPRoute `v1`, `v1beta1` |
| TencentCloud | `tke-pingcap-cicd` | `envoyproxy/gateway:v1.9.3` | True | `infra/external-https` and `infra/internal-https`: Accepted=True, Programmed=True | Gateway/HTTPRoute `v1`, `v1beta1` |

Flux HelmRelease state is `deployed` in both contexts. Helm release revisions are
3 (GCP) and 2 (TencentCloud); both report chart `gateway-helm-v1.9.3` and app
version `v1.9.3`.

Both clusters serve `securitypolicies.gateway.envoyproxy.io/v1alpha1`,
`httproutefilters.gateway.envoyproxy.io/v1alpha1`, and the SecurityPolicy
`spec.extAuth` schema fields (`grpc`, `http`, `failOpen`, `timeout`,
`headersToExtAuth`, and `bodyToExtAuth`). Schema presence does not prove any
extAuth backend is configured or operational.

GCP currently has five SecurityPolicies, each with controller condition
`Accepted=True`: `ci-dashboard-oidc`, `github-token-broker-jwt`,
`tekton-dashboard-oidc`, `tibuild-v2-machine-jwt`, and `tibuild-v2-oidc`.
TencentCloud currently has no SecurityPolicy resources. The recorded Gateway
route objects report `Accepted=True` and `ResolvedRefs=True`; route attachment
and auth behavior still need synthetic request verification.

There are 17 runtime HTTPRoutes across these two clusters. The static manifest
scanner finds 13; runtime-only routes include GCP `apps/ci-dashboard`,
`tibuild/v2-tibuild-v2`, and `cla/cla-assistant`, plus TencentCloud
`zot/zot`. The first two runtime-only routes have Accepted OIDC policies; CLA
and Zot do not have a SecurityPolicy in the observed clusters. This confirms
that the static script is only a drift alarm and is not the complete route
inventory.

## Rendered configuration snapshots

Generated with `kubectl kustomize` from the pinned source tree at `ba861d9a`:

- [`gcp-gateway-config.yaml`](rendered/gcp-gateway-config.yaml), SHA-256
  `e7165ae44da721404f7cd8ec5ce72a7e3878fc97eb525104308595607aa754d2`
- [`tencentcloud-gateway-config.yaml`](rendered/tencentcloud-gateway-config.yaml), SHA-256
  `afc536de23b6f8af53fccd3fc8c325c5d66454e48cb9d0565f62aa1ade813508`

These snapshots cover Gateway configuration Kustomizations, not Helm-rendered
Envoy Gateway controller resources. Full read-only Helm release manifests were
captured from each live context:

- [`gcp-envoy-gateway-helm.yaml`](rendered/gcp-envoy-gateway-helm.yaml), SHA-256
  `6e24f46037ae446a7ed75816e84d1c5dab857156eba82f92b7a07141db2efb60`
- [`tencentcloud-envoy-gateway-helm.yaml`](rendered/tencentcloud-envoy-gateway-helm.yaml), SHA-256
  `f38eb929c9a782596cc7b15f29c88837ad6adaa8f21808f095fc518b4981ba78`
