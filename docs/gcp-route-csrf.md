# GCP browser-route CSRF protection

The route-level Envoy Gateway `SecurityPolicy` resources for EE Portal, TiBuild
v2 and CI Dashboard enforce CSRF with `csrf: {}`. Protection on the Portal route
does not cover requests matching the separate `/tibuild` route. Only Portal and
TiBuild explicitly share the `ee-apps-*` cookie names. Dashboard is currently
read-only, but uses the same guard without an application token framework.
Publisher is not part of this surface: it has no HTTPRoute on this cluster and is
reached only in-cluster as `http://publisher.publisher.svc`.

## Browser requests

Envoy checks POST, PUT, PATCH and DELETE, including bodyless POST requests.
The source must match the destination host and port. It uses `Origin` first,
falling back to `Referer` only when `Origin` is absent. Missing both headers,
`Origin: null`, and a different host/port are rejected with 403. Envoy compares
host and port, not scheme; this does not protect against same-origin XSS.
No additional origins or shadow mode are configured. GET/HEAD and OIDC GET
callbacks remain unaffected. The Portal's `/ee/api/tibuild/v2/*` alias is covered
by its existing policy; `/tibuild/api/v2/*` is covered by the TiBuild policy.

## Machine requests

TiBuild also has a `machine-access.yaml` route on the **same URL** with an
additional `Authorization: Bearer ...` header match. Gateway API's header match
precedence selects it ahead of the path-only browser route. It has a separate
JWT-only SecurityPolicy with `optional: false`, Google's issuer/JWKS and the API
audience `prow.tidb.net`. This route deliberately has no CSRF policy: clients
such as production Tirelease (`apps/prod2/tirelease/configmaps.yaml`, which sets
`baseURL: https://prow.tidb.net/tibuild`) do not send browser Origin headers.

The header only selects a route; it does **not** authenticate the request. An
invalid, expired, wrongly signed or wrong-audience token is rejected, even if the
request carries valid OIDC cookies. There is no OIDC fallback on the machine
route. This preserves Bearer clients without exempting arbitrary
Authorization-bearing requests on a cookie-authenticated route. Browser cookies
alone always use the CSRF-protected route. Machine clients must use the direct
`/tibuild` URL, not the Portal's OIDC-only `/ee/api/tibuild` alias. This separates
credential modes, not an account/service-account allowlist; principal authorization
is unchanged and tracked separately. Do not make JWT optional on a machine
route, attach OIDC to it, or add a wildcard CSRF origin to the browser policy.

## Verification and rollout

Run the manifest regression guard (also run by the apps CD Test job):

```sh
bash scripts/check_gcp_route_csrf.sh
```

Render the affected Kustomize packages and validate SecurityPolicies against the
pinned Envoy Gateway v1.9.0-rc.1 CRD. In a non-production environment, verify:

- Cookie-authenticated POST/PUT/PATCH/DELETE with foreign, absent and null origins
  fail; matching Origin and Referer fallback work. Include bodyless TiBuild
  rerun through **both aliases**.
- Valid machine JWTs work without Origin on the original URLs. Invalid/missing
  JWTs cannot authenticate via the machine route, even with browser cookies.
- Adding a dummy Bearer header cannot bypass CSRF/authentication. Matching Origin
  cannot make invalid JWT authentication succeed.
- Dashboard GET, the Portal, and OIDC GET callbacks/login still work.

Do not trigger real builds or publishing operations as production security probes.
After an authorized rollout, check all affected SecurityPolicies are Accepted,
verify the live Envoy configuration selects the required-JWT routes ahead of the
browser fallback, and repeat safe browser/login/read smoke checks. A manifest or
local filter test is not proof of live enforcement or completed rescanning.
Track Helix finding `95054e85-c1c8-4827-acff-cc1f5ee1538f` through deployment and
rescan separately; the Publisher part of that finding is closed by removing the
route instead of hardening it, and authentication/identity authorization remains
a separate finding.
