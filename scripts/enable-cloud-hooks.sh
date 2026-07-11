#!/bin/bash
# Stamp the cloud relay hook into a repo so its cloud sessions report to
# the status light: copies hooks/status-relay.sh to <repo>/.claude/ and
# merges hook entries for every lifecycle event into the repo's committed
# .claude/settings.json. Idempotent — safe to re-run.
#
# Usage: scripts/enable-cloud-hooks.sh /path/to/repo
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${1:?usage: enable-cloud-hooks.sh /path/to/repo}"
[ -d "$REPO" ] || { echo "no such directory: $REPO" >&2; exit 1; }

mkdir -p "$REPO/.claude"
cp "$HERE/hooks/status-relay.sh" "$REPO/.claude/status-relay.sh"
chmod +x "$REPO/.claude/status-relay.sh"

python3 - "$REPO/.claude/settings.json" <<'PY'
import json, os, sys

path = sys.argv[1]
settings = {}
if os.path.exists(path):
    with open(path) as f:
        settings = json.load(f)

COMMAND = '"$CLAUDE_PROJECT_DIR"/.claude/status-relay.sh'
EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
          "Notification", "Stop", "SessionEnd", "SubagentStart", "SubagentStop"]

hooks = settings.setdefault("hooks", {})
for event in EVENTS:
    entries = hooks.setdefault(event, [])
    already = any(
        h.get("command") == COMMAND
        for entry in entries for h in entry.get("hooks", [])
    )
    if not already:
        entries.append({"hooks": [{"type": "command", "command": COMMAND}]})

with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print(f"cloud relay hooks enabled in {path}")
PY

echo "Remember (once per Claude Code cloud environment):"
echo "  1. set env vars STATUS_LIGHT_RELAY_URL and STATUS_LIGHT_RELAY_TOKEN"
echo "  2. add your Worker's domain to the environment's network allowlist"
echo "Then commit $REPO/.claude/ so cloud sandboxes pick it up."
