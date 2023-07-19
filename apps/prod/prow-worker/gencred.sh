#!/usr/bin/env bash

function main() {
    local ns=$1
    local account=$2
    local saSecretName=$(kubectl -n $ns get sa/${account} -o jsonpath='{.secrets[0].name}')
    local saToken=$(kubectl -n $ns get secret/${saSecretName} -o jsonpath='{.data.token}' | base64 -d)
    local kubeServer=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
    local kubeCA=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

    kubectl config set-cluster "${ns}-${account}" --server=$kubeServer --certificate-authority=<(echo $kubeCA | base64 -d) --embed-certs=true --kubeconfig=${ns}-${account}.conf
    kubectl config set-credentials ${account} --token=$saToken --kubeconfig=${ns}-${account}.conf
    kubectl config set-context "${ns}-${account}" --cluster="${ns}-${account}" --user=${account} --namespace=$ns --kubeconfig=${ns}-${account}.conf
    kubectl config use-context "${ns}-${account}" --kubeconfig="${ns}-${account}".conf
}

main "$@"
