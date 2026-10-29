# CI Dashboard security release: configuration before image

The 2026-10-29 release includes ee-apps #765, #766, #767, #770 and #776,
plus the earlier #763 log redaction. The backend identity contract is documented
in [ee-apps backend-auth.md](https://github.com/PingCAP-QE/ee-apps/blob/648777f2557f5260dcb5491f77cce8fb44756a25/ci-dashboard/docs/backend-auth.md).
The separate ee-ops #2536 CSRF policies must remain enabled.

Do not merge the configuration and image changes as one unordered GitOps
rollout. Use two dependent PRs targeting main. The image PR stays **Draft** until
the configuration has reconciled and the real-identity canary below passes.
Neither PR preparation nor static tests authorize a production change.

## Phase A: authentication prerequisites, unchanged image

The prerequisites PR adds only the application identity environment and the
existing SecurityPolicy's `oidc.forwardIDToken` configuration. It deliberately
keeps image `v2026.10.25-12-g9e55b52` and display version `1.9.13`.
The old application ignores the additional environment/header and remains
vulnerable until Phase B; this is not a completed security remediation.

Before authorizing Phase A:

- Confirm `pingcap.com` is the approved signed Google Workspace `hd` domain.
  The policy is an exact allowlist, not an email suffix or wildcard. If additional
  domains are approved, explicitly review both the manifest and static guard.
- Confirm the existing `apps/ci-dashboard-oidc` Secret has `client-id` and
  `client-secret` keys. Inspect key names only; do not dump values.
- The app references only `client-id`; its audience must match the existing
  Envoy OIDC client. Do not copy client secrets or signing keys into the app.
- Verify the actual Gateway CRD/data plane supports `oidc.forwardIDToken`.
  Retain issuer, callback, openid/email/profile scopes, encrypted sessions,
  refresh and `csrf: {}`. The backend expects the raw decrypted Google ID token
  in exactly one `X-CI-Dashboard-ID-Token` header, not an access token, forwarded
  email, Authorization header or Cookie shortcut.

After the approved merge, wait for Flux/Helm reconciliation. Require the live
Dashboard SecurityPolicy to be Accepted for its **current generation**, and
confirm the app has the intended environment while its image is still unchanged.
A rendered YAML document or an old Accepted condition is insufficient.

## Canary gate before Phase B

Before replacing the working app, obtain explicit authorization for a private
canary and any temporary routing. Use the exact Phase B image, the same app
environment, and actual Envoy Google OIDC forwarding; do not expose a new
unauthenticated route or weaken the existing policy.

Require all of the following and record only pass/fail evidence:

- Dashboard Pod DNS/HTTPS egress to
  `https://www.googleapis.com/oauth2/v1/certs` works.
- A real company user's read-only API request through the canary's authenticated
  Gateway path returns 200. This must reach the new image, not the old app.
- An unauthenticated direct canary Service/Pod API request returns 401. A public
  anonymous request may instead redirect to Google at the Gateway, as designed.
- Initial browser login and a real session refresh work. Successful readiness
  does not verify the actual audience, Workspace domain, email claims, token
  forwarding, refresh behavior or continuing certificate availability.

Do not put tokens, Cookie headers, claims or raw data responses in logs, files,
command history or PR comments. Halt on failure; never set
`CI_DASHBOARD_AUTH_DISABLED=true` as a production workaround.
The static guard forbids that development bypass.

## Phase B: release the verified app and jobs together

Only after Phase A and the canary gate, promote/review the dependent image PR,
refresh CI against current main and authorize its merge. It changes only the
HelmRelease image tag and sidebar display version to `1.9.14`:

```text
ghcr.io/pingcap-qe/ee-apps/ci-dashboard:v2026.10.25-23-g648777f
ghcr.io/pingcap-qe/ee-apps/ci-dashboard-jobs:v2026.10.25-23-g648777f
```

The tag was emitted by successful
[release run 40835363015](https://github.com/PingCAP-QE/ee-apps/actions/runs/40835363015),
source `648777f2557f5260dcb5491f77cce8fb44756a25`. Both registry manifest lists
contain linux/amd64 and linux/arm64. Index digests:

- app: `sha256:caa33ce3d820363ceefd81ee8fdde813a761be5a0fee6dbadb053e7624237efb`
- jobs: `sha256:e02aa893156115985cc6dbbb737f210f2158e44c9c9d440d69f6c7cc0b2d1934`

Keep the existing Kustomize replacements: the HelmRelease tag propagates to all
CronJobs, Jenkins worker and pod watcher. Verify the rendered and live images;
changing only the web Deployment would omit worker-side fixes. No database
migration, CNI change, new Secret name or manual dependency installation is
required for these application fixes.

## Post-check and rollback boundary

- Verify HelmRelease Ready, app `/livez` and `/readyz`, and actual workload image
  references; preserve the existing two replicas and maxUnavailable 0 strategy.
- Repeat real company browser login, session refresh, and read-only Cost/CI
  requests. Anonymous direct Service/Pod, fabricated identity headers and forged
  token signatures must not return data. External identities remain rejected;
  protected API responses must be `private, no-store`.
- Check worker/audit behavior and the next log archive job. The Jenkins console
  reader now requires identity content encoding; confirm the real proxy/server
  honors that contract. Rejected event identity conflicts are durably audited
  and require explicit replay after a trusted repair, not automatic retry.
- Missing app auth configuration produces 503 on readiness/protected routes.
  Missing forwarding with otherwise valid configuration can leave readiness green
  but browser requests returning 401. Do not infer successful login from probes.
- A rollback to the previous image reopens the backend bypass and requires
  explicit approval. Keep the safe gateway/environment prerequisites in place;
  never disable authentication to force a rollout through.
- Submit deployment/verification evidence for Helix review only after these
  checks. Event producer authentication/authorization and Kafka ACLs, historical
  credential retention, and other services' authorization remain separate work.

## Static validation

```sh
bash scripts/check_ci_dashboard_auth_config.sh
bash scripts/check_gcp_route_csrf.sh
kustomize build apps/gcp/ci-dashboard --load-restrictor=LoadRestrictionsNone
```

The auth and CSRF guards run in the apps CD Test job. Static validation is not
proof that a live Secret, Gateway policy, real login or production rollout works.
