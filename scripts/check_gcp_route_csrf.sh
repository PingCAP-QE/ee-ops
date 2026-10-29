#!/usr/bin/env bash
# Regression guard for the browser-facing GCP OIDC routes. Requires yq v4.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

check_policy() {
  local file=$1 namespace=$2 route=$3
  # An empty CSRF policy enforces all mutating requests with no extra origins.
  # Do not replace it with shadow mode or exempt requests based on an unverified
  # Authorization header: these routes also accept ambient OIDC cookies.
  if ! NAMESPACE="$namespace" ROUTE="$route" yq eval -e '
    .kind == "SecurityPolicy" and
    .metadata.namespace == strenv(NAMESPACE) and
    ((.spec.csrf | tag) == "!!map") and
    ((.spec.csrf | length) == 0) and
    (.spec.targetRefs | length == 1) and
    .spec.targetRefs[0].group == "gateway.networking.k8s.io" and
    .spec.targetRefs[0].kind == "HTTPRoute" and
    .spec.targetRefs[0].name == strenv(ROUTE)
  ' "$repo_root/$file" > /dev/null; then
    echo "FAIL: $file must enforce CSRF on $namespace/$route" >&2
    return 1
  fi
  echo "PASS: $namespace/$route enforces CSRF"
}

check_policy apps/gcp/ee-portal/security-policy.yaml ee-portal ee-portal
check_policy apps/gcp/tibuild/v2/security-policy.yaml tibuild v2-tibuild-v2
check_policy apps/gcp/ci-dashboard/security-policy.yaml apps ci-dashboard

check_machine_policy() {
  local file=$1 route=$2 audience=$3
  local directory
  directory=$(dirname "$file")
  yq eval -e '.resources[] | select(. == "machine-access.yaml")' \
    "$repo_root/$directory/kustomization.yaml" > /dev/null
  ROUTE="$route" AUDIENCE="$audience" yq eval -e '
    select(.kind == "HTTPRoute") |
    .metadata.name == strenv(ROUTE) and
    (.spec.hostnames | length == 1) and
    .spec.hostnames[0] == strenv(AUDIENCE) and
    (.spec.rules | length == 1) and
    (.spec.rules[0].matches | length == 1) and
    (.spec.rules[0].matches[0].headers | length == 1) and
    .spec.rules[0].matches[0].headers[0].name == "Authorization" and
    .spec.rules[0].matches[0].headers[0].type == "RegularExpression" and
    .spec.rules[0].matches[0].headers[0].value == "^Bearer .+$"
  ' "$repo_root/$file" > /dev/null
  if ! ROUTE="$route" AUDIENCE="$audience" yq eval -e '
    select(.kind == "SecurityPolicy") |
    (.spec | has("oidc") | not) and
    .spec.jwt.optional == false and
    (.spec.jwt.providers | length == 1) and
    .spec.jwt.providers[0].issuer == "https://accounts.google.com" and
    .spec.jwt.providers[0].remoteJWKS.uri == "https://www.googleapis.com/oauth2/v3/certs" and
    (.spec.jwt.providers[0].audiences | length == 1) and
    .spec.jwt.providers[0].audiences[0] == strenv(AUDIENCE) and
    (.spec.targetRefs | length == 1) and
    .spec.targetRefs[0].group == "gateway.networking.k8s.io" and
    .spec.targetRefs[0].kind == "HTTPRoute" and
    .spec.targetRefs[0].name == strenv(ROUTE)
  ' "$repo_root/$file" > /dev/null; then
    echo "FAIL: $file must require JWT authentication without OIDC fallback" >&2
    return 1
  fi
  echo "PASS: $route requires a verified JWT"
}

check_machine_policy apps/gcp/tibuild/v2/machine-access.yaml tibuild-v2-machine prow.tidb.net

# Headerless browser fallbacks must remain available to cookie clients.
for file in apps/gcp/tibuild/v2/release.yaml apps/gcp/ci-dashboard/release.yaml; do
  yq eval -e '
    [.spec.values.httpRoute.rules[].matches[] | select(has("headers"))] | length == 0
  ' "$repo_root/$file" > /dev/null
done
yq eval -e '[.spec.rules[].matches[] | select(has("headers"))] | length == 0' \
  "$repo_root/apps/gcp/ee-portal/http-route.yaml" > /dev/null
