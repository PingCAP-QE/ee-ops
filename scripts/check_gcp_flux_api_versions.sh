#!/usr/bin/env bash

set -euo pipefail

if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR - yq is required"
  exit 1
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "${repo_root}"

expected_api_version() {
  local cluster=$1
  local kind=$2
  local api_version=$3

  # prod2 runs Flux v2.2.3; gcp and tencentcloud run Flux v2.8.8.
  case "${cluster}" in
    prod2)
      case "${kind}" in
        GitRepository|HelmRepository)
          [[ "${api_version}" == source.toolkit.fluxcd.io/* ]] && echo "source.toolkit.fluxcd.io/v1beta2"
          ;;
        Kustomization)
          [[ "${api_version}" == kustomize.toolkit.fluxcd.io/* ]] && echo "kustomize.toolkit.fluxcd.io/v1beta2"
          ;;
        Alert|Provider)
          [[ "${api_version}" == notification.toolkit.fluxcd.io/* ]] && echo "notification.toolkit.fluxcd.io/v1beta3"
          ;;
        HelmRelease)
          [[ "${api_version}" == helm.toolkit.fluxcd.io/* ]] && echo "helm.toolkit.fluxcd.io/v2beta1"
          ;;
      esac
      ;;
    gcp|tencentcloud)
      case "${kind}" in
        GitRepository|HelmRepository)
          [[ "${api_version}" == source.toolkit.fluxcd.io/* ]] && echo "source.toolkit.fluxcd.io/v1"
          ;;
        Kustomization)
          [[ "${api_version}" == kustomize.toolkit.fluxcd.io/* ]] && echo "kustomize.toolkit.fluxcd.io/v1"
          ;;
        Alert|Provider)
          [[ "${api_version}" == notification.toolkit.fluxcd.io/* ]] && echo "notification.toolkit.fluxcd.io/v1beta3"
          ;;
        HelmRelease)
          [[ "${api_version}" == helm.toolkit.fluxcd.io/* ]] && echo "helm.toolkit.fluxcd.io/v2"
          ;;
      esac
      ;;
  esac
}

check_file() {
  local cluster=$1
  local file=$2
  local records
  local file_violations=0

  # Do not use process substitution here: its exit status is otherwise
  # ignored by bash, which can turn a yq parse error into a false pass.
  if ! records=$(yq eval -N 'select(.kind != null and .apiVersion != null) | (.kind + "|" + .apiVersion)' "${file}"); then
    echo "ERROR - ${file}: unable to parse YAML with yq"
    return 1
  fi

  while IFS='|' read -r kind api_version; do
    [[ -z "${kind}" || -z "${api_version}" ]] && continue

    expected=$(expected_api_version "${cluster}" "${kind}" "${api_version}")
    if [[ -n "${expected}" && "${api_version}" != "${expected}" ]]; then
      echo "ERROR - ${file}: ${kind} uses ${api_version}, expected ${expected} for ${cluster}"
      file_violations=1
    fi
  done <<< "${records}"

  return "${file_violations}"
}

violations=0
for cluster in prod2 gcp tencentcloud; do
  while IFS= read -r -d '' file; do
    if ! check_file "${cluster}" "${file}"; then
      violations=1
    fi
  done < <(find "clusters/${cluster}" "apps/${cluster}" "infrastructure/${cluster}" \
    -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)
done

if [[ "${violations}" -ne 0 ]]; then
  exit 1
fi

echo "INFO - Flux API versions match the configured cluster targets"
