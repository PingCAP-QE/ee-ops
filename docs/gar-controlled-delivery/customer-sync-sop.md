# Customer-side Synchronization SOP

## 📘 Purpose
- This SOP standardizes how customers synchronize delivered images from PingCAP-managed GAR repositories into their own internal registry.

## Audience
- Customer platform engineers
- Customer release engineers
- PingCAP delivery owners assisting customer onboarding

## ✅ Prerequisites
- Customer has received:
  - GAR repository address
  - confirmation of which customer identity has been granted read access to the delivery repository
  - GAR authentication instructions
  - `images.lock`
  - expiration date
  - target image naming convention in the internal registry
- Customer environment can reach GAR.

## What the Customer Must Provide Before PingCAP Grants Access
- One identity to authorize at repository level with `Artifact Registry Reader`.
- Supported default identity types for this workflow:
  - a Google user account email
  - a Google service account email
- Recommended choice:
  - use a Google user account for manual or one-off synchronization
  - use a customer-managed Google service account for automated synchronization
- If the customer cannot provide either identity type, this GAR pull-based SOP should not be treated as the default path.

## 🔐 Authenticating to GAR
- PingCAP does not need to hand over a long-lived Docker password for this workflow.
- Instead, the customer uses the authorized Google identity that has already been granted `Artifact Registry Reader` access to the delivery repository.
- After authenticating that identity with `gcloud`, the customer can obtain a short-lived access token and log in to GAR.

### Example
```bash
gcloud auth login
gcloud auth print-access-token | docker login -u oauth2accesstoken --password-stdin us-docker.pkg.dev
```

### How to Interpret This Prerequisite
1. The customer provides either a Google user account email or a Google service account email to PingCAP.
2. PingCAP grants `Artifact Registry Reader` on the delivery repository to that identity.
3. The customer authenticates that identity locally with `gcloud`.
4. The customer uses the short-lived access token to pull or copy images from GAR.

## Synchronization Rules
- Treat the source digest in `images.lock` as the authoritative delivery reference.
- Prefer registry-to-registry copy methods that preserve the published manifest as much as possible.
- Do not use `docker pull -> docker tag -> docker push` as the default delivery path.
- Validate the target result before declaring success.

## 🔄 Recommended Workflow
1. Authenticate to the delivery GAR repository.
2. Authenticate to the customer's internal registry.
3. Copy each image from GAR into the internal registry by digest.
4. Verify the copied artifact in the internal registry.
5. If the destination registry reports a different digest, compare manifest type and copy method before escalating.
6. Record the synchronization result for the delivery batch.
7. Use fallback pull/tag/push procedures only when registry-to-registry copy tooling is unavailable.

## Preferred Method: `crane copy`
```bash
set -euo pipefail

SRC="asia-east1-docker.pkg.dev/delivery-project/customer-a-r2026q2"
DST="registry.customer.example.com/private-delivery"

crane copy "${SRC}/tidb@sha256:1111" "${DST}/tidb:v8.5.0"
crane copy "${SRC}/tikv@sha256:2222" "${DST}/tikv:v8.5.0"
```

## Preferred Method for Multi-arch Artifacts: `skopeo copy --all`
```bash
set -euo pipefail

SRC="asia-east1-docker.pkg.dev/delivery-project/customer-a-r2026q2"
DST="registry.customer.example.com/private-delivery"

skopeo copy --all "docker://${SRC}/tidb@sha256:1111" "docker://${DST}/tidb:v8.5.0"
skopeo copy --all "docker://${SRC}/tikv@sha256:2222" "docker://${DST}/tikv:v8.5.0"
```

## Fallback Only: `docker pull/tag/push`
```bash
set -euo pipefail

SRC="asia-east1-docker.pkg.dev/delivery-project/customer-a-r2026q2"
DST="registry.customer.example.com/private-delivery"

docker pull "${SRC}/tidb@sha256:1111"
docker tag "${SRC}/tidb@sha256:1111" "${DST}/tidb:v8.5.0"
docker push "${DST}/tidb:v8.5.0"
```

## Why Fallback Is Not Preferred
- Different registries may rewrite manifest schemas, media types, or compression.
- Multi-arch indexes are especially likely to produce a different reported digest at the destination.
- The copied image may still be functionally equivalent, but the final digest shown by the target registry may not match the source digest exactly.

## ✅ Validation Checklist
- The source reference matches `images.lock`.
- The target artifact exists in the internal registry under the expected component and version.
- If the target digest differs from the source digest, the operator verifies whether the difference comes from registry-side manifest rewriting rather than content loss.
- Deployment automation references the customer internal registry, not the GAR delivery repository.
- Synchronization is completed before the delivery repository expiration date.

## 🚨 Failure Handling
- If pull fails:
  verify GAR access and batch expiration.
- If push fails:
  verify internal registry permissions and storage policy.
- If digest does not match:
  compare source and target manifest type and copy method first, then escalate before deployment if the difference cannot be explained.

## Exit Criteria
- All required images are present in the customer's internal registry.
- The customer confirms validation results against `images.lock`.
- The PingCAP delivery owner records the batch as synchronized.
