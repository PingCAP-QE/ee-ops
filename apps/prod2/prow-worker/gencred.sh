#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./gencred.sh [namespace] [serviceaccount] [output] [token_secret]

Defaults:
  namespace:      prow-test-pods
  serviceaccount: k8s-pod-full
  output:         prow-test-pods-k8s-pod-full.conf
  token_secret:   k8s-pod-full-token

This script assumes the current kubectl context points to the target cluster.
It creates a service-account-token Secret if needed, then writes a kubeconfig
scoped to the given namespace and ServiceAccount.
EOF
}

decode_base64() {
    if base64 -d >/dev/null 2>&1 <<<""; then
        base64 -d
    else
        base64 -D
    fi
}

wait_for_secret_token() {
    local ns=$1
    local secret_name=$2

    for _ in $(seq 1 30); do
        local token
        token=$(kubectl -n "$ns" get secret "$secret_name" -o jsonpath='{.data.token}' 2>/dev/null || true)
        if [[ -n "$token" ]]; then
            return 0
        fi
        sleep 1
    done

    echo "timed out waiting for token in secret $secret_name" >&2
    return 1
}

main() {
    if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
        usage
        return 0
    fi

    local ns=${1:-prow-test-pods}
    local account=${2:-k8s-pod-full}
    local output=${3:-${ns}-${account}.conf}
    local token_secret=${4:-${account}-token}
    local cluster_name="${ns}-${account}"

    kubectl -n "$ns" get sa/"$account" >/dev/null

    kubectl -n "$ns" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${token_secret}
  annotations:
    kubernetes.io/service-account.name: ${account}
type: kubernetes.io/service-account-token
EOF

    wait_for_secret_token "$ns" "$token_secret"

    local sa_token
    sa_token=$(kubectl -n "$ns" get secret/"$token_secret" -o jsonpath='{.data.token}' | decode_base64)
    local kube_server
    kube_server=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
    local kube_ca
    kube_ca=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

    kubectl config set-cluster "$cluster_name" \
        --server="$kube_server" \
        --certificate-authority=<(printf '%s' "$kube_ca" | decode_base64) \
        --embed-certs=true \
        --kubeconfig="$output"

    kubectl config set-credentials "$account" \
        --token="$sa_token" \
        --kubeconfig="$output"

    kubectl config set-context "$cluster_name" \
        --cluster="$cluster_name" \
        --user="$account" \
        --namespace="$ns" \
        --kubeconfig="$output"

    kubectl config use-context "$cluster_name" --kubeconfig="$output" >/dev/null

    echo "wrote kubeconfig to $output"
}

main "$@"
