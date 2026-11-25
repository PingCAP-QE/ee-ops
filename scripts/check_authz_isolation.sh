#!/usr/bin/env bash
# Verify OpenFGA/authzd network isolation in the ee-authz namespace.
#
# The deployment's acceptance depends on one runtime property that manifests
# cannot prove: an ordinary workload may not reach the authorization store. This
# runs a throwaway pod in ee-authz with no labels, so no NetworkPolicy selector
# matches it, and probes each listener.
#
#   --mode open      expect the listeners to be reachable (pre-enforcement baseline)
#   --mode enforced  expect every listener to be unreachable
#
# Run it before and after enabling GKE NetworkPolicy enforcement. A probe pod in
# ee-authz is deliberate: that namespace has no egress restriction, so a failure
# means ingress policy, not an unrelated deny-all.
#
# Environment: KUBECTL overrides the binary (used by the self-test).
set -euo pipefail

mode=""
namespace="ee-authz"
kubectl_bin=${KUBECTL:-kubectl}
timeout_seconds=5
# Service listeners only. authzd's 9003 is a pod port scraped by PodMonitoring,
# not a Service port, so an unlabelled pod cannot reach it through DNS either.
targets=(
  "openfga:8080"
  "openfga-check:8080"
  "authzd:9002"
)

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) mode=${2:?--mode needs a value}; shift 2 ;;
    --namespace) namespace=${2:?--namespace needs a value}; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$mode" in
  open | enforced) ;;
  *) echo "FAIL: --mode must be open or enforced" >&2; exit 2 ;;
esac

if ! command -v "$kubectl_bin" >/dev/null 2>&1; then
  echo "FAIL: $kubectl_bin is not available" >&2
  exit 2
fi

pod="authz-isolation-probe"
cleanup() {
  "$kubectl_bin" delete pod "$pod" -n "$namespace" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup

failures=0
total=0

for target in "${targets[@]}"; do
  host=${target%:*}
  port=${target##*:}
  total=$((total + 1))

  # -w 3: fail fast when the policy drops the packet.
  if "$kubectl_bin" run "$pod" -n "$namespace" --rm -i --restart=Never \
    --image=docker.io/library/busybox:1.36 \
    --command -- sh -c "nc -z -w $timeout_seconds $host $port" >/dev/null 2>&1; then
    reachable=yes
  else
    reachable=no
  fi

  case "$mode:$reachable" in
    open:yes)
      echo "ok $total - $target reachable, as expected before enforcement"
      ;;
    enforced:no)
      echo "ok $total - $target unreachable"
      ;;
    open:no)
      echo "not ok $total - $target unreachable; enforcement may already be on, or the Service does not exist" >&2
      failures=$((failures + 1))
      ;;
    enforced:yes)
      echo "not ok $total - $target is still reachable from an unlabelled pod" >&2
      failures=$((failures + 1))
      ;;
  esac
done

echo "# $total checks, $failures failed"
if [ "$failures" -ne 0 ]; then
  echo "# Note: authzd:9002 is expected to become reachable from the Envoy dataplane after attachment;" >&2
  echo "# this probe runs an unlabelled pod, which must never reach it." >&2
fi
[ "$failures" -eq 0 ]
