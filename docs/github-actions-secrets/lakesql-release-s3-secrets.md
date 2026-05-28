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
| `LAKESQL_PACKAGE_APK_PASSPHRASE` | `apk_passphrase` | empty string for the current workflow, because `abuild-sign` signs `APKINDEX.tar.gz` with an unencrypted PEM key |

## Quick start

Prerequisites on the machine that runs the helper script:

- `openssl`
- `gpg` or `gpg2`

Run the helper script from the repo root:

```bash
./scripts/generate_lakesql_release_s3_bundle.sh
```

By default it writes a timestamped directory like `./lakesql-release-s3-secrets-20260528094500`.

Optional flags:

```bash
./scripts/generate_lakesql_release_s3_bundle.sh \
  --output-dir /secure/path/lakesql-release-s3-secrets \
  --gpg-name-real "LakeSQL Package Signing" \
  --gpg-name-email lakesql-release@tidbcloud.com \
  --gpg-expire 2y
```

Generated files:

- `lakesql-package-signing.asc`: ASCII-armored GPG private key
- `lakesql-package-signing.public.asc`: ASCII-armored GPG public key
- `lakesql-package-signing.asc.b64`: base64 value for `LAKESQL_PACKAGE_GPG_PRIVATE_KEY_B64`
- `lakesql-package-signing.fingerprint.txt`: GPG key fingerprint
- `lakesql-packages.rsa`: Alpine APK RSA private key in PEM format
- `lakesql-packages.rsa.pub`: Alpine APK RSA public key in PEM format
- `lakesql-packages.rsa.b64`: base64 value for `LAKESQL_PACKAGE_APK_PRIVATE_KEY_B64`
- `lakesql-packages.rsa.pub.b64`: base64 value for `LAKESQL_PACKAGE_APK_PUBLIC_KEY_B64`
- `lakesql-release-s3-bundle.json`: JSON payload for GCP Secret Manager

## What the helper script does

The helper script performs three actions in one run:

- generates a 4096-bit RSA GPG signing key with a generated passphrase, unless `--gpg-passphrase` is provided
- generates an unencrypted 4096-bit RSA PEM key pair for Alpine APK signing
- renders `lakesql-release-s3-bundle.json` with the exact field names expected by `ee-ops`

It also runs local sanity checks before writing the bundle.

## Why `apk_passphrase` is empty

This is intentional for the current `tidbcloud/lakesql` release workflow.

The workflow uses two different APK signing paths:

- `nfpm package --packager apk` can consume `NFPM_APK_PASSPHRASE`
- `abuild-sign` signs `APKINDEX.tar.gz` directly with the PEM private key and does not consume a separate passphrase input in our current implementation

Because the release job must complete both steps, the safest compatible output today is:

- unencrypted `lakesql-packages.rsa`
- empty-string `apk_passphrase` in the bundle JSON

If LakeSQL later changes the workflow to decrypt the key before calling `abuild-sign`, this runbook and the helper script can be updated to support a non-empty APK passphrase.

## Create or update the source of truth in GCP Secret Manager

Set the project first:

```bash
export PROJECT_ID=pingcap-testing-account
```

Create the bundle secret if it does not already exist:

```bash
gcloud secrets create gha__env__tidbcloud__lakesql__release-s3__bundle --project="${PROJECT_ID}" --replication-policy=automatic
```

Add or rotate the secret version:

```bash
gcloud secrets versions add gha__env__tidbcloud__lakesql__release-s3__bundle \
  --project="${PROJECT_ID}" \
  --data-file=/secure/path/lakesql-release-s3-secrets/lakesql-release-s3-bundle.json
```

## Delivery mapping in ee-ops

The GitOps objects for this environment live under:

- `infrastructure/gcp/github-actions-secrets/repos/tidbcloud/lakesql/00-target-stores`
- `infrastructure/gcp/github-actions-secrets/repos/tidbcloud/lakesql/01-source-secrets`
- `infrastructure/gcp/github-actions-secrets/repos/tidbcloud/lakesql/02-deliveries`

After the bundle secret is present in Secret Manager and Flux reconciles the manifests, ESO will:

- extract the five JSON fields into one cluster-local source secret: `src-lakesql-release-s3-bundle`
- push those five keys into GitHub environment `tidbcloud/lakesql:release-s3`

## Why this is not generated by `ExternalSecret` or `secret-generator`

This repo's current split of responsibility is deliberate:

- `ExternalSecret` reads an existing value from GCP Secret Manager into the cluster
- `PushSecret` pushes that existing value into GitHub Actions secrets
- `secret-generator` is currently used in this repo for simple generated values such as random passwords, not long-lived signing identities

For LakeSQL package signing, key generation should stay outside the cluster because:

- the GPG and APK private keys are release identities that need backup and explicit operator custody
- GCP Secret Manager is the source of truth for GitHub Actions secret delivery in this design
- generating the keys in-cluster would require a separate export and backup path back into GCP, which would complicate rotation and recovery
