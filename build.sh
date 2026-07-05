#!/usr/bin/env bash
#
# build.sh — compile the menu-bar app into a .app bundle under ./build.
#
# Requires the Xcode command line tools (`xcode-select --install`).
# Produces build/ClaudeStatusLight.app which you can launch or drag to
# /Applications. Re-run any time you change Sources/main.swift.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ClaudeStatusLight"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP_BUNDLE}/Contents/MacOS"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found. Install the Xcode command line tools:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

echo "Compiling ${APP_NAME}…"
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"

swiftc -O -o "${MACOS_DIR}/${APP_NAME}" Sources/main.swift -framework Cocoa

cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Claude Status Light</string>
    <key>CFBundleIdentifier</key>
    <string>com.claude.statuslight</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "Built ${APP_BUNDLE}"
echo
echo "Launch it with:"
echo "  open \"${APP_BUNDLE}\""
echo
echo "To start it automatically at login, add it under"
echo "System Settings → General → Login Items."
