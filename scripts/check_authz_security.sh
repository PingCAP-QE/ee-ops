#!/usr/bin/env bash
# Initial policy-contract guard. Every statically declared non-Prod2 HTTPRoute
# must be attached to a SecurityPolicy or listed in the reviewed exception file.
set -euo pipefail
repo_root=${AUTHZ_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
yq_bin=${YQ_BIN:-yq}
coverage="$repo_root/scripts/check_authz_policy_coverage.sh"
exceptions="$repo_root/docs/authz/inventory/route-exceptions.csv"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

if [[ ! -f "$exceptions" ]]; then
  echo "FAIL: missing explicit route exception register: $exceptions" >&2
  exit 2
fi
for tool in "$yq_bin" jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: required tool '$tool' is not installed" >&2
    exit 2
  fi
done

roots=("$repo_root/apps/gcp" "$repo_root/apps/tencentcloud" \
       "$repo_root/infrastructure/gcp" "$repo_root/infrastructure/tencentcloud")
policy_count=0
while IFS= read -r -d '' file; do
  while IFS= read -r policy; do
    [[ -n "$policy" ]] || continue
    policy_count=$((policy_count + 1))
    if ! jq -e '
      def nonempty_string: type == "string" and length > 0;
      def valid_oidc:
        (.spec.oidc.provider.issuer? | nonempty_string) and
        (.spec.oidc.clientIDRef.name? | nonempty_string);
      def valid_jwt:
        (.spec.jwt.providers? | type == "array" and length > 0) and
        all(.spec.jwt.providers[];
          (.issuer? | nonempty_string) and
          (.remoteJWKS.uri? | nonempty_string) and
          (.audiences? | type == "array" and length > 0 and all(.[]; nonempty_string))
        );
      def valid_authorization:
        (.spec.authorization.defaultAction? == "Allow" or .spec.authorization.defaultAction? == "Deny") and
        (.spec.authorization.rules? | type == "array" and length > 0) and
        all(.spec.authorization.rules[]; .action == "Allow" or .action == "Deny");
      valid_oidc or valid_jwt or valid_authorization
    ' <<<"$policy" >/dev/null; then
      name=$(jq -r '.metadata.name // "<unnamed>"' <<<"$policy")
      echo "FAIL: SecurityPolicy $file ($name) has no structurally valid OIDC, JWT, or authorization contract" >&2
      exit 1
    fi
  done < <("$yq_bin" eval-all -j -I 0 -N 'select(.kind == "SecurityPolicy")' "$file" 2>/dev/null | jq -c '.')
done < <(find "${roots[@]}" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)
if (( policy_count == 0 )); then
  echo "FAIL: no SecurityPolicy contracts found in non-Prod2 manifests" >&2
  exit 1
fi
echo "PASS: $policy_count static SecurityPolicy resources have explicit authn/authz fields"

if "$coverage" >"$tmp" 2>&1; then
	cat "$tmp"
  exit 0
fi

cat "$tmp"
echo "FAIL: route-policy gaps remain; exceptions must be reviewed and enumerated before this guard can pass" >&2
exit 1
