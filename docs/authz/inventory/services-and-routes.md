# Services, routes, and existing authorization boundaries

This first inventory combines static Gateway manifests in this repository with
service contracts documented in `docs/gcp-gateway-auth.md`,
`docs/gcp-route-csrf.md`, and the application source. It is not a claim that all
Helm-generated paths or all application operations have been exhaustively
enumerated. `scripts/check_authz_policy_coverage.sh` detects static route
changes; rendered chart routes and runtime routes remain an iteration gate.

| Service / surface | Method and URL family | Resource input / owner source | Principal | Side effect | Current guard |
| --- | --- | --- | --- | --- | --- |
| TiBuild browser | API methods under `https://prow.tidb.net/tibuild/*`; browser route rewrites prefix | Path/query/body varies by operation; owner and project data in TiBuild | Google OIDC browser session | Read and mutation | Gateway OIDC + CSRF; TiBuild `pkg/authz` and identity middleware; owner/mutation checks |
| TiBuild machine | API methods under `https://prow.tidb.net/tibuild/*` | Path/query/body varies | Google ID token with service-account allowlist | Read and mutation | Required JWT issuer/audience and allowlist; TiBuild app checks |
| TiBuild privileged | Publish, hotfix, artifact and TiDB Cloud API prefixes under `/tibuild/api/v2/*` | Domain-specific identifiers and body | Allowlisted machine identity | High-impact mutation | Privileged route and JWT allowlist plus app-side checks |
| DL share management | `POST /api/v1/shares`, `GET /api/v1/shares/{id}`, `DELETE /api/v1/shares/{id}` | Share/resource IDs and request body; DL store | Workload or authenticated service | Create/revoke shares | Dedicated `dl-management` chart has `httpRoute.enabled: false`; no external Gateway route identified |
| DL private object API | `GET https://prow.tidb.net/dl/gcs-obj/{bucket}/{key}`, `/dl/oci-file/{repository}`, `/dl/oci-file-sha256/{repository}`, `/dl/oci-files/{repository}` | Bucket/key/repository | Authenticated workload / current app contract | Object download/list | Static HTTPRoute rewrites `/dl` to `/`; no direct SecurityPolicy; caller and app guards require deeper verification |
| DL public redemption | `GET https://dl.pingcap.net/d/{token}` | Capability token in path | Anonymous bearer-by-URL | Download/session reservation | Cryptographic capability, expiration/revocation, session limits and quota in DL |
| Prow | `/`, `/hook`, `/ti-community-owners`, `/tichi` on Prow hosts | Webhook payload, GitHub repository/job data | GitHub webhook, staff, CI workloads | Job execution and administration | Webhook signatures and Prow/GitHub auth; route chain needs rendered verification |
| Tekton dashboard | `/tekton` on `prow.tidb.net` | Kubernetes resources | OIDC user / Kubernetes identity | Pipeline observation and control | Gateway JWT/OIDC policy plus Kubernetes RBAC |
| Jenkins | Chart-generated ingress host/path in GCP and TencentCloud | Jobs/builds | Authenticated employee / service principal | CI administration and execution | Jenkins authentication/authorization; generated Gateway route not included in static files |
| Zot | `https://cr-qcloud.pingcap.net/*` internal route | OCI repository and artifact | Registry client | Push/pull/delete artifacts | Zot-native authorization and network boundary; verify runtime exposure |
| ChatOps Lark | WebSocket/event API, not an HTTPRoute in this inventory | Lark sender and event | Lark app + event sender | Commands including TiBuild operations | Event signature, app/service identity and per-command actor checks |
| CloudEvents server | Internal HTTP receiver and health endpoints; no Gateway HTTPRoute found in the static inventory | CloudEvent subject/resource data | Tekton / internal workloads | Dispatch events to Kafka consumers | Service-specific request validation and network boundary; enumerate live Service callers |
| Delivery approval | Internal service API, no public route identified here | Approval request/state | Approval service and DL | Approve/reject delivery | Service-owned role/state machine; DL remains issuer of delivery grants |
| CI Dashboard | Helm-generated route on `prow.tidb.net` | Build rows and query filters | OIDC user | Read | OIDC and application row-level filtering; static route needs rendered inventory |
| Roster / Cost Insight | Scheduled Jobs; no Gateway HTTPRoute found | Employee/team data or cloud cost records | Lark sync / cloud workload identity | Read and synchronize/report | Workload IAM and source permissions; no user-facing HTTP authz route identified |
| Mac Builder Operator | Kubernetes controller; no HTTPRoute found | Kubernetes custom resources | Kubernetes ServiceAccount | Reconcile builder resources | Kubernetes RBAC and admission controls, not Gateway authz |

Do not infer full route coverage from this table. Each method/path and resource
resolver must be enumerated from router/OpenAPI sources in ee-apps and compared
with rendered routes before enabling `extAuth`.

## TiBuild v2 API operations from generated OpenAPI

Source: `tibuild/internal/service/gen/http/openapi3.json`. Browser route exposes
the `/tibuild` prefix, while the backend receives the prefix-rewritten path.
The browser and machine routes overlap; exact effective route selection is in
`docs/gcp-gateway-auth.md` and must be considered with the method below.

| Method | External URL | Upstream URL | Object ID input | Side effect / existing guard |
| --- | --- | --- | --- | --- |
| GET | `/tibuild/api/v2/artifact/sync-images` | `/api/v2/artifact/sync-images` | query filters | List tasks; auth middleware |
| POST | `/tibuild/api/v2/artifact/sync-images` | `/api/v2/artifact/sync-images` | request body | Start image sync; machine allowlist and service checks |
| GET | `/tibuild/api/v2/artifact/sync-images/{id}` | `/api/v2/artifact/sync-images/{id}` | path `id` | Read task; auth middleware |
| GET | `/tibuild/api/v2/devbuilds` | `/api/v2/devbuilds` | query filters, optional `scope` | Multi-row list; existing data access scope/filter is authoritative |
| POST | `/tibuild/api/v2/devbuilds` | `/api/v2/devbuilds` | request body | Create build; authz and mutation checks |
| GET | `/tibuild/api/v2/devbuilds/capabilities` | `/api/v2/devbuilds/capabilities` | none | Read capabilities; auth middleware |
| GET | `/tibuild/api/v2/devbuilds/{id}` | `/api/v2/devbuilds/{id}` | path `id` | Read build; owner/visibility behavior needs ADR approval |
| POST | `/tibuild/api/v2/devbuilds/{id}/rerun` | `/api/v2/devbuilds/{id}/rerun` | path `id` | Mutation; existing owner and mutation-policy checks |
| POST | `/tibuild/api/v2/hotfix/bump-tag-for-tidbx` | `/api/v2/hotfix/bump-tag-for-tidbx` | body | Privileged hotfix mutation; machine-only plus app guard |
| POST | `/tibuild/api/v2/hotfix/tidbx/bump-tag` | `/api/v2/hotfix/tidbx/bump-tag` | body | Privileged hotfix mutation; machine-only plus app guard |
| GET | `/tibuild/api/v2/hotfix/tidbx/tag` | `/api/v2/hotfix/tidbx/tag` | query | Read tag; machine route policy |
| POST | `/tibuild/api/v2/publish/images` | `/api/v2/publish/images` | body | Publish images; privileged machine route and app checks |
| POST | `/tibuild/api/v2/publish/tiup/delivery-by-rules` | `/api/v2/publish/tiup/delivery-by-rules` | body | Delivery mutation; privileged machine route and app checks |
| POST | `/tibuild/api/v2/publish/tiup/publish-request` | `/api/v2/publish/tiup/publish-request` | body | Create publish request; privileged machine route and app checks |
| POST | `/tibuild/api/v2/publish/tiup/publish-request-single` | `/api/v2/publish/tiup/publish-request-single` | body | Create publish request; privileged machine route and app checks |
| GET | `/tibuild/api/v2/publish/tiup/publish-request/{request_id}` | `/api/v2/publish/tiup/publish-request/{request_id}` | path `request_id` | Read publishing status; machine route policy |
| GET | `/tibuild/api/v2/publish/units` | `/api/v2/publish/units` | query | Multi-row list; app-side filtering/guard remains |
| GET | `/tibuild/api/v2/publish/units/{id}` | `/api/v2/publish/units/{id}` | path `id` | Read unit; app guard remains |
| POST | `/tibuild/api/v2/publish/units/{id}/retry` | `/api/v2/publish/units/{id}/retry` | path `id` | Mutation; privileged machine route and app guard |
| POST | `/tibuild/api/v2/tidbcloud/devops/cloudconfig/versions/component` | same suffix under `/api/v2` | body | TiDB Cloud mutation; privileged machine route and app guard |
| POST | `/tibuild/api/v2/tidbcloud/sync-kernel-images` | same suffix under `/api/v2` | body | TiDB Cloud mutation; privileged machine route and app guard |
| POST | `/tibuild/api/v2/tidbcloud/tidbx-component-image-builds` | same suffix under `/api/v2` | body | TiDB Cloud mutation; privileged machine route and app guard |

## Other generated service operations

| Service | Method / URL | Resource input | Principal / guard |
| --- | --- | --- | --- |
| DL share management | `POST /api/v1/shares`, `GET /api/v1/shares/{id}`, `DELETE /api/v1/shares/{id}` | Target/resource and share id | Dedicated management service; route disabled in its Helm values; do not infer external exposure |
| DL object delivery | `GET https://prow.tidb.net/dl/gcs-obj/{bucket}/{key}`, `GET /dl/oci-file/{repository}`, `GET /dl/oci-file-sha256/{repository}`, `GET /dl/oci-files/{repository}` → upstream paths without `/dl` | Bucket/key/repository | Existing object access behavior and network controls; verify actual callers before onboarding |
| DL public delivery | `GET https://dl.pingcap.net/d/{token}` plus legacy `/dl/*` | Anonymous capability token | Explicit ReBAC exception; cryptographic token, expiry, revocation and session reservation stay in DL |
| Delivery approval | `GET /`, `POST /requests`, `GET /requests`, `GET /pending`, `GET /requests/{id}`, `POST /requests/{id}/approve|reject|revoke` | Request id and state | Service-owned roles, CSRF and state machine; no Gateway route identified in current inventory |

The TiBuild/OpenAPI and DL/OpenAPI tables identify API contracts. They do not
claim that every operation is currently externally routed. Compare them with
both static and live Gateway inventories; any unexposed operation remains
unrouted and should not be added to the registry implicitly.

## Source-level HTTP operation inventory

This section records operations found in the checked-in Go service wiring and
generated OpenAPI documents in `PingCAP-QE/ee-apps`. Gateway exposure is a
separate question; the `Exposure` column records only what the current ee-ops
manifest/runtime inventory establishes. Paths below are service-relative.

| Service | Method and path | Resource input / owner source | Principal and existing guard | Exposure / notes |
| --- | --- | --- | --- | --- |
| TiBuild | 22 operations listed above | Path, query or body; TiBuild database and service logic | Browser OIDC + CSRF, machine JWT/allowlist, application authz and mutation checks | Browser/machine/privileged routes exist; exact effective route depends on overlap and rewrite |
| DL | `POST /api/v1/shares`, `GET /api/v1/shares/{id}`, `DELETE /api/v1/shares/{id}`; `GET /gcs-obj/{bucket}/{key}`, `/oci-file-sha256/{repository}`, `/oci-file/{repository}`, `/oci-files/{repository}` | Share ID, bucket/key, repository; DL database and artifact metadata | Management service authz; public redemption uses an unguessable capability with TTL, revocation and session limits | Public `/d/{token}` is a distinct Gateway route; management chart defaults `httpRoute.enabled: false`; verify live routes/callers |
| Delivery approval | `GET /`, `POST /requests`, `GET /requests`, `GET /pending`, `GET /requests/{id}`, `POST /requests/{id}/approve`, `POST /requests/{id}/reject`, `POST /requests/{id}/revoke` | Request ID, repository/tag/files; approval store and delivery state | Google ID token independently validated from `X-Approval-Id-Token`; requester/approver roles, CSRF on mutations, and service-owned state transitions | No HTTPRoute found in the current static/runtime inventory; probes and metrics use a separate private listener |
| CloudEvents server | `GET /`, `GET /healthz`, `POST /events` | CloudEvent subject/resource and event type; event-specific handler/catalog | Producer and event validation plus handler-specific checks; must verify the trust boundary for each event type | Chart defaults both `ingress.enabled` and `httpRoute.enabled` to false; internal exposure/callers need runtime confirmation |
| ChatOps Lark | No application HTTP operation; persistent Lark event connection and command handlers | Lark sender, event payload, command arguments and referenced TiBuild resource | Lark event signature, sender-to-user mapping and command-specific actor checks | Out of the HTTPRoute inventory; direct service/network callers and sender mapping remain a separate boundary |
| Mac Builder Operator | Kubernetes reconciliation and metrics/probe surfaces, no user-facing HTTP API | Kubernetes custom resources and cluster state | Kubernetes ServiceAccount RBAC and admission controls | Not a Gateway API service; Prod2-only deployment/callers remain excluded |

**Source evidence:** TiBuild `tibuild/internal/service/gen/http/openapi3.json`;
broker `github-token-broker/internal/service/gen/http/openapi3.json`;
DL `dl/gen/http/openapi3.json`; delivery-approval
`delivery-approval/internal/web/web.go` and `internal/server/server.go`;
CloudEvents `cloudevents-server/cmd/server/main.go` and
`charts/cloudevents-server/values.yaml`; ChatOps `chatops-lark/pkg/events`.
The source-level table establishes implemented operations, not proof of current
network reachability. Rendered Helm and live Gateway/Service/NetworkPolicy
evidence are required before any route is called covered.
