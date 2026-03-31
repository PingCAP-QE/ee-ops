# paperclip Helm Chart

This chart deploys [Paperclip](https://paperclip.ing), the upstream open-source orchestration server for AI-agent companies.

The chart follows the upstream deployment guidance:

- Uses container port `3100`
- Persists `PAPERCLIP_HOME` at `/paperclip`
- Defaults to `authenticated` + `private` mode for networked deployments
- Supports Gateway API `HTTPRoute` as a first-class exposure option
- Allows mounting a Paperclip instance config file for advanced database or storage settings

## Notes

- Upstream docs say embedded PostgreSQL and local disk storage are fine for a single-node deployment. This chart supports that by default via a persistent volume mounted at `/paperclip`.
- Upstream docs recommend external PostgreSQL and S3-compatible storage for more production-oriented or multi-node setups. Mount an instance config secret and/or inject `DATABASE_URL` to switch modes.
- The upstream GHCR repository currently publishes `latest` and `sha-*` tags. This chart pins the default image to the current upstream `sha-98337f5` build.

## Install

```bash
helm install paperclip ./charts/paperclip
```

## Authenticated private deployment behind HTTPRoute

```yaml
paperclip:
  publicUrl: https://paperclip.internal.example.com
  allowedHostnames:
    - paperclip.internal.example.com

httpRoute:
  enabled: true
  parentRefs:
    - kind: Gateway
      name: internal-gateway
      namespace: infra
      sectionName: wildcard-pingcap-net
  hostnames:
    - paperclip.internal.example.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /

auth:
  existingSecret: paperclip-auth

envFrom:
  - secretRef:
      name: paperclip-env
```

Where `paperclip-auth` contains `BETTER_AUTH_SECRET`, and `paperclip-env` can optionally provide values such as `DATABASE_URL`, `OPENAI_API_KEY`, or `ANTHROPIC_API_KEY`.

## External config file

For advanced storage or secrets settings from the upstream docs, mount a Paperclip config file from a secret:

```yaml
config:
  existingSecret: paperclip-config
  secretKey: config.json
```

This mounts the secret to `PAPERCLIP_CONFIG`, defaulting to `/paperclip/instances/default/config.json`.
