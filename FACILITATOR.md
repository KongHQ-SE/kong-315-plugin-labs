# Facilitator notes

Everything here was verified against a real Konnect control plane and a Kong
Gateway **3.15.0.2** data plane. Where a number appears (propagation time,
priority boundary), it was measured, not assumed.

---

## Run of show — 30 minutes

| Time | What |
|------|------|
| −24h | Attendees run `./setup/start.sh` **before** they travel or the night before |
| 0:00 | Framing: two teams, one plugin — why this is a real customer problem (2 min) |
| 0:02 | **Lab 01** steps 1–2: apply the broken config, watch the guardrail vanish (5 min) |
| 0:07 | Explain plugin precedence (3 min) |
| 0:10 | **Lab 01** step 3: clone it, both run (5 min) |
| 0:15 | **Lab 02** steps 1–2: ship a custom plugin, change its config (7 min) |
| 0:22 | **Lab 02** step 3: change the code, no restart (6 min) |
| 0:28 | The propagation gotcha + customer conversations (2 min) |

**Setup is not part of the 30 minutes.** It pulls several hundred MB of images
and creates a Konnect control plane. If 30 people do that simultaneously on
conference wifi, you will lose the room. Send the setup instructions ahead of
time and make the first slide "raise your hand if `./setup/start.sh` failed."

---

## The two moments that land

**Lab 01, step 1.** The global guardrail disappears with *no error*. Let people
sit with that for a second before explaining. Security control silently dropped
because another team configured the same plugin is a story every platform
architect recognises.

**Lab 02, step 3.** Plugin code changes on a running gateway. Have them read the
data plane's start time out loud before and after — same process, new behaviour.
Then ask what their current process is for a ten-line Lua change.

---

## Talking points worth having ready

- Cloned first-party plugins **keep their parent's support tier**. This is the
  difference between a supported configuration and a fork the customer now owns.
- The 3.15 story is the control plane becoming authoritative for plugin **code**,
  not just configuration — that's what closes the gap with Dedicated Cloud Gateways.
- Streaming's constraints are real (see below). Don't oversell it as a
  replacement for all custom plugin packaging.

---

## Troubleshooting

### "Port is already allocated"

Kong wants 8000 and 8443. SSH tunnels, other dev servers, and previous Kong runs
commonly hold them. `setup/start.sh` detects this and lets Docker assign free
ports instead — which is why every lab command uses `$(./bin/proxy-url)` rather
than a hardcoded `:8000`.

If someone hardcodes port 8000 out of habit, this is why they get connection
refused.

### "Nothing happened when I applied the config"

Almost always one of three things:

1. **They didn't wait.** Propagation takes **10–16 seconds**. Use
   `./bin/wait-for`, not `sleep`, and not a bare curl.
2. **They forgot `--include-plugin-definitions`.** Without it, decK silently
   skips `custom_plugins` and `cloned_plugins`. The sync reports success and
   nothing changes. This is the single most common failure in Lab 02.
3. **They changed only plugin code.** See below.

### `wait-for` returned instantly and the result was wrong

Wait on a condition that **distinguishes the new state from the old one**.

`./bin/wait-for --status 200` after Lab 02 step 1 is useless — the route already
returned 200 before the plugin existed, so it succeeds immediately and you
measure the old state. Wait on `--present X-Gate` instead.

Same trap with `--absent`: the probe has to actually *send* the header it's
checking for, or "absent upstream" is trivially true. `bin/wait-for` sends
`X-Internal-Debug` and `X-Internal-Trace` on every request for this reason.

Both of these produced confidently wrong results while building these labs.

### "I changed the handler and nothing changed"

Expected behaviour, and worth teaching rather than hiding.

Data planes reconcile on **config payload** changes; plugin code rides along
with that payload. A code-only edit is stored on the control plane and never
reaches the running data plane.

Measured:

| Change | Result |
|--------|--------|
| Handler code only | not live after 90s |
| Handler code + one config field | live in 16s |
| Handler code only, then DP restart | live 2s after restart |
| Bumping the handler's `VERSION` | no effect |

Fix: change a config value alongside the code, or restart the data plane.

### decK version errors

Nobody should hit this — `bin/deck` runs decK **v1.65.1** in a container. If
someone bypasses the wrapper and uses a local decK, streaming needs ≥ 1.65.1,
and on macOS the Homebrew tap additionally requires `brew trust kong/deck`.
Point them back at the wrapper.

### decK reports "no such file or directory" for a file that exists

Docker Desktop only bind-mounts shared paths — `/Users` on macOS by default,
**not** `/tmp` or `/private/tmp`. The mount silently resolves to an empty
directory. Make sure the repo is cloned somewhere under the home directory.

### The quickstart script says initialization failed

Its post-start validation probes default ports and can report failure even when
the gateway is healthy. `setup/start.sh` ignores that and verifies independently.
If the gateway container exists and is healthy, carry on.

### Konnect returns 401/403

The PAT is wrong, expired, or from a different region. These labs use the **US**
region (`us.api.konghq.com`). Generate a new token at
<https://cloud.konghq.com/global/account/tokens>.

---

## Verified reference numbers

Useful if someone asks and you don't want to guess.

**Plugin cloning**

- decK key `cloned_plugins`; Admin API `/cloned-plugins`
- Fields: `name` (required, unique, `[a-z0-9-]`, must not be a bundled plugin
  name), `ref` (required, must be cloneable, cannot clone a clone),
  `priority` (optional; inherits the referenced plugin's priority when omitted,
  and is stored as `null` rather than resolved)
- 16 cloneable bundled plugins in 3.15: `openid-connect`, `acl`, `pre-function`,
  `post-function`, `request-transformer-advanced`, `request-transformer`,
  `response-transformer-advanced`, `response-transformer`, `key-auth`,
  `file-log`, `http-log`, `tcp-log`, `ip-restriction`, `route-by-header`, `opa`,
  `datakit`
- Requires a license; Konnect entitlement satisfies it automatically
- Measured priority boundary vs stock `request-transformer-advanced`: a clone at
  **802 or higher runs first**, **801 or lower runs second**. At equal priority
  ordering is not guaranteed — set it explicitly.

**Plugin streaming**

- decK key `custom_plugins`; Admin API `/custom-plugins`
- Fields: `name`, `schema`, `handler` (all required)
- Data plane needs `KONG_CUSTOM_PLUGIN_STREAMING_ENABLED=on`
- decK ≥ 1.65.1
- Lua only; exactly one schema + one handler; no `require()` of your own
  modules; no `init_worker`; no timers; no filesystem access
- Not supported on Serverless Gateways

---

## Teardown

```bash
./setup/teardown.sh
```

Prompts for confirmation, then removes the local containers and deletes the
`kong-315-labs` control plane. Nothing else in the org is touched. Remind people
to run it — orphaned control planes accumulate fast after an offsite.
