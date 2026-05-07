# Customer Pull SOP for Docker Hub Private-repository Mode

## 📘 Purpose
- This SOP standardizes how customers pull delivered images from PingCAP-managed
  private Docker Hub repositories.
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
  - the delivery manifest or equivalent image list
- Customer environment can reach Docker Hub.
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

## 🔄 Recommended Workflow
1. Authenticate to Docker Hub with the authorized customer account.
2. Pull the requested image tags from the `tidbcloud` private repositories.
3. Optionally retag and push the images into the customer's internal registry.
4. Record the result for the delivery batch.

## Pull Example
```bash
set -euo pipefail

docker pull tidbcloud/acme-tidb:v8.5.1-r20260507
docker pull tidbcloud/acme-tikv:v8.5.1-r20260507
```

## Optional Sync into an Internal Registry
```bash
set -euo pipefail

docker pull tidbcloud/acme-tidb:v8.5.1-r20260507
docker tag tidbcloud/acme-tidb:v8.5.1-r20260507 registry.customer.example.com/tidb/acme-tidb:v8.5.1-r20260507
docker push registry.customer.example.com/tidb/acme-tidb:v8.5.1-r20260507
```

## ✅ Validation Checklist
- The customer can log in to Docker Hub with the authorized account.
- The customer can pull only the repositories granted for that customer.
- The pulled tags match the delivery manifest.
- If the customer mirrors into an internal registry, the mirrored tags match
  the requested batch identifiers.
- Deployment automation points to the customer-owned target location, not to an
  unauthorized PingCAP repository.

## 🚨 Failure Handling
- If `docker login` fails:
  verify the correct Docker Hub account and password or personal access token.
- If `docker pull` fails with unauthorized:
  verify the account is in the correct Docker Hub team and the repository
  permission is read-only or higher.
- If a repository cannot be found:
  verify the repository name and tag from the delivery manifest.

## Exit Criteria
- All required images are pulled successfully from the authorized private
  repositories.
- The customer confirms the retrieved tags match the delivery manifest.
- The PingCAP delivery owner records the batch as delivered.
