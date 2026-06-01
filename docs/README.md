# Documentation Index

This directory contains repository design notes, migration guides, and operational runbooks.

## Documents

- `kyverno-policy-testing.md`: how to keep Kyverno policies reliable through review, rendered-manifest checks, execution tests, and regression coverage
- `TEKTON_MIGRATION.md`: notes related to Tekton migration work
- `gar-controlled-delivery/README.md`: controlled private-delivery design and related implementation documents
- `github-actions-secrets/README.md`: GitHub Actions secrets central management design

## Notes

Many documents in this repository are design-oriented and scoped to a specific subsystem.

For Kyverno policy work, prefer reading `kyverno-policy-testing.md` before changing rules or tests so quality checks remain consistent across review, local verification, and CI.
