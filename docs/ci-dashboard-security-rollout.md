# CI Dashboard 1.9.14: combined security and freshness release

This single OPS PR combines the application identity environment, Envoy ID-token
forwarding, and the app/jobs image update. It supersedes the earlier proposal to
use two dependent PRs; the standalone image PR is redundant and must not be
merged separately.

The release contains ee-apps #765 (runtime limit validation), #766 (monthly Cost
query bounds), #767 (bounded Jenkins console scanning), #770 (event/build
identity consistency), #776 (backend company identity), and #778 (compact
freshness alerts and UTC calendar-day lag). It retains earlier #763 log
redaction and ee-ops #2536 gateway CSRF protection. The backend contract is
[backend-auth.md](https://github.com/PingCAP-QE/ee-apps/blob/3f13263449b107a72c756d16cf849801612f09b5/ci-dashboard/docs/backend-auth.md).

## One PR is not an atomic Kubernetes transaction

Splitting PRs was a conservative rollout choice, not an application requirement.
The environment and gateway forwarding are backward-compatible with the old
application, so they may be reviewed with the image change. However, Flux/Helm
and Envoy reconcile independently: one Git commit does **not** guarantee that
forwarding is active before new application Pods receive browser traffic.
`maxUnavailable: 0` protects replica availability, not token compatibility.
Readiness does not verify forwarding, real claims or session refresh; an app can
be ready while company browser requests return 401.

Keep this combined PR **Draft** until the target release has succeeded, both
images are present, the exact Workspace-domain policy is approved, and the
pre-merge identity validation below has passed. Do not interpret one PR as an
instruction to skip the validation or promise zero transient authentication
errors. Preparation/static CI alone does not authorize a production mutation.

## Configuration included in this PR

- App `CI_DASHBOARD_OIDC_CLIENT_ID` references the existing
  `apps/ci-dashboard-oidc` Secret's `client-id` key; the backend needs no client
  secret or signing key. The audience must match the gateway OIDC client.
- App `CI_DASHBOARD_OIDC_HOSTED_DOMAINS=pingcap.com` is an exact signed Google
  Workspace `hd` allowlist, not an email suffix/wildcard. Confirm this approved
  domain before merge; additional approved domains require an explicit manifest
  and static-guard review.
- Existing Dashboard SecurityPolicy adds
  `oidc.forwardIDToken.header: X-CI-Dashboard-ID-Token`. Forward the raw decrypted
  Google ID token, not an access token, email assertion, Authorization header or
  Cookie shortcut. Retain issuer/client refs/callback/openid/email/profile,
  encrypted sessions, refresh defaults and `csrf: {}`.
- Shared app/jobs release tag and sidebar version `1.9.14` are updated together.
  The existing Kustomize replacements update all CronJobs, Jenkins worker and
  pod watcher. Chart 0.3.3, scheduling, freshness configuration and Secret names
  are unchanged. No SQL migration, CNI change or manual dependency install.

## Image provenance

Target workflow: [release run 40846589399](https://github.com/PingCAP-QE/ee-apps/actions/runs/40846589399).
Source: `3f13263449b107a72c756d16cf849801612f09b5` (#778 merge).

The workflow completed successfully. Its `Generating tags` output,
`git describe` and GHCR agree on **`v2026.10.25-25-g3f13263`**:

```text
ghcr.io/pingcap-qe/ee-apps/ci-dashboard:v2026.10.25-25-g3f13263
ghcr.io/pingcap-qe/ee-apps/ci-dashboard-jobs:v2026.10.25-25-g3f13263
```

Both registry manifest lists contain linux/amd64 and linux/arm64. Index digests:

- app: `sha256:ffd772efc87fdbfcdd77701d70fa8db6b912a73390fbeab1cfa7cce538b1df9a`
- jobs: `sha256:ca5fb0e4d4c448f6fa133b71c915ab29b83143530f1b58538a42257ceeaa89fb`

Do not substitute the superseded `v2026.10.25-23-g648777f` image, which lacks #778,
or infer future publication from a tag candidate or partially published build.

## Pre-merge identity validation

Existing read-only preflight has confirmed: the old release is healthy, the OIDC
Secret has `client-id`/`client-secret` key names, the served SecurityPolicy CRD
supports `forwardIDToken.header`, and the old app Pod can fetch Google's public
certificates. None of these prove the new image's real login behavior.

Before replacing the working application, obtain explicit authorization for an
isolated private canary and any temporary gateway configuration/routing. Use the
exact final image, the same app environment, and actual Envoy Google OIDC raw
ID-token forwarding. Keep the working application serving; do not create an
unauthenticated public route. A canary may validate the candidate configuration
before this combined PR is merged; it does not require a separate permanent
prerequisite PR. If that validation cannot be arranged, leave the combined PR
Draft rather than silently removing the gate.

Require all of the following; record only pass/fail evidence:

- New-image Pod DNS/HTTPS egress to
  `https://www.googleapis.com/oauth2/v1/certs` works.
- A real company user's read-only API request through the authenticated canary
  path returns 200 and demonstrably reaches the new image, not the old app.
- An unauthenticated direct canary Service/Pod API request returns 401. Public
  anonymous requests may instead redirect to Google at the gateway.
- Real initial browser login and session refresh work; the actual signed `hd`,
  verified-email, issuer/audience/azp and forwarded-token conditions are met.
- The canary's live SecurityPolicy is Accepted for its current generation and
  actual forwarding is active, not merely present in rendered YAML.

Never write tokens, Cookie headers, claims or raw data responses to logs, files,
command history or PR comments. Never set `CI_DASHBOARD_AUTH_DISABLED=true` as a
production workaround. The static guard forbids that development bypass.

## Authorized rollout and post-check

After the validation gates, refresh CI against current main and obtain explicit
merge authorization for the combined PR. Check live gateway policy generation /
Accepted and forwarded-token configuration as soon as reconciliation starts;
then check the new application and worker/job image references. If reconciliation
order briefly exposes the new app before forwarding is active, authenticated
requests can return 401: treat that as a release problem, not successful login.
Halt/contain a failing rollout under the approved operations plan; do not weaken
authentication or improvise an automatic insecure fallback.

- Verify HelmRelease Ready, `/livez` and `/readyz`; preserve two app replicas and
  maxUnavailable 0. Missing auth environment causes readiness/protected 503;
  missing forwarding can leave readiness green but browser requests at 401.
- Recheck real company login/refresh and Cost/CI reads. Anonymous direct
  Service/Pod, fabricated email headers and forged token signatures must not
  return data. External identities stay rejected; API responses must be
  `private, no-store`.
- Check worker/audit and next log archive execution. The console reader requires
  identity encoding from Jenkins/proxy. Rejected build-identity conflicts remain
  audited and need explicit replay after a trusted repair, not automatic retry.
- Observe the existing 09:10 Asia/Shanghai freshness job; #778 adds no job or
  configuration. Evaluated healthy checks are silent; failures appear once per
  item with lag/allowance/excess. Cost DATE thresholds use UTC days (D-4 passes,
  D-5 fails; weekly D-10 passes, D-11 fails), while CI hour thresholds are unchanged.
  Import gap 1 day and attribution gap 0 days are unchanged. AWS split/F04 scope
  diagnostics are neither failures nor proof of success; real local gaps,
  unknown vendors, query/config errors and the unresolved active Azure empty
  source still alert. Do not force a real failure or rewrite data to test this.
- A rollback to the old image reopens the backend bypass and requires explicit
  approval. Safe gateway/environment settings may remain; never disable auth to
  force the release through.
- Submit deployment/test evidence to Helix only after verification. Producer
  authentication/authorization and Kafka ACLs, historical credential retention,
  Azure source-owner decisions and other services' authorization remain separate.

## Static validation

```sh
bash scripts/check_ci_dashboard_auth_config.sh
bash scripts/check_gcp_route_csrf.sh
kustomize build apps/gcp/ci-dashboard --load-restrictor=LoadRestrictionsNone
```

The guards run in apps CD Test. Static success is not proof of a live Secret,
actual forwarding, real company login/refresh, successful deployment or rescan.
