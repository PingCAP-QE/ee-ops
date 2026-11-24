# Authorization inventory verification baseline

Captured 2026-11-24 from the local `origin/main` base commit `ba861d9a`.

| Check | Result |
| --- | --- |
| `bash scripts/check_authz_policy_coverage.sh` | 13 static non-Prod2 HTTPRoutes found; 4 directly target SecurityPolicies; 9 report-only gaps |
| `bash scripts/check_authz_security.sh` | 5 static SecurityPolicies have explicit OIDC/JWT/authz config; exits 1 because the 9 route gaps are not yet owner-approved exceptions |
| `bash scripts/check_gcp_route_csrf.sh` | PASS for browser CSRF, OIDC-only browser route, machine JWT, privileged prefixes, portal exclusion and reviewed network peers |
| `bash scripts/check_jenkins_route_security_headers.sh` + `bash scripts/check_jenkins_route_security_headers_test.sh` | PASS; existing browser headers retained and all 27 regression cases pass |
| `bash scripts/check_ci_dashboard_auth_config.sh` | PASS (static application/gateway identity configuration) |
| `bash scripts/check_gcp_rbac_system_authenticated.sh` | PASS; no non-default ClusterRole bound to `system:authenticated` |
| `uv run --no-project --with pyyaml python3 -m unittest scripts/test_github_token_broker_https.py` | PASS (7 offline cases; isolated dependency, no repository environment changes) |
| `scripts/validate_k8s_yaml.sh` from `apps/`, `infrastructure/`, and `clusters/` | PASS (run serially; no manifest changes in this phase) |
| Envoy Gateway chart | GCP and TencentCloud HelmRelease pin `gateway-helm` v1.9.3 |
| Live controller / CRD / route status | Captured separately in [`runtime-baseline.md`](runtime-baseline.md) for GCP and TencentCloud |
| Shadow/enforce | Not enabled |

The script discovers static YAML objects. It does not render Helm charts, query
Gateway `Accepted`/`Programmed` conditions, inspect active pods, or prove caller
reachability. The 9 gaps therefore remain unresolved inventory items pending
owner review and rendered/runtime evidence.
