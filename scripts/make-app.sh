#!/bin/bash
#
# Build ClaudeStatusLight and assemble it into a proper .app bundle.
#
# Output: ./build/ClaudeStatusLight.app
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ClaudeStatusLight"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "→ Building release binary…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
if [ ! -f "$BIN_PATH" ]; then
    echo "✗ Build did not produce $BIN_PATH" >&2
    exit 1
fi

echo "→ Assembling $APP_BUNDLE…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Claude Status Light</string>
    <key>CFBundleIdentifier</key>
    <string>com.claude.statuslight</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <!-- Menu-bar only: no Dock icon, no app-switcher entry. -->
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "✓ Built $APP_BUNDLE"
echo ""
echo "  Run it now with:   open \"$APP_BUNDLE\""
echo "  Install it with:   cp -R \"$APP_BUNDLE\" /Applications/"
