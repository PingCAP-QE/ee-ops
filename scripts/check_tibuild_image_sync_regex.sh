#!/usr/bin/env bash
# Regression guard for the TiBuild v2 image_sync allowlists.
#
# `image_sync.source_regx` decides which source images tibuild-v2 may copy with
# the release credential into `publish.targets` (docker.io included, i.e. the
# public TiDB release channel), and `target_regx` decides where the copy may
# land. Both are RE2 patterns, so a `.` meant literally has to be written `\.`:
# an unescaped one turns `us-docker.pkg.dev` into "us-docker<any>pkg<any>dev"
# and admits a registrable look-alike host such as us-docker-pkg.dev. That is
# helix finding f-9116d762 (MEDIUM), which shipped in both clusters.
#
# The check is textual on purpose. Python's `re` cannot even compile the
# allowlist (`[\w-/]` is a legal RE2 class but an invalid Python range), and CI
# has no Go toolchain, so instead of matching sample refs against a foreign
# engine this pins the property that makes RE2 reject the look-alikes: every dot
# that is meant literally is escaped, and the pattern stays fully anchored.
#
# The patterns sit in a `config.yaml: |` block scalar, so they are read as text
# rather than through yq.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is required to run this guard" >&2
  exit 1
fi

python3 - "$repo_root" <<'PY'
import re
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])

# Both clusters render the same allowlist; a fix that only reaches one of them
# leaves the other one open.
FILES = [
    "apps/gcp/tibuild/v2/external-secret-config.yaml",
    "apps/prod2/tibuild/v2/external-secret-config.yaml",
]

# Host literals each file must keep, written with escaped dots.
SOURCE_HOSTS = [
    r"hub\.pingcap\.net",
    r"us-docker\.pkg\.dev",
]
TARGET_HOSTS = [
    r"docker\.io",
    r"gcr\.io",
]

PATTERN_RE = r"^\s*{key}:\s*'([^']+)'\s*$"


def extract(text, key):
    m = re.search(PATTERN_RE.format(key=key), text, re.MULTILINE)
    return m.group(1) if m else None


def unescaped_literal_dots(pattern):
    r"""Positions of `.` outside a character class, between two alphanumerics.

    That is the shape of a host separator (or version separator) someone meant
    literally but did not escape; in RE2 it becomes "any one character". A lone
    `.` followed by `*`/`+`/`?` is the deliberate wildcard, `\.` is escaped, and
    `[...]` is skipped.
    """
    hits = []
    in_class = False
    i = 0
    while i < len(pattern):
        ch = pattern[i]
        if ch == "\\":
            i += 2
            continue
        if ch == "[":
            in_class = True
        elif ch == "]":
            in_class = False
        elif ch == "." and not in_class:
            prev = pattern[i - 1] if i else ""
            nxt = pattern[i + 1] if i + 1 < len(pattern) else ""
            if prev.isalnum() and nxt.isalnum():
                hits.append(i)
        i += 1
    return hits


def check_pattern(label, pattern, hosts, errors):
    if pattern is None:
        errors.append(f"{label} is missing")
        return
    if not (pattern.startswith("^") and pattern.endswith("$")):
        errors.append(f"{label} must stay fully anchored (^...$/^...$): {pattern}")
    for pos in unescaped_literal_dots(pattern):
        errors.append(
            f"{label} has an unescaped dot at offset {pos}, so it also matches "
            f"a look-alike host (write it as `\\.`): {pattern}"
        )
    for host in hosts:
        if host not in pattern:
            errors.append(
                f"{label} no longer allows {host.replace(chr(92), '')} "
                f"(escaped as `{host}`): {pattern}"
            )


errors = []
for rel in FILES:
    path = repo_root / rel
    if not path.is_file():
        errors.append(f"{rel} is missing")
        continue
    text = path.read_text()
    if "image_sync:" not in text:
        errors.append(
            f"{rel} no longer configures image_sync; "
            "drop this guard together with the config block"
        )
        continue
    check_pattern(f"{rel}: source_regx", extract(text, "source_regx"),
                  SOURCE_HOSTS, errors)
    check_pattern(f"{rel}: target_regx", extract(text, "target_regx"),
                  TARGET_HOSTS, errors)

if errors:
    for err in errors:
        print(f"FAIL: {err}", file=sys.stderr)
    sys.exit(1)

for rel in FILES:
    print(f"PASS: {rel} pins image_sync source/target registry hosts")
PY
