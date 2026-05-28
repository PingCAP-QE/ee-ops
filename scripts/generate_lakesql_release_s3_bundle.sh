#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Generate the LakeSQL release-s3 signing materials:
- a GPG signing key for deb/rpm + apt metadata signing
- an Alpine APK RSA key pair for apk package/index signing
- lakesql-release-s3-bundle.json for GCP Secret Manager

Usage:
  ./scripts/generate_lakesql_release_s3_bundle.sh [options]

Options:
  --output-dir DIR        Directory to write generated files into.
                          Default: ./lakesql-release-s3-secrets-<timestamp>
  --gpg-passphrase VALUE  Reuse an existing GPG passphrase instead of generating one.
  --gpg-name-real VALUE   GPG key real name.
                          Default: LakeSQL Package Signing
  --gpg-name-email VALUE  GPG key email.
                          Default: lakesql-release@tidbcloud.com
  --gpg-expire VALUE      GPG key expiration passed to GnuPG.
                          Default: 2y
  --help                  Show this help.

Notes:
- The generated APK private key is intentionally unencrypted, so the current
  LakeSQL release workflow can use it with abuild-sign for APKINDEX signing.
- The generated bundle sets "apk_passphrase" to an empty string for the same reason.
EOF
}

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "ERROR - required command not found: ${command_name}" >&2
    exit 1
  fi
}

require_json_safe_value() {
  local field_name="$1"
  local value="$2"

  if [[ "${value}" == *$'\n'* || "${value}" == *'"'* || "${value}" == *'\\'* ]]; then
    echo "ERROR - ${field_name} contains characters this script will not embed into JSON safely" >&2
    echo "ERROR - avoid newlines, double quotes, and backslashes, or let the script generate the value" >&2
    exit 1
  fi
}

resolve_gpg_bin() {
  if [[ -n "${GPG_BIN:-}" ]]; then
    if command -v "${GPG_BIN}" >/dev/null 2>&1; then
      printf '%s\n' "${GPG_BIN}"
      return 0
    fi

    echo "ERROR - GPG_BIN points to a missing command: ${GPG_BIN}" >&2
    exit 1
  fi

  if command -v gpg >/dev/null 2>&1; then
    printf '%s\n' "gpg"
    return 0
  fi

  if command -v gpg2 >/dev/null 2>&1; then
    printf '%s\n' "gpg2"
    return 0
  fi

  echo "ERROR - required command not found: gpg or gpg2" >&2
  exit 1
}

OUTPUT_DIR=""
GPG_PASSPHRASE="${GPG_PASSPHRASE:-}"
GPG_NAME_REAL="LakeSQL Package Signing"
GPG_NAME_EMAIL="lakesql-release@tidbcloud.com"
GPG_EXPIRE_DATE="2y"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="${2:?missing value for --output-dir}"
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
      echo "ERROR - unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_command awk
require_command date
require_command mktemp
require_command openssl
require_command tr

GPG_BIN="$(resolve_gpg_bin)"

if [[ -z "${OUTPUT_DIR}" ]]; then
  OUTPUT_DIR="$(pwd)/lakesql-release-s3-secrets-$(date +%Y%m%d%H%M%S)"
fi

if [[ -e "${OUTPUT_DIR}" ]]; then
  echo "ERROR - output directory already exists: ${OUTPUT_DIR}" >&2
  exit 1
fi

if [[ -z "${GPG_PASSPHRASE}" ]]; then
  GPG_PASSPHRASE="$(openssl rand -base64 32 | tr -d '\n')"
fi

require_json_safe_value "GPG passphrase" "${GPG_PASSPHRASE}"
require_json_safe_value "GPG real name" "${GPG_NAME_REAL}"
require_json_safe_value "GPG email" "${GPG_NAME_EMAIL}"
require_json_safe_value "GPG expiration" "${GPG_EXPIRE_DATE}"

umask 077
mkdir -p "${OUTPUT_DIR}"
chmod 700 "${OUTPUT_DIR}"

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT INT TERM

GNUPGHOME="${WORK_DIR}/gnupg"
export GNUPGHOME
mkdir -p "${GNUPGHOME}"
chmod 700 "${GNUPGHOME}"

GPG_BATCH_FILE="${WORK_DIR}/gpg-lakesql-batch.conf"
cat > "${GPG_BATCH_FILE}" <<EOF
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

echo "INFO - generating GPG signing key"
"${GPG_BIN}" --homedir "${GNUPGHOME}" --batch --pinentry-mode loopback \
  --generate-key "${GPG_BATCH_FILE}" >/dev/null 2>&1

GPG_KEY_FINGERPRINT="$(
  "${GPG_BIN}" --homedir "${GNUPGHOME}" --batch --with-colons --list-secret-keys |
    awk -F: '$1 == "fpr" { print $10; exit }'
)"
if [[ -z "${GPG_KEY_FINGERPRINT}" ]]; then
  echo "ERROR - failed to resolve the generated GPG key fingerprint" >&2
  exit 1
fi

GPG_PRIVATE_ASC="${OUTPUT_DIR}/lakesql-package-signing.asc"
GPG_PUBLIC_ASC="${OUTPUT_DIR}/lakesql-package-signing.public.asc"
GPG_PRIVATE_B64="${OUTPUT_DIR}/lakesql-package-signing.asc.b64"
GPG_FINGERPRINT_FILE="${OUTPUT_DIR}/lakesql-package-signing.fingerprint.txt"

"${GPG_BIN}" --homedir "${GNUPGHOME}" --batch --yes --pinentry-mode loopback \
  --passphrase "${GPG_PASSPHRASE}" --armor --export-secret-keys \
  "${GPG_KEY_FINGERPRINT}" > "${GPG_PRIVATE_ASC}"
"${GPG_BIN}" --homedir "${GNUPGHOME}" --batch --yes --armor --export \
  "${GPG_KEY_FINGERPRINT}" > "${GPG_PUBLIC_ASC}"
printf '%s\n' "${GPG_KEY_FINGERPRINT}" > "${GPG_FINGERPRINT_FILE}"
openssl base64 -A -in "${GPG_PRIVATE_ASC}" -out "${GPG_PRIVATE_B64}"

echo "INFO - generating Alpine APK signing key pair"
APK_PRIVATE_KEY="${OUTPUT_DIR}/lakesql-packages.rsa"
APK_PUBLIC_KEY="${OUTPUT_DIR}/lakesql-packages.rsa.pub"
APK_PRIVATE_B64="${OUTPUT_DIR}/lakesql-packages.rsa.b64"
APK_PUBLIC_B64="${OUTPUT_DIR}/lakesql-packages.rsa.pub.b64"

openssl genrsa -out "${APK_PRIVATE_KEY}" 4096 >/dev/null 2>&1
openssl rsa -in "${APK_PRIVATE_KEY}" -pubout -out "${APK_PUBLIC_KEY}" >/dev/null 2>&1
openssl base64 -A -in "${APK_PRIVATE_KEY}" -out "${APK_PRIVATE_B64}"
openssl base64 -A -in "${APK_PUBLIC_KEY}" -out "${APK_PUBLIC_B64}"

echo "INFO - running local sanity checks"
"${GPG_BIN}" --homedir "${GNUPGHOME}" --batch --list-secret-keys "${GPG_KEY_FINGERPRINT}" >/dev/null 2>&1
openssl rsa -in "${APK_PRIVATE_KEY}" -check -noout >/dev/null 2>&1
openssl rsa -pubin -in "${APK_PUBLIC_KEY}" -text -noout >/dev/null 2>&1

GPG_PRIVATE_KEY_B64="$(<"${GPG_PRIVATE_B64}")"
APK_PRIVATE_KEY_B64="$(<"${APK_PRIVATE_B64}")"
APK_PUBLIC_KEY_B64="$(<"${APK_PUBLIC_B64}")"

BUNDLE_JSON="${OUTPUT_DIR}/lakesql-release-s3-bundle.json"
cat > "${BUNDLE_JSON}" <<EOF
{
  "gpg_private_key_b64": "${GPG_PRIVATE_KEY_B64}",
  "gpg_passphrase": "${GPG_PASSPHRASE}",
  "apk_private_key_b64": "${APK_PRIVATE_KEY_B64}",
  "apk_public_key_b64": "${APK_PUBLIC_KEY_B64}",
  "apk_passphrase": ""
}
EOF

chmod 600 "${GPG_PRIVATE_ASC}" "${GPG_PRIVATE_B64}" "${APK_PRIVATE_KEY}" "${APK_PRIVATE_B64}" "${BUNDLE_JSON}"
chmod 644 "${GPG_PUBLIC_ASC}" "${GPG_FINGERPRINT_FILE}" "${APK_PUBLIC_KEY}" "${APK_PUBLIC_B64}"

cat <<EOF
INFO - generation completed
INFO - output directory: ${OUTPUT_DIR}
INFO - GPG key fingerprint: ${GPG_KEY_FINGERPRINT}
INFO - bundle file: ${BUNDLE_JSON}
INFO - apk_passphrase is intentionally empty because the current LakeSQL release workflow signs APKINDEX with abuild-sign, which expects an unencrypted PEM key
EOF
