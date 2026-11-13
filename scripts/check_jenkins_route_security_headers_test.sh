#!/usr/bin/env bash
# Self-test for check_jenkins_route_security_headers.sh.
#
# Every case writes a throwaway fixture into a temp "repo" (the guard derives
# its repo root from its own location, so it is copied next to the fixture) and
# asserts the guard's exit code. Run it directly; it needs yq v4 on PATH.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
guard="$script_dir/check_jenkins_route_security_headers.sh"

if ! command -v yq >/dev/null 2>&1; then
  echo "FAIL: yq v4 is required to run this self-test" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/scripts"
cp "$guard" "$tmp/scripts/"
fixture="$tmp/apps/tencentcloud/jenkins/release/staging/http-routes.yaml"
mkdir -p "$(dirname "$fixture")"

total=0
failures=0

write_route() {
  cat > "$fixture"
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

run_fixture() {
  /bin/bash "$tmp/scripts/check_jenkins_route_security_headers.sh"
}

# The merged baseline must keep passing: all three Jenkins routes are clean.
expect 0 "repository baseline passes" /bin/bash "$guard"

# A route without header filters is clean.
write_route <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: jenkins
spec:
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
EOF
expect 0 "route without ResponseHeaderModifier passes" run_fixture

# Regression 1: the original #2737 strip, all three headers removed.
write_route <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: jenkins
spec:
  rules:
    - filters:
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            remove:
              - X-Frame-Options
              - Cross-Origin-Opener-Policy
              - Content-Security-Policy
EOF
expect nonzero "removing all three protected headers fails" run_fixture

# Regression 2: lowercase header name must not bypass the guard.
write_route <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: jenkins
spec:
  rules:
    - filters:
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            remove:
              - x-frame-options
EOF
expect nonzero "lowercase x-frame-options remove fails" run_fixture

write_route <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: jenkins
spec:
  rules:
    - filters:
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            remove:
              - content-security-policy
EOF
expect nonzero "lowercase content-security-policy remove fails" run_fixture

# -x is still enforced: a different header containing a protected name passes.
write_route <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: jenkins
spec:
  rules:
    - filters:
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            remove:
              - X-Frame-Options-Report
EOF
expect 0 "unrelated header name containing protected name passes" run_fixture

# Regression 3: weakening `set` values, including lowercase keys.
write_route <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: jenkins
spec:
  rules:
    - filters:
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            set:
              X-Frame-Options: ALLOWALL
EOF
expect nonzero "set X-Frame-Options ALLOWALL fails" run_fixture

write_route <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: jenkins
spec:
  rules:
    - filters:
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            set:
              x-frame-options: ALLOWALL
EOF
expect nonzero "lowercase set x-frame-options ALLOWALL fails" run_fixture

write_route <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: jenkins
spec:
  rules:
    - filters:
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            add:
              X-Frame-Options: ALLOWALL
EOF
expect nonzero "adding a second X-Frame-Options fails" run_fixture

# A `set` that matches the controller's own strictness stays allowed.
write_route <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: jenkins
spec:
  rules:
    - filters:
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            set:
              x-frame-options: SAMEORIGIN
EOF
expect 0 "set X-Frame-Options SAMEORIGIN passes" run_fixture

# Fail-closed: unparsable YAML must not be reported as PASS.
write_route <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: jenkins
spec:
  rules: [ this is not yaml
EOF
expect nonzero "unparsable YAML fails closed" run_fixture

# Fail-closed: yq missing from PATH must not be reported as PASS.
noyq_bin="$tmp/noyq-bin"
mkdir -p "$noyq_bin"
for tool in find grep sort dirname awk; do
  ln -s "$(command -v "$tool")" "$noyq_bin/$tool"
done
expect nonzero "missing yq fails closed" env PATH="$noyq_bin" /bin/bash \
  "$tmp/scripts/check_jenkins_route_security_headers.sh"

# Fail-closed: a failing yq must abort instead of falling through to PASS.
broken_bin="$tmp/broken-yq-bin"
mkdir -p "$broken_bin"
for tool in find grep sort dirname awk; do
  ln -s "$(command -v "$tool")" "$broken_bin/$tool"
done
cat > "$broken_bin/yq" <<'EOF'
#!/bin/bash
echo "yq: error: cannot parse document" >&2
exit 1
EOF
chmod +x "$broken_bin/yq"
expect nonzero "failing yq fails closed" env PATH="$broken_bin" /bin/bash \
  "$tmp/scripts/check_jenkins_route_security_headers.sh"

# Fail-closed: a missing route tree must not pass vacuously.
rm -f "$fixture"
expect nonzero "no Jenkins route files fails closed" run_fixture

echo "# $((total - failures))/$total cases passed"
[ "$failures" -eq 0 ]
