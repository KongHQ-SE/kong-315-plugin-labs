# Kong Gateway 3.15 Plugin Labs

Two hands-on exercises covering the plugin features introduced in **Kong Gateway 3.15**:

| Lab | Feature | Time |
|-----|---------|------|
| [Lab 01](lab-01-plugin-cloning/) | **Plugin Cloning** — run two instances of `request-transformer-advanced` in one request | ~15 min |
| [Lab 02](lab-02-plugin-streaming/) | **Plugin Streaming** — ship a JWT claims-to-headers plugin from the control plane, no image rebuild | ~15 min |

Each lab walks you through explicit `curl` commands and shows the expected
output, so you read what the gateway actually did rather than trusting a script
that says "PASS".

Everything runs against **your own Konnect org** with a single Kong 3.15 data plane in Docker on your laptop.

> **Facilitators:** read [FACILITATOR.md](FACILITATOR.md) for run-of-show, timings, and the failure modes that will actually bite you.

---

## Prerequisites

- **Docker** running, with ~2 GB free
- A **Konnect account** and a **personal access token** ([create one here](https://cloud.konghq.com/global/account/tokens))
- `curl`, `python3` (both ship with macOS)

**You do not need decK installed.** The `bin/deck` wrapper in this repo runs decK v1.65.1 in a container, so everyone is on an identical version. Plugin streaming requires decK ≥ 1.65.1, and most laptops have something older.

---

## Setup (do this *before* the session starts)

```bash
export KONNECT_TOKEN='kpat_your_token_here'
```

```bash
./setup/start.sh
```

That script creates a Konnect control plane named `kong-315-labs`, runs a Kong 3.15 data plane in Docker with plugin streaming enabled, starts a local httpbin upstream, and applies a `mock` service and route.

It prints your proxy URL at the end. Save it:

```bash
export PROXY=$(./bin/proxy-url)
curl -s $PROXY/mock | python3 -m json.tool
```

You should see JSON echoing your request headers. If you do, you're ready.

---

## The one thing that will confuse you

**Config changes take 10–16 seconds to reach the data plane.** If you curl
immediately after applying, you will see the *previous* config and conclude the
exercise is broken.

When a result looks wrong, **re-run the same curl** before debugging anything
else. That's the fix nine times out of ten.

There is deliberately no wrapper script that waits for you, and no script that
tells you whether a step passed. Every check in these labs is a `curl` you run
and output you read. If you're going to demo this to a customer, you want the
commands in your fingers, not in a helper.

---

## Teardown

```bash
./setup/teardown.sh
```

Removes the local containers and deletes the `kong-315-labs` control plane from your Konnect org. Nothing else in your org is touched.

---

## Repo layout

```
setup/          one-command environment bring-up and teardown
bin/            deck wrapper (containerised) and proxy URL helper
lab-01-*/       plugin cloning: broken config -> cloned fix -> stretch task
lab-02-*/       plugin streaming: deploy a custom plugin -> hot-update it
FACILITATOR.md  run-of-show and troubleshooting
```
