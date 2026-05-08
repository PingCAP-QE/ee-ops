# Controlled Delivery Repository Design

## 📘 Overview
- This design defines a controlled image-delivery plane for private delivery.
- The objective is to deliver product images to customers without exposing the
  internal production registry and without giving customers write access to
  PingCAP-managed registries.
- Google Artifact Registry (GAR) is the default delivery backend.
- Docker Hub private repositories are an approved exception backend for
  customers that can only reach Docker Hub and cannot reach GAR.

## 🎯 Goals
- Protect PingCAP-owned product content during private delivery.
- Provide a customer-specific pull endpoint for image synchronization.
- Enforce repository-level isolation across customers and delivery batches.
- Make every delivery action auditable, time-bounded, and revocable.
- Use digest-based delivery as the source of truth.

## Non-goals
- Replacing the customer's internal registry.
- Allowing customers to push back into PingCAP-managed registries.
- Using the production artifact registry directly as the delivery surface.
- Building a self-service platform in phase 1.

## Principles
- Least privilege: customers get read-only access only.
- Repository isolation: one customer must not see another customer's content.
- Time-bound delivery: temporary repositories must expire.
- Deterministic delivery: all image references are validated by digest.
- GitOps-first: repository lifecycle, IAM, and publication intent are declared in Git.
- Auditability: repository creation, access grants, image publication, and cleanup must be traceable.

## Platform Constraints
- GAR standard Docker repositories are the recommended default delivery target.
- GAR cleanup policies apply to standard repositories and fit the
  temporary-delivery use case.
- Virtual repositories are not the primary delivery surface because lifecycle
  and customer isolation should be explicit at repository level.
- Docker Hub private repositories are not the default delivery plane because
  customer access, internal automation credentials, and repository lifecycle are
  governed differently than in GAR and require separate operating controls.

## Delivery Backend Selection
- Default online mode:
  - GAR controlled delivery
- Exception online mode:
  - Docker Hub private-repository delivery
- Fallback when the customer can use neither online mode:
  - approved offline image package delivery

### When GAR Should Be Used
- The customer can reach GAR endpoints.
- The customer can provide one Google user account or one Google service
  account.
- The customer needs repository-level reader access and customer-side
  synchronization into an internal registry.

### When Docker Hub Private Repositories May Be Used
- The customer explicitly cannot reach GAR.
- The customer environment can reach Docker Hub.
- The customer can use one Docker Hub account for pull access.
- Delivery owners accept that repository isolation, team membership, and tag
  lifecycle are governed by Docker Hub rather than by GAR IAM.

## 🏗️ Architecture
- Production artifact plane:
  stores internally published product images and is not directly exposed to customers.
- Delivery artifact plane:
  stores customer-approved delivery copies in the selected delivery backend.
- Customer sync plane:
  customers pull from the delivery repository and push into their own internal registry.

## Repository Model
- Default model: one repository per customer per delivery batch.
- Naming pattern:
  `<customer>-<delivery-batch>`
- Example:
  `customer-a-r2026q2`
- Example image path:
  `asia-east1-docker.pkg.dev/<delivery-project>/customer-a-r2026q2/tidb:v8.5.0`

### Why the Batch Repository Model Is Preferred
- Repository-level IAM is clearer than path-level conventions.
- Expiration and cleanup are easier to implement and audit.
- Customer scope is explicit and easy to revoke.
- Batch repositories reduce accidental reuse of stale content.

### Long-lived Repository Exception
- A long-lived customer repository may be used for strategic customers with frequent deliveries.
- It must still keep:
  - repository-level read-only IAM
  - explicit version retention policy
  - quarterly credential rotation
  - GitOps-managed publication manifests

## Docker Hub Private-repository Model
- Namespace:
  - use the Docker Hub organization `tidbcloud`
- Subscription baseline:
  - Docker Team plan
- Supported Docker Hub organization roles:
  - `member`
  - `editor`
  - `owner`
- Repository isolation model:
  - one private repository per customer per component
- Naming pattern:
  - `<customer>-<component>`
- Example:
  - `tidbcloud/customer-a-tidb`
  - `tidbcloud/customer-a-tikv`
- Batch management model:
  - manage delivery batches by tag, not by repository creation
- Example tags:
  - `v8.5.1`
  - `v8.5.1-r20260507`
  - `v8.5.1-r20260507-hotfix1`

### Why the Docker Hub Model Uses Repository-per-customer-per-component
- Team-based repository permissions are clearer at repository level than at tag
  level.
- Customer access can be scoped without letting customers see other customers'
  repositories.
- Batch tags stay within one repository, which avoids creating a large number of
  temporary repositories for repeated deliveries of the same component.
- Component-level separation makes pull authorization and retirement easier than
  putting all components for one customer into one broad repository.

## 🔐 Identity and Access Model
- Internal identities:
  - `delivery-bot`: writes to delivery repositories
  - `platform-admin`: creates repositories, manages IAM, retirement, and exceptions
- Customer identities:
  - GAR mode:
    - supported for repository-level reader grants:
      - Google user account
      - Google service account
    - recommended default:
      - Google user account for one-off or manual synchronization
      - customer-managed Google service account for automated synchronization
  - Docker Hub private-repository mode:
    - one Docker Hub account per customer
    - that account is added to one Docker Hub team dedicated to that customer
- Required customer role:
  - GAR mode:
    - `roles/artifactregistry.reader`
  - Docker Hub private-repository mode:
    - team-level read-only access to the customer's repositories
- Forbidden:
  - project-level reader grants
  - writer grants for customers
  - shared identities across multiple customers
  - one customer account added to multiple customer teams

## Docker Hub Team and Membership Model
- Organization:
  - `tidbcloud`
- Team naming rule:
  - use the customer name as the team name
- Example:
  - `customer-a`
- Membership rule:
  - each customer team contains exactly one customer account
- Reason:
  - avoid increasing seat cost for multiple accounts under the same customer
- Repository permission rule:
  - each team gets read-only access only to the repositories that belong to that
    customer
- Internal automation rule:
  - image publication automation should use Docker organization-owned
    credentials, not an individual maintainer password
  - prefer Docker organization access tokens when automation is needed
- Recommended organization role usage:
  - customer accounts use `member`
  - PingCAP delivery operators use `editor` or `owner` only when they need to
    manage repositories, teams, or membership

## Delivery Object Model
- Each delivery batch must publish:
  - `images.lock`
  - `release-manifest.yaml`
  - digest list
  - optional SBOM and signatures
- Delivery is validated by digest, not by tag alone.
- Customer synchronization should prefer registry-to-registry copy methods such as `crane copy` or `skopeo copy --all`.
- Plain `docker pull/tag/push` should be treated as fallback only because some registries may rewrite manifests and report a different destination digest.

### Example `images.lock`
```yaml
batch: customer-a-r2026q2
owner: delivery-team
expireAt: 2026-05-01
images:
  - name: tidb
    source: asia-east1-docker.pkg.dev/prod/tidb/tidb:v8.5.0
    delivery: asia-east1-docker.pkg.dev/delivery/customer-a-r2026q2/tidb:v8.5.0
    digest: sha256:1111
  - name: tikv
    source: asia-east1-docker.pkg.dev/prod/tikv/tikv:v8.5.0
    delivery: asia-east1-docker.pkg.dev/delivery/customer-a-r2026q2/tikv:v8.5.0
    digest: sha256:2222
```

## Lifecycle Model
- Temporary repositories:
  - default TTL: 14 or 30 days
  - IAM revoked before or at expiration
  - repository deleted or cleaned after the retention window
- Long-lived repositories:
  - keep only recent versions
  - rotate customer access regularly
  - require owner confirmation before extending retention

## Repository Labels
- Each repository should include:
  - `customer`
  - `owner`
  - `delivery_mode`
  - `expire_at`
  - `ticket`

## 🔄 Operational Workflow
1. Delivery request is approved.
2. Delivery owner selects the online backend:
   - GAR by default
   - Docker Hub private repository only when the customer cannot use GAR
3. Customer provides the identity to be authorized for repository read access.
   - GAR mode:
     - one Google user account email
     - or one customer-managed Google service account email
   - Docker Hub mode:
     - one Docker Hub account name controlled by that customer
4. Git declares the repository, access model, expiration, and manifests.
5. Backend-specific automation creates or updates the delivery surface.
   - GAR mode:
     - Terraform creates or updates the GAR repository
     - Terraform or automation grants `roles/artifactregistry.reader`
   - Docker Hub mode:
     - create or verify the Docker Hub private repositories
     - create or verify the Docker Hub customer team
     - grant read-only repository permissions to that team
6. Delivery bot copies or publishes images by digest into the selected delivery backend.
7. Delivery metadata and manifests are published.
8. Customer synchronizes images into the internal registry or directly pulls them for deployment, depending on the agreed workflow.
9. Expiration or retirement automation revokes access and removes or archives delivery content according to backend policy.

## Customer Request Requirements
- Each delivery request must include:
  - the requested delivery batch or ticket identifier
  - the image list or release manifest to be delivered
  - `images.lock` or the source information required to generate it
  - the requested expiration date
  - the requested delivery backend:
    - GAR
    - or Docker Hub private repository
  - one customer identity to authorize for repository read access
- The authorized customer identity must be one of:
  - GAR mode:
    - a Google user account email
    - or a Google service account email
  - Docker Hub mode:
    - one Docker Hub account name
- Additional Docker Hub mode inputs:
  - normalized customer short name used for repository and team naming
  - component list to be delivered
- If the customer cannot provide a supported identity for either online mode,
  use an approved offline delivery fallback instead of forcing an unsupported
  online workflow.

## Audit Requirements
- Track who created a repository.
- Track which customer identity received reader access.
- Track which digests were published into which repository.
- Track the `images.lock` content for each delivery batch.
- Track expiration, revocation, and deletion events.
- Preserve an immutable batch manifest in Git.

## 🚧 Guardrails
- Do not expose the production artifact registry directly.
- Do not grant customers write access to GAR.
- Do not use shared customer credentials.
- Do not use tag-only delivery records without source digest traceability.
- Do not keep temporary delivery repositories without an expiration policy.

## Recommended Phase Plan
- Phase 1:
  manual request intake, Git-driven repo definitions, delivery bot publication
- Phase 2:
  scripted repository creation, IAM grants, publication, and cleanup
- Phase 3:
  self-service front end backed by the same GitOps flow

## ✅ Decision
- Use GAR standard repositories as the default controlled delivery surface.
- Approve Docker Hub private repositories as an exception delivery surface for
  customers that can only reach Docker Hub.
- In GAR mode, default to one repository per customer per batch.
- In Docker Hub mode, default to one repository per customer per component and
  use tags to represent delivery batches.
- Manage repository lifecycle, access control, publication intent, and
  retirement through GitOps or equivalent reviewed control flows.
