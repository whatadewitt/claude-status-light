#!/bin/bash
# Remove Claude Status Light from macOS.
#
#   ./scripts/uninstall.sh
#
# Stops and unregisters the LaunchAgent, removes the status-light hooks from
# ~/.claude/settings.json, and deletes the installed files.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="$HOME/.claude/status-light"
HOOK_DEST="$INSTALL_DIR/status-hook.sh"
PLIST_LABEL="com.claude.statuslight"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

echo "==> Stopping LaunchAgent"
launchctl unload "$PLIST_DEST" 2>/dev/null || true
rm -f "$PLIST_DEST"

echo "==> Removing hooks from ~/.claude/settings.json"
if command -v python3 >/dev/null; then
    python3 "$REPO_ROOT/scripts/merge_settings.py" remove "$HOOK_DEST" || true
else
    echo "python3 not found; edit ~/.claude/settings.json by hand to remove entries referencing $HOOK_DEST" >&2
fi

echo "==> Removing installed files"
rm -rf "$INSTALL_DIR"

echo "Done. The menu bar light has been removed."
