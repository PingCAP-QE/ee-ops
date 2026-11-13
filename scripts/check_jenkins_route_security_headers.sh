#!/usr/bin/env bash
# Regression guard for the Jenkins browser protections. Requires yq v4.
#
# The Jenkins controller sets X-Frame-Options, Cross-Origin-Opener-Policy and
# Content-Security-Policy itself. A ResponseHeaderModifier that removes them
# turns any stored XSS in build output into a script running with an operator's
# session and lets other sites frame the UI. Prow links Jenkins builds in a new
# tab; it must not rely on the gateway stripping these headers.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
protected_headers="X-Frame-Options Cross-Origin-Opener-Policy Content-Security-Policy"

failed=0
while IFS= read -r file; do
  rel=${file#"$repo_root"/}
  removed=$(yq eval '
    select(.kind == "HTTPRoute") |
    (.spec.rules // [])[] | (.filters // [])[] |
    select(.type == "ResponseHeaderModifier") |
    (.responseHeaderModifier.remove // [])[] | .
  ' "$file" 2>/dev/null || true)

  removed_protected=""
  for header in $protected_headers; do
    if grep -qxF "$header" <<<"$removed"; then
      removed_protected="$removed_protected $header"
    fi
  done

  if [ -n "$removed_protected" ]; then
    echo "FAIL: $rel strips Jenkins browser protections:$removed_protected" >&2
    failed=1
  else
    echo "PASS: $rel passes Jenkins browser protections through"
  fi
done < <(find "$repo_root/apps" -path '*jenkins*' -name 'http-routes.yaml' | sort)

exit "$failed"
