# Machine route enforcement: rollout and acceptance

Covers the transition from `observe` to `enforce` on the TiBuild machine and
privileged routes, the evidence collected, and what the original acceptance matrix
means now that the gateway authorizes capabilities rather than object ownership.

## What was flipped

| Change | Where | Rollback |
| --- | --- | --- |
| 22 registry rules `observe` → `enforce` | Secret Manager `ee-authzd-config` v11 | restore the previous version |
| `AUTHZD_DECISION_MODE` `observe` → `enforce` | `apps/gcp/authzd/workload.yaml` | set it back to `observe` |

Both had to move: a weaker global mode wins over a stronger rule mode, so rules in
`enforce` under a global `observe` change nothing, and a global `enforce` with rules
in `observe` enforces nothing either.

## Preconditions, checked rather than assumed

| Check | Result |
| --- | --- |
| Registry coverage | 22 of 22 operations from the inventory, no gaps |
| Grants | 60 tuples: 12 capabilities × 5 allowlisted callers; second sync a no-op |
| Observation window before the flip | 17 decisions, all `authorized`; `devbuild.read` 13, `artifact.sync` 2, `artifact.read` 2; zero `route_not_registered` |
| Client-visible probe | 8/8, statuses identical to the pre-attach baseline |

## After the flip

| Check | Result |
| --- | --- |
| Deployment and startup log | `AUTHZD_DECISION_MODE=enforce`, `decision_mode=enforce`, 2/2 Ready |
| Requests on the machine route (45 min) | 15 requests, all `200 via_upstream`; no 401, 403 or 5xx |
| Decisions | 16, all `outcome=allow`, `reason_code=authorized` |
| Client-visible probe | 8/8 |

## The acceptance matrix, re-read

The original matrix was written when the gateway was expected to know object
ownership. ADR 0005 removed that expectation, so each case now belongs to one of
three places:

| Case | Where it is decided now | Status |
| --- | --- | --- |
| Caller holds the capability | Gateway: `authorized` | Observed in production |
| Caller lacks the capability | Gateway: `relationship_denied`, HTTP 403 | Not observed: every allowlisted caller holds all twelve capabilities. Reproducible by removing a tuple |
| Path with no rule | Gateway: `route_not_registered`, HTTP 403 | Not observed since coverage completed |
| OpenFGA unavailable | Gateway: deny, fail closed | Not rehearsed in production. Unit-tested |
| Expired or wrong-audience JWT | Gateway JWT filter, **before** `ext_authz`; no decision | Covered by the probe (401, no decision) |
| Unknown build id, cross-tenant id | TiBuild | Out of gateway scope (ADR 0005) |
| Owner vs team member | TiBuild | Out of gateway scope (ADR 0005) |
| Revoked team membership | Not applicable: no team tuples exist | — |
| In-cluster direct call | TiBuild, NetworkPolicy | Unchanged |

Two rows are worth stating plainly: the gateway's failure modes are proven by unit
tests and by the reordering work, but "caller lacks capability" and "OpenFGA
unavailable" have not been exercised against production. Both deny, so a production
rehearsal would produce a 403 for a real caller — do it deliberately, in a window,
not by accident.

## Known gaps

1. **publish, hotfix and tidbcloud have no production decision sample yet.** They
   run at release time. Their rules come from the same inventory and their
   capabilities are held by the same five callers, but "no sample" is not "verified".
   A twenty-minute watch produced zero; a longer watch is running.
2. **Latency budget not measured.** `authzd` emits decision counts, not a latency
   histogram; the added hop is bounded by the 1s timeout but has no p95 number.
3. **A new TiBuild operation now fails closed.** An operation without a registry rule
   returns 403 instead of a recorded would-deny, so adding one means adding its rule
   and grants in the same change.

## Rollback

Set `AUTHZD_DECISION_MODE=observe`. Requests are then allowed regardless of the
decision, authentication and the registry stay as they are, and the change is a
single value with no state. Reverting the registry version is only needed to change
which rules are candidates for enforcement.
