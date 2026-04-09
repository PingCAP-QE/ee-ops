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
  - access credentials or access instructions
  - `images.lock`
  - expiration date
  - target image naming convention in the internal registry
- Customer environment can reach GAR.

Synchronization rules
- Pull by digest, not by tag only.
- Push into the customer's internal registry under the customer's naming policy.
- Validate the final digest before declaring success.

Recommended workflow
1. Authenticate to the delivery GAR repository.
2. Authenticate to the customer's internal registry.
3. Pull each image by digest from GAR.
4. Retag each image for the internal registry.
5. Push to the internal registry.
6. Verify digest or image metadata after push.
7. Record the synchronization result for the delivery batch.

Docker example
```bash
set -euo pipefail

SRC="asia-east1-docker.pkg.dev/delivery-project/customer-a-r2026q2"
DST="registry.customer.example.com/private-delivery"

docker pull "${SRC}/tidb@sha256:1111"
docker tag "${SRC}/tidb@sha256:1111" "${DST}/tidb:v8.5.0"
docker push "${DST}/tidb:v8.5.0"

docker pull "${SRC}/tikv@sha256:2222"
docker tag "${SRC}/tikv@sha256:2222" "${DST}/tikv:v8.5.0"
docker push "${DST}/tikv:v8.5.0"
```

Containerd example
```bash
set -euo pipefail

SRC="asia-east1-docker.pkg.dev/delivery-project/customer-a-r2026q2"
DST="registry.customer.example.com/private-delivery"

ctr images pull "${SRC}/tidb@sha256:1111"
ctr images tag "${SRC}/tidb@sha256:1111" "${DST}/tidb:v8.5.0"
ctr images push "${DST}/tidb:v8.5.0"
```

Validation checklist
- The pulled digest matches `images.lock`.
- The pushed artifact in the internal registry matches the expected component and version.
- Deployment automation references the customer internal registry, not the GAR delivery repository.
- Synchronization is completed before the delivery repository expiration date.

Failure handling
- If pull fails:
  verify GAR access and batch expiration.
- If push fails:
  verify internal registry permissions and storage policy.
- If digest does not match:
  stop and escalate before deployment.

Exit criteria
- All required images are present in the customer's internal registry.
- The customer confirms validation results against `images.lock`.
- The PingCAP delivery owner records the batch as synchronized.
