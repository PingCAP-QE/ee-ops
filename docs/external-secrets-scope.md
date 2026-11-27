# External Secrets scope of `ClusterSecretStore/ee-gcp-sm`

`ee-gcp-sm` is a `ClusterSecretStore` backed by a single GCP Secret Manager
service account. A store has one credential and no per-namespace or per-key
ACL: any namespace that matches `spec.conditions[].namespaceSelector` can create
an `ExternalSecret` against it and read **any** secret that service account can
access. The only fine-grained control point is GCP IAM, which is why the
namespace allowlist is a security boundary and not a convenience.

This page records who is behind that boundary today, cluster by cluster, and how
the namespaces are meant to be split into trust domains. It is the inventory
step of the `ee-gcp-sm` scope reduction that closes Helix finding `4d4abbbe`;
the store, service-account and IAM changes themselves land in follow-up pull
requests.

## How the matrix is produced

`scripts/eso-scope-inventory.sh` walks the Flux Kustomization tree of every
cluster (`clusters/<cluster>` → nested `Kustomization` objects) and renders each
path the way kustomize-controller does:

- kustomize `namespace:` transforms,
- Flux `spec.targetNamespace`,
- Flux `postBuild.substitute` variables (for example the `TEST_PODS_NAMESPACE`
  substitution that gives the Prow PR-job manifests their namespace).

It then reads the allowlist from the rendered `ClusterSecretStore/ee-gcp-sm` and
joins it with the `ExternalSecret` objects that reference it. Paths applied by a
source other than the in-repo `flux-system` GitRepository are not built, and a
manifest that is reconciled twice is counted once.

Regenerate and commit the block below after touching ExternalSecrets or a
namespace allowlist:

```bash
scripts/eso-scope-inventory.sh --write
```

`scripts/eso-scope-inventory.sh --check` fails when the committed block differs
from a fresh render; CI runs it for every pull request that can change the
result. The table is intentionally generated, so a new namespace or secret shows
up as a reviewable diff instead of silently widening the blast radius.

## Reading the tables

- **Allowlisted namespaces** — entries in the store's `namespaceSelector`.
- **Consuming namespaces** — namespaces that actually render an `ExternalSecret`
  against `ee-gcp-sm`. A consumer outside the allowlist would be rejected by the
  store (`SyncFailed`); the script treats that as an error.
- **Namespaces without consumers** — allowlisted but with nothing to pull. Each
  of these is a namespace that can read the whole credential for no reason.
- **Trust domain** — the store the namespace is planned to move to. `CORE` keeps
  the existing `ee-gcp-sm`; `CI`, `JENKINS`, `JENKINS-AGENTS` and `APP` get their
  own GCP service account on the GKE clusters. `JENKINS` is the controller
  namespace only: the per-repo `jenkins-*` agent namespaces are the separate
  `JENKINS-AGENTS` domain, whose identity and store come from the External
  Secrets work in `pingcap-qe/ee-infra` rather than from this repository.
  `unassigned` means the namespace is not part of the split yet and needs a
  decision before the migration, not a guess.
- **Counts** — the `ExternalSecrets` column counts objects, so the same
  ExternalSecret name in two namespaces counts twice. The secret column counts
  distinct GCP secret names, and one ExternalSecret may pull several, so the two
  columns are not comparable with each other.

<!-- BEGIN GENERATED: eso-scope (scripts/eso-scope-inventory.sh) -->
### Summary

| Cluster | Allowlisted namespaces | Consuming namespaces | Namespaces without consumers | ExternalSecrets | Distinct GCP secrets |
| :--- | ---: | ---: | ---: | ---: | ---: |
| `gcp` | 22 | 22 | 0 | 70 | 51 |
| `tencentcloud` | 17 | 17 | 0 | 42 | 38 |
| `prod2` | 6 | 6 | 0 | 14 | 26 |
| **Total** | **45** | **45** | **0** | **126** | **87** |

### Consumers by namespace

#### `gcp`

| Namespace | Trust domain | ExternalSecrets | GCP secret names |
| :--- | :--- | ---: | :--- |
| `apps` | CORE | 3 | `gcp_ci_dashboard_kafka_password`, `gcp_kafka_cluster_ca`, `google-oauth2-client-ee-apps` |
| `chatops-lark` | APP | 1 | `gcp_chatops_lark_json` |
| `cs` | APP | 2 | `gcp_cloudevents_kafka_password`, `gcp_cloudevents_lark_app_secret`, `gcp_cloudevents_test_case_run_dsn`, `gcp_kafka_cluster_ca` |
| `dl` | APP | 4 | `gcp_dl_config_json`, `gcp_dl_delivery_policy_json`, `gcp_dl_delivery_tidb_json`, `google-oauth2-client-ee-apps` |
| `dl-approval` | APP | 3 | `gcp_dl_approval_config_json`, `gcp_dl_approval_tidb_json`, `google-oauth2-client-ee-apps` |
| `ee-authz` | CORE | 2 | `ee-authzd-config`, `ee-openfga-backend` |
| `ee-cd` | CI | 8 | `ga_offline_pkg_s3_json`, `gcp_dockerconfig_json_ee-releaser`, `gcp_prow_github_app_webhook_hmac`, `gcp_sa_json_ee-releaser`, `gcp_tibuild_cloudevent_hmac`, `github-bot-ssh-rsa-json`, `github-bot-token`, `github-bot-username`, `tidbx-delivery-github-issue` |
| `flux-system` | CORE | 1 | `tencentcloud_ci_terraform_creds` |
| `github-token-broker` | CORE | 3 | `gha__system__github_app_private_key`, `github-token-broker-policy`, `github_token_broker_external_reader_token` |
| `infra` | CORE | 2 | `gcp_wildcard_pingcap_net_cert_json`, `gcp_wildcard_tidb_net_cert_json` |
| `jenkins` | JENKINS | 12 | `gcp_jenkins_cache_s3_json`, `github-bot-ssh-rsa-json`, `github-bot-token`, `github-bot-username`, `google-oauth2-client-jenkins`, `prod2_jenkins_beta_codecov_tokens_json`, `prod2_jenkins_beta_ks3util_config` |
| `jenkins-pd` | JENKINS-AGENTS | 1 | `ci_registry_auth_dockerconfig_json` |
| `jenkins-ticdc` | JENKINS-AGENTS | 1 | `ci_registry_auth_dockerconfig_json` |
| `jenkins-tidb` | JENKINS-AGENTS | 1 | `ci_registry_auth_dockerconfig_json` |
| `jenkins-tiflash` | JENKINS-AGENTS | 1 | `ci_registry_auth_dockerconfig_json` |
| `jenkins-tiflow` | JENKINS-AGENTS | 1 | `ci_registry_auth_dockerconfig_json` |
| `jenkins-tikv` | JENKINS-AGENTS | 1 | `ci_registry_auth_dockerconfig_json` |
| `kafka` | APP | 2 | `gcp_ci_dashboard_kafka_password`, `gcp_cloudevents_kafka_password` |
| `prow` | CI | 8 | `gcp_gcs_sa_json`, `gcp_prow_external_clusters_kubeconfig`, `gcp_prow_github_app_json`, `gcp_prow_github_app_oauth_cookie_secret`, `gcp_prow_github_app_webhook_hmac`, `gcp_prow_jenkins_operator_0_auth_json`, `gcp_prow_jenkins_operator_1_auth_json`, `gcp_prow_openai_json`, `github-bot-token` |
| `prow-test-pods` | CI | 8 | `gcp_ci_smtp_config_json`, `gcp_codecov_tokens_json`, `gcp_gcs_sa_json`, `gcp_prow_ci_job_params_flattened`, `gcp_prow_docs_cn_s3_json`, `github-bot-ssh-rsa-json`, `github-bot-token`, `tencentcloud_ci_terraform_creds` |
| `tekton-pipelines` | CI | 1 | `google-oauth2-client-ee-apps` |
| `tibuild` | APP | 4 | `gcp_dockerconfig_json_ee-releaser`, `gcp_sa_json_ee-releaser`, `gcp_tibuild_cloudevent_hmac`, `github-bot-token`, `google-oauth2-client-ee-apps`, `tcms_public_api_json`, `tibuild_v2_dsn`, `tibuild_v2_lark_app_id`, `tibuild_v2_lark_app_secret`, `tidbcloud_ops_api_dev_json`, `tidbcloud_ops_api_prod_json` |

#### `tencentcloud`

| Namespace | Trust domain | ExternalSecrets | GCP secret names |
| :--- | :--- | ---: | :--- |
| `arc-runners` | CI | 1 | `arc__org__pingcap-qe__github_app_installation_id`, `gha__system__github_app_id`, `gha__system__github_app_private_key` |
| `cache` | APP | 3 | `ci_registry_auth_dockerconfig_json`, `tencentcloud_common_creds_json`, `tencentcloud_kellnr_admin_json` |
| `cs` | APP | 2 | `tencentcloud_cloudevents_kafka_password`, `tencentcloud_kafka_cluster_ca`, `tencentcloud_test_case_run_dsn` |
| `ee-cd` | CI | 1 | `tencentcloud_ci_dashboard_db_json` |
| `github-token-broker` | CORE | 2 | `gha__system__github_app_private_key`, `github-token-broker-policy` |
| `infra` | CORE | 2 | `gcp_wildcard_pingcap_net_cert_json`, `gcp_wildcard_tidb_net_cert_json` |
| `jenkins` | JENKINS | 10 | `github-bot-ssh-rsa-json`, `github-bot-token`, `github-bot-username`, `google-oauth2-client-jenkins`, `tencentcloud_common_creds_json`, `tencentcloud_jenkins_artifact_s3_json`, `tencentcloud_jenkins_cache_s3_json`, `tencentcloud_jenkins_codecov_tokens_json` |
| `jenkins-pd` | JENKINS-AGENTS | 1 | `ci_registry_auth_dockerconfig_json` |
| `jenkins-ticdc` | JENKINS-AGENTS | 1 | `ci_registry_auth_dockerconfig_json` |
| `jenkins-tidb` | JENKINS-AGENTS | 1 | `ci_registry_auth_dockerconfig_json` |
| `jenkins-tiflash` | JENKINS-AGENTS | 1 | `ci_registry_auth_dockerconfig_json` |
| `jenkins-tiflow` | JENKINS-AGENTS | 1 | `ci_registry_auth_dockerconfig_json` |
| `jenkins-tikv` | JENKINS-AGENTS | 1 | `ci_registry_auth_dockerconfig_json` |
| `kafka` | APP | 1 | `tencentcloud_cloudevents_kafka_password` |
| `prow-test-pods` | CI | 7 | `ci_registry_auth_dockerconfig_json`, `gcp_ci_smtp_config_json`, `gcp_codecov_tokens_json`, `gcp_gcs_sa_json`, `gcp_prow_ci_job_params_flattened`, `gcp_prow_docs_cn_s3_json`, `github-bot-token` |
| `tibuild` | APP | 3 | `gcp_dockerconfig_json_ee-releaser`, `gcp_sa_json_ee-releaser`, `github-bot-token`, `tibuild_v2_dsn`, `tibuild_v2_lark_app_id`, `tibuild_v2_lark_app_secret`, `tidbx-ops-client-tibuild-v2-basic-auth` |
| `zot` | APP | 4 | `google-oauth2-client-zot`, `tencentcloud_common_creds_json`, `tencentcloud_zot_htpasswd`, `tencentcloud_zot_personal_users`, `tencentcloud_zot_redis_password`, `tencentcloud_zot_s3_json`, `tencentcloud_zot_sessionKeys_json`, `tencentcloud_zot_sync_auth_credentials_json` |

#### `prod2`

| Namespace | Trust domain | ExternalSecrets | GCP secret names |
| :--- | :--- | ---: | :--- |
| `arc-runners` | single store | 1 | `arc__repo__pingcap__tiup__github_app_installation_id`, `gha__system__github_app_id`, `gha__system__github_app_private_key` |
| `dl` | single store | 2 | `prod2_dl_config_json`, `prod2_publisher_worker_dockerconfig_json` |
| `infra` | single store | 2 | `gcp_wildcard_pingcap_cn_cert_json`, `gcp_wildcard_pingcap_net_cert_json` |
| `tibuild` | single store | 4 | `gcp_sa_json_ee-releaser`, `github-bot-token`, `prod2_ee-releasor_dockerconfig_json`, `tibuild_v2_dsn`, `tibuild_v2_lark_app_id`, `tibuild_v2_lark_app_secret`, `tibuild_v2_lark_channels`, `tiup-prod-mirror-url`, `tiup-prod-private-key-json`, `tiup-staging-mirror-url`, `tiup-staging-private-key-json` |
| `tirelease` | single store | 1 | `tirelease-tibuild-sa-key_json`, `tirelease_secret_json` |
| `zot` | single store | 4 | `google-oauth2-client-zot`, `prod2_zot_htpasswd`, `prod2_zot_redis_password`, `prod2_zot_s3`, `prod2_zot_sessionKeys_json`, `prod2_zot_sync_auth_credentials_json` |

### Planned trust domains

#### `gcp`

| Domain | Target store | Namespaces | ExternalSecrets | Distinct GCP secrets |
| :--- | :--- | :--- | ---: | ---: |
| CORE | `ee-gcp-sm` | `apps`, `ee-authz`, `flux-system`, `github-token-broker`, `infra` | 11 | 11 |
| CI | `ee-gcp-sm-ci` | `ee-cd`, `prow`, `prow-test-pods`, `tekton-pipelines` | 25 | 22 |
| JENKINS | `ee-gcp-sm-jenkins` | `jenkins` | 12 | 7 |
| JENKINS-AGENTS | `ee-gcp-sm-jenkins-agents` | `jenkins-pd`, `jenkins-ticdc`, `jenkins-tidb`, `jenkins-tiflash`, `jenkins-tiflow`, `jenkins-tikv` | 6 | 1 |
| APP | `ee-gcp-sm-app` | `chatops-lark`, `cs`, `dl`, `dl-approval`, `kafka`, `tibuild` | 16 | 22 |

`JENKINS-AGENTS` is served by an identity and store owned by the External Secrets work in `pingcap-qe/ee-infra`; this repository does not create that store. `JENKINS` is the controller namespace only.

#### `tencentcloud`

| Domain | Target store | Namespaces | ExternalSecrets | Distinct GCP secrets |
| :--- | :--- | :--- | ---: | ---: |
| CORE | `ee-gcp-sm` | `github-token-broker`, `infra` | 4 | 4 |
| CI | `ee-gcp-sm-ci-app` | `arc-runners`, `ee-cd`, `prow-test-pods` | 9 | 11 |
| JENKINS | `ee-gcp-sm-ci-app` | `jenkins` | 10 | 8 |
| JENKINS-AGENTS | `ee-gcp-sm-ci-app` | `jenkins-pd`, `jenkins-ticdc`, `jenkins-tidb`, `jenkins-tiflash`, `jenkins-tiflow`, `jenkins-tikv` | 6 | 1 |
| APP | `ee-gcp-sm-ci-app` | `cache`, `cs`, `kafka`, `tibuild`, `zot` | 13 | 20 |

`prod2` keeps a single store; 6 namespaces, 26 distinct secret names.

The same store keeps the organisation-wide GitHub App private key (`gha__system__github_app_private_key`) readable from `arc-runners`, so narrowing this store's GCP IAM does not reduce that key's reach: it needs a separate store or an explicit accepted risk.

### Secret index

| GCP secret | Cluster | Namespaces that can read it |
| :--- | :--- | :--- |
| `arc__org__pingcap-qe__github_app_installation_id` | `tencentcloud` | `arc-runners` |
| `arc__repo__pingcap__tiup__github_app_installation_id` | `prod2` | `arc-runners` |
| `ci_registry_auth_dockerconfig_json` | `gcp` | `jenkins-pd`, `jenkins-ticdc`, `jenkins-tidb`, `jenkins-tiflash`, `jenkins-tiflow`, `jenkins-tikv` |
| `ci_registry_auth_dockerconfig_json` | `tencentcloud` | `cache`, `jenkins-pd`, `jenkins-ticdc`, `jenkins-tidb`, `jenkins-tiflash`, `jenkins-tiflow`, `jenkins-tikv`, `prow-test-pods` |
| `ee-authzd-config` | `gcp` | `ee-authz` |
| `ee-openfga-backend` | `gcp` | `ee-authz` |
| `ga_offline_pkg_s3_json` | `gcp` | `ee-cd` |
| `gcp_chatops_lark_json` | `gcp` | `chatops-lark` |
| `gcp_ci_dashboard_kafka_password` | `gcp` | `apps`, `kafka` |
| `gcp_ci_smtp_config_json` | `gcp` | `prow-test-pods` |
| `gcp_ci_smtp_config_json` | `tencentcloud` | `prow-test-pods` |
| `gcp_cloudevents_kafka_password` | `gcp` | `cs`, `kafka` |
| `gcp_cloudevents_lark_app_secret` | `gcp` | `cs` |
| `gcp_cloudevents_test_case_run_dsn` | `gcp` | `cs` |
| `gcp_codecov_tokens_json` | `gcp` | `prow-test-pods` |
| `gcp_codecov_tokens_json` | `tencentcloud` | `prow-test-pods` |
| `gcp_dl_approval_config_json` | `gcp` | `dl-approval` |
| `gcp_dl_approval_tidb_json` | `gcp` | `dl-approval` |
| `gcp_dl_config_json` | `gcp` | `dl` |
| `gcp_dl_delivery_policy_json` | `gcp` | `dl` |
| `gcp_dl_delivery_tidb_json` | `gcp` | `dl` |
| `gcp_dockerconfig_json_ee-releaser` | `gcp` | `ee-cd`, `tibuild` |
| `gcp_dockerconfig_json_ee-releaser` | `tencentcloud` | `tibuild` |
| `gcp_gcs_sa_json` | `gcp` | `prow`, `prow-test-pods` |
| `gcp_gcs_sa_json` | `tencentcloud` | `prow-test-pods` |
| `gcp_jenkins_cache_s3_json` | `gcp` | `jenkins` |
| `gcp_kafka_cluster_ca` | `gcp` | `apps`, `cs` |
| `gcp_prow_ci_job_params_flattened` | `gcp` | `prow-test-pods` |
| `gcp_prow_ci_job_params_flattened` | `tencentcloud` | `prow-test-pods` |
| `gcp_prow_docs_cn_s3_json` | `gcp` | `prow-test-pods` |
| `gcp_prow_docs_cn_s3_json` | `tencentcloud` | `prow-test-pods` |
| `gcp_prow_external_clusters_kubeconfig` | `gcp` | `prow` |
| `gcp_prow_github_app_json` | `gcp` | `prow` |
| `gcp_prow_github_app_oauth_cookie_secret` | `gcp` | `prow` |
| `gcp_prow_github_app_webhook_hmac` | `gcp` | `ee-cd`, `prow` |
| `gcp_prow_jenkins_operator_0_auth_json` | `gcp` | `prow` |
| `gcp_prow_jenkins_operator_1_auth_json` | `gcp` | `prow` |
| `gcp_prow_openai_json` | `gcp` | `prow` |
| `gcp_sa_json_ee-releaser` | `gcp` | `ee-cd`, `tibuild` |
| `gcp_sa_json_ee-releaser` | `tencentcloud` | `tibuild` |
| `gcp_sa_json_ee-releaser` | `prod2` | `tibuild` |
| `gcp_tibuild_cloudevent_hmac` | `gcp` | `ee-cd`, `tibuild` |
| `gcp_wildcard_pingcap_cn_cert_json` | `prod2` | `infra` |
| `gcp_wildcard_pingcap_net_cert_json` | `gcp` | `infra` |
| `gcp_wildcard_pingcap_net_cert_json` | `tencentcloud` | `infra` |
| `gcp_wildcard_pingcap_net_cert_json` | `prod2` | `infra` |
| `gcp_wildcard_tidb_net_cert_json` | `gcp` | `infra` |
| `gcp_wildcard_tidb_net_cert_json` | `tencentcloud` | `infra` |
| `gha__system__github_app_id` | `tencentcloud` | `arc-runners` |
| `gha__system__github_app_id` | `prod2` | `arc-runners` |
| `gha__system__github_app_private_key` | `gcp` | `github-token-broker` |
| `gha__system__github_app_private_key` | `tencentcloud` | `arc-runners`, `github-token-broker` |
| `gha__system__github_app_private_key` | `prod2` | `arc-runners` |
| `github-bot-ssh-rsa-json` | `gcp` | `ee-cd`, `jenkins`, `prow-test-pods` |
| `github-bot-ssh-rsa-json` | `tencentcloud` | `jenkins` |
| `github-bot-token` | `gcp` | `ee-cd`, `jenkins`, `prow`, `prow-test-pods`, `tibuild` |
| `github-bot-token` | `tencentcloud` | `jenkins`, `prow-test-pods`, `tibuild` |
| `github-bot-token` | `prod2` | `tibuild` |
| `github-bot-username` | `gcp` | `ee-cd`, `jenkins` |
| `github-bot-username` | `tencentcloud` | `jenkins` |
| `github-token-broker-policy` | `gcp` | `github-token-broker` |
| `github-token-broker-policy` | `tencentcloud` | `github-token-broker` |
| `github_token_broker_external_reader_token` | `gcp` | `github-token-broker` |
| `google-oauth2-client-ee-apps` | `gcp` | `apps`, `dl`, `dl-approval`, `tekton-pipelines`, `tibuild` |
| `google-oauth2-client-jenkins` | `gcp` | `jenkins` |
| `google-oauth2-client-jenkins` | `tencentcloud` | `jenkins` |
| `google-oauth2-client-zot` | `tencentcloud` | `zot` |
| `google-oauth2-client-zot` | `prod2` | `zot` |
| `prod2_dl_config_json` | `prod2` | `dl` |
| `prod2_ee-releasor_dockerconfig_json` | `prod2` | `tibuild` |
| `prod2_jenkins_beta_codecov_tokens_json` | `gcp` | `jenkins` |
| `prod2_jenkins_beta_ks3util_config` | `gcp` | `jenkins` |
| `prod2_publisher_worker_dockerconfig_json` | `prod2` | `dl` |
| `prod2_zot_htpasswd` | `prod2` | `zot` |
| `prod2_zot_redis_password` | `prod2` | `zot` |
| `prod2_zot_s3` | `prod2` | `zot` |
| `prod2_zot_sessionKeys_json` | `prod2` | `zot` |
| `prod2_zot_sync_auth_credentials_json` | `prod2` | `zot` |
| `tcms_public_api_json` | `gcp` | `tibuild` |
| `tencentcloud_ci_dashboard_db_json` | `tencentcloud` | `ee-cd` |
| `tencentcloud_ci_terraform_creds` | `gcp` | `flux-system`, `prow-test-pods` |
| `tencentcloud_cloudevents_kafka_password` | `tencentcloud` | `cs`, `kafka` |
| `tencentcloud_common_creds_json` | `tencentcloud` | `cache`, `jenkins`, `zot` |
| `tencentcloud_jenkins_artifact_s3_json` | `tencentcloud` | `jenkins` |
| `tencentcloud_jenkins_cache_s3_json` | `tencentcloud` | `jenkins` |
| `tencentcloud_jenkins_codecov_tokens_json` | `tencentcloud` | `jenkins` |
| `tencentcloud_kafka_cluster_ca` | `tencentcloud` | `cs` |
| `tencentcloud_kellnr_admin_json` | `tencentcloud` | `cache` |
| `tencentcloud_test_case_run_dsn` | `tencentcloud` | `cs` |
| `tencentcloud_zot_htpasswd` | `tencentcloud` | `zot` |
| `tencentcloud_zot_personal_users` | `tencentcloud` | `zot` |
| `tencentcloud_zot_redis_password` | `tencentcloud` | `zot` |
| `tencentcloud_zot_s3_json` | `tencentcloud` | `zot` |
| `tencentcloud_zot_sessionKeys_json` | `tencentcloud` | `zot` |
| `tencentcloud_zot_sync_auth_credentials_json` | `tencentcloud` | `zot` |
| `tibuild_v2_dsn` | `gcp` | `tibuild` |
| `tibuild_v2_dsn` | `tencentcloud` | `tibuild` |
| `tibuild_v2_dsn` | `prod2` | `tibuild` |
| `tibuild_v2_lark_app_id` | `gcp` | `tibuild` |
| `tibuild_v2_lark_app_id` | `tencentcloud` | `tibuild` |
| `tibuild_v2_lark_app_id` | `prod2` | `tibuild` |
| `tibuild_v2_lark_app_secret` | `gcp` | `tibuild` |
| `tibuild_v2_lark_app_secret` | `tencentcloud` | `tibuild` |
| `tibuild_v2_lark_app_secret` | `prod2` | `tibuild` |
| `tibuild_v2_lark_channels` | `prod2` | `tibuild` |
| `tidbcloud_ops_api_dev_json` | `gcp` | `tibuild` |
| `tidbcloud_ops_api_prod_json` | `gcp` | `tibuild` |
| `tidbx-delivery-github-issue` | `gcp` | `ee-cd` |
| `tidbx-ops-client-tibuild-v2-basic-auth` | `tencentcloud` | `tibuild` |
| `tirelease-tibuild-sa-key_json` | `prod2` | `tirelease` |
| `tirelease_secret_json` | `prod2` | `tirelease` |
| `tiup-prod-mirror-url` | `prod2` | `tibuild` |
| `tiup-prod-private-key-json` | `prod2` | `tibuild` |
| `tiup-staging-mirror-url` | `prod2` | `tibuild` |
| `tiup-staging-private-key-json` | `prod2` | `tibuild` |

### ExternalSecrets using other stores

Outside this inventory because they do not go through `ee-gcp-sm`:

- `gcp`: `SecretStore/gcp-sm-github-actions` × 8

### Findings

- Allowlists match consumption and every namespace has a trust domain.
<!-- END GENERATED: eso-scope -->

## Related

- Helix finding `4d4abbbe` — the reported over-broad `ee-gcp-sm` scope this
  inventory answers.
- `pingcap-qe/ee-infra` — declarative GSA/IAM for the store credentials and the
  secret-level bindings the migration will rely on.
