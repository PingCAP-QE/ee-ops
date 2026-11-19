#!/usr/bin/env bash
# Self-test for scripts/eso-scope-inventory.sh.
#
# The inventory is a security-relevant report, so the test drives the real
# script against a fixture repository and asserts the parts that are easy to get
# wrong: Flux targetNamespace, postBuild.substitute, nested Kustomization
# walking, store separation, and the documentation drift guard.
set -o errexit
set -o nounset
set -o pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
inventory=${script_dir}/eso-scope-inventory.sh

for tool in kustomize yq python3; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "ERROR - ${tool} is required" >&2
    exit 1
  fi
done

workdir=$(mktemp -d)
if [[ -z "${ESO_TEST_KEEP:-}" ]]; then
  trap 'rm -rf "${workdir}"' EXIT
fi

failures=0

pass() { printf 'PASS - %s\n' "$1"; }
fail() {
  printf 'FAIL - %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_contains() {
  local description=$1 haystack=$2 needle=$3
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    pass "${description}"
  else
    fail "${description}: expected to find '${needle}'"
  fi
}

assert_not_contains() {
  local description=$1 haystack=$2 needle=$3
  if printf '%s' "${haystack}" | grep -qF -- "${needle}"; then
    fail "${description}: did not expect to find '${needle}'"
  else
    pass "${description}"
  fi
}

write_file() {
  local path=$1
  mkdir -p "$(dirname "${path}")"
  cat >"${path}"
}

# build_fixture <root>
# Minimal GitOps tree: a cluster kustomization without a kustomization.yaml
# (Flux synthesises one), a nested Flux Kustomization for the store, an app path
# that needs postBuild.substitute, and a path that needs targetNamespace.
build_fixture() {
  local root=$1

  write_file "${root}/clusters/gcp/00-infrastructure.yaml" <<'YAML'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure
  namespace: flux-system
spec:
  path: ./infrastructure/gcp
  sourceRef:
    kind: GitRepository
    name: flux-system
YAML

  write_file "${root}/clusters/gcp/01-apps.yaml" <<'YAML'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  path: ./apps/gcp
  sourceRef:
    kind: GitRepository
    name: flux-system
YAML

  write_file "${root}/infrastructure/gcp/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - external-secrets
YAML

  write_file "${root}/infrastructure/gcp/external-secrets/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - post.yaml
YAML

  write_file "${root}/infrastructure/gcp/external-secrets/post.yaml" <<'YAML'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: external-secrets-post
  namespace: flux-system
spec:
  path: ./infrastructure/gcp/external-secrets/post
  sourceRef:
    kind: GitRepository
    name: flux-system
YAML

  write_file "${root}/infrastructure/gcp/external-secrets/post/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - store.yaml
YAML

  write_file "${root}/infrastructure/gcp/external-secrets/post/store.yaml" <<'YAML'
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: ee-gcp-sm
spec:
  conditions:
    - namespaceSelector:
        matchExpressions:
          - key: kubernetes.io/metadata.name
            operator: In
            values:
              - apps
              - prow-test-pods
              - tibuild
              - unused-ns
  provider:
    gcpsm:
      projectID: example
YAML

  write_file "${root}/apps/gcp/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - plain
  - job-ns.yaml
  - target.yaml
  - other-store
YAML

  # Plain namespace transform.
  write_file "${root}/apps/gcp/plain/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: apps
resources:
  - es.yaml
YAML

  write_file "${root}/apps/gcp/plain/es.yaml" <<'YAML'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: plain
spec:
  secretStoreRef:
    name: ee-gcp-sm
    kind: ClusterSecretStore
  data:
    - secretKey: value
      remoteRef:
        key: apps_secret
YAML

  # Namespace comes from a Flux postBuild.substitute variable, exactly like
  # apps/gcp/prow/post/job-ns in the real tree.
  write_file "${root}/apps/gcp/job-ns/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${JOB_NAMESPACE}
resources:
  - es.yaml
YAML

  write_file "${root}/apps/gcp/job-ns/es.yaml" <<'YAML'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: job
spec:
  secretStoreRef:
    name: ee-gcp-sm
    kind: ClusterSecretStore
  data:
    - secretKey: value
      remoteRef:
        key: jobs_secret
YAML

  # Nested Flux Kustomization that sets targetNamespace and the substitute.
  write_file "${root}/apps/gcp/job-ns.yaml" <<'YAML'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: job-ns
  namespace: flux-system
spec:
  path: ./apps/gcp/job-ns
  sourceRef:
    kind: GitRepository
    name: flux-system
  postBuild:
    substitute:
      JOB_NAMESPACE: prow-test-pods
YAML

  # Namespace from Flux targetNamespace, no namespace: in kustomize.
  write_file "${root}/apps/gcp/target/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - es.yaml
YAML

  write_file "${root}/apps/gcp/target/es.yaml" <<'YAML'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: targeted
spec:
  secretStoreRef:
    name: ee-gcp-sm
    kind: ClusterSecretStore
  data:
    - secretKey: value
      remoteRef:
        key: targeted_secret
YAML

  write_file "${root}/apps/gcp/target.yaml" <<'YAML'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: target
  namespace: flux-system
spec:
  path: ./apps/gcp/target
  targetNamespace: tibuild
  sourceRef:
    kind: GitRepository
    name: flux-system
YAML

  # Uses a namespaced SecretStore, so it is outside the ee-gcp-sm blast radius.
  write_file "${root}/apps/gcp/other-store/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: apps
resources:
  - es.yaml
YAML

  write_file "${root}/apps/gcp/other-store/es.yaml" <<'YAML'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: other
spec:
  secretStoreRef:
    name: gcp-sm-github-actions
    kind: SecretStore
  data:
    - secretKey: value
      remoteRef:
        key: other_secret
YAML

  write_file "${root}/docs/external-secrets-scope.md" <<'YAML'
# Fixture

<!-- BEGIN GENERATED: eso-scope (scripts/eso-scope-inventory.sh) -->
<!-- END GENERATED: eso-scope -->
YAML
}

fixture="${workdir}/fixture"
build_fixture "${fixture}"

if ! rendered=$(bash "${inventory}" --repo "${fixture}" 2>"${workdir}/render.err"); then
  fail "render should succeed on a consistent fixture (stderr: $(cat "${workdir}/render.err"))"
fi

assert_contains "summary counts the store consumers" "${rendered}" \
  '| `gcp` | 4 | 3 | 1 | 3 | 3 |'
assert_contains "kustomize namespace: is honoured" "${rendered}" '| `apps` | CORE | 1 | `apps_secret` |'
assert_contains "Flux postBuild.substitute is honoured" "${rendered}" \
  '| `prow-test-pods` | CI | 1 | `jobs_secret` |'
assert_not_contains "substitute placeholders do not leak into namespaces" "${rendered}" '${JOB_NAMESPACE}'
assert_contains "Flux targetNamespace is honoured" "${rendered}" '| `tibuild` | APP | 1 | `targeted_secret` |'
assert_contains "allowlisted namespace without consumers is reported" "${rendered}" \
  'allowlisted namespaces without any ExternalSecret: `unused-ns`'
assert_contains "namespaced SecretStore consumers stay out of the matrix" "${rendered}" \
  '`SecretStore/gcp-sm-github-actions` × 1'
assert_contains "nested Flux Kustomizations are walked" "${rendered}" '`ee-gcp-sm`'
assert_contains "store allowlist is read from the rendered store" "${rendered}" '| CORE | `ee-gcp-sm` | `apps` |'

# A consumer outside the allowlist would be rejected by the store: the report
# must fail instead of quietly listing it.
rogue="${workdir}/rogue"
cp -R "${fixture}" "${rogue}"
sed -i.bak 's/^              - unused-ns$/              - unused-ns/' "${rogue}/infrastructure/gcp/external-secrets/post/store.yaml"
rm -f "${rogue}/infrastructure/gcp/external-secrets/post/store.yaml.bak"
sed -i.bak 's/^namespace: apps$/namespace: rogue/' "${rogue}/apps/gcp/plain/kustomization.yaml"
rm -f "${rogue}/apps/gcp/plain/kustomization.yaml.bak"
if bash "${inventory}" --repo "${rogue}" >"${workdir}/rogue.md" 2>"${workdir}/rogue.err"; then
  fail "render must fail when a consumer is missing from the store allowlist"
else
  pass "render fails when a consumer is missing from the store allowlist"
fi
assert_contains "the allowlist violation names the namespace" "$(cat "${workdir}/rogue.md")" \
  'namespaces consume the store but are missing from its allowlist: `rogue`'

# Drift guard: --write records the block, --check accepts it, and any stale copy
# is rejected.
bash "${inventory}" --repo "${fixture}" --write >/dev/null 2>&1
if bash "${inventory}" --repo "${fixture}" --check >/dev/null 2>"${workdir}/check.err"; then
  pass "--check accepts a freshly written document"
else
  fail "--check rejected a freshly written document (stderr: $(cat "${workdir}/check.err"))"
fi
sed -i.bak 's/| `gcp` | 4 | 3 | 1 | 3 | 3 |/| `gcp` | 9 | 9 | 9 | 9 | 9 |/' \
  "${fixture}/docs/external-secrets-scope.md"
rm -f "${fixture}/docs/external-secrets-scope.md.bak"
if bash "${inventory}" --repo "${fixture}" --check >/dev/null 2>"${workdir}/drift.err"; then
  fail "--check must reject a document that drifted from the manifests"
else
  pass "--check rejects a document that drifted from the manifests"
fi
assert_contains "drift report points at the refresh command" "$(cat "${workdir}/drift.err")" \
  'Run '"'"'scripts/eso-scope-inventory.sh --write'"'"' and commit the result.'

if [[ "${failures}" -ne 0 ]]; then
  printf '\n%d assertion(s) failed\n' "${failures}" >&2
  exit 1
fi

echo "INFO - eso scope inventory self-test passed"
