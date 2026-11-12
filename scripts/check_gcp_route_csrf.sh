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

# The EE Portal manifest set is intentionally down (no HTTPRoute, no policy);
# the checks below resume automatically when those files come back.
if [ -f "$repo_root/apps/gcp/ee-portal/security-policy.yaml" ]; then
  check_policy apps/gcp/ee-portal/security-policy.yaml ee-portal ee-portal
fi
check_policy apps/gcp/tibuild/v2/security-policy.yaml tibuild v2-tibuild-v2
check_policy apps/gcp/ci-dashboard/security-policy.yaml apps ci-dashboard
check_policy apps/gcp/tekton/setup/dashboard-security-policy.yaml tekton-pipelines tekton

# The browser route must stay OIDC-only. A JWT provider with optional: true, or
# passThroughAuthHeader, lets a non-canonical Authorization header skip OIDC.
check_oidc_only_browser_policy() {
  local file=$1 namespace=$2 route=$3
  if ! NAMESPACE="$namespace" ROUTE="$route" yq eval -e '
    .kind == "SecurityPolicy" and
    .metadata.namespace == strenv(NAMESPACE) and
    .metadata.name == "tibuild-v2-oidc" and
    (.spec | has("jwt") | not) and
    (.spec.oidc | has("passThroughAuthHeader") | not) and
    (.spec.targetRefs | length == 1) and
    .spec.targetRefs[0].group == "gateway.networking.k8s.io" and
    .spec.targetRefs[0].kind == "HTTPRoute" and
    .spec.targetRefs[0].name == strenv(ROUTE)
  ' "$repo_root/$file" > /dev/null; then
    echo "FAIL: $file must keep the browser route OIDC-only (no JWT, no passThroughAuthHeader)" >&2
    return 1
  fi
  echo "PASS: $namespace/$route is OIDC-only"
}

check_oidc_only_browser_policy apps/gcp/tibuild/v2/security-policy.yaml tibuild v2-tibuild-v2

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
  # The policy may cover the privileged-path route as well, so allow up to two
  # targets. Counted in bash: the yq release CI installs (v4.6.1) cannot parse
  # array construction inside this expression.
  targets=$(yq eval 'select(.kind == "SecurityPolicy") | .spec.targetRefs[].name' "$repo_root/$file" 2>/dev/null | grep -c . || true)
  if [ "${targets:-0}" -lt 1 ] || [ "${targets:-0}" -gt 2 ]; then
    echo "FAIL: $file must target one or two HTTPRoutes (found ${targets:-0})" >&2
    return 1
  fi
  if ! ROUTE="$route" AUDIENCE="$audience" yq eval -e '
    select(.kind == "SecurityPolicy") |
    (.spec | has("oidc") | not) and
    .spec.jwt.optional == false and
    (.spec.jwt.providers | length == 1) and
    .spec.jwt.providers[0].issuer == "https://accounts.google.com" and
    .spec.jwt.providers[0].remoteJWKS.uri == "https://www.googleapis.com/oauth2/v3/certs" and
    (.spec.jwt.providers[0].audiences | length == 1) and
    .spec.jwt.providers[0].audiences[0] == strenv(AUDIENCE)
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
# The EE Portal route is intentionally absent right now (its exposure is being
# reworked); keep asserting the fallback shape only when it exists.
if [ -f "$repo_root/apps/gcp/ee-portal/http-route.yaml" ]; then
  yq eval -e '[.spec.rules[].matches[] | select(has("headers"))] | length == 0' \
    "$repo_root/apps/gcp/ee-portal/http-route.yaml" > /dev/null
fi

# Privileged TiBuild prefixes must be carved out of the browser route. This
# drifted once already: `docs/gcp-gateway-auth.md` listed `/api/v2/tidbcloud/*`
# as covered while the HTTPRoute only carried publish/hotfix/artifact, so an
# OIDC employee could still roll component versions and sync kernel images.
check_privileged_prefixes() {
  local file=$1
  local directory
  directory=$(dirname "$file")
  yq eval -e '.resources[] | select(. == "privileged-access.yaml")' \
    "$repo_root/$directory/kustomization.yaml" > /dev/null

  local broken=""
  local prefix
  for prefix in publish hotfix artifact tidbcloud; do
    # Each prefix needs its own rule, and the rewrite has to name the prefix
    # itself: rewriting to "/" drops the api/v2/<kind> part of the path.
    if ! PREFIX="/tibuild/api/v2/$prefix" REWRITE="/api/v2/$prefix" yq eval -e '
      select(.kind == "HTTPRoute") |
      [.spec.rules[]
        | select(.matches[0].path.value == strenv(PREFIX))
        | select(.filters[0].urlRewrite.path.replacePrefixMatch == strenv(REWRITE))
      ] | length == 1
    ' "$repo_root/$file" > /dev/null; then
      broken="$broken $prefix"
    fi
  done
  if [ -n "$broken" ]; then
    echo "FAIL: $file must route these privileged prefixes to the machine policy:$broken" >&2
    return 1
  fi
  echo "PASS: privileged TiBuild prefixes are machine-only"
}

check_privileged_prefixes apps/gcp/tibuild/v2/privileged-access.yaml

# `/tibuild` is read-only for browsers: every mutating method goes to the
# machine-only route. The split only works because the two method sets are
# disjoint — Envoy Gateway orders same-path routes by path length and header
# count, not by method, so a method-less browser rule would tie with the write
# rule and the winner would be arbitrary.
check_write_methods() {
  local route_file=$1 browser_file=$2

  if ! yq eval -e '
    [ .spec.values.httpRoute.rules[].matches[]
      | select(.method == null or
               (.method != "GET" and .method != "HEAD" and .method != "OPTIONS"))
    ] | length == 0
  ' "$repo_root/$browser_file" > /dev/null; then
    echo "FAIL: $browser_file must match only GET/HEAD/OPTIONS; a method-less or mutating match lets a browser session reach writes" >&2
    return 1
  fi

  local missing=""
  local method
  for method in POST PUT PATCH DELETE; do
    if ! METHOD="$method" yq eval -e '
      select(.kind == "HTTPRoute") |
      [ .spec.rules[]
        | select(.filters[0].urlRewrite.path.replacePrefixMatch == "/")
        | .matches[]
        | select(.method == strenv(METHOD) and .path.value == "/tibuild")
      ] | length == 1
    ' "$repo_root/$route_file" > /dev/null; then
      missing="$missing $method"
    fi
  done
  if [ -n "$missing" ]; then
    echo "FAIL: $route_file must serve these mutating methods on /tibuild:$missing" >&2
    return 1
  fi
  echo "PASS: tibuild writes are machine-only and reads stay on OIDC"
}

check_write_methods apps/gcp/tibuild/v2/privileged-access.yaml apps/gcp/tibuild/v2/release.yaml
