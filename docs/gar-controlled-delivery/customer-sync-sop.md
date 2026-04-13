Customer-side Synchronization SOP
=================================

Purpose
- This SOP standardizes how customers synchronize delivered images from PingCAP-managed GAR repositories into their own internal registry.

Audience
- Customer platform engineers
- Customer release engineers
- PingCAP delivery owners assisting customer onboarding

Prerequisites
- Customer has received:
  - GAR repository address
  - confirmation of which Google identity has been granted read access to the delivery repository
  - GAR authentication instructions
  - `images.lock`
  - expiration date
  - target image naming convention in the internal registry
- Customer environment can reach GAR.

Authenticating to GAR
- PingCAP does not need to hand over a long-lived Docker password for this workflow.
- Instead, the customer uses a Google identity that has already been granted `Artifact Registry Reader` access to the delivery repository.
- After authenticating that identity with `gcloud`, the customer can obtain a short-lived access token and log in to GAR.

Example
```bash
gcloud auth login
gcloud auth print-access-token | docker login -u oauth2accesstoken --password-stdin us-docker.pkg.dev
```

How to interpret this prerequisite
1. PingCAP confirms which Google identity is authorized to read the delivery repository.
2. The customer authenticates that identity locally with `gcloud`.
3. The customer uses the short-lived access token to pull or copy images from GAR.

Synchronization rules
- Treat the source digest in `images.lock` as the authoritative delivery reference.
- Prefer registry-to-registry copy methods that preserve the published manifest as much as possible.
- Do not use `docker pull -> docker tag -> docker push` as the default delivery path.
- Validate the target result before declaring success.

Recommended workflow
1. Authenticate to the delivery GAR repository.
2. Authenticate to the customer's internal registry.
3. Copy each image from GAR into the internal registry by digest.
4. Verify the copied artifact in the internal registry.
5. If the destination registry reports a different digest, compare manifest type and copy method before escalating.
6. Record the synchronization result for the delivery batch.
7. Use fallback pull/tag/push procedures only when registry-to-registry copy tooling is unavailable.

Preferred method: `crane copy`
```bash
set -euo pipefail

SRC="asia-east1-docker.pkg.dev/delivery-project/customer-a-r2026q2"
DST="registry.customer.example.com/private-delivery"

crane copy "${SRC}/tidb@sha256:1111" "${DST}/tidb:v8.5.0"
crane copy "${SRC}/tikv@sha256:2222" "${DST}/tikv:v8.5.0"
```

Preferred method for multi-arch artifacts: `skopeo copy --all`
```bash
set -euo pipefail

SRC="asia-east1-docker.pkg.dev/delivery-project/customer-a-r2026q2"
DST="registry.customer.example.com/private-delivery"

skopeo copy --all "docker://${SRC}/tidb@sha256:1111" "docker://${DST}/tidb:v8.5.0"
skopeo copy --all "docker://${SRC}/tikv@sha256:2222" "docker://${DST}/tikv:v8.5.0"
```

Fallback only: `docker pull/tag/push`
```bash
set -euo pipefail

SRC="asia-east1-docker.pkg.dev/delivery-project/customer-a-r2026q2"
DST="registry.customer.example.com/private-delivery"

docker pull "${SRC}/tidb@sha256:1111"
docker tag "${SRC}/tidb@sha256:1111" "${DST}/tidb:v8.5.0"
docker push "${DST}/tidb:v8.5.0"
```

Why fallback is not preferred
- Different registries may rewrite manifest schemas, media types, or compression.
- Multi-arch indexes are especially likely to produce a different reported digest at the destination.
- The copied image may still be functionally equivalent, but the final digest shown by the target registry may not match the source digest exactly.

Validation checklist
- The source reference matches `images.lock`.
- The target artifact exists in the internal registry under the expected component and version.
- If the target digest differs from the source digest, the operator verifies whether the difference comes from registry-side manifest rewriting rather than content loss.
- Deployment automation references the customer internal registry, not the GAR delivery repository.
- Synchronization is completed before the delivery repository expiration date.

Failure handling
- If pull fails:
  verify GAR access and batch expiration.
- If push fails:
  verify internal registry permissions and storage policy.
- If digest does not match:
  compare source and target manifest type and copy method first, then escalate before deployment if the difference cannot be explained.

Exit criteria
- All required images are present in the customer's internal registry.
- The customer confirms validation results against `images.lock`.
- The PingCAP delivery owner records the batch as synchronized.
