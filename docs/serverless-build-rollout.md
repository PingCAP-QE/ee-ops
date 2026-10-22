# Serverless build runtime configuration

The tibuild-v2 ExternalSecret templates in GCP and TencentCloud add five product
mappings to `tidbcloud/<product>`: tidb-cse, pd-cse, tidb-operator-cse,
cassandra-on-mysql and qdrant-on-tidb. Both clusters consume the CI env-gcp routes.
Prod2's local Tekton was retired in 2026-10; it retains its fail-closed endpoint
and does not advertise these new products. Use the GCP/TencentCloud tibuild-v2
instances for devbuilds.

EE-apps PR #725 and CI PR #5376 are merged. The existing ee-apps release workflow
published `v2026.10.18-21-g8f00edb` for both services:

- `ghcr.io/pingcap-qe/ee-apps/exp-tibuild-v2`, manifest digest
  `sha256:b366597363620a4af22ba722bb234a64decbd75cb16c2cbb3c9e126c0267a0f2`.
- `ghcr.io/pingcap-qe/ee-apps/chatops-lark`, manifest digest
  `sha256:d61540d0ec8a5f9f241ed1e91b28821aaaf59b50cc29995306905a4a2e61aedf`.

The GCP/TencentCloud tibuild-v2 and GCP chatops-lark HelmReleases pin that published
tag. Publication alone does not prove deployment or end-to-end devbuild support.
Release record: https://github.com/PingCAP-QE/ee-apps/actions/runs/39735884185.

The existing `github-pat-secret` ExternalSecret supplies GitHub username/password
for checkout and private Go/Cargo dependencies. Serverless PipelineRuns mount it
as `git-credentials`; build scripts never embed it in image layers. Its GitHub
token needs repository access and tidbcloud SAML SSO. The existing
`image-release-cred` references `gcp_sa_json_ee-releaser` and
`gcp_dockerconfig_json_ee-releaser`; keep credentials in this secret channel.

The private formal GAR repository is managed by ee-infra:
`us-docker.pkg.dev/pingcap-testing-account/serverless`. Project IAM inspection on
2026-10-19 confirmed `ee-releaser` has Artifact Registry admin/create-on-push roles,
and `gar-reader` has project-level Artifact Registry reader access. Repository
creation does not grant public access. Devbuild continues using the existing
`dev` GAR; publisher/delivery rules exclude these source repositories from
distribution and TiUP. Existing image-sync validation patterns intentionally do
not admit these dev artifacts.

## Rollout gates

1. Merge/provision private GAR via the existing Flux Terraform path; never run a
   local apply. Merge artifacts and CI changes, leaving formal routes staged.
2. Validate native Linux amd64/arm64 packages, checksums, image labels and complete
   manifests from pinned source/config revisions; record build URLs and digests.
3. Release the ee-apps images, update their HelmRelease image pins, reconcile
   product mappings, then verify actual capabilities and devbuild branch/tag/PR/
   commit inputs. Check two requested platforms produce two runs and reports wait
   for both; single-platform requests produce one. Verify artifact downloads and
   the existing Lark card structure. Request `version` remains compatibility
   metadata; available artifact tags come from Git. Completion waits for requested
   platforms, without requiring binary packages or version metadata.
4. Merge source cutover PRs, create the prescribed Git baselines on merged cutover
   commits and activate only explicit formal branch/tag routes. Confirm repository
   webhooks reach the GitHub EventListener. Keep old artifacts for rollback.
5. Provision the ee-infra dedicated `serverless-image-sync-reader` identity and
   GitHub OIDC provider. Its trust is restricted to the controller repository ID,
   owner ID, main ref and the two named sync workflows; its GAR reader role covers
   only `serverless`. Verify its main-branch authentication and retain target
   ECR/AliCloud writers/readers on their existing permissions.
   Validate formal images in dev destinations before switching prod sources.

No native regional Qdrant, TiKV, TiFlash, historical tag migration or business
workload deployment is part of this rollout. Configuration changes alone do not
prove service image deployment, registry access from the controller runner, or
end-to-end distribution; record those checks before moving to the next gate.
