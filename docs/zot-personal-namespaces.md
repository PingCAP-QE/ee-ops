# zot `personal/**` namespaces (tencentcloud)

`cr.pingcap.net` is the zot registry in the tencentcloud (TKE) cluster, deployed with
Flux from `apps/tencentcloud/zot/`. Each listed employee gets a scratch namespace
`personal/<email-local-part>/**` that only they can read/write.

## How it is wired

| Where | What |
|---|---|
| GCP SM secret `tencentcloud_zot_personal_users` | JSON array of emails, e.g. `["alice@pingcap.com"]` |
| `apps/tencentcloud/zot/pre/external-secrets.yaml` | ExternalSecret → Secret `zot-config-secrets`, key `PERSONAL_USERS` |
| `apps/tencentcloud/zot/config.yaml` | Flux `postBuild.substituteFrom` that secret; substitutes `${PERSONAL_USERS}` into the config |
| `apps/tencentcloud/zot/config/config.json` | `http.accessControl.repositories["personal/**"]` = users `${PERSONAL_USERS}` + CEL condition |

The CEL condition keeps a user inside their own namespace even if the list is wrong:

```cel
req.repository.startsWith('personal/' + req.user.username.split('@')[0] + '/')
```

## Why the policy must be `users`-based, never `groups`-based

zot resolves the groups used for authorization differently per authentication method:

- **htpasswd / basic auth (docker login with a password), mTLS**: groups are computed from
  `http.accessControl.groups` in the config and cached into the meta DB
  (`SetUserGroups`).
- **OIDC (the zot UI "Sign in with Google")**: groups come **only** from the ID token /
  UserInfo `groups` claim. Google ID tokens have no such claim, so an empty group set is
  written to the meta DB, *overwriting* anything that was there.
- **API key (`docker login -u <email> -p <api-key>`)**: groups are read **only** from the
  meta DB (`GetUserGroups`). There is **no fallback** to `http.accessControl.groups`.

Humans on this registry never have an htpasswd entry (only `admin`, `ci-bot`, `cd-bot`
do); they sign into the UI with Google and then create an API key. So for every human
user the meta DB group set is empty and **any `groups`-based policy silently never
matches** — a push is denied, while reads still succeed via `defaultPolicy: ["read"]`.

Symptoms seen in production (2026-11-06, `personal/liting/br-basic-test`):

- `docker login -u liting@pingcap.com -p <api-key>` appears to work. It always does: zot
  bypasses authz for `GET /v2/`, so the credentials are never validated at login time.
- `docker push` fails with `denied: requested access to the resource is denied`, while
  the same user can push to `ttl-1w/...` (those are `defaultPolicy` grants, not group
  grants).
- The 403 body carries no "reason" detail, which means *no policy matched at all*, not
  "the CEL condition rejected you" (a condition denial would return the configured
  message, e.g. `only your personal namespace`).

`ci-bot` / `cd-bot` are unaffected: they authenticate with htpasswd passwords, so their
config-defined groups (`pullers` / `pushers`) are applied.

## Isolation is enforced per user

The `users` grant says *who may push to `personal/**` at all*; the CEL condition says
*which sub-path*. Both must hold, so a listed user can only write `personal/<own-local-part>/`
and a non-listed user can write nothing under `personal/`.

Verified on zot `v2.1.18` with this exact policy shape in a throwaway namespace (API-key
authentication, i.e. the same path production uses; the meta-DB group set was empty):

| request (`POST /v2/<repo>/blobs/uploads/`) | identity | result |
|---|---|---|
| `personal/alice/app` | apikey of `alice@test` | `202` |
| `personal/alice/team/app` | apikey of `alice@test` | `202` |
| `personal/bob/app` | apikey of `alice@test` | `403` `only your personal namespace` |
| `personal/alice-evil/app` (prefix trick) | apikey of `alice@test` | `403` `only your personal namespace` |
| `personal/alice/app` | wrong apikey | `401` |
| `personal/alice/app` | `-u bob@test -p <alice's key>` | `401` |
| anything | anonymous | `401` |

A `403` that carries the `reason` detail means the policy matched and the condition
rejected it; a `403` without `reason` means no policy matched (the bug this document
describes).

`personal/**` keeps `defaultPolicy: ["read"]`, so reads (and kubelet/CI pulls of
`personal/<user>/<image>`, e.g. `personal/wuhui.zuo/git_cdn`) stay available to any
authenticated identity — write isolation does not depend on it.

## Adding a user

1. Append the email to `tencentcloud_zot_personal_users` in GCP Secret Manager
   (`pingcap-testing-account`), creating a new version.
2. Wait for the ExternalSecret refresh (≤1h) and let Flux re-render `zot-config`:

   ```bash
   flux --context tke-cls-9zpon9y1 reconcile externalsecret zot-config-secrets -n zot
   flux --context tke-cls-9zpon9y1 reconcile kustomization zot-config -n zot
   kubectl --context tke-cls-9zpon9y1 -n zot get cm zot-config \
     -o jsonpath='{.data.config\.json}' | jq '.http.accessControl.repositories["personal/**"]'
   ```

3. **Restart zot** — the access-control config is only read at startup:

   ```bash
   kubectl --context tke-cls-9zpon9y1 -n zot rollout restart sts/zot
   kubectl --context tke-cls-9zpon9y1 -n zot rollout status sts/zot
   ```

4. Verify the identity that zot actually attributes the requests to:

   ```bash
   kubectl --context tke-cls-9zpon9y1 -n zot logs zot-0 --since=10m \
     | jq -c 'select(.path|tostring|startswith("/v2/personal")) | {time,username,method,path,statusCode}'
   ```

## Debugging checklist

- 403 on push **plus** `username` correct in the logs **plus** no `reason` detail ⇒ the
  authorizing policy did not match (wrong `users`/`groups`), not a credential problem.
  Re-check the rendered ConfigMap, not the repo file.
- 401 instead of 403 ⇒ the API key is unknown/expired, or the `-u` username does not
  match the identity stored with the key.
- A push rejected with a custom message from a condition ⇒ authn and policy matching are
  fine, the CEL expression is wrong.
