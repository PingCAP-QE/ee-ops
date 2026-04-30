#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: flux_gcp_preflight.sh --min-k8s <major.minor> --max-k8s <major.minor> [--context <kubectl-context>] [--allow-non-gke]

Checks that:
  1. the connected cluster is running a Kubernetes version supported by the target Flux release
  2. Flux CRDs no longer store the deprecated API versions removed by the next upgrade phase
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR - missing required command: $1"
    exit 1
  fi
}

version_ge() {
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$2" ]]
}

version_le() {
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$2" ]]
}

compare_arrays() {
  local left="$1"
  local right="$2"
  [[ "${left}" == "${right}" ]]
}

context=""
min_k8s=""
max_k8s=""
require_gke=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)
      context="$2"
      shift 2
      ;;
    --min-k8s)
      min_k8s="$2"
      shift 2
      ;;
    --max-k8s)
      max_k8s="$2"
      shift 2
      ;;
    --allow-non-gke)
      require_gke=0
      shift
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

if [[ -z "${min_k8s}" || -z "${max_k8s}" ]]; then
  echo "ERROR - --min-k8s and --max-k8s are required"
  usage
  exit 1
fi

if ! version_le "${min_k8s}" "${max_k8s}"; then
  echo "ERROR - --min-k8s must be lower than or equal to --max-k8s"
  exit 1
fi

require_command kubectl

kubectl_args=()
if [[ -n "${context}" ]]; then
  kubectl_args+=(--context "${context}")
fi

version_json=$(kubectl "${kubectl_args[@]}" get --raw /version)
git_version=$(printf '%s' "${version_json}" | sed -n 's/.*"gitVersion":"\([^"]*\)".*/\1/p')
major=$(printf '%s' "${version_json}" | sed -n 's/.*"major":"\([^"]*\)".*/\1/p')
minor_raw=$(printf '%s' "${version_json}" | sed -n 's/.*"minor":"\([^"]*\)".*/\1/p')
minor=${minor_raw%%[^0-9]*}

if [[ -z "${git_version}" || -z "${major}" || -z "${minor}" ]]; then
  echo "ERROR - unable to parse the Kubernetes server version"
  exit 1
fi

server_minor="${major}.${minor}"

echo "INFO - Connected cluster version: ${git_version} (${server_minor})"

if [[ "${require_gke}" -eq 1 && "${git_version}" != *-gke.* ]]; then
  echo "ERROR - expected a GKE server version, got ${git_version}"
  exit 1
fi

if ! version_ge "${server_minor}" "${min_k8s}"; then
  echo "ERROR - cluster version ${server_minor} is lower than the supported minimum ${min_k8s}"
  exit 1
fi

if ! version_le "${server_minor}" "${max_k8s}"; then
  echo "ERROR - cluster version ${server_minor} is higher than the supported maximum ${max_k8s}"
  exit 1
fi

echo "INFO - Cluster version is within the requested support window"

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

check_stored_versions gitrepositories.source.toolkit.fluxcd.io v1
check_stored_versions kustomizations.kustomize.toolkit.fluxcd.io v1
check_stored_versions alerts.notification.toolkit.fluxcd.io v1beta3
check_stored_versions providers.notification.toolkit.fluxcd.io v1beta3
check_stored_versions helmreleases.helm.toolkit.fluxcd.io v2beta2

if [[ "${violations}" -ne 0 ]]; then
  exit 1
fi

echo "INFO - Flux CRD storedVersions are ready for the next GCP upgrade phase"
