#!/usr/bin/env bash
# Self-test for check_authz_isolation.sh.
#
# Swaps in a fake kubectl (via KUBECTL) that reports every listener as reachable
# or blocked, then asserts the guard's verdict for each mode.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
guard="$script_dir/check_authz_isolation.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/kubectl" <<'SH'
#!/usr/bin/env bash
# Fake kubectl. FAKE_REACHABLE=1 reports the probe as connected.
set -u
case "${1:-}" in
  delete) exit 0 ;;
  run)
    if [ "${FAKE_REACHABLE:-0}" = "1" ]; then
      exit 0
    fi
    exit 1
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$tmp/kubectl"

total=0
failures=0

# expect <0|nonzero> <label> <env assignments...> -- <guard args...>
expect() {
  local want=$1 label=$2
  shift 2
  local envs=()
  while [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  local status=0
  env KUBECTL="$tmp/kubectl" "${envs[@]}" "$guard" "$@" >"$tmp/last.log" 2>&1 || status=$?
  total=$((total + 1))
  if { [ "$want" = 0 ] && [ "$status" -eq 0 ]; } ||
    { [ "$want" = nonzero ] && [ "$status" -ne 0 ]; }; then
    echo "ok $total - $label (exit $status)"
  else
    echo "not ok $total - $label (want $want, exit $status)" >&2
    sed 's/^/    /' "$tmp/last.log" >&2
    failures=$((failures + 1))
  fi
}

expect 0 "reachable listeners pass in open mode" \
  FAKE_REACHABLE=1 -- --mode open
expect nonzero "a blocked listener fails in open mode" \
  FAKE_REACHABLE=0 -- --mode open
expect 0 "blocked listeners pass in enforced mode" \
  FAKE_REACHABLE=0 -- --mode enforced
expect nonzero "a reachable listener fails in enforced mode" \
  FAKE_REACHABLE=1 -- --mode enforced
expect nonzero "a missing mode is refused" \
  FAKE_REACHABLE=1 --
expect nonzero "an unknown mode is refused" \
  FAKE_REACHABLE=1 -- --mode sometimes

echo "# $total checks, $failures failed"
[ "$failures" -eq 0 ]
