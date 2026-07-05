#!/bin/bash
#
# One-shot installer:
#   1. builds the .app bundle
#   2. copies it to /Applications
#   3. installs the hook script into ~/.claude/
#   4. merges the status-light hooks into ~/.claude/settings.json
#   5. launches the app
#
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_DIR="$(pwd)"

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOK_SRC="$REPO_DIR/hooks/claude-status-light-hook.sh"
HOOK_DST="$CLAUDE_DIR/claude-status-light-hook.sh"
SNIPPET="$REPO_DIR/hooks/settings-snippet.json"

echo "==> 1/5  Building the app"
bash scripts/make-app.sh

echo ""
echo "==> 2/5  Installing to /Applications"
rm -rf "/Applications/ClaudeStatusLight.app"
cp -R "build/ClaudeStatusLight.app" "/Applications/"

echo ""
echo "==> 3/5  Installing hook script"
mkdir -p "$CLAUDE_DIR"
cp "$HOOK_SRC" "$HOOK_DST"
chmod +x "$HOOK_DST"
echo "    $HOOK_DST"

echo ""
echo "==> 4/5  Merging hooks into $SETTINGS"
if ! command -v python3 >/dev/null 2>&1; then
    echo "    ⚠ python3 not found — skipping automatic merge."
    echo "    Manually merge the contents of hooks/settings-snippet.json into $SETTINGS"
else
    python3 - "$SETTINGS" "$SNIPPET" <<'PY'
import json, os, sys

settings_path, snippet_path = sys.argv[1], sys.argv[2]

with open(snippet_path) as f:
    snippet = json.load(f)

if os.path.exists(settings_path):
    with open(settings_path) as f:
        try:
            settings = json.load(f)
        except json.JSONDecodeError:
            print(f"    ⚠ {settings_path} is not valid JSON — not touching it.")
            sys.exit(1)
else:
    settings = {}

hooks = settings.setdefault("hooks", {})

def already_installed(entries):
    for entry in entries:
        for h in entry.get("hooks", []):
            if "claude-status-light-hook.sh" in h.get("command", ""):
                return True
    return False

added = []
for event, entries in snippet["hooks"].items():
    bucket = hooks.setdefault(event, [])
    if already_installed(bucket):
        continue
    bucket.extend(entries)
    added.append(event)

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

if added:
    print("    Added status-light hooks for: " + ", ".join(added))
else:
    print("    Hooks already present — nothing to change.")
PY
fi

echo ""
echo "==> 5/5  Launching"
open "/Applications/ClaudeStatusLight.app"

echo ""
echo "✓ Done. Look for the grey dot in your menu bar."
echo "  Start a Claude Code session and it should turn blue while working,"
echo "  green when Claude is waiting on you, and grey when idle."
echo ""
echo "  To make it start automatically: System Settings → General →"
echo "  Login Items → add ClaudeStatusLight."
