#!/usr/bin/env bash
# Regression guard for the GKE `prow` RBAC finding: no non-default ClusterRole
# may be bound to Group `system:authenticated`. Only the upstream default
# bindings (system:basic-user, system:discovery, system:public-info-viewer) may
# target that group.
#
# Two of the original findings come from the remote tektoncd/operator
# release.yaml, so the primary check renders apps/gcp/tekton/setup the same way
# kustomize-controller does. The scan over the checked-in apps/gcp manifests
# also catches local copies and still works without network access. Operand RBAC
# that the Tekton operator generates at runtime cannot be seen here: keep such
# operands out of GitOps (see apps/gcp/tekton/setup/kustomization.yaml).
set -o errexit

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tekton_setup=apps/gcp/tekton/setup
app_dir=apps/gcp

# ClusterRoles bound to Group system:authenticated by the upstream default
# bindings; any other role bound to that group is a finding.
allowed_roles="system:basic-user system:discovery system:public-info-viewer"

if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR - yq is required" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR - python3 is required" >&2
  exit 1
fi

workdir=$(mktemp -d)
trap 'rm -rf "${workdir}"' EXIT
records="${workdir}/bindings.jsonl"

# Render every ClusterRoleBinding as one compact JSON record. CI pins yq
# v4.6.1, which predates the array/any helpers (and needs explicit file
# arguments), so the subject check runs in python3 instead.
select_bindings() {
  yq eval --no-doc -j -I=0 '
    select(tag == "!!map")
    | select(.kind == "ClusterRoleBinding")
    | {"name": .metadata.name, "role": (.roleRef.name // ""), "subjects": (.subjects // [])}
  ' "$@"
}

audit() {
  local source=$1
  python3 - "${source}" "${allowed_roles}" "${records}" <<'PY'
import json
import sys

source, allowed_roles, records_path = sys.argv[1], set(sys.argv[2].split()), sys.argv[3]

violations = 0
with open(records_path) as records:
    for line in records:
        if not line.strip():
            continue
        binding = json.loads(line)
        authenticated = [
            subject
            for subject in binding.get("subjects") or []
            if subject.get("kind") == "Group"
            and subject.get("name") == "system:authenticated"
        ]
        if not authenticated or binding["role"] in allowed_roles:
            continue
        print(
            "FAIL - {}: ClusterRoleBinding {} binds non-default ClusterRole {} "
            "to Group system:authenticated".format(
                source, binding["name"], binding["role"]
            ),
            file=sys.stderr,
        )
        violations = 1

if violations == 0:
    print("PASS - {}: no non-default ClusterRole bound to Group system:authenticated".format(source))
sys.exit(violations)
PY
}

violations=0

# 1. Rendered overlay: the authoritative view, including the remote operator
# release. A render failure (offline workstation) falls back to check 2.
if command -v kustomize >/dev/null 2>&1; then
  if kustomize build --load-restrictor=LoadRestrictionsNone \
    "${repo_root}/${tekton_setup}" > "${workdir}/rendered.yaml" 2> "${workdir}/render.log"; then
    select_bindings "${workdir}/rendered.yaml" > "${records}"
    if ! audit "${tekton_setup} (rendered)"; then
      violations=1
    fi
  else
    echo "WARN - cannot render ${tekton_setup}, relying on the static scan:" >&2
    sed -n '1,3p' "${workdir}/render.log" >&2
  fi
else
  echo "WARN - kustomize is not installed, relying on the static scan" >&2
fi

# 2. Checked-in manifests: catches ClusterRoleBindings added locally.
: > "${records}"
while IFS= read -r file; do
  select_bindings "${file}" >> "${records}"
done < <(find "${repo_root}/${app_dir}" -type f \( -name '*.yaml' -o -name '*.yml' \) \
  -exec grep -lF "ClusterRoleBinding" {} +)
if ! audit "${app_dir} manifests"; then
  violations=1
fi

if [[ "${violations}" -ne 0 ]]; then
  echo "ERROR - Group system:authenticated must only be bound to the default ClusterRoles: ${allowed_roles}" >&2
  exit 1
fi
echo "INFO - Group system:authenticated is only bound to the default ClusterRoles"
