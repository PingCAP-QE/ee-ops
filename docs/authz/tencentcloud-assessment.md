# TencentCloud (TKE) assessment

Read-only findings from the `tke-pingcap-cicd` cluster on 2026-11-27, plus what the
deployment would need. This is the assessment phase, not a rollout.

## What the cluster already supports

| Item | Finding |
| --- | --- |
| Envoy Gateway controller | `docker.io/envoyproxy/gateway:v1.9.3` — the same version as GCP |
| `SecurityPolicy` CRD | `v1alpha1`, exposes `extAuth` with `contextExtensions`, `statusOnError`, `timeout`, `failOpen`, gRPC backends |
| `oidc.forwardIDToken` | Present |
| Gateways | `infra/external-https` (public) and `infra/internal-https`, both `Programmed=True` |
| Secret access | A `ClusterSecretStore` named `ee-gcp-sm` is `Valid`/`Ready` — GCP Secret Manager is reachable from TKE |

So the mechanism transfers: same controller, same CRD surface, same secret source.
That was the main risk in the plan's Phase 11 and it is resolved.

## What is different, and it changes the shape

| Item | Finding | Consequence |
| --- | --- | --- |
| `SecurityPolicy` objects | **None** | There is no gateway authentication on TKE today. GCP's model is OIDC/JWT at the gateway plus extAuth; here extAuth would be the first policy on the cluster |
| TiBuild route | No HTTPRoute for `tibuild`, although `tibuild/v2-tibuild-v2` runs 2/2 | The pilot service is not gateway-exposed on TKE, so "the same routes as GCP" does not exist to copy |
| Exposed routes | `github-token-broker` (qcloud host), `jenkins` ×2, `zot` ×2, `cache/git-cdn` | The candidate set is different from GCP: the broker, Jenkins and Zot |
| Zot | Two routes, OCI registry | Deferred by `deferred-scope.md`: native registry authz, not a gateway target |
| Jenkins | Browser UI, chart-generated routes | Needs OIDC first; extAuth on an unauthenticated route has nothing to authorize |
| authzd / OpenFGA | Not deployed | An independent store is required (ADR 0004: per-cluster store, same model, no replication); the datastore for it does not exist yet |

The important one is the first row. On GCP, extAuth sits behind an existing
authentication layer, so `authzd` can rely on "someone already proved who this is".
On TKE there is no such layer, and adding extAuth without authentication would mean
`authzd` sees anonymous traffic and denies it — or, worse, that a route is protected
by a decision nobody authenticated.

## What deployment would need

1. **Authentication first.** Choose the routes worth exposing and put OIDC/JWT on
   them before extAuth, otherwise the ordering that made GCP work has nothing to
   build on.
2. **A store with a datastore.** ADR 0004 wants an independent store per cluster.
   GCP uses a TiDB database; TKE has no OpenFGA yet and no chosen database. This is
   a decision, not a task: the same TiDB, a new instance, or another engine.
3. **A credential and network path** from `authzd` to that store, and from the
   gateway to `authzd` — plus the `ReferenceGrant` and `NetworkPolicy` equivalents
   that GCP needed.
4. **A scope decision.** With Zot deferred and TiBuild unrouted, the realistic first
   target is the GitHub token broker, which is exactly the service whose GCP
   ordering property (credential injection after extAuth) already checked out.

## Recommendation

Do not deploy yet. Two decisions come first, and neither is a coding task:

- **Which routes are in scope**, given TiBuild is not routed here and Zot is deferred.
- **Where the OpenFGA store lives** on TKE, since an independent store is required
  and no datastore has been chosen.

Everything else — the CRD support, the controller version, the secret source — is
already verified and would not block a later rollout.
