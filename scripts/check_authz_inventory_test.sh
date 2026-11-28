#!/usr/bin/env bash
# Self-test the inventory scripts against isolated manifest fixtures.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fixture="$tmp/repo"
mkdir -p "$fixture/scripts" \
  "$fixture/apps/gcp" "$fixture/apps/tencentcloud" \
  "$fixture/clusters/gcp" "$fixture/clusters/tencentcloud" \
  "$fixture/infrastructure/gcp" "$fixture/infrastructure/tencentcloud"
cp "$repo_root/scripts/check_authz_policy_coverage.sh" \
  "$repo_root/scripts/check_authz_security.sh" "$fixture/scripts/"

cat >"$fixture/apps/gcp/routes.yaml" <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mapped-route
  namespace: demo
spec:
  hostnames: [example.test]
  rules:
    - matches:
        - path: {type: PathPrefix, value: /mapped}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: gap-route
  namespace: demo
spec:
  hostnames: [example.test]
  rules:
    - matches:
        - path: {type: PathPrefix, value: /gap}
EOF
cat >"$fixture/apps/gcp/policy.yaml" <<'EOF'
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: mapped-policy
  namespace: demo
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: mapped-route
  jwt:
    optional: false
    providers:
      - name: test
        issuer: https://issuer.test
        remoteJWKS:
          uri: https://issuer.test/jwks
        audiences:
          - example.test
EOF
coverage="$fixture/scripts/check_authz_policy_coverage.sh"
security="$fixture/scripts/check_authz_security.sh"
if AUTHZ_REPO_ROOT="$fixture" "$coverage" >"$tmp/coverage.csv" 2>"$tmp/coverage.log"; then
  echo "FAIL: expected unmapped route to return 1" >&2
  exit 1
fi
grep -q 'mapped-route.*mapped' "$tmp/coverage.csv"
grep -q 'gap-route.*gap' "$tmp/coverage.csv"
grep -q 'Unmapped HTTPRoutes: 1' "$tmp/coverage.log"

# The security guard runs the coverage check last, so the unmapped fixture route
# makes it fail; the structural PASS line still has to appear.
if AUTHZ_REPO_ROOT="$fixture" "$security" >"$tmp/security.log" 2>&1; then
  echo "FAIL: expected the unmapped route to fail the security guard" >&2
  exit 1
fi
grep -q 'PASS: 1 static SecurityPolicy' "$tmp/security.log"
grep -q 'Unmapped HTTPRoutes: 1' "$tmp/security.log"

cat >"$fixture/apps/gcp/policy.yaml" <<'EOF'
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: empty-jwt-policy
  namespace: demo
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: mapped-route
  jwt:
    providers: []
EOF
if AUTHZ_REPO_ROOT="$fixture" "$security" >"$tmp/invalid-security.log" 2>&1; then
  echo "FAIL: expected empty JWT provider list to fail" >&2
  exit 1
fi
grep -q 'no structurally valid OIDC, JWT, or authorization contract' "$tmp/invalid-security.log"

cat >"$fixture/apps/gcp/policy.yaml" <<'EOF'
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: empty-oidc-policy
  namespace: demo
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: mapped-route
  oidc: {}
EOF
if AUTHZ_REPO_ROOT="$fixture" "$security" >"$tmp/invalid-oidc.log" 2>&1; then
  echo "FAIL: expected empty OIDC configuration to fail" >&2
  exit 1
fi
grep -q 'no structurally valid OIDC, JWT, or authorization contract' "$tmp/invalid-oidc.log"

cat >"$fixture/apps/gcp/policy.yaml" <<'EOF'
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: authorization-policy
  namespace: demo
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: mapped-route
  authorization:
    defaultAction: Deny
    rules:
      - name: allow-fixture
        action: Allow
        principal:
          clientCIDRs:
            - 192.0.2.0/24
EOF
# Drop the unmapped fixture route: with no exception register the coverage contract
# can only pass when every route is mapped, so this is the end-to-end success case.
cat >"$fixture/apps/gcp/routes.yaml" <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mapped-route
  namespace: demo
spec:
  hostnames: [example.test]
  rules:
    - matches:
        - path: {type: PathPrefix, value: /mapped}
EOF
AUTHZ_REPO_ROOT="$fixture" "$security" >"$tmp/authorization-security.log" 2>&1
grep -q 'PASS: 1 static SecurityPolicy' "$tmp/authorization-security.log"
grep -q 'Unmapped HTTPRoutes: 0' "$tmp/authorization-security.log"

echo "PASS: authorization inventory fixture cases"
