#!/usr/bin/env bash
# Inventory Gateway routes and their explicit SecurityPolicy references.
# Requires Mike Farah yq v4 and jq. Prod2 trees are deliberately not inputs.
set -euo pipefail

repo_root=${AUTHZ_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
yq_bin=${YQ_BIN:-yq}
for tool in "$yq_bin" jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: required tool '$tool' is not installed" >&2
    exit 2
  fi
done
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

roots=("$repo_root/apps/gcp" "$repo_root/apps/tencentcloud" \
       "$repo_root/clusters/gcp" "$repo_root/clusters/tencentcloud" \
       "$repo_root/infrastructure/gcp" "$repo_root/infrastructure/tencentcloud")
objects="$tmp/objects.ndjson"
: >"$objects"

while IFS= read -r -d '' file; do
  source_path=${file#"$repo_root/"}
  "$yq_bin" eval-all -j -I 0 -N 'select(.kind != null)' "$file" 2>/dev/null | \
    jq -c --arg source "$source_path" '. + {inventorySource: $source}' >>"$objects" || {
    echo "FAIL: cannot parse $file" >&2
    exit 2
  }
done < <(find "${roots[@]}" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)

jq -s '[.[] | select(.kind == "SecurityPolicy") | {
  namespace: (.metadata.namespace // "default"),
  refs: (.spec.targetRefs // [])
}]' "$objects" >"$tmp/policies.json"

printf 'Resource inventory (static YAML, non-Prod2):\n' >&2
for kind in Gateway HTTPRoute SecurityPolicy HTTPRouteFilter NetworkPolicy; do
  count=$(jq -s --arg kind "$kind" '[.[] | select(.kind == $kind)] | length' "$objects")
  printf '  %-18s %s\n' "$kind" "$count" >&2
done
rewrites=$(jq -s '[.[] | select(.kind == "HTTPRoute") | .spec.rules[]?.filters[]? | select(.type == "URLRewrite")] | length' "$objects")
printf '  %-18s %s (inline HTTPRoute filters)\n' URLRewrite "$rewrites" >&2
printf 'Static object detail (kind, namespace, name, source):\n' >&2
jq -sr '.[] | select(.kind == "Gateway" or .kind == "HTTPRoute" or .kind == "SecurityPolicy" or .kind == "HTTPRouteFilter" or .kind == "NetworkPolicy") | [ .kind, (.metadata.namespace // "default"), (.metadata.name // "<unnamed>"), .inventorySource ] | @tsv' "$objects" >&2
jq -sr '.[] | select(.kind == "HTTPRoute") as $r | $r.spec.rules[]?.filters[]? | select(.type == "URLRewrite") | ["URLRewrite", ($r.metadata.namespace // "default"), $r.metadata.name, ((.urlRewrite.path // {})|tojson), $r.inventorySource] | @tsv' "$objects" >&2

echo "cluster,namespace,route,hostnames,paths,security_policies,status"
gaps=0
while IFS= read -r route; do
    ns=$(jq -r '.metadata.namespace // "default"' <<<"$route")
    name=$(jq -r '.metadata.name // "<unnamed>"' <<<"$route")
    hosts=$(jq -r '(.spec.hostnames // []) | join("|")' <<<"$route")
    paths=$(jq -r '[.spec.rules[]?.matches[]?.path.value // "/"] | unique | join("|")' <<<"$route")
    source=$(jq -r '.inventorySource' <<<"$route")
    policies=$(jq -r --arg ns "$ns" --arg name "$name" \
      '[.[] | select(.namespace == $ns) | .refs[]? | select(.kind == "HTTPRoute" and .name == $name)] | length' \
      "$tmp/policies.json")
    cluster=${source#apps/}; cluster=${cluster#infrastructure/}; cluster=${cluster#clusters/}; cluster=${cluster%%/*}
    status=gap
    if (( policies > 0 )); then
      status=mapped
    elif awk -F, -v c="$cluster" -v n="$ns" -v r="$name" \
      'NR > 1 && $1 == c && $2 == n && $3 == r && $4 != "" && $5 != "" && $6 == "approved" { found=1 } END { exit !found }' \
      "$repo_root/docs/authz/inventory/route-exceptions.csv"; then
      status=exception
    else
      ((gaps+=1))
    fi
    printf '"%s","%s","%s","%s","%s",%s,%s\n' \
      "$cluster" "$ns" "$name" "$hosts" "$paths" "$policies" "$status"
done < <(jq -sc '.[] | select(.kind == "HTTPRoute")' "$objects" | jq -c '.')

echo "# Unmapped HTTPRoutes: $gaps" >&2
(( gaps == 0 )) || exit 1
