#!/bin/bash
# Smoke-test install-publisher.sh --pair against a stub relay: the success
# path must write relay.json (local short hostname, mode 600) before the
# build step, and the 404 path must exit with guidance. A fake `swift` on
# PATH halts the script right after the config is written, so this never
# builds anything or touches launchd.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export HOME="$(mktemp -d)"
CODE="abababababababababababababababab"
CONFIG="$HOME/.claude/status-light/relay.json"

cat > "$HOME/stub.py" <<'PY'
import http.server, json, sys

CODE = sys.argv[1]
used = False

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global used
        if self.path == f"/pair/{CODE}" and not used:
            used = True
            body = json.dumps({"url": "https://relay.example", "token": "tok123"}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def log_message(self, *args):
        pass

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY
python3 "$HOME/stub.py" "$CODE" > "$HOME/port.txt" &
STUB_PID=$!
trap 'kill "$STUB_PID" 2>/dev/null || true' EXIT
for _ in $(seq 50); do [ -s "$HOME/port.txt" ] && break; sleep 0.1; done
BASE="http://127.0.0.1:$(cat "$HOME/port.txt")"

mkdir -p "$HOME/fakebin"
printf '#!/bin/sh\nexit 7\n' > "$HOME/fakebin/swift"
chmod +x "$HOME/fakebin/swift"
export PATH="$HOME/fakebin:$PATH"

echo "--- success path writes relay.json, then stops at the fake build"
set +e
bash "$HERE/scripts/install-publisher.sh" --pair "$BASE" "$CODE"
STATUS=$?
set -e
[ "$STATUS" -eq 7 ] || { echo "FAIL: expected exit 7 from fake swift, got $STATUS"; exit 1; }
[ -f "$CONFIG" ] || { echo "FAIL: relay.json not written"; exit 1; }
python3 - "$CONFIG" <<'PY'
import json, os, socket, sys
path = sys.argv[1]
config = json.load(open(path))
assert config["url"] == "https://relay.example", config
assert config["token"] == "tok123", config
assert config["host"] == socket.gethostname().split(".")[0], config
mode = os.stat(path).st_mode & 0o777
assert mode == 0o600, oct(mode)
print("relay.json checks passed")
PY

echo "--- second redemption of the same code fails with guidance"
rm "$CONFIG"
set +e
OUT="$(bash "$HERE/scripts/install-publisher.sh" --pair "$BASE" "$CODE" 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 1 ] || { echo "FAIL: expected exit 1 on 404, got $STATUS"; exit 1; }
echo "$OUT" | grep -q "expired or already used" || { echo "FAIL: missing guidance in: $OUT"; exit 1; }
[ ! -f "$CONFIG" ] || { echo "FAIL: relay.json written despite 404"; exit 1; }

echo "--- --pair with a missing code errors out"
set +e
bash "$HERE/scripts/install-publisher.sh" --pair "$BASE" >/dev/null 2>&1
STATUS=$?
set -e
[ "$STATUS" -eq 1 ] || { echo "FAIL: expected exit 1 for missing code, got $STATUS"; exit 1; }

echo "pair_test.sh: all checks passed"
