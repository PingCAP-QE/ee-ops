#!/usr/bin/env bash
# Self-test for check_tibuild_image_sync_regex.sh.
#
# Every case writes throwaway fixtures into a temp "repo" (the guard derives its
# repo root from its own location, so it is copied next to the fixtures) and
# asserts the guard's exit code. Run it directly; it needs python3 on PATH.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
guard="$script_dir/check_tibuild_image_sync_regex.sh"

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is required to run this self-test" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/scripts"
cp "$guard" "$tmp/scripts/"

gcp="$tmp/apps/gcp/tibuild/v2/external-secret-config.yaml"
prod2="$tmp/apps/prod2/tibuild/v2/external-secret-config.yaml"
mkdir -p "$(dirname "$gcp")" "$(dirname "$prod2")"

# source_regx/target_regx as they must be written: every literal dot escaped.
good_source='^(hub\.pingcap\.net|us-docker\.pkg\.dev/pingcap-testing-account/(hotfix|hub))/(pingcap|tikv)/[\w-/]+:v\d+\.\d+\.\d+-\d{8,}.*$'
good_target='^((docker\.io/)?pingcap/[\w-]+|gcr\.io/pingcap-public/dbaas/[\w-]+):v\d+\.\d+\.\d+-\d{8,}.*$'

# The two defects this guard exists for, spelled out instead of derived: bash
# parameter expansion mangles backslashes, and a silent no-op substitution would
# make the case pass for the wrong reason.
bad_source='^(hub\.pingcap\.net|us-docker.pkg.dev/pingcap-testing-account/(hotfix|hub))/(pingcap|tikv)/[\w-/]+:v\d+\.\d+\.\d+-\d{8,}.*$'
bad_target='^((docker.io/)?pingcap/[\w-]+|gcr\.io/pingcap-public/dbaas/[\w-]+):v\d+\.\d+\.\d+-\d{8,}.*$'
unanchored_source='^(hub\.pingcap\.net|us-docker\.pkg\.dev/pingcap-testing-account/(hotfix|hub))/(pingcap|tikv)/[\w-/]+:v\d+\.\d+\.\d+-\d{8,}.*'

write_fixtures() {
  local source=$1 target=$2
  local body
  body=$(cat <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: v2-config
spec:
  target:
    template:
      data:
        config.yaml: |
          image_sync:
            source_regx: '${source}'
            target_regx: '${target}'
            polling_rate: "10s"
EOF
)
  printf '%s\n' "$body" >"$gcp"
  printf '%s\n' "$body" >"$prod2"
}

total=0
failed=0

# expect <0|1> <description> [--] [setup commands run before the guard]
expect() {
  local want=$1 desc=$2
  shift 2
  total=$((total + 1))
  local out rc
  set +e
  out=$(cd "$tmp" && bash "$tmp/scripts/check_tibuild_image_sync_regex.sh" 2>&1)
  rc=$?
  set -e
  if { [ "$want" -eq 0 ] && [ "$rc" -eq 0 ]; } ||
     { [ "$want" -ne 0 ] && [ "$rc" -ne 0 ]; }; then
    echo "ok   $desc"
  else
    echo "FAIL $desc (want exit $want, got $rc)"
    echo "$out" | sed 's/^/     /'
    failed=$((failed + 1))
  fi
}

# 1. The shape this repo actually ships.
write_fixtures "$good_source" "$good_target"
expect 0 "escaped allowlist passes"

# 2. The defect this guard exists for: unescaped dots in the GAR host.
write_fixtures "$bad_source" "$good_target"
expect 1 "unescaped us-docker.pkg.dev is rejected"

# 3. Same defect on the publish side: docker.io/target_regx left unescaped.
write_fixtures "$good_source" "$bad_target"
expect 1 "unescaped target registry is rejected"

# 4. A pattern that is missing entirely cannot be checked, so it fails closed.
python3 - "$gcp" "$prod2" <<'PY'
import sys
from pathlib import Path

for arg in sys.argv[1:]:
    path = Path(arg)
    kept = [line for line in path.read_text().splitlines() if "source_regx" not in line]
    path.write_text("\n".join(kept) + "\n")
PY
expect 1 "missing source_regx is rejected"

# 5. Anchoring: an unanchored allowlist matches anywhere in a reference.
write_fixtures "$unanchored_source" "$good_target"
expect 1 "source_regx without the trailing anchor is rejected"

# 6. Both clusters must carry the allowlist.
write_fixtures "$good_source" "$good_target"
rm "$prod2"
expect 1 "missing prod2 config is rejected"

echo
if [ "$failed" -ne 0 ]; then
  echo "FAIL: $failed of $total cases failed" >&2
  exit 1
fi
echo "PASS: $total cases"
