# LakeSQL release-s3 Secrets

This document defines the GitHub Actions secrets required by `tidbcloud/lakesql` environment `release-s3`, how they are mapped in `ee-ops`, and how to generate them.

## Managed secrets

These GitHub Actions environment secrets are delivered by External Secrets Operator to `tidbcloud/lakesql` environment `release-s3`.

The source of truth in GCP Secret Manager is a single JSON secret:

- `gha__env__tidbcloud__lakesql__release-s3__bundle`

Expected JSON shape:

```json
{
  "gpg_private_key_b64": "<base64 of ASCII-armored GPG private key>",
  "gpg_passphrase": "<GPG key passphrase>",
  "apk_private_key_b64": "<base64 of Alpine RSA private key>",
  "apk_public_key_b64": "<base64 of Alpine RSA public key>",
  "apk_passphrase": "<Alpine RSA private key passphrase>"
}
```

That bundle is unpacked into the following GitHub Actions environment secrets:

| GitHub secret name | JSON field | Expected value |
| --- | --- | --- |
| `LAKESQL_PACKAGE_GPG_PRIVATE_KEY_B64` | `gpg_private_key_b64` | base64 of ASCII-armored GPG private key used for `deb`/`rpm` signing and apt metadata signing |
| `LAKESQL_PACKAGE_GPG_PASSPHRASE` | `gpg_passphrase` | passphrase for the GPG private key |
| `LAKESQL_PACKAGE_APK_PRIVATE_KEY_B64` | `apk_private_key_b64` | base64 of Alpine RSA private key used by `abuild-sign` |
| `LAKESQL_PACKAGE_APK_PUBLIC_KEY_B64` | `apk_public_key_b64` | base64 of Alpine RSA public key published to `/keys/lakesql-packages.rsa.pub` |
| `LAKESQL_PACKAGE_APK_PASSPHRASE` | `apk_passphrase` | passphrase for the Alpine RSA private key; may be empty if the key is created without one |

## Generate the GPG signing key

Create an isolated GnuPG home first:

```bash
export GNUPGHOME="$(mktemp -d)"
chmod 700 "${GNUPGHOME}"
```

Create a passphrase and keep it for `LAKESQL_PACKAGE_GPG_PASSPHRASE`:

```bash
openssl rand -base64 32
```

Generate the key in batch mode:

```bash
cat >gpg-lakesql-batch.conf <<'EOF'
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: LakeSQL Package Signing
Name-Email: lakesql-release@tidbcloud.com
Expire-Date: 2y
Passphrase: __REPLACE_WITH_GPG_PASSPHRASE__
%commit
EOF

gpg --batch --generate-key gpg-lakesql-batch.conf
```

Resolve the key id and export the private key in ASCII armor:

```bash
GPG_KEY_ID="$(gpg --batch --list-secret-keys --with-colons | awk -F: '$1 == "sec" { print $5; exit }')"
gpg --batch --pinentry-mode loopback --passphrase '__REPLACE_WITH_GPG_PASSPHRASE__' \
  --armor --export-secret-keys "${GPG_KEY_ID}" > lakesql-package-signing.asc
base64 < lakesql-package-signing.asc | tr -d '\n' > lakesql-package-signing.asc.b64
```

Outputs:

- `lakesql-package-signing.asc.b64` -> `LAKESQL_PACKAGE_GPG_PRIVATE_KEY_B64`
- the passphrase string -> `LAKESQL_PACKAGE_GPG_PASSPHRASE`

Optional sanity checks:

```bash
base64 -d lakesql-package-signing.asc.b64 | gpg --batch --import
gpg --batch --list-secret-keys "${GPG_KEY_ID}"
```

## Generate the Alpine APK signing key pair

Create a passphrase and keep it for `LAKESQL_PACKAGE_APK_PASSPHRASE`:

```bash
openssl rand -base64 32
```

Generate a 4096-bit RSA key pair:

```bash
openssl genrsa -aes256 -passout pass:'__REPLACE_WITH_APK_PASSPHRASE__' -out lakesql-packages.rsa 4096
openssl rsa -in lakesql-packages.rsa -passin pass:'__REPLACE_WITH_APK_PASSPHRASE__' -pubout -out lakesql-packages.rsa.pub
base64 < lakesql-packages.rsa | tr -d '\n' > lakesql-packages.rsa.b64
base64 < lakesql-packages.rsa.pub | tr -d '\n' > lakesql-packages.rsa.pub.b64
```

Outputs:

- `lakesql-packages.rsa.b64` -> `LAKESQL_PACKAGE_APK_PRIVATE_KEY_B64`
- `lakesql-packages.rsa.pub.b64` -> `LAKESQL_PACKAGE_APK_PUBLIC_KEY_B64`
- the passphrase string -> `LAKESQL_PACKAGE_APK_PASSPHRASE`

Optional sanity checks:

```bash
base64 -d lakesql-packages.rsa.b64 | openssl rsa -passin pass:'__REPLACE_WITH_APK_PASSPHRASE__' -check -noout
base64 -d lakesql-packages.rsa.pub.b64 | openssl rsa -pubin -inform PEM -text -noout
```

## Create or update the source of truth in GCP Secret Manager

Set the project first:

```bash
export PROJECT_ID=pingcap-testing-account
```

Create the bundle secret if it does not already exist:

```bash
gcloud secrets create gha__env__tidbcloud__lakesql__release-s3__bundle --project="${PROJECT_ID}" --replication-policy=automatic
```

Render the JSON payload locally:

```bash
cat > lakesql-release-s3-bundle.json <<'EOF'
{
  "gpg_private_key_b64": "__REPLACE_WITH_GPG_PRIVATE_KEY_B64__",
  "gpg_passphrase": "__REPLACE_WITH_GPG_PASSPHRASE__",
  "apk_private_key_b64": "__REPLACE_WITH_APK_PRIVATE_KEY_B64__",
  "apk_public_key_b64": "__REPLACE_WITH_APK_PUBLIC_KEY_B64__",
  "apk_passphrase": "__REPLACE_WITH_APK_PASSPHRASE__"
}
EOF
```

Add or rotate the secret version:

```bash
gcloud secrets versions add gha__env__tidbcloud__lakesql__release-s3__bundle --project="${PROJECT_ID}" --data-file=lakesql-release-s3-bundle.json
```

## Delivery mapping in ee-ops

The GitOps objects for this environment live under:

- `infrastructure/gcp/github-actions-secrets/repos/tidbcloud/lakesql/00-target-stores`
- `infrastructure/gcp/github-actions-secrets/repos/tidbcloud/lakesql/01-source-secrets`
- `infrastructure/gcp/github-actions-secrets/repos/tidbcloud/lakesql/02-deliveries`

After the bundle secret is present in Secret Manager and Flux reconciles the manifests, ESO will:

- extract the five JSON fields into one cluster-local source secret: `src-lakesql-release-s3-bundle`
- push those five keys into GitHub environment `tidbcloud/lakesql:release-s3`
