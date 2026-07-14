#!/bin/bash
# Set up this Mac to publish its Claude Code sessions to the relay: builds
# the binary, installs it under ~/.claude/status-light/bin, and registers a
# launchd agent that keeps `--publish` running. Run on the REMOTE Mac (the
# office mini, etc.) — the Mac showing the light doesn't publish.
#
# Config comes from one of (checked in this order):
#   --pair <url> <code>          fetch it with a code from Settings →
#                                "Pair another machine…" on the main Mac
#   --url <u> --token <t> [--host <label>]
#   an existing ~/.claude/status-light/relay.json (copied by hand)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$HOME/.claude/status-light/relay.json"
BIN_DIR="$HOME/.claude/status-light/bin"
LABEL="com.claude-status-light.publisher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

URL="" TOKEN="" HOST="" PAIR_URL="" PAIR_CODE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --url)   URL="$2"; shift 2 ;;
        --token) TOKEN="$2"; shift 2 ;;
        --host)  HOST="$2"; shift 2 ;;
        --pair)
            [ $# -ge 3 ] || { echo "--pair needs <url> <code>" >&2; exit 1; }
            PAIR_URL="$2"; PAIR_CODE="$3"; shift 3 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ -n "$PAIR_URL" ] && [ -n "$PAIR_CODE" ]; then
    echo "Fetching relay config…"
    BODY="$(curl -fsS "${PAIR_URL%/}/pair/$PAIR_CODE")" || {
        echo "code expired or already used — generate a new one from Settings on your main Mac." >&2
        exit 1
    }
    mkdir -p "$(dirname "$CONFIG")"
    python3 - "$CONFIG" "$BODY" <<'PY'
import json, socket, sys
path, body = sys.argv[1:3]
config = json.loads(body)
json.dump({"url": config["url"], "token": config["token"],
           "host": socket.gethostname().split(".")[0]},
          open(path, "w"), indent=2)
PY
    chmod 600 "$CONFIG"
elif [ -n "$URL" ] && [ -n "$TOKEN" ]; then
    mkdir -p "$(dirname "$CONFIG")"
    python3 - "$CONFIG" "$URL" "$TOKEN" "$HOST" <<'PY'
import json, socket, sys
path, url, token, host = sys.argv[1:5]
json.dump({"url": url, "token": token,
           "host": host or socket.gethostname().split(".")[0]},
          open(path, "w"), indent=2)
PY
    chmod 600 "$CONFIG"
fi
[ -f "$CONFIG" ] || { echo "no $CONFIG — copy it from your main Mac or pass --url/--token" >&2; exit 1; }

echo "Building…"
cd "$HERE"
swift build -c release
mkdir -p "$BIN_DIR"
cp "$(swift build -c release --show-bin-path)/ClaudeStatusLight" "$BIN_DIR/claude-status-light"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_DIR/claude-status-light</string>
        <string>--publish</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardErrorPath</key><string>/tmp/claude-status-light-publisher.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Publisher installed and running (host: $(python3 -c "import json;print(json.load(open('$CONFIG'))['host'])"))."
echo "Logs: /tmp/claude-status-light-publisher.log"
