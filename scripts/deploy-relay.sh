#!/bin/bash
# Deploy the status relay Worker to the user's Cloudflare account and write
# ~/.claude/status-light/relay.json for the app / publisher / other scripts.
# Idempotent: re-deploys keep the existing token unless --rotate-token.
#
# Requires: npm, a Cloudflare account (wrangler will open a login browser
# window on first use).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$HOME/.claude/status-light/relay.json"

command -v npm >/dev/null || { echo "npm is required (install Node.js)" >&2; exit 1; }

cd "$HERE/relay"
npm install --no-fund --no-audit

# Keep an existing token across re-deploys so remote machines stay valid.
TOKEN=""
if [ -f "$CONFIG" ] && [ "${1:-}" != "--rotate-token" ]; then
    TOKEN="$(python3 -c "import json;print(json.load(open('$CONFIG')).get('token',''))" 2>/dev/null || true)"
fi
[ -n "$TOKEN" ] || TOKEN="$(openssl rand -hex 32)"

DEPLOY_OUT="$(npx wrangler deploy 2>&1 | tee /dev/stderr)"
URL="$(printf '%s' "$DEPLOY_OUT" | grep -Eo 'https://[A-Za-z0-9.-]+\.workers\.dev' | head -1)"
[ -n "$URL" ] || { echo "could not find the deployed URL in wrangler output" >&2; exit 1; }

printf '%s' "$TOKEN" | npx wrangler secret put RELAY_TOKEN

mkdir -p "$(dirname "$CONFIG")"
python3 - "$CONFIG" "$URL" "$TOKEN" <<'PY'
import json, socket, sys
path, url, token = sys.argv[1:4]
json.dump({"url": url, "token": token, "host": socket.gethostname().split(".")[0]},
          open(path, "w"), indent=2)
PY
chmod 600 "$CONFIG"

echo
echo "Relay deployed: $URL"
echo "Config written: $CONFIG (chmod 600)"
echo "Restart Claude Status Light to pick up remote sessions."
echo "For other Macs: copy $CONFIG over (edit \"host\"), then run scripts/install-publisher.sh there."
echo "For cloud sessions: scripts/enable-cloud-hooks.sh <repo>, then set STATUS_LIGHT_RELAY_URL/_TOKEN"
echo "  env vars and allowlist ${URL#https://} in your Claude Code cloud environment."
