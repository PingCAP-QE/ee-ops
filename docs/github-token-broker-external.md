# External access to the GitHub token broker

The cluster-internal `github-token-broker` is also reachable from the public
internet at:

```text
POST https://prow.pingcap.net/gh-broker/v1/token
```

This document describes the deployment-only design: the broker image, chart and
code are unchanged.

## Topology

```text
client
  Authorization: Bearer <Google ID token>
    -> GKE external HTTPS (TLS terminated)
    -> eg-internal Envoy
         HTTPRoute: exact /gh-broker/v1/token, POST
         URLRewrite: /v1/token
         SecurityPolicy: JWT (issuer, audience) + claim authorization
         HTTPRouteFilter: replace Authorization with the broker SA token
    -> Service github-token-broker:80
    -> broker: TokenReview + policy (unchanged)
```

Only the token path is routed. `/metrics`, `/healthz` and `/readyz` stay
cluster-internal.

## Authentication model

External callers present a **Google ID token** with:

```text
iss = https://accounts.google.com
aud = https://prow.pingcap.net/gh-broker
email = gh-broker-client-macos@pingcap-testing-account.iam.gserviceaccount.com
```

The gateway validates the signature, issuer and audience, then the
`authorization` policy allows only:

- the service account email above (machine clients), or
- `hd = pingcap.com` (reserved for a future internal OIDC provider; Google user
  tokens carry the OAuth client ID in `aud`, so they cannot reach this endpoint
  directly).

The caller's token never reaches the broker. A `HTTPRouteFilter` overwrites the
`Authorization` header with the token of a dedicated `external-reader`
ServiceAccount, which has **no RoleBindings or ClusterRoleBindings**. The broker
performs the normal `TokenReview` and policy check.

### Issuing credentials to a machine client

Use one service account per client, named `gh-broker-client-<client>`. The first
one covers the macOS build workers:

```bash
gcloud iam service-accounts create gh-broker-client-macos \
  --project=pingcap-testing-account \
  --display-name="GitHub token broker client: macOS workers" \
  --description="Identity for macOS build workers calling the external token broker. No GCP IAM roles."
```

None of these service accounts has GCP IAM roles. Create a JSON key per client
installation and hand it over out of band:

```bash
gcloud iam service-accounts keys create key.json \
  --iam-account=gh-broker-client-macos@pingcap-testing-account.iam.gserviceaccount.com \
  --project=pingcap-testing-account
```

A key can only mint ID tokens with the audience above; it cannot call Google
APIs. Use one key per client and delete the key to revoke that client
(`gcloud iam service-accounts keys delete`).

To onboard another client: create `gh-broker-client-<name>`, add its email to
the `broker-clients` claim values in
`apps/gcp/github-token-broker/security-policy.yaml`, and issue a key.

### Minting a token

gcloud (activate the key in an isolated config directory):

```bash
export CLOUDSDK_CONFIG=$(mktemp -d)
gcloud auth activate-service-account --key-file=key.json
gcloud auth print-identity-token --audiences=https://prow.pingcap.net/gh-broker
```

Python:

```python
from google.auth.transport.requests import Request
from google.oauth2 import service_account

creds = service_account.IDTokenCredentials.from_service_account_file(
    "key.json", target_audience="https://prow.pingcap.net/gh-broker"
)
creds.refresh(Request())
print(creds.token)
```

Go:

```go
creds, err := idtoken.CredentialsFromJSON(ctx, keyJSON,
    "https://prow.pingcap.net/gh-broker")
tok, err := creds.TokenSource.Token()
```

Node:

```js
const auth = new GoogleAuth({keyFile: "key.json"});
const client = await auth.getIdTokenClient("https://prow.pingcap.net/gh-broker");
const headers = await client.getRequestHeaders();
```

## Broker identity

```text
Secret/external-reader-token (ServiceAccount token)
  -> PushSecret -> GCP Secret Manager
  -> ExternalSecret (template "Bearer {{ .token }}")
  -> Secret/github-token-broker-upstream (key: credential)
  -> HTTPRouteFilter/credentialInjection
```

Both directions refresh hourly. The broker never receives the caller's token,
and the caller never receives the broker's ServiceAccount token.

## Authorization

The allowlist lives in the GCP Secret Manager secret
`github-token-broker-policy` (not in this repository). A minimal rule:

```yaml
  - caller:
      namespace: github-token-broker
      service_account: external-reader
    allow:
      - owner: example-org
        repositories: ["example-repo"]
        max_permissions:
          contents: read
```

The broker reloads the policy within seconds; no restart is needed. Keep the
external rule read-only: there is no additional code-level ceiling in the
deployment-only design.

## Verification

```bash
# 401 without a token
curl -sS -o /dev/null -w '%{http_code}\n' -X POST \
  https://prow.pingcap.net/gh-broker/v1/token \
  -H 'Content-Type: application/json' \
  -d '{"repo":"example-org/example-repo","repositories":["example-repo"]}'

# 200 with a valid ID token (do not echo the token)
curl -sS -o /dev/null -w '%{http_code}\n' -X POST \
  https://prow.pingcap.net/gh-broker/v1/token \
  -H "Authorization: Bearer ${ID_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"repo":"example-org/example-repo","repositories":["example-repo"],"permissions":{"contents":"read"}}'

# The broker ServiceAccount must not have RBAC permissions
kubectl auth can-i --list \
  --as=system:serviceaccount:github-token-broker:external-reader
```

## Residual risks

1. **Installation-wide token.** When a request omits `repositories` and asks for
   no write permission, the broker mints a token for the whole installation.
   The gateway cannot inspect or rewrite the JSON body. External callers can
   therefore obtain read access to every repository the GitHub App is installed
   on, not only the allowlist. Detect it by alerting on broker log entries for
   `external-reader` with `"repositories":[]`. A code guard or a dedicated
   GitHub App would close this gap.
2. **Shared broker identity.** Every external caller is mapped to the same
   broker `external-reader` ServiceAccount; broker audit logs and rate limits
   cannot distinguish clients. The gateway can distinguish them by the JWT
   `email` claim, but that requires claim-based logging.
3. **Long-lived keys.** Service account keys do not expire. Use one key per
   client and rotate them; the ID tokens themselves are short-lived (one hour).
4. **PAT fallback.** Keep `github.fallback.enabled=false`. If a PAT is
   configured, external callers could receive it for owners where the App is not
   installed.

## Rollback

- Remove the `github-token-broker-external` HTTPRoute: the public endpoint
  returns 404 and the broker stays available in-cluster.
- Remove the `broker-clients` authorization rule (or delete the service account
  key): external requests fail with 403/401.
- Remove the `external-reader` policy rule to revoke authorization
  independently of the gateway.

None of these steps affects in-cluster callers.
