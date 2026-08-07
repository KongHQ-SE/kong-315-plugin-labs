#!/usr/bin/env bash
# Brings up the full lab environment:
#   1. a Konnect control plane named kong-315-labs
#   2. a Kong Gateway 3.15 data plane in Docker, with plugin streaming enabled
#   3. a local httpbin upstream (no internet dependency at request time)
#   4. a `mock` service + route
#
# Safe to re-run. It recreates the local containers each time.
set -euo pipefail

CP_NAME="${CP_NAME:-kong-315-labs}"
APP_NAME="kong-quickstart"
GW_NAME="${APP_NAME}-gateway"
NET_NAME="${APP_NAME}-net"
HTTPBIN_NAME="lab-httpbin"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

info()  { printf '\033[34m•\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m✔\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m!\033[0m %s\n' "$*"; }
die()   { printf '\033[31m✘\033[0m %s\n' "$*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------
: "${KONNECT_TOKEN:?KONNECT_TOKEN is not set. Run: export KONNECT_TOKEN='kpat_...'}"
[[ "$KONNECT_TOKEN" == kpat_* ]] || warn "KONNECT_TOKEN does not start with 'kpat_' — is that a Konnect PAT?"
docker info >/dev/null 2>&1 || die "Docker is not running."

info "Validating Konnect token..."
code=$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $KONNECT_TOKEN" \
  "https://us.api.konghq.com/v2/control-planes?page%5Bsize%5D=1" --max-time 25 || true)
case "$code" in
  200) ok "Token accepted (region: us)." ;;
  401|403) die "Konnect rejected the token (HTTP $code). Generate a new PAT." ;;
  *) die "Could not reach Konnect (HTTP ${code:-none}). Check your network." ;;
esac

# --- port conflicts ----------------------------------------------------------
# Kong wants 8000/8443. SSH tunnels and other dev servers commonly hold these.
# Rather than fail, hand Docker the job of picking free ports; bin/proxy-url
# resolves whatever it chose.
PORT_FLAG=()
for p in 8000 8443; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    warn "Port $p is already in use — Docker will assign free ports instead."
    PORT_FLAG=(-P)
    break
  fi
done

# --- gateway -----------------------------------------------------------------
info "Starting Kong Gateway 3.15 data plane + control plane '$CP_NAME'..."
QS="$(mktemp)"
curl -Ls https://get.konghq.com/quickstart -o "$QS" || die "Could not download the Kong quickstart script."

# The quickstart's own post-start validation probes default ports and can report
# failure even when the gateway is healthy, so we verify independently below.
set +e
bash "$QS" -k "$KONNECT_TOKEN" -n "$CP_NAME" "${PORT_FLAG[@]}" \
  -e KONG_CUSTOM_PLUGIN_STREAMING_ENABLED=on >/tmp/kong-lab-start.log 2>&1
set -e
rm -f "$QS"

docker inspect "$GW_NAME" >/dev/null 2>&1 \
  || { tail -20 /tmp/kong-lab-start.log; die "Gateway container was not created. Log above."; }

info "Waiting for the gateway to become healthy..."
for _ in $(seq 1 60); do
  [[ "$(docker inspect --format '{{.State.Health.Status}}' "$GW_NAME" 2>/dev/null)" == "healthy" ]] && break
  sleep 2
done
ok "Data plane running: $(docker inspect --format '{{.Config.Image}}' "$GW_NAME")"

# --- upstream ----------------------------------------------------------------
# A local httpbin, deliberately. The quickstart's -m flag points at
# httpbin.org, which makes every lab request depend on conference wifi and a
# shared public service. Keep the upstream in-cluster.
#
# go-httpbin rather than kennethreitz/httpbin: it ships arm64, so it runs
# natively on Apple Silicon instead of under emulation. Note it listens on
# 8080, and it returns header values as JSON arrays rather than strings —
# the verify scripts normalise both shapes.
info "Starting local httpbin upstream..."
docker rm -f "$HTTPBIN_NAME" >/dev/null 2>&1 || true
docker run -d --name "$HTTPBIN_NAME" --network "$NET_NAME" \
  mccutchen/go-httpbin:v2.15.0 >/dev/null
ok "Upstream '$HTTPBIN_NAME' running on network '$NET_NAME'."

# --- config ------------------------------------------------------------------
info "Applying mock service and route..."
CP_NAME="$CP_NAME" "$REPO_ROOT/bin/deck" gateway sync setup/kong.yaml >/dev/null
ok "Service and route applied."

# --- verify ------------------------------------------------------------------
PROXY="$("$REPO_ROOT/bin/proxy-url")"
info "Verifying end to end (config propagation takes ~10-16s)..."
for _ in $(seq 1 45); do
  if [[ "$(curl -sS -o /dev/null -w '%{http_code}' "$PROXY/mock" --max-time 10 2>/dev/null)" == "200" ]]; then
    ok "Proxy is serving /mock."
    echo
    echo "  Proxy URL:  $PROXY"
    echo "  Try it:     curl -s \$(./bin/proxy-url)/mock | python3 -m json.tool"
    echo
    echo "  Next:       lab-01-plugin-cloning/README.md"
    exit 0
  fi
  sleep 2
done

die "Gateway is up but /mock is not serving. See FACILITATOR.md -> Troubleshooting."
