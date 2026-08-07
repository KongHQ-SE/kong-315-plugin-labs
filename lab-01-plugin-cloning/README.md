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
export PROXY=$(./bin/proxy-url)
```

Run everything from the **repo root**, not from this folder.

---

## Step 1 — Apply the obvious config

```bash
./bin/deck gateway sync lab-01-plugin-cloning/step1-broken.yaml
```

Wait for it to reach the data plane, then check what actually ran.

`X-App-Tier` is added to the request Kong sends **upstream**, so `--present`
checks the JSON httpbin echoes back rather than the response headers:

```bash
./bin/wait-for --present X-App-Tier
```

```bash
./lab-01-plugin-cloning/verify.sh
```

You should see:

```
  platform guardrail (remove) ran?  NO
  app team transform (add) ran?     YES

  => Only the route-scoped plugin ran.
```

**The guardrail vanished.** No error, no warning, no log line. `X-Internal-Debug`
sailed through to the upstream.

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

```bash
./bin/wait-for --absent X-Internal-Debug
```

```bash
./lab-01-plugin-cloning/verify.sh
```

Now:

```
  platform guardrail (remove) ran?  YES
  app team transform (add) ran?     YES

  => BOTH RAN. Cloning worked.
```

The app team's config never changed. The platform team got its guardrail back.

---

## Step 4 — Stretch: prove that priority matters

`priority: 900` isn't decoration. The guardrail must run *before* the app team's
transform, or a route could re-add a header you just stripped.

Change the priority in `step2-cloned.yaml` from `900` to `801`, re-sync, and
re-verify:

```bash
./bin/deck gateway sync lab-01-plugin-cloning/step2-cloned.yaml --include-plugin-definitions
```

Then read [SOLUTION.md](SOLUTION.md) for what you should have seen and why.

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
