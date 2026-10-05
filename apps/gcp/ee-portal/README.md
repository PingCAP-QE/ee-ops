# EE Portal configuration

Module authors edit `modules/<module>/module.yaml` and its `pages/*.yaml` files. The portal runtime does not need source changes for supported catalog, list, form, and detail pages.

Regenerate the checked-in registry with the versioned Go CLI from `PingCAP-QE/ee-apps`:

```sh
go run /path/to/ee-apps/experiments/portal/cmd/portal-config \
  --input "$PWD/apps/gcp/ee-portal/modules" \
  --output "$PWD/apps/gcp/ee-portal/generated/registry.json"
```

For local development against an `ee-apps` checkout:

```sh
go run /path/to/ee-apps/experiments/portal/cmd/portal-config \
  --input /path/to/ee-ops/apps/gcp/ee-portal/modules \
  --output /path/to/ee-ops/apps/gcp/ee-portal/generated/registry.json
```

CI recompiles the registry and rejects any diff. It also renders the Kustomize package so hashed ConfigMap references are checked before merge.

## Identity boundary

Envoy Gateway owns Google OIDC/JWT authentication. It verifies the session and
extracts the `sub`, `email` and `name` claims from the OIDC ID-token cookie into
the Envoy-owned `X-User-Id`, `X-User-Email` and `X-User-Name` headers. The
Portal and TiBuild services only consume that identity for display and
ownership checks; they do not validate tokens or decide whether an account is
allowed to enter the system. The backend Service must remain reachable only
through the trusted Gateway path.
