# EE Portal configuration

Module authors edit `modules/<module>/module.yaml` and its `pages/*.yaml` files. The portal runtime does not need source changes for supported catalog, list, form, and detail pages.

Regenerate the checked-in registry with the versioned compiler from `PingCAP-QE/ee-apps`:

```sh
docker run --rm \
  -v "$PWD/apps/gcp/ee-portal:/work" \
  ghcr.io/pingcap-qe/ee-apps/exp-ee-portal-config:v0.1.0 \
  --input /work/modules --output /work/generated/registry.json
```

For local development against an `ee-apps` checkout:

```sh
cd experiments/portal
npm ci
npm run config:compile -- \
  --input /path/to/ee-ops/apps/gcp/ee-portal/modules \
  --output /path/to/ee-ops/apps/gcp/ee-portal/generated/registry.json
```

CI recompiles the registry and rejects any diff. It also renders the Kustomize package so hashed ConfigMap references are checked before merge.
