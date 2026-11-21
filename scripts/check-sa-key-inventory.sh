#!/usr/bin/env bash
# Guard for the static service-account key register
# (docs/credential-rotation/sa-key-inventory.md).
#
# GCP service-account keys never expire and carry no owner, so the register in
# Git is the only thing that can enforce rotation. This guard is the enforcement
# point and fails closed:
#
#   * a missing register, a register without rows, or an unreadable row is an
#     error, never a silent pass;
#   * every row needs an Owner and a real Created date (YYYY-MM-DD). Placeholders
#     (`TBD`, `TODO`, `?`, `<...>`) are reported as PENDING and fail: a register
#     that cannot say when a key was created cannot enforce anything;
#   * a key id that appears twice fails, so a key cannot be registered twice and
#     then rotated in one place only;
#   * a key older than its declared Max age (days) fails;
#   * coverage is cross-checked against the repository, so deleting a row cannot
#     make the guard quieter: every GCP store that authenticates with a static
#     key (`secretAccessKeySecretRef`) and every identity listed in the broker's
#     `broker-clients` policy must have a row.
#
# Usage: check-sa-key-inventory.sh [--file PATH] [--today YYYY-MM-DD]
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
inventory="$repo_root/docs/credential-rotation/sa-key-inventory.md"
today=$(date -u +%F)

usage() {
  cat <<'EOF'
usage: check-sa-key-inventory.sh [--file PATH] [--today YYYY-MM-DD]

  --file PATH      register to validate (default: docs/credential-rotation/sa-key-inventory.md)
  --today DATE     reference date for the max-age check (default: today, UTC)
  -h, --help       show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --file)
      inventory=${2:?--file needs a path}
      shift 2
      ;;
    --today)
      today=${2:?--today needs a date}
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR - unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR - yq v4 is required to read the GCP store manifests" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR - python3 is required to validate the register" >&2
  exit 1
fi
if [ ! -f "$inventory" ]; then
  echo "FAIL: register not found: $inventory" >&2
  exit 1
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# Static-key GCP stores in the tree, as <cluster>/<namespace>/<secret>.
# The cluster comes from the path (infrastructure/<cluster>/...), the namespace
# and Secret from the store's own secretAccessKeySecretRef.
#
# The yq expression must stay on one physical line: the CI pin is yq v4.6.1, and
# it mis-parses an expression that starts on a later line (`namespace` resolves,
# `name` becomes null). The self-test covers this.
: >"$workdir/stores"
while IFS= read -r file; do
  rel=${file#"$repo_root"/}
  cluster=${rel#infrastructure/}
  cluster=${cluster%%/*}
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    printf '%s/%s\n' "$cluster" "$ref" >>"$workdir/stores"
  done < <(yq eval --no-doc 'select(.kind == "ClusterSecretStore" or .kind == "SecretStore") | select(.spec.provider.gcpsm.auth.secretRef.secretAccessKeySecretRef != null) | .spec.provider.gcpsm.auth.secretRef.secretAccessKeySecretRef | .namespace + "/" + .name' "$file")
done < <(find "$repo_root/infrastructure" -type f -name '*.yaml' | sort)

# Identities allowed to call the public broker endpoint; each one holds a key.
policy="$repo_root/apps/gcp/github-token-broker/security-policy.yaml"
: >"$workdir/clients"
if [ -f "$policy" ]; then
  # Single physical line for the same yq v4.6.1 reason as the store expression.
  yq eval --no-doc 'select(.kind == "SecurityPolicy") | (.spec.authorization.rules // [])[] | select(.name == "broker-clients") | (.principal.jwt.claims // [])[] | select(.name == "email") | (.values // [])[]' "$policy" >"$workdir/clients"
fi

python3 - "$inventory" "$today" "$workdir/stores" "$workdir/clients" <<'PY'
import datetime
import re
import sys

inventory, today_raw, stores_path, clients_path = sys.argv[1:5]

try:
    today = datetime.date.fromisoformat(today_raw)
except ValueError:
    print(f"ERROR - --today is not YYYY-MM-DD: {today_raw!r}", file=sys.stderr)
    sys.exit(2)

PLACEHOLDER = re.compile(r"^(?:tbd|todo|xxx|pending|\?+|<.*>)$", re.IGNORECASE)
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

with open(inventory, encoding="utf-8") as handle:
    lines = handle.read().splitlines()

errors = []
pending = []
rows = []

def cells_of(line):
    return [cell.strip() for cell in line.strip().strip("|").split("|")]

for number, line in enumerate(lines, start=1):
    stripped = line.strip()
    if not (stripped.startswith("|") and stripped.endswith("|")):
        continue
    cells = cells_of(line)
    if not cells or cells[0].lower().startswith("key id"):
        continue
    if all(re.fullmatch(r":?-{3,}:?", cell) for cell in cells):
        continue
    rows.append((number, cells))

if not rows:
    print(f"FAIL: {inventory}: no register rows found", file=sys.stderr)
    sys.exit(1)

seen_ids = {}
parsed = []
for number, cells in rows:
    where = f"line {number}"
    if len(cells) != 6:
        errors.append(
            f"{where}: expected 6 columns "
            "(Key ID | Service account | Used by | Owner | Created | Max age (days)), "
            f"found {len(cells)}"
        )
        continue
    key_id, service_account, used_by, owner, created, max_age = cells
    tokens = [token for token in re.split(r"[,;\s]+", used_by) if token]
    identity = where
    if key_id and not PLACEHOLDER.match(key_id):
        identity = key_id
    elif service_account and not PLACEHOLDER.match(service_account):
        identity = service_account
    elif tokens:
        identity = tokens[0]
    label = f"{where} ({identity})"
    issues_before = len(errors) + len(pending)

    if not owner or PLACEHOLDER.match(owner):
        errors.append(f"{label}: Owner is missing")
    if not created or PLACEHOLDER.match(created):
        pending.append(
            f"{label}: Created is missing (read it from "
            "`gcloud iam service-accounts keys list --format='table(name,validAfterTime)'`)"
        )
    elif not DATE.match(created):
        errors.append(f"{label}: Created is not YYYY-MM-DD: {created!r}")
    else:
        created_date = datetime.date.fromisoformat(created)
        if created_date > today:
            errors.append(f"{label}: Created {created} is in the future")
        if not max_age.isdigit():
            errors.append(f"{label}: Max age is not a number of days: {max_age!r}")
        else:
            limit = int(max_age)
            if limit < 1 or limit > 365:
                errors.append(f"{label}: Max age must be 1..365 days, found {limit}")
            age = (today - created_date).days
            if age > limit:
                errors.append(
                    f"{label}: key is {age} days old, past its {limit}-day max age "
                    "- rotate it and record the new key"
                )

    if key_id and not PLACEHOLDER.match(key_id):
        if key_id in seen_ids:
            errors.append(
                f"{label}: key id {key_id} is already registered at line {seen_ids[key_id]}"
            )
        else:
            seen_ids[key_id] = number

    parsed.append((number, cells, label))

    if len(errors) + len(pending) == issues_before:
        print(f"PASS: {label} is complete")
    else:
        print(f"SEE ABOVE: {label} is not usable yet")

# Coverage. Both lists come from the repository, not from the register, so
# removing a row is always detected.
def read_list(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return [item.strip() for item in handle if item.strip()]
    except FileNotFoundError:
        return []

stores = read_list(stores_path)
clients = read_list(clients_path)

used_by_tokens = set()
client_cells = set()
for _, cells, _ in parsed:
    for token in re.split(r"[,;\s]+", cells[2]):
        if token:
            used_by_tokens.add(token)
    client_cells.add(cells[1].lower())

for store in stores:
    if store not in used_by_tokens:
        errors.append(
            f"unregistered: {store} authenticates with a static service-account key "
            "but no row lists it under 'Used by'"
        )
    else:
        print(f"PASS: {store} is registered")

for client in clients:
    if client.lower() not in client_cells:
        errors.append(
            f"unregistered: {client} can call the broker but has no key row "
            "(add its key to the register)"
        )
    else:
        print(f"PASS: {client} is registered")

if pending:
    print(
        "PENDING: the register is missing data that CI cannot invent "
        "(fill it in the same change that touches the key):",
        file=sys.stderr,
    )
    for item in pending:
        print(f"  - {item}", file=sys.stderr)

if errors:
    print("FAIL: the service-account key register is not clean:", file=sys.stderr)
    for item in errors:
        print(f"  - {item}", file=sys.stderr)
    sys.exit(1)

if pending:
    sys.exit(1)

print(f"PASS: {len(rows)} registered keys, no duplicates, none past its max age")
PY
