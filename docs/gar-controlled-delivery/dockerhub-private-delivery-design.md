# Docker Hub Private-repository Delivery Design

## 📘 Overview
- This document defines the Docker Hub private-repository delivery mode for
  customers that can only reach Docker Hub and cannot use GAR.
- This is an exception delivery backend, not the default private-delivery
  backend.

## 🎯 Goals
- Provide an online private-delivery path for customers that cannot reach GAR.
- Keep customer pull permissions scoped by repository and team.
- Separate customers by repository namespace conventions and Docker Hub teams.
- Keep delivery batches auditable through tag conventions and delivery
  manifests.

## Non-goals
- Replacing the GAR-based default delivery design.
- Giving customers organization-wide visibility into `tidbcloud`.
- Giving customers write access to any PingCAP-managed repository.
- Using one shared private repository for multiple customers.

## Platform Baseline
- Docker Hub organization:
  - `tidbcloud`
- Subscription plan:
  - Docker Team
- Access-control primitives used in this design:
  - private repositories
  - organization teams
  - repository permissions
- Recommended automation credential:
  - Docker organization access token owned by the `tidbcloud` organization

## Repository Model
- Repository namespace:
  - `tidbcloud/<customer>-<component>`
- Repository creation rule:
  - one private repository per customer per component
- Example:
  - `tidbcloud/acme-tidb`
  - `tidbcloud/acme-tikv`
  - `tidbcloud/acme-pd`

### Why Repository-per-customer-per-component
- Docker Hub repository permissions are naturally enforced at repository level.
- This keeps customer access narrow and understandable.
- Component-level repositories avoid mixing unrelated product images under one
  broad repository permission.
- Re-delivery of the same component uses new tags instead of creating more
  repositories.

## Tag Model
- Tags represent delivery batches and released variants.
- Recommended tag format:
  - `<version>`
  - `<version>-<delivery-batch>`
  - `<version>-<delivery-batch>-<hotfix>`
- Example:
  - `v8.5.1`
  - `v8.5.1-r20260507`
  - `v8.5.1-r20260507-hotfix1`

## Team and Membership Model
- Team naming rule:
  - use the customer short name
- Example:
  - `acme`
- Membership rule:
  - each team contains exactly one customer account
- Rationale:
  - avoid additional paid seats for multiple customer accounts under the same
    customer

## Repository Permission Model
- Each customer team gets read-only access only to that customer's repositories.
- Example:
  - team `acme` gets read-only access to:
    - `tidbcloud/acme-tidb`
    - `tidbcloud/acme-tikv`
  - team `acme` must not see:
    - `tidbcloud/other-customer-tidb`
- Forbidden:
  - organization owner access for customers
  - write access for customers
  - one team mapped to multiple unrelated customers

## Internal Roles
- `platform-admin`:
  - creates repositories
  - creates teams
  - manages customer membership exceptions
- `delivery-bot`:
  - pushes images and tags into customer repositories
  - should use organization-owned credentials
- `delivery-owner`:
  - approves repository naming, component scope, and expiration

## Publication Model
- Delivery content must still be validated by digest before publication.
- Publication metadata must include:
  - customer
  - component
  - source digest
  - destination repository
  - destination tags
  - ticket or batch id
- Customer-facing tags are convenience references.
- Internal audit must still record source digests as the source of truth.

## Lifecycle Model
- Repositories are long-lived by default for repeat delivery to the same
  customer and component.
- Tags are the primary batch lifecycle unit.
- Retirement actions may include:
  - removing obsolete tags from documentation and manifests
  - revoking team permissions
  - archiving or deleting repositories when the customer relationship ends

## Operational Workflow
1. Delivery request is approved.
2. Delivery owner confirms the customer can only use Docker Hub, not GAR.
3. Delivery owner defines:
   - customer short name
   - component list
   - batch id
   - destination tags
4. Platform admin creates or verifies:
   - private repositories under `tidbcloud`
   - one Docker Hub team for that customer
   - one customer account in that team
5. Platform admin grants read-only repository access to the team.
6. Delivery bot pushes images into the customer repositories.
7. Delivery manifests and pull instructions are sent to the customer.
8. Customer logs in with the authorized Docker Hub account and pulls the
   requested tags.
9. When delivery access expires, PingCAP revokes team access or removes the
   customer from the team, depending on the agreement.

## Audit Requirements
- Record which customer account was added to which team.
- Record which repositories were granted to that team.
- Record which source digests were published to which tags.
- Record who changed repository permissions and when.
- Preserve the delivery manifest and ticket reference in Git.

## 🚧 Guardrails
- Do not reuse one repository across multiple customers.
- Do not use one customer team for multiple customers.
- Do not let customer accounts push to repositories.
- Do not use personal maintainer credentials as the automation credential.
- Do not publish without recording source digests.

## ✅ Decision
- Docker Hub private repositories in `tidbcloud` are an approved exception
  delivery mode when the customer can only reach Docker Hub.
- Repository isolation is `customer + component`.
- Batch isolation is represented by tags.
- Team isolation is `one team per customer`, with exactly one customer account
  in that team.
