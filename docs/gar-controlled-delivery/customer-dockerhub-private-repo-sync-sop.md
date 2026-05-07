# Customer-side Synchronization SOP for Docker Hub Private-repository Mode

## 📘 Purpose
- This SOP standardizes how customers synchronize delivered images from
  PingCAP-managed private Docker Hub repositories.
- This SOP applies only when the agreed delivery backend is Docker Hub private
  repositories under the `tidbcloud` organization.

## Audience
- Customer platform engineers
- Customer release engineers
- PingCAP delivery owners assisting onboarding

## ✅ Prerequisites
- Customer has received:
  - the repository list
  - the image tags for the delivery batch
  - the Docker Hub account that PingCAP authorized for pull access
  - `images.lock`
  - the delivery manifest or equivalent image list
- Customer environment can reach Docker Hub.
- Customer environment can reach the customer's internal registry if the
  images will be mirrored there.
- Customer account has already accepted the Docker Hub invitation and has been
  placed in the customer-specific team.

## What the Customer Must Provide Before PingCAP Grants Access
- One Docker Hub account name controlled by that customer.
- That account will be the only account added to the customer-specific Docker
  Hub team.
- If the customer requires multiple pull identities, that is a separate access
  exception and should not be treated as the default onboarding path.

## 🔐 Authenticating to Docker Hub
- The customer authenticates with the authorized Docker Hub account.
- For CLI usage, prefer `docker login -u <username>` with a password or
  personal access token.
- For non-interactive automation, prefer a Docker personal access token created
  by the authorized customer account.

### Example
```bash
export DOCKERHUB_USERNAME="customer-account"
export DOCKERHUB_TOKEN="<dockerhub-pat>"

echo "${DOCKERHUB_TOKEN}" | docker login -u "${DOCKERHUB_USERNAME}" --password-stdin
```

## Delivery Naming Rules
- Repository naming pattern:
  - `tidbcloud/<customer>-<component>`
- Tag naming pattern:
  - `<version>`
  - or `<version>-<delivery-batch>`
- Example:
  - `tidbcloud/acme-tidb:v8.5.1-r20260507`

## Synchronization Rules
- Treat the source digest in `images.lock` as the authoritative delivery
  reference.
- Prefer registry-to-registry copy methods that keep the published manifest as
  intact as possible.
- Do not use `docker pull -> docker tag -> docker push` as the default
  synchronization path.
- Use plain Docker pull/tag/push only as fallback when registry-to-registry
  copy tooling is unavailable.
- Validate the destination result against `images.lock` before declaring the
  batch synchronized.

## 🔄 Recommended Workflow
1. Authenticate to Docker Hub with the authorized customer account.
2. Authenticate to the customer's internal registry if the images will be
   mirrored there.
3. Copy each delivered image from Docker Hub into the customer's internal
   registry by digest or by the approved delivery tag with digest validation.
4. Verify the copied artifact in the internal registry.
5. If the destination registry reports a different digest, compare manifest
   type and copy method before escalating.
6. Record the synchronization result for the delivery batch.
7. Use fallback pull/tag/push procedures only when registry-to-registry copy
   tooling is unavailable.

## Preferred Method: `crane copy`
```bash
set -euo pipefail

SRC="tidbcloud"
DST="registry.customer.example.com/private-delivery"

crane copy "${SRC}/acme-tidb@sha256:1111" "${DST}/acme-tidb:v8.5.1-r20260507"
crane copy "${SRC}/acme-tikv@sha256:2222" "${DST}/acme-tikv:v8.5.1-r20260507"
```

## Preferred Method for Multi-arch Artifacts: `skopeo copy --all`
```bash
set -euo pipefail

SRC="tidbcloud"
DST="registry.customer.example.com/private-delivery"

skopeo copy --all "docker://${SRC}/acme-tidb@sha256:1111" "docker://${DST}/acme-tidb:v8.5.1-r20260507"
skopeo copy --all "docker://${SRC}/acme-tikv@sha256:2222" "docker://${DST}/acme-tikv:v8.5.1-r20260507"
```

## Fallback Only: `docker pull/tag/push`
```bash
set -euo pipefail

docker pull tidbcloud/acme-tidb@sha256:1111
docker tag tidbcloud/acme-tidb@sha256:1111 registry.customer.example.com/private-delivery/acme-tidb:v8.5.1-r20260507
docker push registry.customer.example.com/private-delivery/acme-tidb:v8.5.1-r20260507
```

## ✅ Validation Checklist
- The customer can log in to Docker Hub with the authorized account.
- The customer can pull only the repositories granted for that customer.
- The source references match `images.lock`.
- The target artifact exists in the internal registry under the expected
  component and batch tag.
- If the target digest differs from the source digest, the operator verifies
  whether the difference comes from registry-side manifest rewriting rather
  than content loss.
- Deployment automation points to the customer-owned target location, not to
  an unauthorized PingCAP repository.

## 🚨 Failure Handling
- If `docker login` fails:
  verify the correct Docker Hub account and password or personal access token.
- If source pull or source copy fails with unauthorized:
  verify the account is in the correct Docker Hub team and the repository
  permission is read-only or higher.
- If a repository cannot be found:
  verify the repository name and tag or digest from the delivery manifest and
  `images.lock`.
- If destination push fails:
  verify internal registry permissions and storage policy.

## Exit Criteria
- All required images are synchronized successfully into the target location.
- The customer confirms the synchronized results against `images.lock`.
- The PingCAP delivery owner records the batch as synchronized.
