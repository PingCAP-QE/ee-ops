# Serverless build runtime configuration

The tibuild-v2 ExternalSecret templates in GCP, prod2 and TencentCloud add five
product mappings to `tidbcloud/<product>`: tidb-cse, pd-cse, tidb-operator-cse,
cassandra-on-mysql and qdrant-on-tidb. GCP/TencentCloud consume the CI env-gcp
routes; prod2 consumes env-prod2. Both route sets must be present before these
capabilities are advertised. Publish tibuild-v2/chatops-lark images from the
coordinated ee-apps change through their existing image release channel, pin the
resulting image tags/digests in HelmRelease values and roll them out before
claiming devbuild support. Do not invent image tags before they exist.

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
`dev` GAR and never invokes artifact delivery. Existing image-sync validation
patterns intentionally do not admit these dev artifacts.

## Rollout gates

1. Merge/provision private GAR via the existing Flux Terraform path; never run a
   local apply. Merge artifacts and CI changes, leaving formal routes staged.
2. Validate native Linux amd64/arm64 packages, checksums, image labels and complete
   manifests from pinned source/config revisions; record build URLs and digests.
3. Release the ee-apps images, update their HelmRelease image pins, reconcile
   product mappings, then verify actual capabilities and devbuild branch/tag/PR/
   commit inputs. Check two requested platforms produce two runs and reports wait
   for both; single-platform requests produce one. Verify artifact downloads and
   rendered Lark cards without confusing request `version` with Git version.
4. Merge source cutover PRs, create the prescribed Git baselines on merged cutover
   commits and activate only explicit formal branch/tag routes. Confirm repository
   webhooks reach the GitHub EventListener. Keep old artifacts for rollback.
5. Confirm the docker-image-controller runner identity has formal GAR read access
   and target ECR/AliCloud writers/readers retain their existing permissions.
   Validate formal images in dev destinations before switching prod sources.

No native regional Qdrant, TiKV, TiFlash, historical tag migration or business
workload deployment is part of this rollout. Configuration changes alone do not
prove service image deployment, registry access from the controller runner, or
end-to-end distribution; record those checks before moving to the next gate.
