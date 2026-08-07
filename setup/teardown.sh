#!/usr/bin/env bash
# Removes the local lab containers and deletes the lab control plane from Konnect.
# Only touches resources this lab created.
set -uo pipefail

CP_NAME="${CP_NAME:-kong-315-labs}"

: "${KONNECT_TOKEN:?KONNECT_TOKEN is not set. Run: export KONNECT_TOKEN='kpat_...'}"

echo "This will delete:"
echo "  - local containers: kong-quickstart-gateway, kong-quickstart-database, lab-httpbin"
echo "  - Konnect control plane: $CP_NAME"
echo
read -r -p "Proceed? [y/N] " reply
[[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

docker rm -f lab-httpbin >/dev/null 2>&1 && echo "removed lab-httpbin"

QS="$(mktemp)"
if curl -Ls https://get.konghq.com/quickstart -o "$QS"; then
  bash "$QS" -k "$KONNECT_TOKEN" -n "$CP_NAME" -d >/dev/null 2>&1 \
    && echo "removed gateway containers and control plane '$CP_NAME'"
fi
rm -f "$QS"

docker network rm kong-quickstart-net >/dev/null 2>&1 || true

echo "Done."
