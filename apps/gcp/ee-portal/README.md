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

## Not exposed through the Gateway

This Portal has no HTTPRoute and is intentionally reachable only in-cluster
(`kubectl -n ee-portal port-forward`). Its former route (`prow.tidb.net/ee`,
including the `/ee/api/tibuild` proxy) authenticated any OIDC employee but
authorized no principal, and the TiBuild pages only called `/tibuild/api/v2`.
Exposing it again requires an authorization model of its own;
`scripts/check_gcp_route_csrf.sh` fails if a route reappears here.

Because of that, the `apiUrl` in `modules/*/module.yaml` is only meaningful when
the Portal is served behind something that proxies the prefix (the compiler
copies it verbatim into `generated/registry.json`). Under a port-forward it
resolves against the Portal's own origin and will not reach TiBuild.
