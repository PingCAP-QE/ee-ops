#!/usr/bin/env bash
# Print the PoC data plane's HTTP filter order and assert the expected sequence.
set -euo pipefail

gateway=${GATEWAY:-eg-authz-poc}
namespace=${NAMESPACE:-infra}
expected="csrf ext_authz oauth2 jwt_authn rbac local_ratelimit credential_injector router"
# After reordering, ext_authz must follow jwt_authn.
want="csrf oauth2 jwt_authn ext_authz rbac local_ratelimit credential_injector router"

kubectl -n "$namespace" port-forward "svc/eg-authz-poc" 19999:19000 >/dev/null 2>&1 &
forward_pid=$!
trap 'kill "$forward_pid" 2>/dev/null || true' EXIT
sleep 5

kubectl -n "$namespace" get svc eg-authz-poc >/dev/null
# The admin port is on the proxy pods, not on the Service; port-forward the pod.
pod=$(kubectl -n "$namespace" get pods -l "gateway.envoyproxy.io/owning-gateway-name=$gateway" -o jsonpath='{.items[0].metadata.name}')
kill "$forward_pid" 2>/dev/null || true
kubectl -n "$namespace" port-forward "pod/$pod" 19998:19000 >/dev/null 2>&1 &
forward_pid=$!
sleep 5

curl -s http://127.0.0.1:19998/config_dump > /tmp/poc-config-dump.json
python3 - <<'PY'
import json
want = "csrf oauth2 jwt_authn ext_authz rbac local_ratelimit credential_injector router".split()
d = json.load(open("/tmp/poc-config-dump.json"))
chains = []
def walk(o):
    if isinstance(o, dict):
        hfs = o.get("http_filters")
        if isinstance(hfs, list) and any("ext_authz" in (f.get("name") or "") for f in hfs):
            chains.append(hfs)
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(d)
if not chains:
    raise SystemExit("no filter chain with ext_authz found")
order = []
for f in chains[0]:
    name = (f.get("name") or "").split("/")[0]
    short = {
        "envoy.filters.http.csrf": "csrf",
        "envoy.filters.http.ext_authz": "ext_authz",
        "envoy.filters.http.oauth2": "oauth2",
        "envoy.filters.http.jwt_authn": "jwt_authn",
        "envoy.filters.http.rbac": "rbac",
        "envoy.filters.http.local_ratelimit": "local_ratelimit",
        "envoy.filters.http.credential_injector": "credential_injector",
        "envoy.filters.http.router": "router",
    }.get(name, name)
    if short in want:
        order.append(short)
print("observed:", " ".join(order))
print("expected:", " ".join(want))
if order != want:
    raise SystemExit("filter order does not match the PoC expectation")
print("OK: ext_authz follows jwt_authn and still precedes credential_injector")
PY
