#!/usr/bin/env bash
# Self-test for check_authz_shadow_probe.sh.
#
# Runs the probe against a local stub that imitates the Gateway's behaviour, so
# the assertions can be exercised without touching a cluster. Three scenarios:
#
#   clean  - the Gateway rejects exactly as expected: the probe must pass.
#   error  - one path answers 500: the probe must fail.
#   accept - the Gateway accepts an unauthenticated read: the probe must fail.
#
# Run directly; it needs python3 and curl.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
guard="$script_dir/check_authz_shadow_probe.sh"

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is required to run this self-test" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "FAIL: curl is required to run this self-test" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/stub.py" <<'PY'
import http.server
import socketserver
import sys

mode = sys.argv[1]


class Handler(http.server.BaseHTTPRequestHandler):
    def _reply(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _handle(self):
        path = self.path
        if mode == "error" and path.startswith("/tibuild/api/v2/devbuilds"):
            return self._reply(500)
        if mode == "accept" and path == "/tibuild/api/v2/devbuilds":
            return self._reply(200)
        if self.headers.get("Authorization"):
            return self._reply(401)
        if path.startswith("//tibuild"):
            return self._reply(301)
        return self._reply(302)

    do_GET = _handle
    do_POST = _handle

    def log_message(self, *args):
        pass


with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
    print(httpd.server_address[1], flush=True)
    httpd.serve_forever()
PY

total=0
failures=0

start_stub() {
  local mode=$1
  local log="$tmp/stub-$mode.log"
  python3 "$tmp/stub.py" "$mode" >"$log" 2>&1 &
  stub_pid=$!
  for _ in $(seq 1 50); do
    if [ -s "$log" ]; then
      stub_port=$(head -n 1 "$log")
      return 0
    fi
    sleep 0.1
  done
  echo "FAIL: stub ($mode) did not start" >&2
  exit 1
}

stop_stub() {
  kill "$stub_pid" 2>/dev/null || true
  wait "$stub_pid" 2>/dev/null || true
}

# expect <0|nonzero> <label> <command...>
expect() {
  local want=$1 label=$2
  shift 2
  local status=0
  "$@" >"$tmp/last.log" 2>&1 || status=$?
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

start_stub clean
expect 0 "clean gateway behaviour passes" \
  "$guard" --base-url "http://127.0.0.1:$stub_port"
stop_stub

start_stub error
expect nonzero "a 5xx fails the probe" \
  "$guard" --base-url "http://127.0.0.1:$stub_port"
if grep -q "server error" "$tmp/last.log"; then
  total=$((total + 1))
  echo "ok $total - the 5xx case is named in the output"
else
  total=$((total + 1))
  echo "not ok $total - the 5xx case is not named in the output" >&2
  failures=$((failures + 1))
fi
stop_stub

start_stub accept
expect nonzero "an accepted unauthenticated read fails the probe" \
  "$guard" --base-url "http://127.0.0.1:$stub_port"
stop_stub

expect nonzero "--expect-decisions without credentials is refused" \
  "$guard" --base-url "http://127.0.0.1:1" --expect-decisions

expect nonzero "an unknown argument is refused" \
  "$guard" --base-url "http://127.0.0.1:1" --nope

echo "# $total checks, $failures failed"
[ "$failures" -eq 0 ]
