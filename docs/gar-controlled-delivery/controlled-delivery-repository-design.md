GAR Controlled Delivery Repository Design
=========================================

Overview
- This design defines a controlled image-delivery plane for private delivery.
- The objective is to deliver product images to customers without exposing the
  internal production registry and without giving customers write access to
  PingCAP-managed registries.
- Google Artifact Registry (GAR) is the delivery backend.

Design goals
- Protect PingCAP-owned product content during private delivery.
- Provide a customer-specific pull endpoint for image synchronization.
- Enforce repository-level isolation across customers and delivery batches.
- Make every delivery action auditable, time-bounded, and revocable.
- Use digest-based delivery as the source of truth.

Non-goals
- Replacing the customer's internal registry.
- Allowing customers to push back into PingCAP-managed registries.
- Using the production artifact registry directly as the delivery surface.
- Building a self-service platform in phase 1.

Principles
- Least privilege: customers get read-only access only.
- Repository isolation: one customer must not see another customer's content.
- Time-bound delivery: temporary repositories must expire.
- Deterministic delivery: all image references are validated by digest.
- GitOps-first: repository lifecycle, IAM, and publication intent are declared in Git.
- Auditability: repository creation, access grants, image publication, and cleanup must be traceable.

Platform constraints
- GAR standard Docker repositories are the recommended delivery target.
- GAR cleanup policies apply to standard repositories and fit the temporary-delivery use case.
- Virtual repositories are not the primary delivery surface because lifecycle and customer isolation should be explicit at repository level.

Architecture
- Production artifact plane:
  stores internally published product images and is not directly exposed to customers.
- Delivery artifact plane:
  stores customer-approved delivery copies in GAR.
- Customer sync plane:
  customers pull from the delivery repository and push into their own internal registry.

Repository model
- Default model: one repository per customer per delivery batch.
- Naming pattern:
  `<customer>-<delivery-batch>`
- Example:
  `customer-a-r2026q2`
- Example image path:
  `asia-east1-docker.pkg.dev/<delivery-project>/customer-a-r2026q2/tidb:v8.5.0`

Why the batch repository model is preferred
- Repository-level IAM is clearer than path-level conventions.
- Expiration and cleanup are easier to implement and audit.
- Customer scope is explicit and easy to revoke.
- Batch repositories reduce accidental reuse of stale content.

Long-lived repository exception
- A long-lived customer repository may be used for strategic customers with frequent deliveries.
- It must still keep:
  - repository-level read-only IAM
  - explicit version retention policy
  - quarterly credential rotation
  - GitOps-managed publication manifests

Identity and access model
- Internal identities:
  - `delivery-bot`: writes to delivery repositories
  - `platform-admin`: creates repositories, manages IAM, retirement, and exceptions
- Customer identities:
  - preferred: customer-managed Google identity or service account
  - fallback: PingCAP-managed dedicated read-only identity for that customer only
- Required customer role:
  - `roles/artifactregistry.reader`
- Forbidden:
  - project-level reader grants
  - writer grants for customers
  - shared identities across multiple customers

Delivery object model
- Each delivery batch must publish:
  - `images.lock`
  - `release-manifest.yaml`
  - digest list
  - optional SBOM and signatures
- Delivery is validated by digest, not by tag alone.

Example `images.lock`
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

Lifecycle model
- Temporary repositories:
  - default TTL: 14 or 30 days
  - IAM revoked before or at expiration
  - repository deleted or cleaned after the retention window
- Long-lived repositories:
  - keep only recent versions
  - rotate customer access regularly
  - require owner confirmation before extending retention

Repository labels
- Each repository should include:
  - `customer`
  - `owner`
  - `delivery_mode`
  - `expire_at`
  - `ticket`

Operational workflow
1. Delivery request is approved.
2. Git declares the repository, IAM, and expiration.
3. Terraform creates or updates the GAR repository.
4. Delivery bot copies images by digest from production into the delivery repository.
5. Delivery metadata and manifests are published.
6. Customer synchronizes images into the internal registry.
7. Expiration automation revokes access and removes expired repositories.

Audit requirements
- Track who created a repository.
- Track which customer identity received reader access.
- Track which digests were published into which repository.
- Track expiration, revocation, and deletion events.
- Preserve an immutable batch manifest in Git.

Security guardrails
- Do not expose the production artifact registry directly.
- Do not grant customers write access to GAR.
- Do not use shared customer credentials.
- Do not deliver by tag only.
- Do not keep temporary delivery repositories without an expiration policy.

Recommended phase plan
- Phase 1:
  manual request intake, Git-driven repo definitions, delivery bot publication
- Phase 2:
  scripted repository creation, IAM grants, publication, and cleanup
- Phase 3:
  self-service front end backed by the same GitOps flow

Decision
- Use GAR standard repositories as the controlled delivery surface.
- Default to one repository per customer per batch.
- Manage repository lifecycle, IAM, publication intent, and retirement through GitOps.
