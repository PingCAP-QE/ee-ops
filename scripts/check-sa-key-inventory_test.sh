#!/usr/bin/env bash
# Self-test for check-sa-key-inventory.sh.
#
# The guard derives its repository root from its own location, so every case
# copies the guard into a throwaway repository with a small fixture tree
# (one static-key store, one broker client) and asserts the guard's exit code.
# The register fixture is what changes per case; `--today` pins the age check.
#
# The cases cover the failure modes the register exists for: a row that was
# deleted, a field nobody filled in, a key registered twice, and a key that
# outlived its own maximum age.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
guard="$script_dir/check-sa-key-inventory.sh"

if ! command -v yq >/dev/null 2>&1; then
  echo "FAIL: yq v4 is required to run this self-test" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is required to run this self-test" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/scripts" "$tmp/docs/credential-rotation" \
  "$tmp/infrastructure/gcp/external-secrets/post" \
  "$tmp/apps/gcp/github-token-broker"
cp "$guard" "$tmp/scripts/"

register="$tmp/docs/credential-rotation/sa-key-inventory.md"
today=2026-11-13

# One static-key store: gcp/infra/gcp-sm-sa-secret.
cat >"$tmp/infrastructure/gcp/external-secrets/post/css-ee-gcp-sm.yaml" <<'EOF'
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: ee-gcp-sm
spec:
  provider:
    gcpsm:
      auth:
        secretRef:
          secretAccessKeySecretRef:
            namespace: infra
            name: gcp-sm-sa-secret
            key: secret-access-credentials
      projectID: pingcap-testing-account
EOF

# One broker client identity.
cat >"$tmp/apps/gcp/github-token-broker/security-policy.yaml" <<'EOF'
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: github-token-broker-jwt
spec:
  authorization:
    defaultAction: Deny
    rules:
      - name: broker-clients
        action: Allow
        principal:
          jwt:
            provider: google
            claims:
              - name: email
                values:
                  - gh-broker-client-macos@pingcap-testing-account.iam.gserviceaccount.com
EOF

store_row='| 1a2b3c4d5e6f | TBD | gcp/infra/gcp-sm-sa-secret | sig-root-approvers | 2026-10-01 | 90 |'
client_row='| 9f8e7d6c5b4a | gh-broker-client-macos@pingcap-testing-account.iam.gserviceaccount.com | github-token-broker external endpoint | sig-root-approvers | 2026-10-01 | 90 |'
header='| Key ID | Service account | Used by | Owner | Created | Max age (days) |
| :--- | :--- | :--- | :--- | :--- | ---: |'

write_register() {
  {
    echo "# Static service-account key register"
    echo
    echo "Fixture register."
    echo
    echo "$header"
    printf '%s\n' "$@"
  } >"$register"
}

total=0
failures=0

# expect <0|nonzero> <label> [guard arguments...]
expect() {
  local want=$1 label=$2
  shift 2
  local status=0
  bash "$tmp/scripts/check-sa-key-inventory.sh" --today "$today" "$@" \
    >"$tmp/last.log" 2>&1 || status=$?
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

# A complete register passes: this is the shape a real rotation produces.
write_register "$store_row" "$client_row"
expect 0 "complete register passes"

# Removing the store row must fail: the store still authenticates with a key.
write_register "$client_row"
expect nonzero "deleting the store row fails (coverage)"

# Removing the client row must fail: the client still holds a key.
write_register "$store_row"
expect nonzero "deleting the broker client row fails (coverage)"

# Nobody filled in the owner.
write_register \
  '| 1a2b3c4d5e6f | TBD | gcp/infra/gcp-sm-sa-secret |  | 2026-10-01 | 90 |' "$client_row"
expect nonzero "missing owner fails"

# A TBD creation date is a pending row, not a pass.
write_register \
  '| 1a2b3c4d5e6f | TBD | gcp/infra/gcp-sm-sa-secret | sig-root-approvers | TBD | 90 |' "$client_row"
expect nonzero "TBD creation date fails"

# The same key id twice means one copy was never updated after a rotation.
write_register "$store_row" "$client_row" \
  '| 9f8e7d6c5b4a | another@pingcap-testing-account.iam.gserviceaccount.com | second consumer | sig-root-approvers | 2026-10-01 | 90 |'
expect nonzero "duplicate key id fails"

# 2026-01-01 + 90 days is well before 2026-11-13.
write_register \
  '| 1a2b3c4d5e6f | TBD | gcp/infra/gcp-sm-sa-secret | sig-root-approvers | 2026-01-01 | 90 |' "$client_row"
expect nonzero "key past its max age fails"

# A limit outside 1..365 days is a typo or an attempt to disable the check.
write_register \
  '| 1a2b3c4d5e6f | TBD | gcp/infra/gcp-sm-sa-secret | sig-root-approvers | 2026-10-01 | 999 |' "$client_row"
expect nonzero "max age outside 1..365 fails"

# A row the parser cannot read must not be skipped silently.
write_register \
  '| 1a2b3c4d5e6f | TBD | gcp/infra/gcp-sm-sa-secret | sig-root-approvers | 2026-10-01 |' "$client_row"
expect nonzero "row with a missing column fails"

# No rows at all is a failure, not a vacuous pass.
write_register
expect nonzero "empty register fails"

# An explicit --file that does not exist is an error, not a pass.
total=$((total + 1))
if bash "$tmp/scripts/check-sa-key-inventory.sh" --today "$today" \
  --file "$tmp/does-not-exist.md" >"$tmp/last.log" 2>&1; then
  echo "not ok $total - missing register file fails (exit 0)" >&2
  failures=$((failures + 1))
else
  echo "ok $total - missing register file fails"
fi

echo
if [ "$failures" -ne 0 ]; then
  echo "FAIL: $failures of $total cases failed" >&2
  exit 1
fi
echo "PASS: $total cases"
