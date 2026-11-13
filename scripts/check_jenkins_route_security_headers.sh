#!/usr/bin/env bash
# Regression guard for the Jenkins browser protections. Requires yq v4.
#
# The Jenkins controller sets X-Frame-Options, Cross-Origin-Opener-Policy and
# Content-Security-Policy itself. A ResponseHeaderModifier that removes them
# turns any stored XSS in build output into a script running with an operator's
# session and lets other sites frame the UI. Prow links Jenkins builds in a new
# tab; it must not rely on the gateway stripping these headers.
#
# The guard fails closed:
#   * a missing or failing yq is a hard error, never a silent pass;
#   * header names are compared case-insensitively, because HTTP header names
#     are case-insensitive and Envoy lowercases them (`x-frame-options`);
#   * `set` (and `add`) entries are inspected too, not only `remove`: replacing
#     the controller's value with a weaker one, or appending a second value,
#     defeats the protection just as well. Values are allow-listed, so unknown
#     spellings fail closed;
#   * finding no Jenkins route files at all is a failure, so a renamed path
#     cannot make the guard pass vacuously.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
protected_headers="X-Frame-Options Cross-Origin-Opener-Policy Content-Security-Policy"

if ! command -v yq >/dev/null 2>&1; then
  echo "FAIL: yq v4 is required to inspect HTTPRoute header filters" >&2
  exit 1
fi

# is_safe_set_value <canonical header> <value>
# Allow-list only the values that are at least as strict as what the Jenkins
# controller sends. Content-Security-Policy has no generic safe replacement, so
# any `set` of it is treated as a regression.
is_safe_set_value() {
  local header=$1 value=$2
  value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
  case "$header" in
    X-Frame-Options)
      [ "$value" = "sameorigin" ] || [ "$value" = "deny" ]
      ;;
    Cross-Origin-Opener-Policy)
      [ "$value" = "same-origin" ]
      ;;
    *)
      return 1
      ;;
  esac
}

failed=0
files=0
while IFS= read -r file; do
  files=$((files + 1))
  rel=${file#"$repo_root"/}

  # Emit one `<action>\t<header>\t<value>` line per modifier entry. The YAML is
  # rendered through a fixed synthetic document because the yq pinned in CI
  # (v4.6.1) predates `to_entries`, so map entries are split by awk instead.
  entries=$(yq eval '
    select(.kind == "HTTPRoute") |
    (.spec.rules // [])[] | (.filters // [])[] |
    select(.type == "ResponseHeaderModifier") |
    {
      "remove": (.responseHeaderModifier.remove // []),
      "set": (.responseHeaderModifier.set // {}),
      "add": (.responseHeaderModifier.add // {})
    }
  ' "$file" | awk '
    BEGIN { state = "" }
    /^remove:/ { state = "remove"; next }
    /^set:/ { state = "set"; next }
    /^add:/ { state = "add"; next }
    state == "remove" && /^[[:space:]]+-[[:space:]]/ {
      line = $0
      sub(/^[[:space:]]+-[[:space:]]*/, "", line)
      gsub(/"/, "", line)
      print "remove\t" line "\t"
      next
    }
    (state == "set" || state == "add") && /^[[:space:]]+[^[:space:]]/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sep = index(line, ": ")
      if (sep == 0) next
      name = substr(line, 1, sep - 1)
      value = substr(line, sep + 2)
      gsub(/"/, "", name)
      if (value ~ /^".*"$/) value = substr(value, 2, length(value) - 2)
      print state "\t" name "\t" value
    }
  ')

  problems=""
  while IFS=$'\t' read -r action name value; do
    [ -n "$name" ] || continue

    # Header names are matched case-insensitively; -x keeps the match on the
    # whole name so a header that merely contains a protected name is skipped.
    canonical=""
    for header in $protected_headers; do
      if printf '%s\n' "$name" | grep -qixF -- "$header"; then
        canonical=$header
        break
      fi
    done
    [ -n "$canonical" ] || continue

    case "$action" in
      remove)
        problems="$problems remove:$canonical"
        ;;
      set)
        if is_safe_set_value "$canonical" "$value"; then
          continue
        fi
        problems="$problems set:$canonical=$value"
        ;;
      add)
        problems="$problems add:$canonical=$value"
        ;;
    esac
  done <<<"$entries"

  if [ -n "$problems" ]; then
    echo "FAIL: $rel strips or weakens Jenkins browser protections:$problems" >&2
    failed=1
  else
    echo "PASS: $rel passes Jenkins browser protections through"
  fi
done < <(find "$repo_root/apps" -path '*jenkins*' -name 'http-routes.yaml' | sort)

# A renamed/moved route tree would otherwise make the guard pass vacuously.
if [ "$files" -eq 0 ]; then
  echo "FAIL: no Jenkins http-routes.yaml files found under apps" >&2
  failed=1
fi

exit "$failed"
