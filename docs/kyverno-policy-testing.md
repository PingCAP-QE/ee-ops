# Kyverno Policy Quality Assurance Guide

This document describes how to keep Kyverno policies maintainable and reliable over time.

It is intentionally focused on **quality assurance practices** rather than any single policy's implementation details.

## Goals

- Verify that policy behavior matches intent before rollout.
- Prevent regressions when policies, overlays, or resource shapes change.
- Make policy changes easier to review.
- Keep testing repeatable in local development and CI.

## Recommended Quality Assurance Layers

Use more than one layer of verification.

### 1. Static review

Before running tools, review the policy itself:

- confirm the target resource kinds are correct
- confirm `match` and `exclude` scopes are intentional
- confirm `preconditions` reflect the real execution conditions
- confirm mutations and validations are consistent with one another
- confirm namespaced `Policy` resources are tested in the namespace shape they will actually use after rendering

A lightweight review catches many mistakes early, especially accidental overmatching or policies that never match.

### 2. Rendered-manifest verification

If a policy is managed through Kustomize overlays, validate the rendered output rather than only the raw base file.

This is especially important for:

- namespace injection
- overlay patches
- shared base policies reused by multiple environments
- resource names changed by overlays or generators

Recommended checks:

- render the owning overlay
- confirm the final `Policy` or `ClusterPolicy` exists as expected
- confirm metadata such as namespace and name are correct
- confirm the final rendered rule contents still match the intended behavior

### 3. Policy execution tests

Run Kyverno CLI tests against representative resources.

Use these tests to verify:

- resources which should match do match
- resources which should be skipped are skipped for the correct reason
- expected mutation output is correct
- expected validation pass/fail behavior is correct

At minimum, design test cases for:

- a normal passing case
- a non-matching case
- a boundary case
- a regression case covering the change you just made

### 4. Broader GitOps validation

After policy-specific checks, run the repository's normal manifest validation flow.

This helps catch:

- broken YAML after refactoring
- invalid Kustomize references
- unexpected cross-file impact
- drift between policy files and deployment structure

## What to Test for Every Policy Change

When a policy changes, verify the following areas intentionally.

### Match behavior

Check that the rule applies to the intended resources and only those resources.

Typical risks:

- selector too broad
- selector too narrow
- missing namespace context
- changed labels or annotations causing silent skip behavior

### Preconditions

Check both paths:

- when preconditions should pass
- when preconditions should not pass

A policy can appear healthy while never executing because preconditions are never satisfied.

### Mutation output

For mutate rules, verify the final resource shape rather than only checking that the rule reported `pass`.

Confirm:

- the expected field was added, changed, or preserved
- defaults are applied only where intended
- override rules still override earlier defaults correctly
- no unrelated fields were unintentionally changed

### Validation outcome

For validate rules, confirm both:

- resources that should pass
- resources that should fail

Validation tests should include at least one intentionally invalid resource to prove the rule really blocks what it is designed to block.

### Overlay compatibility

If a policy lives under a shared base, verify at least one consuming overlay after every meaningful change.

If multiple overlays rely on different labels, namespaces, or patches, consider testing more than one overlay.

## Recommended Test Case Structure

A good policy test suite is small but intentional.

Prefer a table like this when designing test cases:

| Case type | Purpose |
| --- | --- |
| positive case | proves intended resources are handled correctly |
| negative case | proves unrelated resources are not affected |
| boundary case | proves edge conditions behave correctly |
| regression case | locks in behavior for a previously fixed bug or tricky branch |

Examples of boundary conditions include:

- missing annotation or label
- empty string values
- malformed input
- alternate namespace
- changed resource kind

## Common Failure Signals

### Rule is `Excluded`

This usually means the resource never matched.

Possible causes:

- wrong namespace after rendering
- missing selector labels
- wrong kind
- overlay changed the final resource shape

### Preconditions not met

This means the rule matched the resource scope but did not proceed.

Possible causes:

- missing input data
- expression logic too strict
- transformation or parsing result different from expected

### Patched resource mismatch

This means the expected mutated output does not match the actual output.

Possible causes:

- expected file is stale
- policy changed but test fixture did not
- Kyverno preserved or added metadata not accounted for in expected output

## Review and Maintenance Practices

To keep policy quality sustainable over time:

- keep policy changes small and focused
- update tests in the same change as the policy
- prefer adding regression tests for every bug fix
- remove duplicated policy logic where practical
- document non-obvious policy intent near the test or in docs

When a shared policy is reused across environments, treat test maintenance as part of the policy change rather than a follow-up task.

## Suggested CI Direction

If Kyverno policy coverage grows, consider a dedicated CI step that:

1. renders affected overlays
2. runs Kyverno CLI tests
3. runs repository-wide manifest validation

This provides both fast policy feedback and broader GitOps safety checks.

## Practical Principle

Do not rely on a single signal.

A policy is in good shape only when:

- the rendered manifest is correct
- representative resources exercise the intended rule paths
- expected outputs are stable
- repository-level validation still passes

That combination gives much better confidence than checking syntax alone.
