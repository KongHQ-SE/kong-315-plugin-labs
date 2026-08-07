# Lab 02 — Plugin Streaming

**~15 minutes.** New in Kong Gateway 3.15.

## The scenario

A team needs a custom plugin: block traffic outside business hours, with a
break-glass header for incidents. Nothing bundled does exactly this.

Before 3.15, shipping that to a hybrid fleet meant building a custom gateway
image, pushing it to a registry, rolling every data plane, and coordinating with
whoever owns the deploy pipeline. A ten-line Lua change became a release.

With plugin streaming, the plugin's **code** lives on the control plane and is
streamed to every connected data plane.

---

## Before you start

```bash
export KONNECT_TOKEN='kpat_your_token_here'
export PROXY=$(./bin/proxy-url)
```

Run everything from the **repo root**.

---

## Step 1 — Ship the plugin

Open [step1-plugin.yaml](step1-plugin.yaml) and read the `custom_plugins:` block.
The whole plugin is there: `schema` and `handler`, as inline Lua.

```bash
./bin/deck gateway sync lab-02-plugin-streaming/step1-plugin.yaml --include-plugin-definitions
```

Wait for `X-Gate` — the header the plugin adds to the upstream request. Don't
wait on `--status 200`: the route already returned 200 before the plugin
existed, so that condition is true immediately and tells you nothing.

```bash
./bin/wait-for --present X-Gate
```

```bash
./lab-02-plugin-streaming/verify.sh
```

You should get **HTTP 200**, and `X-Gate: open` was added to the upstream request.

You just deployed a custom plugin to a running gateway. No image was built. No
container was restarted. Note the data plane's start time in the output — you'll
compare against it in Step 3.

---

## Step 2 — Close the gate (config change)

[step2-closed.yaml](step2-closed.yaml) has a **byte-identical handler**. Only the
`config:` block changed.

```bash
./bin/deck gateway sync lab-02-plugin-streaming/step2-closed.yaml --include-plugin-definitions
```

```bash
./bin/wait-for --status 503
```

```bash
./lab-02-plugin-streaming/verify.sh
```

Now: **HTTP 503**, `X-Gate-Reason: outside-hours`, `Retry-After: 3600`, and the
break-glass header still gets through with a 200.

---

## Step 3 — Change the code itself

This is the part that used to require a release.

[step3-hotpatch.yaml](step3-hotpatch.yaml) modifies the **handler** to return two
new headers on the 503, and also changes the `message` config value.

```bash
./bin/deck gateway sync lab-02-plugin-streaming/step3-hotpatch.yaml --include-plugin-definitions
```

```bash
./bin/wait-for 'X-Gate-Hotpatch: v2'
```

```bash
./lab-02-plugin-streaming/verify.sh
```

You should now see `X-Gate-Opens-At` and `X-Gate-Hotpatch: v2` — and the data
plane's **start time and PID are unchanged from Step 1**. New plugin code, same
process, no restart, no rebuild.

---

## ⚠️ The gotcha that matters most

**Data planes reconcile when the config payload changes. Plugin code rides along
with that payload.**

Edit only the handler and re-sync, and the control plane will happily store your
new code while every data plane keeps running the old one — silently. No error,
no warning.

Measured on 3.15.0.2:

| Change | Result |
|--------|--------|
| Handler code only | still not live after 90s |
| Same code + a one-field config change | live in 16s |
| Handler code only, then restart the DP | live 2s after restart |

Bumping the handler's `VERSION` field does **not** help — that was tested too.

In practice most real code changes ship alongside a config change, so this stays
hidden until the one time it doesn't. If you're pushing a pure code fix, either
touch a config value or restart the data plane.

---

## Step 4 — Stretch

Set a real business-hours window for the Dallas office and confirm the gate
behaves as expected:

```yaml
allowed_days: ["mon","tue","wed","thu","fri"]
start_hour: 9
end_hour: 17
utc_offset_hours: -5     # US Central Daylight Time
```

Then look at the 503 body — it reports `local_hour` and `local_dow`
(`0` = Sunday). Do those match Dallas wall-clock time?

See [SOLUTION.md](SOLUTION.md) when you're done.

---

## Streaming constraints

Streamed plugins are more restricted than file-installed ones:

- **Lua only** — no Go, JavaScript, or Python plugins
- **Exactly one schema and one handler** — no helper modules
- **No `require()`** of your own modules
- **No `init_worker` phase, no timers**
- **No filesystem access**
- **Not supported on Serverless Gateways** (Dedicated Cloud and self-managed only)

That last set is why this lab's handler computes day-of-week with arithmetic on
`ngx.time()` instead of calling `os.date()` — no library dependency, nothing for
the sandbox to reject, and no timezone database needed in the container.

If your plugin needs shared modules, background timers, or non-Lua code, use the
traditional packaging route instead.

### Customer conversations this unlocks

- "Our platform team is the bottleneck for every plugin change"
- "We maintain a custom gateway image just for two small plugins"
- Plugin version skew across a large fleet — the control plane is now authoritative
- Dedicated Cloud Gateway parity for hybrid and self-managed deployments
