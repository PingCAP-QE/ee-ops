#!/usr/bin/env bash
# Static Dashboard ID-token contract check. Requires Python 3 and existing yq v4.
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$repo_root" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]) / "apps/gcp/ci-dashboard"

def load(name):
    # --tojson also supports the yq 4.6 version installed by CI.
    return json.loads(subprocess.check_output(
        ["yq", "eval", "--tojson", ".", str(root / name)], text=True,
    ))

def require(condition, message):
    if not condition:
        raise SystemExit("FAIL: " + message)

resources = load("kustomization.yaml").get("resources", [])
for name in ("release.yaml", "security-policy.yaml", "external-secret.yaml"):
    require(name in resources, "kustomization.yaml must include " + name)

release = load("release.yaml")
policy = load("security-policy.yaml")["spec"]
external = load("external-secret.yaml")
require(external["metadata"].get("namespace") == "apps"
        and external["spec"].get("target", {}).get("name") == "ci-dashboard-oidc",
        "retain the apps/ci-dashboard-oidc Secret target")
require(external["spec"].get("secretStoreRef") == {
    "name": "ee-gcp-sm", "kind": "ClusterSecretStore",
}, "retain the existing GCP Secret Manager store")
extracts = external["spec"].get("dataFrom", [])
require(len(extracts) == 1 and extracts[0].get("extract", {}).get("key")
        == "google-oauth2-client-ee-apps", "retain the existing OIDC credential source")
env = release["spec"]["values"]["env"]

def one_env(name):
    matches = [item for item in env if item.get("name") == name]
    require(len(matches) == 1, "expected one " + name)
    return matches[0]

client = one_env("CI_DASHBOARD_OIDC_CLIENT_ID")
require("value" not in client and client.get("valueFrom") == {
    "secretKeyRef": {"name": "ci-dashboard-oidc", "key": "client-id"},
}, "app must reference ci-dashboard-oidc/client-id, without a literal or optional value")
domains = one_env("CI_DASHBOARD_OIDC_HOSTED_DOMAINS")
require(domains.get("value") == "pingcap.com" and "valueFrom" not in domains,
        "Workspace domain must match the approved pingcap.com policy")
require(not any(item.get("name") == "CI_DASHBOARD_AUTH_DISABLED" for item in env),
        "production must not set the development authentication bypass")
oidc = policy["oidc"]
require(oidc.get("provider", {}).get("issuer") == "https://accounts.google.com",
        "retain the Google OIDC issuer")
require(oidc.get("clientIDRef", {}).get("name") == "ci-dashboard-oidc"
        and oidc.get("clientSecret", {}).get("name") == "ci-dashboard-oidc",
        "gateway and app must use the existing OIDC client")
require(oidc.get("redirectURL") == "https://prow.tidb.net/dashboard/oauth2/callback",
        "retain the Dashboard OIDC callback")
require(oidc.get("forwardIDToken") == {"header": "X-CI-Dashboard-ID-Token"},
        "forward the Google ID token in the backend's exact header")
require(oidc.get("disableTokenEncryption", False) is False,
        "do not disable OIDC session token encryption")
require(sorted(oidc.get("scopes", [])) == ["email", "openid", "profile"],
        "retain openid/email/profile scopes")
require(policy.get("csrf") == {}, "retain enforcing CSRF without extra origins")
print("PASS: Dashboard app/gateway identity configuration agrees (static check only)")
PY
