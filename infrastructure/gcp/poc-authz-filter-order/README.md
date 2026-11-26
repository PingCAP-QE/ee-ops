# PoC: Envoy filter ordering for external authorization

Validates `EnvoyProxy.spec.filterOrder` on the deployed v1.9.x data plane before
any change to the shared `eg-internal` proxy.

**Nothing here is applied by Flux.** The directory has no `kustomization.yaml`
and is not referenced by `infrastructure/` or `apps/`. Apply and delete by hand
while running the PoC; see the runbook below.

## Why an isolated Gateway

`filterOrder` is `EnvoyProxy`-scoped, and `EnvoyProxy` is attached per Gateway
through `spec.infrastructure.parametersRef`. Moving `ext_authz` on the shared
proxy would change the filter chain for every route on `prow.tidb.net`
simultaneously. A second Gateway with its own `EnvoyProxy` gets the reordering
without touching production.

The PoC Gateway is `ClusterIP`-only, like the internal one, so it allocates no
load balancer and is reachable only through a port-forward.

## What the PoC can and cannot prove

Can:

- the installed CRD accepts `filterOrder`, and the reordered chain appears in
  `config_dump` with `ext_authz` after `jwt_authn` and still before
  `credential_injector`;
- a request without a valid JWT is rejected by `jwt_authn` **before**
  `ext_authz`, so it produces no decision (this changes the shadow probe
  expectations recorded in `docs/authz/shadow-rollout.md`);
- a request with a valid JWT reaches `ext_authz`, so a decision is recorded;
- the token broker's credential replacement still runs after `ext_authz`, so the
  caller's original `Authorization` header is still what `authzd` sees.

Cannot (needs a real browser against the production host):

- that `forwardIDToken` delivers the OIDC ID token to `ext_authz`. A detached
  Gateway gets no browser session: the OAuth redirect URI registered at Google
  points at `https://prow.tidb.net/tibuild/oauth2/callback`, and an isolated
  data plane cannot receive that callback. The header delivery has to be proven
  on the shared proxy, after this PoC justifies the reordering.

## Runbook

1. Validate the objects against the live CRDs without applying:

   ```sh
   kubectl apply --dry-run=server -f infrastructure/gcp/poc-authz-filter-order/
   ```

2. Apply, and wait for the new data plane:

   ```sh
   kubectl apply -f infrastructure/gcp/poc-authz-filter-order/
   kubectl -n infra get pods -l gateway.envoyproxy.io/owning-gateway-name=eg-authz-poc
   ```

3. Read the filter chain (must be `csrf → oauth2 → jwt_authn → ext_authz → rbac →
   local_ratelimit → credential_injector → router`):

   ```sh
   ./verify.sh
   ```

4. Probe through the PoC Gateway:

   ```sh
   kubectl -n infra port-forward svc/eg-authz-poc 18080:80
   curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: authz-poc.prow.tidb.net' http://127.0.0.1:18080/probe
   # expect 401 from jwt_authn, and NO new decision for that correlation id
   ```

   Then repeat with a real ID token for audience `prow.tidb.net`; expect the
   request to pass and one decision with `reason_code=route_not_registered`
   (the PoC route has no registry entry) under observe mode.

5. Delete everything:

   ```sh
   kubectl delete -f infrastructure/gcp/poc-authz-filter-order/ --ignore-not-found
   ```

## If it works

Promote by adding `filterOrder` to the shared `internal` `EnvoyProxy`
(`infrastructure/gcp/gateways/config/envoy-gateway-internal.yaml`), one PR, with
the browser `forwardIDToken` acceptance done immediately after on the real host.
Rollback is deleting the three lines.
