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
```

```bash
export PROXY=$(./bin/proxy-url)
export TOKEN=$(./lab-02-plugin-streaming/make-token.sh)
```

Run everything from the **repo root**.

Look at what's actually in that token, so you know what should come out the
other side:

```bash
echo "$TOKEN" | cut -d. -f2 | python3 -c '
import base64, json, sys
payload = sys.stdin.read().strip()
payload += "=" * (-len(payload) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(payload)), indent=2))
'
```

```json
{
  "sub": "user-42",
  "email": "jane@acme.com",
  "tenant_id": "acme-corp",
  "roles": [
    "admin",
    "billing"
  ],
  "realm_access": {
    "roles": [
      "platform-admin",
      "auditor"
    ]
  },
  "iss": "https://id.acme.com",
  "exp": 4102444800
}
```

Note `roles` is a flat array, and `realm_access.roles` is **nested**. That
distinction is the whole of Steps 2 and 3.

Before you change anything, record what the data plane is right now:

```bash
docker inspect --format '  started={{.State.StartedAt}}  pid={{.State.Pid}}' kong-quickstart-gateway
```

```
  started=2026-08-07T20:24:48.922669197Z  pid=3637404
```

Keep those numbers. They're the proof at the end.

---

## Step 1 — Ship the plugin

Open [step1-plugin.yaml](step1-plugin.yaml) and read the `custom_plugins:`
block. The whole plugin is there — `schema` and `handler`, as inline Lua.

```bash
./bin/deck gateway sync lab-02-plugin-streaming/step1-plugin.yaml --include-plugin-definitions
```

Now send the token and read what the upstream received:

```bash
curl -s "$PROXY/mock" -H "Authorization: Bearer $TOKEN" \
| python3 -c '
import json, sys
headers = json.load(sys.stdin)["headers"]
for name in sorted(headers):
    if name.lower().startswith("x-jwt-"):
        value = headers[name]
        print(f"  {name}: {value[0] if isinstance(value, list) else value}")
'
```

> **Nothing yet?** Wait a few seconds and re-run. Config takes **10–16 seconds**
> to reach the data plane. Every confusing result in this lab is that timer.

```
  X-Jwt-Claims-Mapped: 4
  X-Jwt-Email: jane@acme.com
  X-Jwt-Roles: admin,billing
  X-Jwt-Sub: user-42
  X-Jwt-Tenant-Id: acme-corp
```

Four claims, with the `roles` array flattened to a comma-separated list. You
just deployed a custom plugin to a running gateway — no image built, no
container restarted.

### Now try to break it

The plugin sets headers your upstream is going to trust. So what stops a client
from just *sending* those headers?

Send forged ones, with **no token at all**:

```bash
curl -s "$PROXY/mock" \
  -H 'X-JWT-sub: attacker-999' \
  -H 'X-JWT-tenant-id: victim-corp' \
| python3 -c '
import json, sys
headers = json.load(sys.stdin)["headers"]
forged = [n for n in headers if n.lower().startswith("x-jwt-")]
print("  X-JWT-* headers reaching upstream:", forged if forged else "none - stripped")
'
```

```
  X-JWT-* headers reaching upstream: none - stripped
```

The handler clears any inbound header matching its own prefix before it sets its
own. Without those four lines of Lua you'd have built an impersonation
vulnerability, not an auth integration. Look for the loop in
[step1-plugin.yaml](step1-plugin.yaml).

---

## Step 2 — A config change, and a lesson

Product comes back: *"our IdP is Keycloak, the roles we care about are nested
under `realm_access.roles`. Forward those too."*

Easy — add it to the claims list. The handler in
[step2-nested.yaml](step2-nested.yaml) is **byte-identical** to Step 1. Confirm
that yourself rather than taking our word for it — the `grep` drops comment-only
lines so you see just the real change:

```bash
diff lab-02-plugin-streaming/step1-plugin.yaml lab-02-plugin-streaming/step2-nested.yaml \
  | grep -E '^[<>]' | grep -vE '^[<>] *#'
```

```
<               claims: ["sub", "email", "tenant_id", "roles"]
>               claims: ["sub", "email", "tenant_id", "roles", "realm_access.roles"]
```

One line. Not a single character of Lua changed.

```bash
./bin/deck gateway sync lab-02-plugin-streaming/step2-nested.yaml --include-plugin-definitions
```

Wait ~20 seconds, then run the same curl as Step 1:

```bash
curl -s "$PROXY/mock" -H "Authorization: Bearer $TOKEN" \
| python3 -c '
import json, sys
headers = json.load(sys.stdin)["headers"]
for name in sorted(headers):
    if name.lower().startswith("x-jwt-"):
        value = headers[name]
        print(f"  {name}: {value[0] if isinstance(value, list) else value}")
'
```

```
  X-Jwt-Claims-Mapped: 4
  X-Jwt-Email: jane@acme.com
  X-Jwt-Roles: admin,billing
  X-Jwt-Sub: user-42
  X-Jwt-Tenant-Id: acme-corp
```

Still **4**. No `X-Jwt-Realm-Access-Roles` header. No error, no warning.

The plugin looked up a literal key named `"realm_access.roles"` in a flat table,
found nothing, and moved on. **Config alone cannot fix this** — it needs new
logic.

---

## Step 3 — Change the code itself

This is the part that used to require a release.

See exactly what changes:

```bash
diff lab-02-plugin-streaming/step2-nested.yaml lab-02-plugin-streaming/step3-hotpatch.yaml \
  | grep -E '^[<>]' | grep -vE '^[<>] *#'
```

```
<         VERSION = "1.0.0",
>         VERSION = "1.1.0",
>       -- Resolve a dot-separated path such as "realm_access.roles".
>       local function lookup(claims, path)
>         local node = claims
>         for part in path:gmatch("[^%.]+") do
>           if type(node) ~= "table" then return nil end
>           node = node[part]
>         end
>         return node
>       end
>
<           local s = stringify(claims[claim])
>           local s = stringify(lookup(claims, claim))
<               claims: [..., "realm_access.roles"]
>               claims: [..., "realm_access.roles", "iss"]
```

A `lookup()` helper that walks dot-separated paths (**code**), and the `iss`
claim added to the list (**config**). Both matter — see the warning below.

```bash
./bin/deck gateway sync lab-02-plugin-streaming/step3-hotpatch.yaml --include-plugin-definitions
```

Same curl again:

```bash
curl -s "$PROXY/mock" -H "Authorization: Bearer $TOKEN" \
| python3 -c '
import json, sys
headers = json.load(sys.stdin)["headers"]
for name in sorted(headers):
    if name.lower().startswith("x-jwt-"):
        value = headers[name]
        print(f"  {name}: {value[0] if isinstance(value, list) else value}")
'
```

```
  X-Jwt-Claims-Mapped: 6
  X-Jwt-Email: jane@acme.com
  X-Jwt-Iss: https://id.acme.com
  X-Jwt-Realm-Access-Roles: platform-admin,auditor
  X-Jwt-Roles: admin,billing
  X-Jwt-Sub: user-42
  X-Jwt-Tenant-Id: acme-corp
```

Six claims, including the nested one. Now check the data plane again:

```bash
docker inspect --format '  started={{.State.StartedAt}}  pid={{.State.Pid}}' kong-quickstart-gateway
```

```
  started=2026-08-07T20:24:48.922669197Z  pid=3637404
```

**Identical to what you recorded before Step 1.** New plugin logic, same
process, no restart, no rebuild, no registry push.

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

Prove it to yourself: edit `step3-hotpatch.yaml`, change the handler's
`X-JWT-` prefix logic or add a claim mapping, but **touch nothing** in the
`config:` block. Re-sync and curl. Nothing changes.

---

## Step 4 — Stretch

Pick one:

1. **Make a claim mandatory.** Return `403` when a configured claim is missing,
   instead of silently skipping it.
2. **Rename claims on the way out.** Let config map `tenant_id` → `X-Org-Id`
   rather than deriving the header name from the claim.
3. **Break the security model on purpose.** Remove the anti-spoofing loop,
   re-apply *with a config change*, and re-run the forged-header curl from
   Step 1. Watch the forged values reach upstream.

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
