#!/usr/bin/env bash
# Shows the gate's current behaviour, plus how long the data plane has been
# running — the number that proves no restart happened.
set -uo pipefail

PROXY="${PROXY:-$("$(dirname "${BASH_SOURCE[0]}")/../bin/proxy-url")}"
GW="${GW_NAME:-kong-quickstart-gateway}"

hdrs="$(mktemp)"; body="$(mktemp)"
code=$(curl -sS -o "$body" -D "$hdrs" -w '%{http_code}' "$PROXY/mock" --max-time 20 2>/dev/null)

echo
echo "  HTTP status : $code"

for h in X-Gate-Reason X-Gate-Opens-At X-Gate-Hotpatch Retry-After; do
  v=$(tr -d '\r' < "$hdrs" | grep -i "^${h}:" | head -1 | sed "s/^[^:]*: *//")
  [[ -n "$v" ]] && printf '  %-16s: %s\n' "$h" "$v"
done

if [[ "$code" == "503" ]]; then
  echo "  body        : $(head -c 300 "$body")"
else
  # Header values are a string or a list depending on the httpbin upstream.
  gate=$(BODY_FILE="$body" python3 <<'PY' 2>/dev/null
import json, os
try:
    with open(os.environ["BODY_FILE"]) as fh:
        v = json.load(fh).get("headers", {}).get("X-Gate")
except Exception:
    v = None
if isinstance(v, list):
    v = v[0] if v else None
print(v if v else "(none)")
PY
)
  echo "  X-Gate seen upstream: ${gate:-(none)}"
fi

echo
echo "  break-glass bypass:"
bcode=$(curl -sS -o /dev/null -w '%{http_code}' -H 'X-Break-Glass: incident-4471' "$PROXY/mock" --max-time 20 2>/dev/null)
echo "    with X-Break-Glass header -> HTTP $bcode"

started=$(docker inspect --format '{{.State.StartedAt}}' "$GW" 2>/dev/null)
pid=$(docker inspect --format '{{.State.Pid}}' "$GW" 2>/dev/null)
echo
echo "  data plane started at : $started"
echo "  data plane pid        : $pid"
echo "  (unchanged across steps = the plugin was updated without a restart)"
echo

rm -f "$hdrs" "$body"
