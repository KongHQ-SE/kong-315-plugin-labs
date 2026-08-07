# Lab 02 — Solution notes

## Step 4: the Dallas window

```yaml
allowed_days: ["mon","tue","wed","thu","fri"]
start_hour: 9
end_hour: 17
utc_offset_hours: -5
```

`utc_offset_hours: -5` is US Central **Daylight** Time. Central Standard Time is
`-6`. The plugin takes a fixed offset, so it does not follow DST transitions — a
deliberate simplification, and worth naming out loud if a customer asks.

If you need true timezone handling, that's an argument for a file-installed
plugin with a timezone library, since streamed plugins can't `require()` one.

## Reading the 503 body

```json
{
  "message": "Closed for scheduled maintenance. Try again shortly.",
  "reason": "outside-hours",
  "local_hour": 14,
  "local_dow": 5
}
```

- `local_dow` is `0` = Sunday through `6` = Saturday
- `local_hour` is 24-hour, already offset-adjusted

`reason` distinguishes the two ways to be closed:

- `day-not-allowed` — today isn't in `allowed_days`
- `outside-hours` — right day, wrong hour

## How the date math works

```lua
local t    = ngx.time() + math.floor((config.utc_offset_hours or 0) * 3600)
local days = math.floor(t / 86400)
local dow  = (days + 4) % 7
local hour = math.floor((t % 86400) / 3600)
```

Epoch day 0 (1970-01-01) was a **Thursday**. With Sunday as 0, Thursday is 4, so
`(days + 4) % 7` maps epoch days onto weekday indices.

Verified live: on Friday 2026-08-07 at 20:00 UTC the plugin reported
`local_dow: 5` and `local_hour: 20`. Both correct.

## Why not `os.date()`?

`os.date()` does work in a streamed plugin — that was verified, not assumed. The
arithmetic version was chosen because it doesn't depend on the container's
timezone data, which is a deployment variable you don't control across a fleet.
Either approach is defensible; this one has one fewer moving part.

## Things that surprised us while building this

**Bumping `VERSION` does not trigger a code reload.** It looks like it should.
It doesn't. Only a config payload change (or a restart) does.

**`--include-plugin-definitions` is required.** Without it decK silently skips
`custom_plugins` and `cloned_plugins` entirely — your sync "succeeds" and nothing
happens.

**Config propagation takes 10–16 seconds.** Long enough that curling immediately
gives you the previous state and a wrong conclusion. Use `./bin/wait-for`.

**`kong.response.exit()` with a Lua table** serializes to JSON automatically and
sets the content type, so you don't need to reach for `cjson` at all here.

## What the sandbox actually allows

The "no `require()`" constraint is narrower than it first reads: it blocks
**your own** modules, not Kong's bundled Lua libraries. Probed on a live 3.15
data plane from inside a streamed plugin:

| Call | Result |
|------|--------|
| `require("cjson")` | works |
| `require("cjson.safe")` | works |
| `require("resty.string")` | works |
| `ngx.decode_base64()` | works |
| `os.date()` / `os.time()` | work |
| `kong.request.get_body()` | available |

That matters for scoping real customer plugins: JSON parsing, base64 decoding,
and hashing are all on the table. What you can't do is split your plugin across
files, run in `init_worker`, create timers, or touch the filesystem.
