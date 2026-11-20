# Tekton Cluster Decommissioning History

This document records the Tekton consolidation/decommissioning steps:

1. legacy `prod` -> `prod2` (historical);
2. `prod2` -> `gcp` / `tencentcloud` (2026-10);
3. `tencentcloud` -> `gcp` (2026-11).

## Legacy prod -> prod2 (historical)

- Tekton components were migrated to prod2 and removed from prod.
- The legacy prod cluster was later decommissioned and its Flux GitOps
  configuration removed.
- Rationale: consolidate Tekton workloads in prod2 and remove the maintenance
  surface for the retired prod cluster.

## prod2 -> gcp / tencentcloud (2026-10)

- prod2 (`ksy-pingcap-cicd`) Tekton is retired. The `apps/prod2/tekton/`
  directory and its four Flux Kustomizations are removed.
- Remaining prod2 builds were migrated to `env-gcp` triggers:
  - darwin: `build-component-darwin-mac` (gcp macbuild);
  - linux: `build-component-linux` / `build-component-all-platforms-mac`;
  - Harbor image-push triggers moved to the gcp Harbor EventListener.
- `tibuild-v2` in prod2 no longer triggers local Tekton; use the gcp or
  tencentcloud tibuild-v2 instance for devbuilds.
- `cloudevents-server` in prod2 is removed once no non-Tekton consumer remains.

## tencentcloud -> gcp (2026-11)

Tencentcloud had a full Tekton stack (`apps/tencentcloud/tekton/`: operator,
pipelines, triggers, dashboard, chains, manual-approval-gate) since 2026-08,
but nothing ever triggered it:

- no `PipelineRun`/`TaskRun` was ever kept on the cluster (the 30-minute pruner
  reported `0 expired PipelineRuns` on every run), while gcp carried all the
  build traffic;
- the only producers wired to a Tekton EventListener point at **gcp**:
  prow's `prow-tekton` external plugin endpoint is
  `http://el-github.ee-cd.svc:8080` in the gcp cluster, Harbor lives in gcp,
  and the tencentcloud tibuild-v2 instance has no public route and received no
  API traffic, so it never emitted its `el-tibuild` CloudEvents;
- the triggers were synced from the ci repository's `env-gcp` path, i.e. a
  copy with no tencentcloud-specific wiring.

teardown:

- `apps/tencentcloud/tekton/` removed: the `tekton-setup`, `tekton-configs` and
  `tekton-dashboard-ext` Flux Kustomizations are pruned, taking the operator,
  both Tekton namespaces, the CRDs, the event listeners, the dashboard route
  (`https://do.pingcap.net/tekton`), its OIDC `SecurityPolicy`/`ExternalSecret`
  and the dashboard extension with them.
- `ee-cd` survives: it is not Tekton-only (ci-dashboard-pod-watcher lives
  there), so its manifest moved to
  `apps/tencentcloud/ci-dashboard-pod-watcher/namespace.yaml`, annotated with
  `kustomize.toolkit.fluxcd.io/prune: disabled` so the `tekton-configs` prune
  cannot delete it (the annotation was applied in a separate, earlier
  revision — the prune reads the live object).
- `apps/tencentcloud/tibuild/v2/`: the `tekton:` block (CloudEvent endpoint,
  dashboard URLs, HMAC secret) is gone — that instance runs the image-copy
  delivery workers, devbuilds are dispatched by gcp.
- `apps/tencentcloud/cloudevents-server/`: the `tekton:` handler config and the
  `tekton_notify_lark_json` secret extraction are gone; the instance still
  handles the Jenkins `cdevents` test-case-run events.
- `tekton-pipelines`/`tekton-operator` dropped from the tencentcloud Kyverno
  node-selector policy and from the `ee-gcp-sm` ClusterSecretStore namespace
  allow-list.

Manual follow-ups (not in GitOps):

- remove `https://do.pingcap.net/tekton/oauth2/callback` from the Google OAuth
  client stored in Secret Manager key `google-oauth2-client-ee-apps` (the gcp
  route keeps `https://prow.tidb.net/tekton/oauth2/callback`).
- the Tekton dashboard of the gcp cluster (`https://prow.tidb.net/tekton`)
  remains the only dashboard; pipeline view links for tencentcloud no longer
  exist.
- reverting this means re-adding `apps/tencentcloud/tekton/` and the
  `tekton:` blocks above; nothing else in the cluster depends on them.

## Verification and validation

- Confirm `apps/prod2/tekton/`, `clusters/prod2` Tekton references, and the
  `tekton-operator` / `tekton-pipelines` namespace policy entries are absent
  from the repository.
- Confirm prod2 Flux no longer reconciles `tekton-*` Kustomizations.
- Confirm gcp/tencentcloud Tekton triggers exist for the migrated builds and
  that a canary build succeeds.
- On cluster: no Tekton CRDs, namespaces, webhooks, APIService, or
  `ee-cd`-scoped Tekton resources remain in prod2.

## Notes

- References to `prod` in other clusters may identify an image registry or
  deployment stage and are unrelated to the retired clusters.
