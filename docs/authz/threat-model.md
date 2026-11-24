# Unified authorization threat model: inventory baseline

## Assets and trust boundaries

- Human and workload identity, tenant/project membership, build ownership,
  GitHub token scopes, DL capabilities, and production CI services.
- GKE Gateway to Envoy Gateway forwarding, Envoy to service routing, direct
  ClusterIP callers, authzd/OpenFGA, and relationship synchronization.
- Prod2 is excluded from every rollout and deployment target.

## Threats and required controls

| Threat | Example | Required mitigation / evidence |
| --- | --- | --- |
| Forged identity header | Caller supplies `X-User-*` or tenant header | Strip/overwrite at trusted proxy; authzd validates signed identity token; spoofing tests |
| GKE-to-Envoy forwarding bypass | Traffic reaches a route through a different effective Gateway/policy path | Inventory both hops; inspect accepted/programmed status and live route selection |
| Cross-tenant path forgery | A caller supplies another tenant's project/build ID | Resolve resource and parent chain from trusted catalog; compare canonical tenant; deny on mismatch |
| Confused deputy | Broker or ChatOps workload authority is mistaken for caller authority | Keep external actor and service principal separate; use explicit delegation checks |
| Direct-call bypass | In-cluster caller reaches ClusterIP without Gateway | Enumerate NetworkPolicy peers; preserve application checks until bypass is closed or protected |
| OpenFGA/resolver outage | Timeout or stale/missing relationship causes indeterminate decision | Enforce paths fail closed; bounded timeout/retries; expose error and sync-lag telemetry |
| Tuple write abuse | Application or end user writes arbitrary relationship tuples | Dedicated admin/sync identity; deny tuple writes to ordinary workloads; audit reconciliation |
| Credential/log disclosure | Token, Authorization, or anonymous DL URL enters logs | Redact sensitive fields; test logs and metrics for secret leakage |

## Baseline limitations

This document is a design-level threat analysis. No live cluster/controller
status, rendered manifest snapshot, packet path, or current authn regression
command result is asserted. Collect those artifacts before shadow mode.
