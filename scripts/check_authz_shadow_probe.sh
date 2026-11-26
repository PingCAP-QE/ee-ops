#!/usr/bin/env bash
# Probe the TiBuild routes during the external-authorization shadow period.
#
# Two jobs:
#   1. Prove that attaching extAuth in observe mode did not change what clients
#      see: unauthenticated probes must be rejected by the existing OIDC/JWT
#      layer exactly as before, and nothing may answer 5xx.
#   2. Produce decision evidence: with --expect-decisions it asserts that the
#      window during which the probes ran contains decisions.
#
# Note on attribution: a client-supplied X-Request-Id does NOT survive. Envoy
# regenerates the request id (preserve_external_request_id defaults to false), so
# authzd's correlation_id is Envoy's value, not ours. Attribute decisions by
# reason code, capability or time window instead of by a client-chosen id.
#
# Requests are chosen so that nothing mutates state: unauthenticated probes are
# rejected before the backend, path variants are read-only, and the authenticated
# mutation probes a build id that cannot exist.
#
# Usage:
#   check_authz_shadow_probe.sh [--base-url URL] [--id-token TOKEN]
#                               [--cookie 'name=value; name=value']
#                               [--expect-decisions] [--expect-principal VALUE]
#                               [--project PROJECT] [--since-minutes N]
#                               [--log-filter TEMPLATE]
#
# --id-token and --cookie enable the authenticated cases; without them only the
# unauthenticated probes run. --expect-decisions requires gcloud and at least one
# authenticated case: a request the Gateway rejects never reaches ext_authz, so
# only an authenticated probe can leave a decision. Attribution is by time window
# and, optionally, by --expect-principal.
set -euo pipefail

base_url="https://prow.tidb.net"
id_token=""
cookie=""
expect_decisions=0
expect_principal=""
project=""
since_minutes=15
log_filter='resource.type="k8s_container" resource.labels.namespace_name="ee-authz" jsonPayload.correlation_id="%s"'
timeout_seconds=15

usage() {
  sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base-url) base_url=${2:?--base-url needs a value}; shift 2 ;;
    --id-token) id_token=${2:?--id-token needs a value}; shift 2 ;;
    --cookie) cookie=${2:?--cookie needs a value}; shift 2 ;;
    --expect-decisions) expect_decisions=1; shift ;;
    --expect-principal) expect_principal=${2:?--expect-principal needs a value}; shift 2 ;;
    --project) project=${2:?--project needs a value}; shift 2 ;;
    --since-minutes) since_minutes=${2:?--since-minutes needs a value}; shift 2 ;;
    --log-filter) log_filter=${2:?--log-filter needs a value}; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

base_url=${base_url%/}
if [ -z "$base_url" ]; then
  echo "FAIL: --base-url is required" >&2
  exit 2
fi
if [ "$expect_decisions" -eq 1 ] && ! command -v gcloud >/dev/null 2>&1; then
  echo "FAIL: --expect-decisions needs gcloud on PATH" >&2
  exit 2
fi
if [ "$expect_decisions" -eq 1 ] && [ -z "$id_token" ] && [ -z "$cookie" ]; then
  echo "FAIL: --expect-decisions needs --id-token or --cookie; rejected requests never reach ext_authz" >&2
  exit 2
fi

total=0
failures=0
declare -a probe_ids=()
declare -a probe_labels=()
declare -a probe_statuses=()

# request_id emits a UUID for the request header. Envoy regenerates the request
# id, so this value does not appear in authzd's correlation_id; it is kept so the
# probe is still identifiable in proxy access logs.
request_id() {
  local hex
  hex=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  printf '%s-%s-4%s-%s-%s\n' \
    "${hex:0:8}" "${hex:8:4}" "${hex:14:3}" \
    "$(printf '%x' $((0x${hex:16:1} & 0x3 | 0x8)))${hex:17:3}" "${hex:20:12}"
}

# probe <label> <method> <path> <expect: ok|authn> [extra curl args...]
#   ok    - any non-5xx answer is acceptable (the request is expected to succeed)
#   authn - the existing authn layer must reject it: never 200, never 5xx
probe() {
  local label=$1 method=$2 path=$3 expectation=$4
  shift 4
  local id status
  id=$(request_id)
  status=$(curl -sS --path-as-is --max-time "$timeout_seconds" \
    -o /dev/null -w '%{http_code}' \
    -X "$method" -H "X-Request-Id: $id" "$@" "$base_url$path" 2>/dev/null || echo "000")

  total=$((total + 1))
  probe_ids+=("$id")
  probe_labels+=("$label")
  probe_statuses+=("$status")

  local problem=""
  case "$status" in
    000) problem="request failed (timeout, DNS, or TLS)" ;;
    5??) problem="server error" ;;
    *)
      if [ "$expectation" = authn ] && [ "$status" = 200 ]; then
        problem="unauthenticated request was accepted"
      fi
      ;;
  esac
  if [ -n "$problem" ]; then
    echo "not ok $total - $label: HTTP $status ($problem)" >&2
    failures=$((failures + 1))
  else
    echo "ok $total - $label: HTTP $status"
  fi
}

run_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "# probing $base_url"

# Rejected by OIDC or JWT before the backend, and before ext_authz.
probe "unauthenticated list" GET "/tibuild/api/v2/devbuilds" authn
probe "malformed bearer" GET "/tibuild/api/v2/devbuilds" authn \
  -H "Authorization: Bearer not-a-jwt"
probe "unsupported auth scheme" GET "/tibuild/api/v2/devbuilds" authn \
  -H "Authorization: Basic Zm9vOmJhcg=="
probe "privileged publish without token" POST "/tibuild/api/v2/publish/images" authn
probe "devbuild rerun without token" POST "/tibuild/api/v2/devbuilds/000000/rerun" authn

# Path variants must never reach a 5xx and must never bypass authentication.
probe "double slash" GET "//tibuild/api/v2/devbuilds" authn
probe "dot segment" GET "/tibuild/api/v2/../api/v2/devbuilds" authn
probe "unregistered path" GET "/tibuild/__authz_shadow_probe__" ok

# Authenticated cases. Both are state-free: a read, and a rerun of a build id
# that cannot exist.
if [ -n "$cookie" ]; then
  probe "authenticated browser read" GET "/tibuild/api/v2/devbuilds" ok \
    -H "Cookie: $cookie"
fi
if [ -n "$id_token" ]; then
  probe "authenticated machine rerun of unknown build" \
    POST "/tibuild/api/v2/devbuilds/__authz_shadow_probe__/rerun" ok \
    -H "Authorization: Bearer $id_token"
fi

if [ "$expect_decisions" -eq 1 ]; then
  echo "# checking decision records since $run_start"
  filter="$log_filter timestamp>=\"$run_start\""
  if [ -n "$expect_principal" ]; then
    filter="$filter jsonPayload.principal=\"$expect_principal\""
  fi
  read_args=(logging read "$filter" --limit=5 "--format=value(timestamp)")
  if [ -n "$project" ]; then
    read_args+=(--project "$project")
  fi
  total=$((total + 1))
  if gcloud "${read_args[@]}" 2>/dev/null | grep -q .; then
    echo "ok $total - decisions recorded for the probe window"
  else
    echo "not ok $total - no decision recorded for the probe window (filter: $filter)" >&2
    failures=$((failures + 1))
  fi
fi

echo "# $((total + failures)) checks, $failures failed"
[ "$failures" -eq 0 ]
