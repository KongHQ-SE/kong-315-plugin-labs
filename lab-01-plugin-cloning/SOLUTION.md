# Lab 01 — Solution notes

## Step 4: what happens at `priority: 801`

The guardrail breaks again — but for a completely different reason than in Step 1.

At `priority: 801` the clone still exists and still runs. It just runs **after**
the app team's `request-transformer-advanced`. Since our clone only *removes*
headers, and the app team's plugin only *adds* one, the ordering happens to be
harmless with this particular config.

Change the app team's route plugin to re-add the header you're stripping and the
danger is obvious:

```yaml
- name: request-transformer-advanced
  config:
    add:
      headers:
        - "X-Internal-Debug: injected-by-route"
```

- Clone at **900** → scrub runs first, then the route re-adds it. Header present.
- Clone at **801** → route adds it, then the scrub removes it. Header absent.

Same two plugins, same configs, opposite outcomes. Priority is the only difference.

## The measured boundary

Tested on Kong Gateway 3.15.0.2 against a Konnect control plane, using a clone
that removes a header and a stock `request-transformer-advanced` that adds it:

| Clone priority | Clone ran |
|----------------|-----------|
| 900 | first |
| 802 | first |
| 801 | second |
| 800 | second |
| 700 | second |

So `request-transformer-advanced` resolves just below 802. A clone at **802 or
higher** runs before the stock plugin; **801 or lower** runs after.

**At equal priority, ordering is not guaranteed.** Don't rely on a tie. If order
matters, set the priority explicitly and leave headroom — which is why the lab
uses 900 rather than 802.

## If you omit `priority` entirely

The clone inherits the referenced plugin's priority. The API stores `priority:
null` and resolves it at runtime, so `GET /cloned-plugins` will *not* show you a
number. That's expected, not a bug.

## Naming constraints

The schema enforces:

- Lowercase `[a-z0-9-]`, must start with a letter and end with a letter or digit
- Must be unique
- **Must not be the name of a bundled plugin**
- The `ref` target must be cloneable, and **you cannot clone a clone**

Prefix your clones (`rta-`, `acme-`) so a future Kong release adding a bundled
plugin can't collide with a name you're already using in production.

## Gotcha that will cost you five minutes

Config takes **10–16 seconds** to reach the data plane. If you `curl` immediately
after `sync`, you'll read the *previous* state and conclude nothing happened.

This bit the author of this lab while building it — an early version of the
priority table above was completely wrong because every measurement was one
iteration stale. Use `./bin/wait-for` rather than a fixed `sleep`.
