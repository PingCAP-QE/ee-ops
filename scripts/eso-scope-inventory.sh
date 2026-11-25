#!/usr/bin/env bash
# Inventory of every namespace that can read GCP Secret Manager through the
# `ee-gcp-sm` ClusterSecretStore, per cluster and per planned trust domain.
#
# The store's own credential decides what is readable, so the blast radius of a
# namespace that may use the store equals *every* secret the store's GCP service
# account can access. This script renders what that means today: it walks the
# Flux Kustomization tree of each cluster and builds every path the way
# kustomize-controller does (kustomize `namespace:`, Flux `targetNamespace` and
# `postBuild.substitute` applied), then reports the ExternalSecrets that
# reference the store and the GCP secret names they pull.
#
# `docs/external-secrets-scope.md` embeds the generated block between the
# `BEGIN GENERATED` / `END GENERATED` markers. `--check` regenerates it and
# fails when the committed copy drifted (wired into CI), `--write` refreshes it.
#
# Requirements: kustomize, yq (v4), python3.
set -o errexit
set -o nounset
set -o pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "${script_dir}/.." && pwd)
doc_path=docs/external-secrets-scope.md
clusters="gcp tencentcloud prod2"
store_name=ee-gcp-sm
max_depth=8

usage() {
  cat <<'EOF'
Usage: scripts/eso-scope-inventory.sh [--check|--write|--render] [--repo DIR]

  --render  Print the generated markdown block to stdout (default).
  --check   Fail when docs/external-secrets-scope.md differs from the generated
            block. This is the CI drift guard.
  --write   Rewrite the generated block in docs/external-secrets-scope.md.
  --repo    Repository to inventory (default: the checkout holding this script).

The inventory is derived from the in-repo Flux Kustomization tree, so it needs
no cluster access.
EOF
}

mode=render
while [[ $# -gt 0 ]]; do
  case "$1" in
    --render) mode="render" ;;
    --check) mode="check" ;;
    --write) mode="write" ;;
    --repo)
      [[ $# -ge 2 ]] || { echo "ERROR - --repo needs a value" >&2; exit 2; }
      repo_root=$(cd "$2" && pwd)
      shift
      ;;
    --repo=*)
      repo_root=$(cd "${1#--repo=}" && pwd)
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR - unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

for tool in kustomize yq python3; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "ERROR - ${tool} is required" >&2
    exit 1
  fi
done

cd "${repo_root}"

# yq renames the JSON output flag over time: CI pins v4.6.x where it is `-j`,
# newer releases deprecated it in favour of `-o=json`.
yq_json_flag=-j
if yq eval --help 2>&1 | grep -q -- '--output-format'; then
  yq_json_flag=-o=json
fi

workdir=$(mktemp -d)
es_records="${workdir}/external-secrets.jsonl"
store_records="${workdir}/cluster-secret-stores.jsonl"
warnings="${workdir}/warnings.txt"
: >"${es_records}"
: >"${store_records}"
: >"${warnings}"

cleanup() {
  # ESO_SCOPE_INVENTORY_DEBUG_DIR keeps the intermediate records for debugging.
  if [[ -n "${ESO_SCOPE_INVENTORY_DEBUG_DIR:-}" ]]; then
    mkdir -p "${ESO_SCOPE_INVENTORY_DEBUG_DIR}"
    cp "${es_records}" "${store_records}" "${warnings}" "${ESO_SCOPE_INVENTORY_DEBUG_DIR}/" 2>/dev/null || true
  fi
  rm -rf "${workdir}"
}
trap cleanup EXIT

warn() {
  printf '%s\n' "$*" >>"${warnings}"
  printf 'WARN - %s\n' "$*" >&2
}

# apply_substitutions <substitute-json-object>
# Replace ${KEY} with the Flux postBuild.substitute value, the same way
# kustomize-controller renders the built manifests.
apply_substitutions() {
  local substitute_json=$1
  if [[ "${substitute_json}" == "{}" || -z "${substitute_json}" ]]; then
    cat
    return 0
  fi
  python3 -c '
import json
import sys

mapping = json.loads(sys.argv[1])
data = sys.stdin.buffer.read().decode("utf-8")
for key, value in mapping.items():
    data = data.replace("${" + key + "}", str(value))
sys.stdout.write(data)
' "${substitute_json}"
}

# build_path <dir>
# Render one Flux Kustomization path. When the directory has no kustomization
# file, kustomize-controller synthesises one from every manifest directly in it;
# mirror that instead of failing.
build_path() {
  local path=$1
  if [[ -f "${path}/kustomization.yaml" || -f "${path}/kustomization.yml" || -f "${path}/Kustomization" ]]; then
    kustomize build --load-restrictor LoadRestrictionsNone "${path}"
    return
  fi

  # Copy the manifests next to the generated kustomization so the build stays
  # inside its root (older kustomize releases are strict about absolute paths).
  local overlay
  overlay=$(mktemp -d "${workdir}/overlay.XXXXXX")
  local file
  for file in "${path}"/*.yaml "${path}"/*.yml; do
    [[ -f "${file}" ]] || continue
    cp "${file}" "${overlay}/"
  done
  local resources=""
  for file in "${overlay}"/*.yaml "${overlay}"/*.yml; do
    [[ -f "${file}" ]] || continue
    resources="${resources}  - $(basename "${file}")\n"
  done
  {
    printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n'
    printf '%b' "${resources}"
  } >"${overlay}/kustomization.yaml"
  kustomize build --load-restrictor LoadRestrictionsNone "${overlay}"
}

# collect_objects <cluster> <target-namespace> <output-tsv>
# Record the ExternalSecrets and ClusterSecretStores of one built Flux
# Kustomization path, and emit the nested Flux Kustomizations that still have to
# be built. The nested records are unit-separator separated: a tab is IFS
# whitespace, so empty columns would collapse.
collect_objects() {
  local cluster=$1
  local target_namespace=$2
  local kust_out=$3
  python3 -c '
import json
import sys

cluster, target_namespace, es_out, store_out, kust_out, warnings_out = sys.argv[1:7]


def metadata(obj):
    return obj.get("metadata") or {}


def dig(mapping, *path):
    current = mapping
    for key in path:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current


def secret_keys(spec):
    keys = []
    for entry in spec.get("data") or []:
        key = dig(entry or {}, "remoteRef", "key")
        if key:
            keys.append(key)
    for entry in spec.get("dataFrom") or []:
        key = dig(entry or {}, "extract", "key")
        if key:
            keys.append(key)
    return keys


def uses_metadata_query(spec):
    return any((entry or {}).get("find") for entry in spec.get("dataFrom") or [])


with open(es_out, "a", encoding="utf-8") as es, \
        open(store_out, "a", encoding="utf-8") as store, \
        open(kust_out, "a", encoding="utf-8") as kust:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        kind = obj.get("kind")
        spec = obj.get("spec") or {}

        if kind == "ExternalSecret":
            reference = spec.get("secretStoreRef") or {}
            es.write(json.dumps({
                "cluster": cluster,
                "namespace": target_namespace or metadata(obj).get("namespace") or "default",
                "name": metadata(obj).get("name"),
                "store_kind": reference.get("kind") or "SecretStore",
                "store_name": reference.get("name") or "",
                "keys": secret_keys(spec),
                "find": 1 if uses_metadata_query(spec) else 0,
            }, sort_keys=True) + "\n")
            continue

        if kind == "ClusterSecretStore":
            namespaces = []
            unsupported = []
            for condition in spec.get("conditions") or []:
                selector = dig(condition or {}, "namespaceSelector") or {}
                if selector.get("matchLabels"):
                    unsupported.append("matchLabels")
                for expression in selector.get("matchExpressions") or []:
                    expression = expression or {}
                    operator = expression.get("operator") or ""
                    key = expression.get("key") or ""
                    if key == "kubernetes.io/metadata.name" and operator == "In":
                        namespaces.extend(expression.get("values") or [])
                    else:
                        unsupported.append("%s %s" % (key or "matchLabels", operator or "-"))
            store.write(json.dumps({
                "cluster": cluster,
                "name": metadata(obj).get("name"),
                "apiVersion": obj.get("apiVersion") or "",
                "namespaces": namespaces,
                "unsupported": sorted(set(unsupported)),
            }, sort_keys=True) + "\n")
            continue

        if kind != "Kustomization":
            continue
        if not (obj.get("apiVersion") or "").startswith("kustomize.toolkit.fluxcd.io"):
            continue
        source = spec.get("sourceRef") or {}
        if source.get("kind") != "GitRepository" or source.get("name") != "flux-system":
            continue
        path = spec.get("path") or ""
        if not path or path.startswith("http://") or path.startswith("https://"):
            continue
        if dig(spec, "postBuild", "substituteFrom"):
            # postBuild also supports variables from ConfigMaps/Secrets; those
            # cannot be resolved from the repository alone, so surface it instead
            # of rendering a document with unknown placeholders.
            with open(warnings_out, "a", encoding="utf-8") as warning:
                warning.write(
                    "%s: %s uses postBuild.substituteFrom; values from ConfigMaps/Secrets are not resolved\n"
                    % (cluster, path))
        kust.write("\x1f".join([
            path,
            target_namespace or spec.get("targetNamespace") or "",
            json.dumps(dig(spec, "postBuild", "substitute") or {}, sort_keys=True),
        ]) + "\n")
' "${cluster}" "${target_namespace}" "${es_records}" "${store_records}" "${kust_out}" "${warnings}"
}

# walk_cluster <cluster>
# Breadth-first walk of the Flux Kustomization tree, mirroring what
# kustomize-controller reconciles. Paths outside the repository, or applied by a
# source other than the in-repo GitRepository, are not built.
walk_cluster() {
  local cluster=$1
  local root=clusters/${cluster}

  if [[ ! -d "${root}" ]]; then
    warn "${cluster}: ${root} does not exist, skipped"
    return 0
  fi

  local -a paths=("./${root}")
  local -a overrides=("")
  local -a substitutes=("{}")
  local -a depths=("0")
  local visited=" "
  local i=0

  while [[ "${i}" -lt "${#paths[@]}" ]]; do
    local path=${paths[${i}]}
    local override=${overrides[${i}]}
    local substitute=${substitutes[${i}]}
    local depth=${depths[${i}]}
    i=$((i + 1))

    local key="${path}|${override}|${substitute}"
    case "${visited}" in
      *" ${key} "*) continue ;;
    esac
    visited="${visited}${key} "

    if [[ ! -d "${path}" ]]; then
      warn "${cluster}: ${path} is declared by a Flux Kustomization but missing from the repository"
      continue
    fi

    local built="${workdir}/build.$$.${i}.yaml"
    if ! build_path "${path}" >"${built}" 2>"${workdir}/kustomize.err"; then
      warn "${cluster}: kustomize build ${path} failed: $(head -2 "${workdir}/kustomize.err" | tr '\n' ' ')"
      rm -f "${built}"
      continue
    fi

    if [[ "${substitute}" != "{}" ]]; then
      apply_substitutions "${substitute}" <"${built}" >"${built}.subst"
      mv "${built}.subst" "${built}"
    fi

    local kust_out="${workdir}/kustomizations.$$.${i}.tsv"
    yq eval --no-doc "${yq_json_flag}" -I=0 '.' "${built}" \
      | collect_objects "${cluster}" "${override}" "${kust_out}"
    rm -f "${built}"

    if [[ -f "${kust_out}" ]] && [[ "${depth}" -lt "${max_depth}" ]]; then
      while IFS=$'\x1f' read -r child_path child_ns child_substitute; do
        [[ -z "${child_path}" ]] && continue
        paths+=("./${child_path#./}")
        overrides+=("${child_ns}")
        substitutes+=("${child_substitute}")
        depths+=("$((depth + 1))")
      done <"${kust_out}"
    fi
    rm -f "${kust_out}"
  done
}

walked_clusters=""
for cluster in ${clusters}; do
  if [[ -d "clusters/${cluster}" ]]; then
    walked_clusters="${walked_clusters} ${cluster}"
    walk_cluster "${cluster}"
  else
    warn "${cluster}: clusters/${cluster} does not exist, skipped"
  fi
done

render_inventory() {
  python3 - "${es_records}" "${store_records}" "${warnings}" "${clusters}" "${store_name}" <<'PY'
import json
import sys
from collections import defaultdict, OrderedDict

es_records, store_records, warnings_path, cluster_list, store_name = sys.argv[1:6]
clusters = cluster_list.split()

# Trust domain split for the store migration: one store per domain on GCP, and
# CORE plus a single extra store on TENCENTCLOUD. `JENKINS` is the controller
# namespace only; the per-repo `jenkins-*` agent namespaces get their own
# identity and store from the pingcap-qe/ee-infra External Secrets work, so they
# form the separate `JENKINS-AGENTS` domain. A namespace that is not listed here
# is reported as unassigned instead of guessed: the split drives the follow-up
# migration, so adding a namespace has to be a deliberate decision.
DOMAINS = OrderedDict([
    ("CORE", ["apps", "ee-authz", "flux-system", "github-token-broker", "infra"]),
    ("CI", ["arc-runners", "ee-cd", "prow", "prow-test-pods", "tekton-pipelines"]),
    ("JENKINS", ["jenkins"]),
    ("JENKINS-AGENTS", ["jenkins-pd", "jenkins-ticdc", "jenkins-tidb",
                        "jenkins-tiflash", "jenkins-tiflow", "jenkins-tikv"]),
    ("APP", ["cache", "chatops-lark", "cs", "dl", "dl-approval", "kafka", "tibuild", "zot"]),
])
DOMAIN_OF = {ns: domain for domain, namespaces in DOMAINS.items() for ns in namespaces}
# prod2 keeps a single store for every consumer.
SINGLE_STORE_CLUSTERS = {"prod2"}

raw_external_secrets = defaultdict(list)
for line in open(es_records, encoding="utf-8"):
    record = json.loads(line)
    raw_external_secrets[record["cluster"]].append(record)

# The same manifest can be reconciled by more than one Flux Kustomization (a
# directory that is both a kustomize resource of its parent and the path of its
# own Kustomization). Kubernetes applies that object once, so count it once and
# keep the union of the referenced secret names.
external_secrets = defaultdict(list)
for cluster, records in raw_external_secrets.items():
    merged = OrderedDict()
    for record in records:
        key = (record["namespace"], record["name"])
        if key not in merged:
            merged[key] = record
            continue
        kept = merged[key]
        kept["keys"] = sorted(set(kept["keys"]) | set(record["keys"]))
        kept["find"] = kept["find"] or record["find"]
    external_secrets[cluster] = list(merged.values())

stores = defaultdict(list)
for line in open(store_records, encoding="utf-8"):
    record = json.loads(line)
    stores[record["cluster"]].append(record)

warnings = [line.strip() for line in open(warnings_path, encoding="utf-8") if line.strip()]
findings = []
fatal_reasons = []


def scoped_records(cluster):
    return [
        record for record in external_secrets[cluster]
        if record["store_kind"] == "ClusterSecretStore" and record["store_name"] == store_name
    ]


def store_allowlist(cluster):
    matches = [store for store in stores[cluster] if store["name"] == store_name]
    if not matches:
        findings.append("%s: no `ClusterSecretStore/%s` is rendered for this cluster" % (cluster, store_name))
        return None
    if len(matches) > 1:
        findings.append("%s: more than one `ClusterSecretStore/%s` is rendered" % (cluster, store_name))
    # Only `kubernetes.io/metadata.name In [...]` can be evaluated offline. Any
    # other selector would make the allowlist wrong in an unknown direction, so
    # it fails the report instead of being dropped.
    unsupported = matches[0]["unsupported"]
    if unsupported:
        fatal_reasons.append("%s: store allowlist uses selector expressions the inventory cannot evaluate: %s" % (
            cluster, ", ".join(unsupported)))
    return set(matches[0]["namespaces"])


def target_store(cluster, domain):
    """Store that will serve one trust domain after the migration."""
    if domain == "CORE":
        return "`%s`" % store_name
    if cluster == "tencentcloud":
        # ESO 0.19 has no Workload Identity on TKE, so every non-CORE domain
        # shares one store and one static key instead of four identities.
        return "`%s-ci-app`" % store_name
    return "`%s-%s`" % (store_name, domain.lower())


def namespace_rows(cluster):
    rows = defaultdict(lambda: {"es": 0, "keys": set()})
    for record in scoped_records(cluster):
        rows[record["namespace"]]["es"] += 1
        rows[record["namespace"]]["keys"].update(record["keys"])
        if record["find"]:
            rows[record["namespace"]]["keys"].add("(metadata query, no explicit key)")
    return rows


def distinct_keys(cluster, namespaces=None):
    keys = set()
    for record in scoped_records(cluster):
        if namespaces is not None and record["namespace"] not in namespaces:
            continue
        keys.update(record["keys"])
    return keys


def markdown_list(values):
    return ", ".join("`%s`" % value for value in values) if values else "—"


out = []
write = out.append

write("### Summary")
write("")
write("| Cluster | Allowlisted namespaces | Consuming namespaces | Namespaces without consumers | ExternalSecrets | Distinct GCP secrets |")
write("| :--- | ---: | ---: | ---: | ---: | ---: |")
totals = {"allow": 0, "used": 0, "zero": 0, "es": 0, "keys": set()}
for cluster in clusters:
    allowlist = store_allowlist(cluster)
    used = {record["namespace"] for record in scoped_records(cluster)}
    keys = distinct_keys(cluster)
    zero = (allowlist - used) if allowlist is not None else set()
    if allowlist is not None:
        extra = used - allowlist
        if extra:
            fatal_reasons.append(
                "%s: namespaces consume the store but are missing from its allowlist: %s"
                % (cluster, markdown_list(sorted(extra)))
            )
    totals["allow"] += len(allowlist or ())
    totals["used"] += len(used)
    totals["zero"] += len(zero)
    totals["es"] += len(scoped_records(cluster))
    totals["keys"] |= keys
    write("| `%s` | %d | %d | %d | %d | %d |" % (
        cluster, len(allowlist or ()), len(used), len(zero), len(scoped_records(cluster)), len(keys)))
    if zero:
        findings.append(
            "%s: allowlisted namespaces without any ExternalSecret, to be dropped from the allowlist: %s"
            % (cluster, markdown_list(sorted(zero))))
write("| **Total** | **%d** | **%d** | **%d** | **%d** | **%d** |" % (
    totals["allow"], totals["used"], totals["zero"], totals["es"], len(totals["keys"])))
write("")

write("### Consumers by namespace")
write("")
for cluster in clusters:
    rows = namespace_rows(cluster)
    write("#### `%s`" % cluster)
    write("")
    if not rows:
        write("No ExternalSecret references the store.")
        write("")
        continue
    write("| Namespace | Trust domain | ExternalSecrets | GCP secret names |")
    write("| :--- | :--- | ---: | :--- |")
    for namespace in sorted(rows):
        if cluster in SINGLE_STORE_CLUSTERS:
            domain = "single store"
        else:
            domain = DOMAIN_OF.get(namespace, "**unassigned**")
        write("| `%s` | %s | %d | %s |" % (
            namespace, domain, rows[namespace]["es"], markdown_list(sorted(rows[namespace]["keys"]))))
        if "${" in namespace:
            findings.append(
                "%s: namespace `%s` still contains an unresolved postBuild substitution" % (cluster, namespace))
        elif domain == "**unassigned**":
            findings.append("%s: namespace `%s` is not assigned to a trust domain" % (cluster, namespace))
    write("")

write("### Planned trust domains")
write("")
for cluster in clusters:
    if cluster in SINGLE_STORE_CLUSTERS:
        namespaces = sorted({record["namespace"] for record in scoped_records(cluster)})
        write("`%s` keeps a single store; %d namespaces, %d distinct secret names." % (
            cluster, len(namespaces), len(distinct_keys(cluster))))
        write("")
        app_key = "gha__system__github_app_private_key"
        # One namespace can hold several ExternalSecrets that all pull the key;
        # list the namespace once per cluster, not once per ExternalSecret.
        key_holders = sorted({record["namespace"] for record in scoped_records(cluster) if app_key in record["keys"]})
        if key_holders:
            write("The same store keeps the organisation-wide GitHub App private key "
                  "(`%s`) readable from %s, so narrowing this store's GCP IAM does not "
                  "reduce that key's reach: it needs a separate store or an explicit "
                  "accepted risk." % (app_key, markdown_list(key_holders)))
            write("")
        continue
    write("#### `%s`" % cluster)
    write("")
    write("| Domain | Target store | Namespaces | ExternalSecrets | Distinct GCP secrets |")
    write("| :--- | :--- | :--- | ---: | ---: |")
    rows = namespace_rows(cluster)
    for domain, domain_namespaces in DOMAINS.items():
        present = [namespace for namespace in domain_namespaces if namespace in rows]
        target = target_store(cluster, domain)
        write("| %s | %s | %s | %d | %d |" % (
            domain, target, markdown_list(present),
            sum(rows[namespace]["es"] for namespace in present),
            len(distinct_keys(cluster, set(present)))))
    unassigned = sorted(namespace for namespace in rows if namespace not in DOMAIN_OF)
    if unassigned:
        write("| **Unassigned** | to be decided | %s | %d | %d |" % (
            markdown_list(unassigned),
            sum(rows[namespace]["es"] for namespace in unassigned),
            len(distinct_keys(cluster, set(unassigned)))))
    write("")
    if cluster == "gcp":
        write("`JENKINS-AGENTS` is served by an identity and store owned by the "
              "External Secrets work in `pingcap-qe/ee-infra`; this repository does "
              "not create that store. `JENKINS` is the controller namespace only.")
        write("")

write("### Secret index")
write("")
write("| GCP secret | Cluster | Namespaces that can read it |")
write("| :--- | :--- | :--- |")
index = defaultdict(lambda: defaultdict(set))
for cluster in clusters:
    for record in scoped_records(cluster):
        for key in record["keys"]:
            index[key][cluster].add(record["namespace"])
for key in sorted(index):
    for cluster in clusters:
        if cluster in index[key]:
            write("| `%s` | `%s` | %s |" % (
                key, cluster, markdown_list(sorted(index[key][cluster]))))
write("")

write("### ExternalSecrets using other stores")
write("")
other = defaultdict(int)
for cluster in clusters:
    for record in external_secrets[cluster]:
        if not (record["store_kind"] == "ClusterSecretStore" and record["store_name"] == store_name):
            other[(cluster, record["store_kind"], record["store_name"])] += 1
if other:
    write("Outside this inventory because they do not go through `%s`:" % store_name)
    write("")
    for (cluster, store_kind, name), count in sorted(other.items()):
        write("- `%s`: `%s/%s` × %d" % (cluster, store_kind, name, count))
else:
    write("None.")
write("")

write("### Findings")
write("")
for finding in findings + fatal_reasons:
    write("- %s" % finding)
for warning in warnings:
    write("- %s" % warning)
if not findings and not fatal_reasons and not warnings:
    write("- Allowlists match consumption and every namespace has a trust domain.")
write("")

print("\n".join(out).rstrip() + "\n", end="")
sys.exit(1 if fatal_reasons else 0)
PY
}

set +o errexit
generated_block="$(render_inventory)"
render_status=$?
set -o errexit

begin_marker='<!-- BEGIN GENERATED: eso-scope (scripts/eso-scope-inventory.sh) -->'
end_marker='<!-- END GENERATED: eso-scope -->'

extract_block() {
  python3 -c '
import sys

path, begin, end = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
start = text.find(begin)
stop = text.find(end)
if start == -1 or stop == -1 or stop < start:
    sys.exit(3)
sys.stdout.write(text[start + len(begin):stop].strip("\n") + "\n")
' "$1" "${begin_marker}" "${end_marker}"
}

case "${mode}" in
  render)
    printf '%s\n' "${generated_block}"
    exit "${render_status}"
    ;;
  check)
    if [[ ! -f "${doc_path}" ]]; then
      echo "ERROR - ${doc_path} is missing; run scripts/eso-scope-inventory.sh --write" >&2
      exit 1
    fi
    if ! extract_block "${doc_path}" >"${workdir}/committed.md"; then
      echo "ERROR - ${doc_path} is missing the generated-block markers" >&2
      exit 1
    fi
    printf '%s\n' "${generated_block}" >"${workdir}/generated.md"
    if ! diff -u "${workdir}/committed.md" "${workdir}/generated.md" >"${workdir}/scope.diff"; then
      echo "ERROR - ${doc_path} is out of date with the cluster manifests:" >&2
      cat "${workdir}/scope.diff" >&2
      echo "Run 'scripts/eso-scope-inventory.sh --write' and commit the result." >&2
      exit 1
    fi
    echo "INFO - ${doc_path} matches the generated inventory"
    exit "${render_status}"
    ;;
  write)
    if [[ ! -f "${doc_path}" ]]; then
      echo "ERROR - ${doc_path} does not exist; create it before running --write" >&2
      exit 1
    fi
    printf '%s\n' "${generated_block}" >"${workdir}/generated.md"
    python3 -c '
import sys

path, begin, end, generated = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(generated, encoding="utf-8") as handle:
    block = handle.read().rstrip("\n")
with open(path, encoding="utf-8") as handle:
    text = handle.read()
start = text.find(begin)
stop = text.find(end)
if start == -1 or stop == -1 or stop < start:
    sys.exit("ERROR - %s is missing the generated-block markers" % path)
text = text[:start + len(begin)] + "\n" + block + "\n" + text[stop:]
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
' "${doc_path}" "${begin_marker}" "${end_marker}" "${workdir}/generated.md"
    echo "INFO - updated ${doc_path}"
    exit "${render_status}"
    ;;
esac
