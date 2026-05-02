#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: flux_gcp_post_upgrade_verify.sh [--context <kubectl-context>] [--namespace <flux-namespace>]

Checks after the GCP Flux v2.7 upgrade:
  1. Flux controllers in the target namespace are rolled out
  2. Flux CRD status.storedVersions have migrated to the current storage versions
  3. `flux check` passes and no Flux resources remain NotReady
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR - missing required command: $1"
    exit 1
  fi
}

compare_arrays() {
  local left="$1"
  local right="$2"
  [[ "${left}" == "${right}" ]]
}

context=""
namespace="flux-system"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)
      context="$2"
      shift 2
      ;;
    --namespace)
      namespace="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR - unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

require_command kubectl
require_command flux

kubectl_args=()
flux_args=()

if [[ -n "${context}" ]]; then
  kubectl_args+=(--context "${context}")
  flux_args+=(--context "${context}")
fi

echo "INFO - Waiting for Flux controller deployments to be available"
for deployment in source-controller kustomize-controller helm-controller notification-controller; do
  kubectl "${kubectl_args[@]}" -n "${namespace}" rollout status "deployment/${deployment}" --timeout=5m
done

violations=0

check_stored_versions() {
  local crd="$1"
  shift

  local expected_sorted
  local actual_sorted

  expected_sorted=$(printf '%s\n' "$@" | sort | paste -sd ',' -)
  actual_sorted=$(kubectl "${kubectl_args[@]}" get crd "${crd}" -o jsonpath='{range .status.storedVersions[*]}{.}{"\n"}{end}' | sed '/^$/d' | sort | paste -sd ',' -)

  if [[ -z "${actual_sorted}" ]]; then
    echo "ERROR - ${crd}: status.storedVersions is empty"
    violations=1
    return
  fi

  if ! compare_arrays "${actual_sorted}" "${expected_sorted}"; then
    echo "ERROR - ${crd}: storedVersions=${actual_sorted}, expected=${expected_sorted}"
    violations=1
    return
  fi

  echo "INFO - ${crd}: storedVersions=${actual_sorted}"
}

echo "INFO - Verifying Flux CRD storage-version migration"
check_stored_versions buckets.source.toolkit.fluxcd.io v1
check_stored_versions gitrepositories.source.toolkit.fluxcd.io v1
check_stored_versions helmcharts.source.toolkit.fluxcd.io v1
check_stored_versions helmrepositories.source.toolkit.fluxcd.io v1
check_stored_versions ocirepositories.source.toolkit.fluxcd.io v1
check_stored_versions kustomizations.kustomize.toolkit.fluxcd.io v1
check_stored_versions helmreleases.helm.toolkit.fluxcd.io v2
check_stored_versions alerts.notification.toolkit.fluxcd.io v1beta3
check_stored_versions providers.notification.toolkit.fluxcd.io v1beta3
check_stored_versions receivers.notification.toolkit.fluxcd.io v1

if [[ "${violations}" -ne 0 ]]; then
  exit 1
fi

echo "INFO - Running flux check"
flux "${flux_args[@]}" check

echo "INFO - Checking Flux resource readiness"
not_ready=$(flux "${flux_args[@]}" get all --all-namespaces --status-selector=ready=false --no-header 2>/dev/null | sed '/^$/d')
if [[ -n "${not_ready}" ]]; then
  echo "ERROR - Found Flux resources that are not ready"
  echo "${not_ready}"
  exit 1
fi

echo "INFO - Flux resources are ready"
flux "${flux_args[@]}" get all --all-namespaces
