#!/usr/bin/env bash
#
# gencred.sh mints a time-limited ServiceAccount token through the TokenRequest
# API (`kubectl create token`) and writes it into a kubeconfig for the Prow
# build cluster.
#
# It deliberately does NOT create a `kubernetes.io/service-account-token`
# Secret any more. Such a Secret carries a token that never expires and that
# anything able to read Secrets in the namespace can copy; the Kubernetes API
# server also audits every use of it as a legacy token
# (authentication.k8s.io/legacy-token-manual-secret). The token minted here is
# bound to the ServiceAccount, expires at the time printed by this script, and
# is never stored in the cluster.
#
# The generated kubeconfig embeds a live credential: never commit it, and
# rotate it before the printed expiry (see README.md).

set -euo pipefail

readonly DEFAULT_NAMESPACE=prow-test-pods
readonly DEFAULT_SERVICEACCOUNT=k8s-pod-full
readonly DEFAULT_CONTEXT=tke-pingcap-cicd
# 90 days. Rationale is in README.md ("Token lifetime and rotation").
readonly DEFAULT_DURATION=2160h

# TokenRequest bounds. The API server accepts 10 minutes .. 2^32 seconds
# (measured on the tencentcloud cluster, see README.md); keep the script's
# pre-validation in sync so a typo fails here instead of at the API call.
readonly MIN_TOKEN_SECONDS=600
readonly MAX_TOKEN_SECONDS=4294967296

usage() {
    cat <<'EOF'
Usage:
  ./gencred.sh [options] [namespace] [serviceaccount] [output]

Mints a time-limited ServiceAccount token (TokenRequest API) and writes a
single-context kubeconfig for it. No ServiceAccount token Secret is created.

Options:
  --duration=DUR
        Token lifetime as a Go duration (e.g. 2160h, 90m, 1h30m).
        Default: 2160h (90 days). Valid range: 10m .. 4294967296s.
  --context=NAME
        Context name written into the kubeconfig. It must equal the Prow
        build-cluster alias used in the job specs (`cluster:`), because Prow
        maps every kubeconfig context other than the in-cluster one to a build
        cluster of that name.
        Default: tke-pingcap-cicd
  --cleanup-old-secret[=NAME]
        Delete the legacy Secret that holds the previous non-expiring token
        (default NAME: <serviceaccount>-token). Deleting the Secret invalidates
        that old token immediately, so run this only after the new kubeconfig
        has been published and the Prow components have been restarted.
  -h, --help
        Show this help.

Positional arguments (all optional, kept for backwards compatibility):
  namespace       default: prow-test-pods
  serviceaccount  default: k8s-pod-full
  output          default: <namespace>-<serviceaccount>.conf

The former 4th and 5th positional arguments (token_secret, context) are gone:
no token Secret is created, and the context is now set with --context=NAME.

The script assumes the current kubectl context points to the target cluster.
It only calls the TokenRequest subresource: nothing is written to the cluster,
and the token stops working at its expiry.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

decode_base64() {
    if base64 -d >/dev/null 2>&1 <<<""; then
        base64 -d
    else
        base64 -D
    fi
}

# Print the number of seconds in a Go duration made of integer components
# (2160h, 90m, 1h30m, 45s). Returns non-zero for anything else.
duration_to_seconds() {
    local rest=$1 seconds=0 number unit
    [[ -n $rest ]] || return 1
    while [[ -n $rest ]]; do
        number=${rest%%[hms]*}
        [[ -n $number && $number =~ ^[0-9]+$ ]] || return 1
        unit=${rest:${#number}:1}
        rest=${rest:${#number}+1}
        case $unit in
            h) seconds=$((seconds + number * 3600)) ;;
            m) seconds=$((seconds + number * 60)) ;;
            s) seconds=$((seconds + number)) ;;
            *) return 1 ;;
        esac
    done
    echo "$seconds"
}

main() {
    local ns=$DEFAULT_NAMESPACE
    local account=$DEFAULT_SERVICEACCOUNT
    local output=""
    local context=$DEFAULT_CONTEXT
    local duration=$DEFAULT_DURATION
    local cleanup_old_secret=0
    local old_secret=""
    local -a positionals=()

    while (($# > 0)); do
        case "$1" in
            -h | --help)
                usage
                return 0
                ;;
            --duration)
                (($# >= 2)) || die "--duration needs a value"
                duration=$2
                shift 2
                ;;
            --duration=*)
                duration=${1#*=}
                shift
                ;;
            --context)
                (($# >= 2)) || die "--context needs a value"
                context=$2
                shift 2
                ;;
            --context=*)
                context=${1#*=}
                shift
                ;;
            --cleanup-old-secret)
                cleanup_old_secret=1
                shift
                ;;
            --cleanup-old-secret=*)
                cleanup_old_secret=1
                old_secret=${1#*=}
                shift
                ;;
            --)
                shift
                positionals+=("$@")
                break
                ;;
            -*)
                echo "ERROR: unknown option: $1" >&2
                usage >&2
                return 2
                ;;
            *)
                positionals+=("$1")
                shift
                ;;
        esac
    done

    if ((${#positionals[@]} > 3)); then
        die "unexpected extra argument(s): ${positionals[*]:3}
The 'token_secret' positional argument no longer exists (no token Secret is
created) and 'context' moved to --context=NAME. See --help."
    fi
    if ((${#positionals[@]} >= 1)); then ns=${positionals[0]}; fi
    if ((${#positionals[@]} >= 2)); then account=${positionals[1]}; fi
    if ((${#positionals[@]} >= 3)); then output=${positionals[2]}; fi
    if [[ -z $output ]]; then output=${ns}-${account}.conf; fi
    if [[ -z $duration ]]; then die "--duration may not be empty"; fi
    if [[ -z $context ]]; then die "--context may not be empty"; fi

    local duration_seconds
    duration_seconds=$(duration_to_seconds "$duration") ||
        die "invalid --duration '$duration': use a Go duration such as 2160h, 90m or 1h30m"
    ((duration_seconds >= MIN_TOKEN_SECONDS)) ||
        die "token lifetime must be at least 10 minutes (got '$duration')"
    ((duration_seconds <= MAX_TOKEN_SECONDS)) ||
        die "token lifetime must be at most $MAX_TOKEN_SECONDS seconds (got '$duration')"

    if ! kubectl -n "$ns" get sa/"$account" >/dev/null; then
        die "ServiceAccount $ns/$account not found: is the current kubectl context the target cluster?"
    fi

    local token_and_expiry sa_token expires_at
    token_and_expiry=$(kubectl -n "$ns" create token "$account" \
        --duration="$duration" \
        -o go-template='{{.status.token}} {{.status.expirationTimestamp}}')
    sa_token=${token_and_expiry%% *}
    expires_at=${token_and_expiry##* }
    if [[ -z $sa_token || -z $expires_at || $sa_token == "$token_and_expiry" ]]; then
        die "unexpected output from 'kubectl create token' (expected token and expiry)"
    fi

    local kube_server kube_ca
    kube_server=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
    kube_ca=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

    # The kubeconfig embeds a bearer token: keep it readable by the owner only.
    umask 077

    kubectl config set-cluster "$context" \
        --server="$kube_server" \
        --certificate-authority=<(printf '%s' "$kube_ca" | decode_base64) \
        --embed-certs=true \
        --kubeconfig="$output"

    kubectl config set-credentials "$account" \
        --token="$sa_token" \
        --kubeconfig="$output"

    kubectl config set-context "$context" \
        --cluster="$context" \
        --user="$account" \
        --namespace="$ns" \
        --kubeconfig="$output"

    kubectl config use-context "$context" --kubeconfig="$output" >/dev/null

    # Fail before anything is published if the minted token cannot do the job it
    # is generated for.
    local can_create
    if ! can_create=$(kubectl --kubeconfig="$output" --context="$context" -n "$ns" \
        auth can-i create pods 2>&1); then
        die "could not verify the generated kubeconfig: $can_create"
    fi
    if [[ $can_create != "yes" ]]; then
        die "the generated kubeconfig cannot create pods in '$ns' (auth can-i: $can_create);
check that the ServiceAccount Role/RoleBinding from rbac.yaml are applied"
    fi

    if ((cleanup_old_secret)); then
        local secret_name=${old_secret:-${account}-token}
        if kubectl -n "$ns" get secret/"$secret_name" >/dev/null 2>&1; then
            kubectl -n "$ns" delete secret/"$secret_name"
            echo "deleted legacy token Secret $ns/$secret_name: the previous non-expiring token is now invalid"
        else
            echo "legacy token Secret $ns/$secret_name not found, nothing to clean up"
        fi
    elif kubectl -n "$ns" get secret/"${account}-token" >/dev/null 2>&1; then
        echo "NOTE: legacy token Secret $ns/${account}-token still exists and its token never expires."
        echo "      Delete it once the new kubeconfig is live: ./gencred.sh --cleanup-old-secret"
    fi

    echo "wrote kubeconfig to $output (context: $context, namespace: $ns, serviceaccount: $account)"
    echo "the token expires at $expires_at (lifetime: $duration)"
    echo "publish it to gcp_prow_external_clusters_kubeconfig and restart the Prow components before then (see README.md)"
}

main "$@"
