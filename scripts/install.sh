#!/bin/bash
# Build and install Claude Status Light on macOS.
#
#   ./scripts/install.sh
#
# Steps: build the app, assemble a proper .app bundle in ~/Applications (with a
# generated icon), install the hook + merge it into ~/.claude/settings.json,
# register a login item so it starts at login, and launch it now.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Claude Status Light"
APP_DIR="$HOME/Applications/$APP_NAME.app"
INSTALL_DIR="$HOME/.claude/status-light"
HOOK_DEST="$INSTALL_DIR/status-hook.sh"
OLD_PLIST="$HOME/Library/LaunchAgents/com.claude.statuslight.plist"

echo "==> Checking prerequisites"
if [[ "$(uname)" != "Darwin" ]]; then
    echo "This installer is for macOS only." >&2
    exit 1
fi
command -v swift >/dev/null || { echo "Swift not found. Install Xcode or the Command Line Tools (xcode-select --install)." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found. Install the Xcode Command Line Tools (xcode-select --install)." >&2; exit 1; }

echo "==> Building (release)"
cd "$REPO_ROOT"
if ! swift build -c release; then
    cat >&2 <<'EOF'

──────────────────────────────────────────────────────────────────────
Build failed.

If the errors above mention "redefinition of module 'SwiftBridging'" or
"this SDK is not supported by the compiler", your Swift compiler and SDK
are mismatched. This is a macOS toolchain issue, not a problem with this
project. Fix it, then re-run ./scripts/install.sh:

  • If Xcode is installed, point the tools at it:
      sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
      sudo xcodebuild -license accept

  • If you only use the Command Line Tools, reinstall them:
      sudo rm -rf /Library/Developer/CommandLineTools
      sudo xcode-select --install

Check what you're using with:   xcode-select -p && swift --version
──────────────────────────────────────────────────────────────────────
EOF
    exit 1
fi
BUILT_BINARY="$(swift build -c release --show-bin-path)/ClaudeStatusLight"

echo "==> Migrating any previous install"
if [[ -f "$OLD_PLIST" ]]; then
    launchctl unload "$OLD_PLIST" 2>/dev/null || true
    rm -f "$OLD_PLIST"
    echo "    removed old LaunchAgent"
fi

echo "==> Stopping any running instance"
pkill -x ClaudeStatusLight 2>/dev/null || true

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
install -m 0755 "$BUILT_BINARY" "$APP_DIR/Contents/MacOS/ClaudeStatusLight"

# Generate the app icon with the app's own renderer, then pack it with iconutil.
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$APP_DIR/Contents/MacOS/ClaudeStatusLight" --render-iconset "$ICONSET" 2>/dev/null || true
if command -v iconutil >/dev/null && [[ -d "$ICONSET" ]]; then
    iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns" 2>/dev/null || true
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>com.claude.statuslight</string>
    <key>CFBundleExecutable</key><string>ClaudeStatusLight</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> Installing hook and wiring ~/.claude/settings.json"
mkdir -p "$INSTALL_DIR/sessions"
install -m 0755 "$REPO_ROOT/hooks/status-hook.sh" "$HOOK_DEST"
python3 "$REPO_ROOT/scripts/merge_settings.py" add "$HOOK_DEST"

echo "==> Registering login item"
# (First run may prompt to allow controlling System Events — that's expected.)
osascript >/dev/null 2>&1 <<OSA || echo "    could not add login item automatically; add \"$APP_NAME\" under System Settings ▸ General ▸ Login Items."
tell application "System Events"
    try
        delete (every login item whose name is "$APP_NAME")
    end try
    make login item at end with properties {path:"$APP_DIR", hidden:false}
end tell
OSA

echo "==> Launching"
open "$APP_DIR"

echo ""
echo "Done. A colored pixel mascot should appear in your menu bar."
echo "  🟢 awaiting task   🟡 running   🔴 waiting for input   ⚪️ not running"
echo ""
echo "Open Settings from the menu to enable the floating window or dock icon."
echo "Open a new Claude Code session (or restart an open one) so the hooks take effect."
echo "Uninstall any time with ./scripts/uninstall.sh"
