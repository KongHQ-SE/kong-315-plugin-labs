# Lab 01 — Plugin Cloning

**~15 minutes.** New in Kong Gateway 3.15.

## The scenario

You run the platform team. You want one global guardrail: strip spoofable
`X-Internal-*` headers off every request before it reaches any upstream, so a
client can't forge internal trust headers.

An app team owns a route and uses `request-transformer-advanced` to tag their
own traffic.

Both of you need the same plugin. Watch what happens.

---

## Before you start

```bash
export KONNECT_TOKEN='kpat_your_token_here'
```

```bash
export PROXY=$(./bin/proxy-url)
```

Run everything from the **repo root**, not from this folder.

The upstream is a local httpbin that echoes back whatever Kong forwards to it.
That's the trick that makes this lab readable: you're not guessing what the
gateway did, you're reading what the upstream actually received.

---

## Step 1 — Apply the obvious config

```bash
./bin/deck gateway sync lab-01-plugin-cloning/step1-broken.yaml
```

Now send a request carrying the two internal headers the platform guardrail is
supposed to strip:

```bash
curl -s "$PROXY/mock" \
  -H 'X-Internal-Debug: leak-me' \
  -H 'X-Internal-Trace: also-leak' \
| python3 -c '
import json, sys
headers = json.load(sys.stdin)["headers"]
for name in sorted(headers):
    if name.lower().startswith("x-"):
        value = headers[name]
        print(f"  {name}: {value[0] if isinstance(value, list) else value}")
'
```

> **If the output looks unchanged from before**, wait a few seconds and run the
> curl again. Config takes **10–16 seconds** to reach the data plane. Every
> confusing result in this lab is that timer.

Expected:

```
  X-App-Tier: gold
  X-Forwarded-For: 172.23.0.1
  X-Forwarded-Host: localhost
  X-Forwarded-Path: /mock
  X-Forwarded-Port: 8000
  X-Forwarded-Proto: http
  X-Internal-Debug: leak-me
  X-Internal-Trace: also-leak
  X-Kong-Request-Id: e5b3726dfe6c7e0c9d3a9d09a9bf735d
  X-Real-Ip: 172.23.0.1
```

Read those last two carefully. `X-Internal-Debug` and `X-Internal-Trace`
**reached the upstream**. `X-App-Tier: gold` is there, so the app team's
route-level plugin ran.

**The guardrail vanished.** No error, no warning, no log line.

---

## Step 2 — Why

Kong allows **one instance of a given plugin per request**. When the same plugin
is configured at more than one scope, the most specific scope wins and the others
are discarded:

```
  consumer + route + service   >   consumer + route   >   ...   >   global
```

Your global `request-transformer-advanced` and the app team's route-level
`request-transformer-advanced` are *the same plugin*. The route-scoped one is
more specific, so it replaces yours entirely.

Before 3.15 the workarounds were all bad: fold both teams' rules into one shared
config (now the platform team owns app-team logic), or hand-fork the plugin
source under a new name and maintain it yourself forever.

---

## Step 3 — Clone the plugin

`cloned_plugins` creates a new plugin that reuses the referenced plugin's code
and schema under a **different name**:

```yaml
cloned_plugins:
  - name: rta-platform
    ref: request-transformer-advanced
    priority: 900
```

Because `rta-platform` is a different plugin name, it no longer collides with
the app team's instance.

Note the `--include-plugin-definitions` flag — `cloned_plugins` and
`custom_plugins` are plugin *definitions*, and decK skips them without it. The
`bin/deck` wrapper does **not** add it for you, on purpose: forgetting it is a
mistake worth making once.

```bash
./bin/deck gateway sync lab-01-plugin-cloning/step2-cloned.yaml --include-plugin-definitions
```

Confirm the clone actually exists on the control plane:

```bash
./bin/deck gateway dump --include-plugin-definitions -o - | grep -A3 'cloned_plugins:'
```

```
cloned_plugins:
- name: rta-platform
  priority: 900
  ref: request-transformer-advanced
```

Now run the **exact same curl as Step 1**:

```bash
curl -s "$PROXY/mock" \
  -H 'X-Internal-Debug: leak-me' \
  -H 'X-Internal-Trace: also-leak' \
| python3 -c '
import json, sys
headers = json.load(sys.stdin)["headers"]
for name in sorted(headers):
    if name.lower().startswith("x-"):
        value = headers[name]
        print(f"  {name}: {value[0] if isinstance(value, list) else value}")
'
```

Expected:

```
  X-App-Tier: gold
  X-Forwarded-For: 172.23.0.1
  X-Forwarded-Host: localhost
  X-Forwarded-Path: /mock
  X-Forwarded-Port: 8000
  X-Forwarded-Proto: http
  X-Kong-Request-Id: 69a4ad5aa3a2dd42ad32e66aaa6ba007
  X-Real-Ip: 172.23.0.1
```

`X-Internal-Debug` and `X-Internal-Trace` are **gone** — the platform guardrail
ran. `X-App-Tier: gold` is still there — the app team's transform ran too.

Both plugins executed in the same request. The app team's config never changed.

---

## Step 4 — Stretch: prove that priority matters

`priority: 900` isn't decoration. The guardrail must run *before* the app team's
transform, or a route could re-add a header you just stripped.

Make the collision explicit. Edit `step2-cloned.yaml` so the app team's plugin
re-adds the header the platform team strips:

```yaml
          - name: request-transformer-advanced
            config:
              add:
                headers:
                  - "X-App-Tier: gold"
                  - "X-Internal-Debug: injected-by-route"
```

Re-sync and run the curl. Then change the clone's `priority` from `900` to
`801`, re-sync, and run it again. Same two plugins, same configs — opposite
results.

[SOLUTION.md](SOLUTION.md) has the measured priority table and explains the
boundary.

---

## What to remember

- One plugin instance runs per request; a more specific scope **silently replaces**
  a broader one
- `cloned_plugins` gives the same plugin code a second identity so both can run
- Cloned first-party plugins keep their parent's **support tier** — this is not a
  fork you now own
- 16 bundled plugins are cloneable in 3.15, including `openid-connect`, `acl`,
  `key-auth`, `ip-restriction`, and both transformer families
- Clones require a license; Konnect entitlement satisfies this automatically

### Customer conversations this unlocks

- Dual JWT/OIDC validation against two different identity providers in one request
- A global IP allowlist plus a stricter per-route one, both enforced
- Layered ACLs where a platform baseline and a team-specific policy coexist
- Any "we forked a Kong plugin just to change its name or priority" tech debt
