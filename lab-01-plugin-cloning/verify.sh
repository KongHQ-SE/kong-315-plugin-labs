#!/usr/bin/env bash
# Reports which of the two transforms actually ran.
#
# We send two internal headers the platform guardrail is supposed to strip, then
# read the JSON httpbin echoes back — that shows what Kong ACTUALLY forwarded
# upstream, not what we sent.
set -uo pipefail

PROXY="${PROXY:-$("$(dirname "${BASH_SOURCE[0]}")/../bin/proxy-url")}"

RESP="$(mktemp)"
trap 'rm -f "$RESP"' EXIT

curl -sS "$PROXY/mock" \
  -H 'X-Internal-Debug: leak-me' \
  -H 'X-Internal-Trace: also-leak' \
  --max-time 20 -o "$RESP" || { echo "Request failed. Is the gateway up?"; exit 1; }

RESP_FILE="$RESP" python3 <<'PY'
import json, os, sys

try:
    with open(os.environ["RESP_FILE"]) as fh:
        headers = json.load(fh)["headers"]
except Exception:
    print("Could not parse the upstream response. Is the gateway up?")
    sys.exit(1)

def value(name):
    """Header values come back as a string or a list depending on which
    httpbin implementation is upstream. Normalise to a plain string."""
    v = headers.get(name)
    if isinstance(v, list):
        return v[0] if v else None
    return v

seen = {k.lower() for k in headers}
debug_through = "x-internal-debug" in seen
trace_through = "x-internal-trace" in seen
scrub_ran = not debug_through and not trace_through
tier = value("X-App-Tier")

print()
print(f"  X-Internal-Debug reached upstream : {debug_through}")
print(f"  X-Internal-Trace reached upstream : {trace_through}")
print(f"  X-App-Tier                        : {tier if tier else '(absent)'}")
print()
print(f"  platform guardrail (remove) ran?  {'YES' if scrub_ran else 'NO'}")
print(f"  app team transform (add) ran?     {'YES' if tier else 'NO'}")
print()

if scrub_ran and tier:
    print("  => BOTH RAN. Cloning worked.")
elif tier and not scrub_ran:
    print("  => Only the route-scoped plugin ran.")
    print("     The global guardrail was silently discarded — this is the")
    print("     precedence problem plugin cloning solves.")
elif scrub_ran and not tier:
    print("  => Only the global plugin ran. Check the route-level config.")
else:
    print("  => Neither ran. Did the config finish propagating? Try:")
    print("     ./bin/wait-for --absent X-Internal-Debug")
print()
PY
