# Lab 02 — Solution notes

## The security model — read this before demoing to a customer

**This plugin decodes claims. It does not verify signatures.** On its own it
would happily trust any JWT-shaped string a client sends.

Two things keep it safe, and both are deliberate:

**1. It runs after authentication.** `PRIORITY = 900` puts it below Kong's auth
plugins (`key-auth` is 1250, `jwt` higher still), so by the time it executes the
token has already been validated. This is the same priority lesson as Lab 01 —
if you set this plugin *above* your auth plugin, you're mapping claims from an
unverified token straight into headers your backend trusts.

**2. It strips inbound headers using its own prefix.** Without that loop, a
client could simply send `X-JWT-sub: admin` with no token and impersonate
anyone, because the upstream cannot tell a gateway-set header from a
client-supplied one. `verify.sh` tests this on every run.

In production, pair it with `jwt` or `openid-connect`. Say that out loud in a
customer demo — SEs who show claim-forwarding without mentioning validation
teach a vulnerability.

## Stretch 1 — make a claim mandatory

Add a config field:

```lua
{ required_claims = { type = "array", elements = { type = "string" }, default = {} } },
```

Then, after decoding, before mapping:

```lua
for _, claim in ipairs(config.required_claims or {}) do
  if lookup(claims, claim) == nil then
    return kong.response.exit(403, {
      message = "token is missing a required claim",
      claim = claim,
    })
  end
end
```

Remember this is a code change — pair it with a config change or the data plane
will keep running the old handler.

## Stretch 2 — rename claims on the way out

Change `claims` from an array of strings to an array of records:

```lua
{ claims = {
    type = "array",
    elements = {
      type = "record",
      fields = {
        { name   = { type = "string", required = true } },
        { header = { type = "string" } },
      },
    },
} },
```

Then in the handler use `entry.header or header_name(prefix, entry.name)`.

This is a **breaking schema change** — existing plugin configs using the old
shape will fail validation. Worth discussing: streamed plugins make code changes
easy, which makes schema versioning discipline more important, not less.

## Stretch 3 — break it on purpose

Delete the anti-spoofing loop, re-apply with a config change, and re-run
`verify.sh`. The spoofing check flips to:

```
    !! forged headers REACHED upstream: ['X-Jwt-Sub', 'X-Jwt-Tenant-Id']
```

Any upstream trusting `X-JWT-sub` is now trivially bypassable. Restore it with
`step3-hotpatch.yaml`.

## Why `cjson.safe` rather than `cjson`

`cjson.decode` raises on malformed input. `cjson.safe.decode` returns `nil` plus
an error instead. A plugin in the request path should never throw on a
client-supplied string — a malformed token would become a 500.

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

That's why this plugin can parse JSON and base64 at all. What you can't do is
split across files, run in `init_worker`, create timers, or touch the filesystem.

## Base64url vs base64

JWT uses base64**url** encoding: `-` and `_` instead of `+` and `/`, and padding
stripped. `ngx.decode_base64` expects standard base64, so the handler translates
the alphabet and re-adds padding. A remainder of 1 is invalid and returns `nil`
rather than garbage.

## Things that surprised us while building this

**Bumping `VERSION` does not trigger a code reload.** It looks like it should.
Only a config payload change (or a restart) does.

**`--include-plugin-definitions` is required.** Without it decK silently skips
`custom_plugins` and `cloned_plugins` entirely — your sync "succeeds" and nothing
happens.

**Config propagation takes 10–16 seconds.** Long enough that curling immediately
gives you the previous state and a wrong conclusion. Use `./bin/wait-for`.

**Wait on a condition that distinguishes the new state.** After Step 1, waiting
on `--status 200` is useless — the route returned 200 before the plugin existed.
Wait on `--present X-Jwt-Sub`.
