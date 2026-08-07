# Lab 02 — Plugin Streaming

**~15 minutes.** New in Kong Gateway 3.15.

## The scenario

Kong's `jwt` and `openid-connect` plugins validate the token — but they forward
only `X-Consumer-ID` and `X-Consumer-Custom-ID` upstream. **Not the claims.**

So every upstream service ends up re-parsing the JWT itself just to learn who
the caller is. The usual tell: at least six separate community plugins exist to
solve exactly this. It's one of the most commonly written custom plugins in the
Kong ecosystem.

You're going to build it — and ship it to a running fleet without an image
rebuild.

---

## Before you start

```bash
export KONNECT_TOKEN='kpat_your_token_here'
export PROXY=$(./bin/proxy-url)
export TOKEN=$(./lab-02-plugin-streaming/make-token.sh)
```

Run everything from the **repo root**.

The test token carries these claims:

```json
{
  "sub": "user-42",
  "email": "jane@acme.com",
  "tenant_id": "acme-corp",
  "roles": ["admin", "billing"],
  "realm_access": { "roles": ["platform-admin", "auditor"] },
  "iss": "https://id.acme.com"
}
```

---

## Step 1 — Ship the plugin

Open [step1-plugin.yaml](step1-plugin.yaml) and read the `custom_plugins:`
block. The whole plugin is there — `schema` and `handler`, as inline Lua.

```bash
./bin/deck gateway sync lab-02-plugin-streaming/step1-plugin.yaml --include-plugin-definitions
```

```bash
./bin/wait-for --present X-Jwt-Sub
```

```bash
./lab-02-plugin-streaming/verify.sh
```

You should see four claims land upstream, with the `roles` array flattened to a
comma-separated list:

```
    X-Jwt-Email                  jane@acme.com
    X-Jwt-Roles                  admin,billing
    X-Jwt-Sub                    user-42
    X-Jwt-Tenant-Id              acme-corp
```

`verify.sh` also runs a **spoofing check**: it sends forged `X-JWT-sub` and
`X-JWT-tenant-id` headers with *no token at all*. Those must never reach the
upstream — the plugin strips any inbound header using its prefix. Without that,
you've built an impersonation vulnerability, not an auth integration.

Note the data plane's start time. You'll compare against it in Step 3.

---

## Step 2 — A config change, and a lesson

Product comes back: *"our IdP is Keycloak, the roles we care about are nested
under `realm_access.roles`. Forward those too."*

Easy — add it to the claims list. The handler in
[step2-nested.yaml](step2-nested.yaml) is **byte-identical** to Step 1.

```bash
./bin/deck gateway sync lab-02-plugin-streaming/step2-nested.yaml --include-plugin-definitions
```

```bash
./lab-02-plugin-streaming/verify.sh
```

The counter still reads **4**, and no `X-Jwt-Realm-Access-Roles` header appears.

No error. No warning. The plugin looked up a literal key named
`"realm_access.roles"` in a flat table, found nothing, and moved on. **Config
alone cannot fix this** — it needs new logic.

---

## Step 3 — Change the code itself

This is the part that used to require a release.

[step3-hotpatch.yaml](step3-hotpatch.yaml) adds a `lookup()` helper that
resolves dot-separated paths, and also adds the `iss` claim to the config.

```bash
./bin/deck gateway sync lab-02-plugin-streaming/step3-hotpatch.yaml --include-plugin-definitions
```

```bash
./bin/wait-for --present X-Jwt-Realm-Access-Roles
```

```bash
./lab-02-plugin-streaming/verify.sh
```

Now six claims map, including the nested one:

```
    X-Jwt-Realm-Access-Roles     platform-admin,auditor
```

And the data plane's **start time and PID are unchanged from Step 1**. New
plugin logic, same process, no restart, no rebuild, no registry push.

---

## ⚠️ The gotcha that matters most

**Data planes reconcile when the config payload changes. Plugin code rides
along with that payload.**

Edit only the handler and re-sync, and the control plane will happily store your
new code while every data plane keeps running the old one — silently.

Measured on 3.15.0.2:

| Change | Result |
|--------|--------|
| Handler code only | still not live after 90s |
| Same code + a one-field config change | live in 16s |
| Handler code only, then restart the DP | live 2s after restart |

Bumping the handler's `VERSION` does **not** help — that was tested too.

Step 3 works because it changes code *and* config together. Most real changes
do, which is why this stays hidden until the one time it doesn't.

---

## Step 4 — Stretch

Pick one:

1. **Make a claim mandatory.** Return `403` when a configured claim is missing,
   instead of silently skipping it.
2. **Rename claims on the way out.** Let config map `tenant_id` → `X-Org-Id`
   rather than deriving the header name from the claim.
3. **Break the security model on purpose.** Remove the anti-spoofing loop,
   re-apply, and re-run `verify.sh`. Watch the forged headers reach upstream.

See [SOLUTION.md](SOLUTION.md).

---

## Streaming constraints

- **Lua only** — no Go, JavaScript, or Python plugins
- **Exactly one schema and one handler** — you cannot split across files
- **No `require()` of your own modules** (Kong's bundled libraries are fine —
  this plugin uses `cjson.safe`)
- **No `init_worker` phase, no timers**
- **No filesystem access**
- **Not supported on Serverless Gateways** (Dedicated Cloud and self-managed only)

If your plugin needs shared modules, background timers, or non-Lua code, use the
traditional packaging route instead.

### Customer conversations this unlocks

- "Every one of our services re-parses the JWT because the gateway won't pass
  claims through"
- "Our platform team is the bottleneck for every plugin change"
- "We maintain a custom gateway image just for two small plugins"
- Plugin version skew across a large fleet — the control plane is now authoritative
- Dedicated Cloud Gateway parity for hybrid and self-managed deployments
