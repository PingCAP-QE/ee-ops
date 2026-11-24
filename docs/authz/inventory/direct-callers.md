# Direct callers and network bypass inventory

This is the initial manifest-backed inventory. A NetworkPolicy peer identifies
a namespace allowed at the network layer; it does not prove a particular
workload identity or that the caller passes through the Gateway.

| Service | Allowed source | Evidence | Authorization implication |
| --- | --- | --- | --- |
| TiBuild v2 API (port 80) | `infra`, `tibuild`, `chatops-lark`, `ee-portal` namespaces | `apps/gcp/tibuild/v2/networkpolicy.yaml` | `infra` is the Envoy data plane; same-namespace chart callers remain; ChatOps and Portal call ClusterIP directly. All bypass Gateway policies; preserve TiBuild authn/authz and actor checks. |
| Prow control plane (ports 80, 8080, 8888) | `infra` namespace and all pods in `prow` namespace | `apps/gcp/prow/post/netpol-ingress.yaml` | `infra` is Envoy; same-namespace hook/plugin/deck/ghproxy traffic bypasses Gateway. Prow webhook signatures and native authorization remain required. |
| DL management (ports 80, 8001) | `infra` namespace | `apps/gcp/dl/delivery/networkpolicy.yaml` | Only Envoy can reach the issuer listener; probes/metrics stay private. No other namespace caller is allowed by this policy. |
| DL public (ports 80, 8001) | `infra` namespace | `apps/gcp/dl/delivery/networkpolicy.yaml` | Anonymous redemption enters through the dedicated Gateway route; preserve DL token validation, expiry, revocation and quota. |
| GitHub token broker (port 8443) | `arc-runners` namespace | `apps/gcp/github-token-broker/networkpolicy-arc-https.yaml` | Direct native TLS caller path bypasses Gateway; retain broker TokenReview, repository narrowing and permission ceiling. |

The tables are based on checked-in selectors, not a live connection audit.
Runtime identities and live `NetworkPolicy` enforcement were not inspected;
owners must verify rendered pod labels and actual caller ServiceAccounts before
claiming the bypasses are closed.
