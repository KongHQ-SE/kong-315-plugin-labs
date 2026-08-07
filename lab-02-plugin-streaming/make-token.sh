#!/usr/bin/env bash
# Prints a test JWT for the lab.
#
# The signature is deliberately fake. This lab's plugin only DECODES claims —
# it does not verify anything. In production you pair it with the jwt or
# openid-connect plugin, which validates the signature first. See SOLUTION.md.
set -euo pipefail

python3 <<'PY'
import base64, json

def b64u(d):
    return base64.urlsafe_b64encode(
        json.dumps(d, separators=(",", ":")).encode()
    ).decode().rstrip("=")

header = {"alg": "HS256", "typ": "JWT"}
payload = {
    "sub": "user-42",
    "email": "jane@acme.com",
    "tenant_id": "acme-corp",
    "roles": ["admin", "billing"],
    "realm_access": {"roles": ["platform-admin", "auditor"]},
    "iss": "https://id.acme.com",
    "exp": 4102444800,
}
print(f"{b64u(header)}.{b64u(payload)}.ZmFrZS1zaWduYXR1cmU")
PY
