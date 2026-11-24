# Authorization acceptance test matrix

| Spec AC | Scenario | Expected result | Evidence required |
| --- | --- | --- | --- |
| AC 1 | Every exposed non-Prod2 route mapped or explicit exception | No unclassified route | Coverage script, rendered route inventory, owner-approved exceptions |
| AC 6 | Route/method/path mapping and rewrite behavior | Exact external and upstream matches; misses deny | Registry fixtures plus Envoy route-selection test |
| AC 7 | Identity trust and anti-spoofing | Invalid token/header spoof denied | Browser/machine integration tests across GKE and Envoy |
| AC 9 | Direct ClusterIP caller | Existing authn/authz remains effective or access is blocked | NetworkPolicy render and caller matrix |
| AC 10 | OpenFGA/resolver unavailable | Enforcing request fails closed; shadow preserves existing outcome | Fault-injection test and status-code/log evidence |
| AC 14 | Prod2 exclusion | No deployment/config/caller change in Prod2 | Per-PR changed-path check and Git diff |

Run the existing authn baseline in GCP before changes:

```sh
bash scripts/check_gcp_route_csrf.sh
```

This repository-only command checks configuration invariants; it does not
replace synthetic HTTP requests or live Gateway status evidence.
