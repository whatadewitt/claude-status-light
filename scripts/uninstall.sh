#!/bin/bash
# Remove Claude Status Light from macOS.
#
#   ./scripts/uninstall.sh
#
# Quits the app, removes the login item, strips the hooks from
# ~/.claude/settings.json, and deletes the app bundle and installed files.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Claude Status Light"
APP_DIR="$HOME/Applications/$APP_NAME.app"
INSTALL_DIR="$HOME/.claude/status-light"
HOOK_DEST="$INSTALL_DIR/status-hook.sh"
OLD_PLIST="$HOME/Library/LaunchAgents/com.claude.statuslight.plist"

echo "==> Quitting the app"
pkill -f "$APP_DIR/Contents/MacOS/ClaudeStatusLight" 2>/dev/null || true

echo "==> Removing login item"
osascript >/dev/null 2>&1 <<OSA || true
tell application "System Events"
    try
        delete (every login item whose name is "$APP_NAME")
    end try
end tell
OSA

echo "==> Removing any old LaunchAgent"
if [[ -f "$OLD_PLIST" ]]; then
    launchctl unload "$OLD_PLIST" 2>/dev/null || true
    rm -f "$OLD_PLIST"
fi

echo "==> Removing hooks from ~/.claude/settings.json"
if command -v python3 >/dev/null; then
    python3 "$REPO_ROOT/scripts/merge_settings.py" remove "$HOOK_DEST" || true
else
    echo "python3 not found; edit ~/.claude/settings.json by hand to remove entries referencing $HOOK_DEST" >&2
fi

echo "==> Removing installed files"
rm -rf "$APP_DIR" "$INSTALL_DIR"

echo "Done. Claude Status Light has been removed."
