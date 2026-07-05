#!/bin/bash
# Build and install Claude Status Light on macOS.
#
#   ./scripts/install.sh
#
# Steps: build the app, install the binary + hook into ~/.claude/status-light,
# merge the hooks into ~/.claude/settings.json (with backup), and register a
# LaunchAgent so the light starts at login (and right now).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="$HOME/.claude/status-light"
BINARY_DEST="$INSTALL_DIR/ClaudeStatusLight"
HOOK_DEST="$INSTALL_DIR/status-hook.sh"
PLIST_LABEL="com.claude.statuslight"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

echo "==> Checking prerequisites"
if [[ "$(uname)" != "Darwin" ]]; then
    echo "This installer is for macOS only." >&2
    exit 1
fi
command -v swift >/dev/null || { echo "Swift not found. Install Xcode or the Command Line Tools (xcode-select --install)." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found. Install the Xcode Command Line Tools (xcode-select --install)." >&2; exit 1; }

echo "==> Building (release)"
cd "$REPO_ROOT"
swift build -c release
BUILT_BINARY="$(swift build -c release --show-bin-path)/ClaudeStatusLight"

echo "==> Installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/sessions"
install -m 0755 "$BUILT_BINARY" "$BINARY_DEST"
install -m 0755 "$REPO_ROOT/hooks/status-hook.sh" "$HOOK_DEST"

echo "==> Wiring hooks into ~/.claude/settings.json"
python3 "$REPO_ROOT/scripts/merge_settings.py" add "$HOOK_DEST"

echo "==> Registering LaunchAgent"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_DEST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BINARY_DEST</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST

# Reload cleanly whether or not it was already running.
launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl load "$PLIST_DEST"

echo ""
echo "Done. A colored dot should appear in your menu bar."
echo "  🟢 idle   🔵 working   🟡 needs attention   ⚪️ no session"
echo ""
echo "Open a new Claude Code session (or restart an open one) so the new"
echo "hooks take effect. Uninstall any time with ./scripts/uninstall.sh"
