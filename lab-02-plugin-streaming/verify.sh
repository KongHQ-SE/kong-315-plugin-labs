#!/usr/bin/env bash
# Shows which JWT claims reached the upstream service, proves forged headers are
# stripped, and reports data plane uptime (the number that proves no restart).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY="${PROXY:-$("$HERE/../bin/proxy-url")}"
GW="${GW_NAME:-kong-quickstart-gateway}"
TOKEN="${TOKEN:-$("$HERE/make-token.sh")}"

RESP="$(mktemp)"; SPOOF="$(mktemp)"
trap 'rm -f "$RESP" "$SPOOF"' EXIT

curl -sS "$PROXY/mock" -H "Authorization: Bearer $TOKEN" --max-time 20 -o "$RESP" \
  || { echo "Request failed. Is the gateway up?"; exit 1; }

# A forged header with NO token at all — must never reach the upstream.
curl -sS "$PROXY/mock" \
  -H 'X-JWT-sub: attacker-999' \
  -H 'X-JWT-tenant-id: victim-corp' \
  --max-time 20 -o "$SPOOF" || true

RESP_FILE="$RESP" SPOOF_FILE="$SPOOF" python3 <<'PY'
import json, os, sys

def load(path):
    try:
        with open(path) as fh:
            return json.load(fh).get("headers", {})
    except Exception:
        return None

def one(v):
    # httpbin implementations return either a string or a list of strings.
    if isinstance(v, list):
        return v[0] if v else None
    return v

headers = load(os.environ["RESP_FILE"])
if headers is None:
    print("Could not parse the upstream response. Is the gateway up?")
    sys.exit(1)

mapped = {k: one(v) for k, v in headers.items() if k.lower().startswith("x-jwt-")}
count = mapped.pop("X-Jwt-Claims-Mapped", None)

print()
print("  Claims that reached the upstream service:")
if mapped:
    for k in sorted(mapped):
        print(f"    {k:28} {mapped[k]}")
else:
    print("    (none)")
print(f"\n  claims-mapped counter: {count if count else '(absent)'}")

nested = [k for k in mapped if "realm" in k.lower()]
print(f"  nested claim resolved: {'YES — ' + nested[0] if nested else 'no'}")

spoof = load(os.environ["SPOOF_FILE"])
print()
print("  Spoofing check (forged X-JWT-* headers, no token):")
if spoof is None:
    print("    could not evaluate")
else:
    leaked = [k for k in spoof if k.lower().startswith("x-jwt-")]
    if leaked:
        print(f"    !! forged headers REACHED upstream: {leaked}")
    else:
        print("    forged headers stripped — upstream saw none")
print()
PY

echo "  data plane started at : $(docker inspect --format '{{.State.StartedAt}}' "$GW" 2>/dev/null)"
echo "  data plane pid        : $(docker inspect --format '{{.State.Pid}}' "$GW" 2>/dev/null)"
echo "  (unchanged across steps = the plugin was updated without a restart)"
echo
