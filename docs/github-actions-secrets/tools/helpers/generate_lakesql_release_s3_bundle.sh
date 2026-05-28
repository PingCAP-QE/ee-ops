#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_PATH="./docs/github-actions-secrets/tools/helpers/generate_lakesql_release_s3_bundle.sh"
readonly MODE_GENERATE="generate"
readonly MODE_VALIDATE_BUNDLE="validate-bundle"

readonly DEFAULT_GPG_NAME_REAL="LakeSQL Package Signing"
readonly DEFAULT_GPG_NAME_EMAIL="lakesql-release@tidbcloud.com"
readonly DEFAULT_GPG_EXPIRE_DATE="2y"
readonly DEFAULT_APK_PASSPHRASE=""

readonly FILE_GPG_PRIVATE_ASC="lakesql-package-signing.asc"
readonly FILE_GPG_PUBLIC_ASC="lakesql-package-signing.public.asc"
readonly FILE_GPG_PRIVATE_B64="lakesql-package-signing.asc.b64"
readonly FILE_GPG_FINGERPRINT="lakesql-package-signing.fingerprint.txt"
readonly FILE_APK_PRIVATE_KEY="lakesql-packages.rsa"
readonly FILE_APK_PUBLIC_KEY="lakesql-packages.rsa.pub"
readonly FILE_APK_PRIVATE_B64="lakesql-packages.rsa.b64"
readonly FILE_APK_PUBLIC_B64="lakesql-packages.rsa.pub.b64"
readonly FILE_BUNDLE_JSON="lakesql-release-s3-bundle.json"

readonly BUNDLE_FIELD_GPG_PRIVATE_KEY_B64="gpg_private_key_b64"
readonly BUNDLE_FIELD_GPG_PASSPHRASE="gpg_passphrase"
readonly BUNDLE_FIELD_APK_PRIVATE_KEY_B64="apk_private_key_b64"
readonly BUNDLE_FIELD_APK_PUBLIC_KEY_B64="apk_public_key_b64"
readonly BUNDLE_FIELD_APK_PASSPHRASE="apk_passphrase"

MODE="${MODE_GENERATE}"
OUTPUT_DIR=""
BUNDLE_JSON_PATH=""
GPG_PASSPHRASE="${GPG_PASSPHRASE:-}"
GPG_NAME_REAL="${DEFAULT_GPG_NAME_REAL}"
GPG_NAME_EMAIL="${DEFAULT_GPG_NAME_EMAIL}"
GPG_EXPIRE_DATE="${DEFAULT_GPG_EXPIRE_DATE}"
GPG_BIN=""
WORK_DIR=""
GNUPGHOME=""

log_info() {
  printf 'INFO - %s\n' "$*" >&2
}

die() {
  printf 'ERROR - %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Generate or validate the LakeSQL release-s3 signing bundle.

Usage:
  ${SCRIPT_PATH} [options]
  ${SCRIPT_PATH} ${MODE_VALIDATE_BUNDLE} --bundle-json PATH

Modes:
  default                 Generate signing materials and a bundle JSON file.
  ${MODE_VALIDATE_BUNDLE} Validate an existing bundle JSON file.

Generate options:
  --output-dir DIR        Directory to write generated files into.
                          Default: ./lakesql-release-s3-secrets-<timestamp>
  --gpg-passphrase VALUE  Reuse an existing GPG passphrase instead of generating one.
  --gpg-name-real VALUE   GPG key real name.
                          Default: ${DEFAULT_GPG_NAME_REAL}
  --gpg-name-email VALUE  GPG key email.
                          Default: ${DEFAULT_GPG_NAME_EMAIL}
  --gpg-expire VALUE      GPG key expiration passed to GnuPG.
                          Default: ${DEFAULT_GPG_EXPIRE_DATE}

Validate options:
  --bundle-json PATH      Path to an existing ${FILE_BUNDLE_JSON} file to validate.

General options:
  --help                  Show this help.

Notes:
- The generated APK private key is intentionally unencrypted, so the current
  LakeSQL release workflow can use it with abuild-sign for APKINDEX signing.
- The generated bundle sets "apk_passphrase" to an empty string for the same reason.
EOF
}

require_command() {
  local command_name="$1"

  command -v "${command_name}" >/dev/null 2>&1 || die "required command not found: ${command_name}"
}

resolve_gpg_bin() {
  if [[ -n "${GPG_BIN:-}" ]]; then
    command -v "${GPG_BIN}" >/dev/null 2>&1 || die "GPG_BIN points to a missing command: ${GPG_BIN}"
    printf '%s\n' "${GPG_BIN}"
    return 0
  fi

  if command -v gpg >/dev/null 2>&1; then
    printf '%s\n' "gpg"
    return 0
  fi

  if command -v gpg2 >/dev/null 2>&1; then
    printf '%s\n' "gpg2"
    return 0
  fi

  die "required command not found: gpg or gpg2"
}

require_json_safe_value() {
  local field_name="$1"
  local value="$2"

  case "${value}" in
    *$'\n'*|*\"*|*\\*)
      die "${field_name} contains characters this script will not embed into JSON safely"
      ;;
  esac
}

parse_args() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      "${MODE_VALIDATE_BUNDLE}")
        MODE="${MODE_VALIDATE_BUNDLE}"
        shift
        ;;
      "${MODE_GENERATE}")
        shift
        ;;
    esac
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output-dir)
        OUTPUT_DIR="${2:?missing value for --output-dir}"
        shift 2
        ;;
      --bundle-json)
        BUNDLE_JSON_PATH="${2:?missing value for --bundle-json}"
        shift 2
        ;;
      --gpg-passphrase)
        GPG_PASSPHRASE="${2:?missing value for --gpg-passphrase}"
        shift 2
        ;;
      --gpg-name-real)
        GPG_NAME_REAL="${2:?missing value for --gpg-name-real}"
        shift 2
        ;;
      --gpg-name-email)
        GPG_NAME_EMAIL="${2:?missing value for --gpg-name-email}"
        shift 2
        ;;
      --gpg-expire)
        GPG_EXPIRE_DATE="${2:?missing value for --gpg-expire}"
        shift 2
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "unknown argument: $1"
        ;;
    esac
  done
}

validate_environment() {
  local required_commands=(awk date jq mktemp openssl tr)
  local command_name

  for command_name in "${required_commands[@]}"; do
    require_command "${command_name}"
  done

  GPG_BIN="$(resolve_gpg_bin)"
}

set_defaults() {
  if [[ -z "${OUTPUT_DIR}" ]]; then
    OUTPUT_DIR="$(pwd)/lakesql-release-s3-secrets-$(date +%Y%m%d%H%M%S)"
  fi

  if [[ -z "${GPG_PASSPHRASE}" ]]; then
    GPG_PASSPHRASE="$(openssl rand -base64 32 | tr -d '\n')"
  fi
}

validate_generate_inputs() {
  [[ ! -e "${OUTPUT_DIR}" ]] || die "output directory already exists: ${OUTPUT_DIR}"

  require_json_safe_value "GPG passphrase" "${GPG_PASSPHRASE}"
  require_json_safe_value "GPG real name" "${GPG_NAME_REAL}"
  require_json_safe_value "GPG email" "${GPG_NAME_EMAIL}"
  require_json_safe_value "GPG expiration" "${GPG_EXPIRE_DATE}"
}

validate_validate_inputs() {
  [[ -n "${BUNDLE_JSON_PATH}" ]] || die "--bundle-json is required in ${MODE_VALIDATE_BUNDLE} mode"
  [[ -f "${BUNDLE_JSON_PATH}" ]] || die "bundle JSON file not found: ${BUNDLE_JSON_PATH}"
}

prepare_directories() {
  umask 077
  mkdir -p "${OUTPUT_DIR}"
  chmod 700 "${OUTPUT_DIR}"

  WORK_DIR="$(mktemp -d)"
  GNUPGHOME="${WORK_DIR}/gnupg"
  export GNUPGHOME

  mkdir -p "${GNUPGHOME}"
  chmod 700 "${GNUPGHOME}"
}

prepare_work_dir_only() {
  WORK_DIR="$(mktemp -d)"
}

cleanup() {
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    rm -rf "${WORK_DIR}"
  fi
}

output_path() {
  local file_name="$1"
  printf '%s/%s\n' "${OUTPUT_DIR}" "${file_name}"
}

write_gpg_batch_file() {
  local batch_file="$1"

  cat > "${batch_file}" <<EOF
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: ${GPG_NAME_REAL}
Name-Email: ${GPG_NAME_EMAIL}
Expire-Date: ${GPG_EXPIRE_DATE}
Passphrase: ${GPG_PASSPHRASE}
%commit
EOF
}

generate_gpg_materials() {
  local batch_file="$1"
  local private_asc="$2"
  local public_asc="$3"
  local private_b64="$4"
  local fingerprint_file="$5"
  local gpg_key_fingerprint

  write_gpg_batch_file "${batch_file}"

  log_info "generating GPG signing key"
  "${GPG_BIN}" --homedir "${GNUPGHOME}" --batch --pinentry-mode loopback \
    --generate-key "${batch_file}" >/dev/null 2>&1

  gpg_key_fingerprint="$(
    "${GPG_BIN}" --homedir "${GNUPGHOME}" --batch --with-colons --list-secret-keys |
      awk -F: '$1 == "fpr" { print $10; exit }'
  )"
  [[ -n "${gpg_key_fingerprint}" ]] || die "failed to resolve the generated GPG key fingerprint"

  "${GPG_BIN}" --homedir "${GNUPGHOME}" --batch --yes --pinentry-mode loopback \
    --passphrase "${GPG_PASSPHRASE}" --armor --export-secret-keys \
    "${gpg_key_fingerprint}" > "${private_asc}"
  "${GPG_BIN}" --homedir "${GNUPGHOME}" --batch --yes --armor --export \
    "${gpg_key_fingerprint}" > "${public_asc}"
  printf '%s\n' "${gpg_key_fingerprint}" > "${fingerprint_file}"
  openssl base64 -A -in "${private_asc}" -out "${private_b64}"

  printf '%s\n' "${gpg_key_fingerprint}"
}

generate_apk_materials() {
  local private_key="$1"
  local public_key="$2"
  local private_b64="$3"
  local public_b64="$4"

  log_info "generating Alpine APK signing key pair"
  openssl genrsa -out "${private_key}" 4096 >/dev/null 2>&1
  openssl rsa -in "${private_key}" -pubout -out "${public_key}" >/dev/null 2>&1
  openssl base64 -A -in "${private_key}" -out "${private_b64}"
  openssl base64 -A -in "${public_key}" -out "${public_b64}"
}

run_generated_material_checks() {
  local gpg_key_fingerprint="$1"
  local apk_private_key="$2"
  local apk_public_key="$3"

  log_info "running local sanity checks"
  "${GPG_BIN}" --homedir "${GNUPGHOME}" --batch --list-secret-keys "${gpg_key_fingerprint}" >/dev/null 2>&1
  openssl rsa -in "${apk_private_key}" -check -noout >/dev/null 2>&1
  openssl rsa -pubin -in "${apk_public_key}" -text -noout >/dev/null 2>&1
}

write_bundle_json() {
  local bundle_json="$1"
  local gpg_private_b64_file="$2"
  local apk_private_b64_file="$3"
  local apk_public_b64_file="$4"
  local gpg_private_key_b64
  local apk_private_key_b64
  local apk_public_key_b64

  gpg_private_key_b64="$(<"${gpg_private_b64_file}")"
  apk_private_key_b64="$(<"${apk_private_b64_file}")"
  apk_public_key_b64="$(<"${apk_public_b64_file}")"

  cat > "${bundle_json}" <<EOF
{
  "${BUNDLE_FIELD_GPG_PRIVATE_KEY_B64}": "${gpg_private_key_b64}",
  "${BUNDLE_FIELD_GPG_PASSPHRASE}": "${GPG_PASSPHRASE}",
  "${BUNDLE_FIELD_APK_PRIVATE_KEY_B64}": "${apk_private_key_b64}",
  "${BUNDLE_FIELD_APK_PUBLIC_KEY_B64}": "${apk_public_key_b64}",
  "${BUNDLE_FIELD_APK_PASSPHRASE}": "${DEFAULT_APK_PASSPHRASE}"
}
EOF
}

set_output_permissions() {
  local private_files=("$1" "$2" "$3" "$4" "$5")
  local public_files=("$6" "$7" "$8" "$9")

  chmod 600 "${private_files[@]}"
  chmod 644 "${public_files[@]}"
}

decode_base64_to_file() {
  local encoded_value="$1"
  local output_file="$2"

  printf '%s' "${encoded_value}" | openssl base64 -d -A -out "${output_file}" 2>/dev/null ||
    die "failed to decode base64 content into ${output_file}"
}

bundle_field_value() {
  local bundle_json="$1"
  local field_name="$2"

  jq -er --arg field "${field_name}" '
    . as $root
    | if ($root | type) != "object" then
        error("bundle root must be a JSON object")
      elif ($root[$field] | type) != "string" then
        error("field \($field) must be a string")
      else
        $root[$field]
      end
  ' "${bundle_json}"
}

validate_bundle_json_structure() {
  local bundle_json="$1"
  local expected_keys
  local actual_keys

  expected_keys="$(
    printf '%s\n' \
      "${BUNDLE_FIELD_APK_PASSPHRASE}" \
      "${BUNDLE_FIELD_APK_PRIVATE_KEY_B64}" \
      "${BUNDLE_FIELD_APK_PUBLIC_KEY_B64}" \
      "${BUNDLE_FIELD_GPG_PASSPHRASE}" \
      "${BUNDLE_FIELD_GPG_PRIVATE_KEY_B64}" | sort
  )"
  actual_keys="$(jq -r 'keys[]' "${bundle_json}" | sort)"

  [[ "${actual_keys}" == "${expected_keys}" ]] || die "bundle JSON must contain exactly the expected five keys"
}

validate_bundle_json_content() {
  local bundle_json="$1"
  local validation_dir="$2"
  local gpg_private_asc_file="${validation_dir}/${FILE_GPG_PRIVATE_ASC}"
  local apk_private_key_file="${validation_dir}/${FILE_APK_PRIVATE_KEY}"
  local apk_public_key_file="${validation_dir}/${FILE_APK_PUBLIC_KEY}"
  local apk_public_key_from_private_file="${validation_dir}/derived-${FILE_APK_PUBLIC_KEY}"
  local apk_passphrase
  local gpg_passphrase

  validate_bundle_json_structure "${bundle_json}"
  mkdir -p "${validation_dir}"

  gpg_passphrase="$(bundle_field_value "${bundle_json}" "${BUNDLE_FIELD_GPG_PASSPHRASE}")"
  [[ -n "${gpg_passphrase}" ]] || die "${BUNDLE_FIELD_GPG_PASSPHRASE} must not be empty"

  apk_passphrase="$(bundle_field_value "${bundle_json}" "${BUNDLE_FIELD_APK_PASSPHRASE}")"
  [[ "${apk_passphrase}" == "${DEFAULT_APK_PASSPHRASE}" ]] || die "${BUNDLE_FIELD_APK_PASSPHRASE} must be an empty string for the current workflow"

  decode_base64_to_file \
    "$(bundle_field_value "${bundle_json}" "${BUNDLE_FIELD_GPG_PRIVATE_KEY_B64}")" \
    "${gpg_private_asc_file}"
  decode_base64_to_file \
    "$(bundle_field_value "${bundle_json}" "${BUNDLE_FIELD_APK_PRIVATE_KEY_B64}")" \
    "${apk_private_key_file}"
  decode_base64_to_file \
    "$(bundle_field_value "${bundle_json}" "${BUNDLE_FIELD_APK_PUBLIC_KEY_B64}")" \
    "${apk_public_key_file}"

  grep -q '^-----BEGIN PGP PRIVATE KEY BLOCK-----$' "${gpg_private_asc_file}" ||
    die "decoded ${BUNDLE_FIELD_GPG_PRIVATE_KEY_B64} is missing the expected armored header"
  grep -q '^-----END PGP PRIVATE KEY BLOCK-----$' "${gpg_private_asc_file}" ||
    die "decoded ${BUNDLE_FIELD_GPG_PRIVATE_KEY_B64} is missing the expected armored footer"
  "${GPG_BIN}" --batch --list-packets "${gpg_private_asc_file}" >/dev/null 2>&1 ||
    die "decoded ${BUNDLE_FIELD_GPG_PRIVATE_KEY_B64} is not a valid GPG private key"

  openssl rsa -in "${apk_private_key_file}" -check -noout >/dev/null 2>&1 ||
    die "decoded ${BUNDLE_FIELD_APK_PRIVATE_KEY_B64} is not a valid RSA private key"
  openssl rsa -pubin -in "${apk_public_key_file}" -text -noout >/dev/null 2>&1 ||
    die "decoded ${BUNDLE_FIELD_APK_PUBLIC_KEY_B64} is not a valid RSA public key"
  openssl rsa -in "${apk_private_key_file}" -pubout -out "${apk_public_key_from_private_file}" >/dev/null 2>&1

  cmp -s "${apk_public_key_file}" "${apk_public_key_from_private_file}" ||
    die "decoded APK public key does not match the decoded APK private key"
}

generate_mode() {
  local gpg_batch_file
  local gpg_private_asc
  local gpg_public_asc
  local gpg_private_b64
  local gpg_fingerprint_file
  local apk_private_key
  local apk_public_key
  local apk_private_b64
  local apk_public_b64
  local bundle_json
  local gpg_key_fingerprint

  set_defaults
  validate_generate_inputs
  prepare_directories

  gpg_batch_file="${WORK_DIR}/gpg-lakesql-batch.conf"
  gpg_private_asc="$(output_path "${FILE_GPG_PRIVATE_ASC}")"
  gpg_public_asc="$(output_path "${FILE_GPG_PUBLIC_ASC}")"
  gpg_private_b64="$(output_path "${FILE_GPG_PRIVATE_B64}")"
  gpg_fingerprint_file="$(output_path "${FILE_GPG_FINGERPRINT}")"
  apk_private_key="$(output_path "${FILE_APK_PRIVATE_KEY}")"
  apk_public_key="$(output_path "${FILE_APK_PUBLIC_KEY}")"
  apk_private_b64="$(output_path "${FILE_APK_PRIVATE_B64}")"
  apk_public_b64="$(output_path "${FILE_APK_PUBLIC_B64}")"
  bundle_json="$(output_path "${FILE_BUNDLE_JSON}")"

  gpg_key_fingerprint="$(
    generate_gpg_materials \
      "${gpg_batch_file}" \
      "${gpg_private_asc}" \
      "${gpg_public_asc}" \
      "${gpg_private_b64}" \
      "${gpg_fingerprint_file}"
  )"
  generate_apk_materials "${apk_private_key}" "${apk_public_key}" "${apk_private_b64}" "${apk_public_b64}"
  run_generated_material_checks "${gpg_key_fingerprint}" "${apk_private_key}" "${apk_public_key}"
  write_bundle_json "${bundle_json}" "${gpg_private_b64}" "${apk_private_b64}" "${apk_public_b64}"
  validate_bundle_json_content "${bundle_json}" "${WORK_DIR}/bundle-validation"
  set_output_permissions \
    "${gpg_private_asc}" \
    "${gpg_private_b64}" \
    "${apk_private_key}" \
    "${apk_private_b64}" \
    "${bundle_json}" \
    "${gpg_public_asc}" \
    "${gpg_fingerprint_file}" \
    "${apk_public_key}" \
    "${apk_public_b64}"

  log_info "generation completed"
  log_info "output directory: ${OUTPUT_DIR}"
  log_info "GPG key fingerprint: ${gpg_key_fingerprint}"
  log_info "bundle file: ${bundle_json}"
  log_info "bundle JSON validation passed"
  log_info "apk_passphrase is intentionally empty because the current LakeSQL release workflow signs APKINDEX with abuild-sign, which expects an unencrypted PEM key"
}

validate_bundle_mode() {
  prepare_work_dir_only
  validate_validate_inputs
  validate_bundle_json_content "${BUNDLE_JSON_PATH}" "${WORK_DIR}/bundle-validation"
  log_info "bundle JSON validation passed: ${BUNDLE_JSON_PATH}"
}

main() {
  trap cleanup EXIT INT TERM

  parse_args "$@"
  validate_environment

  case "${MODE}" in
    "${MODE_GENERATE}")
      generate_mode
      ;;
    "${MODE_VALIDATE_BUNDLE}")
      validate_bundle_mode
      ;;
    *)
      die "unsupported mode: ${MODE}"
      ;;
  esac
}

main "$@"
