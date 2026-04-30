#!/usr/bin/env bash

set -euo pipefail

if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR - yq is required"
  exit 1
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "${repo_root}"

violations=0

while IFS= read -r -d '' file; do
  while IFS=$'\t' read -r kind api_version; do
    [[ -z "${kind}" || "${kind}" == "null" ]] && continue
    [[ -z "${api_version}" || "${api_version}" == "null" ]] && continue

    expected=""

    case "${kind}" in
      GitRepository|HelmRepository)
        if [[ "${api_version}" == source.toolkit.fluxcd.io/* ]]; then
          expected="source.toolkit.fluxcd.io/v1"
        fi
        ;;
      Kustomization)
        if [[ "${api_version}" == kustomize.toolkit.fluxcd.io/* ]]; then
          expected="kustomize.toolkit.fluxcd.io/v1"
        fi
        ;;
      Alert|Provider)
        if [[ "${api_version}" == notification.toolkit.fluxcd.io/* ]]; then
          expected="notification.toolkit.fluxcd.io/v1beta3"
        fi
        ;;
      HelmRelease)
        if [[ "${api_version}" == helm.toolkit.fluxcd.io/* ]]; then
          expected="helm.toolkit.fluxcd.io/v2beta2"
        fi
        ;;
    esac

    if [[ -n "${expected}" && "${api_version}" != "${expected}" ]]; then
      echo "ERROR - ${file}: ${kind} uses ${api_version}, expected ${expected}"
      violations=1
    fi
  done < <(yq eval -N 'select(.kind != null and .apiVersion != null) | [.kind, .apiVersion] | @tsv' "${file}")
done < <(find clusters/gcp apps/gcp infrastructure/gcp -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)

if [[ "${violations}" -ne 0 ]]; then
  exit 1
fi

echo "INFO - GCP Flux API versions match the PR1 targets"
