#!/bin/bash
#
# build-app.sh — compile ClaudeStatusLight and wrap it in a .app bundle.
#
# Run this on a Mac with the Xcode Command Line Tools installed
# (`xcode-select --install`). Produces ./build/ClaudeStatusLight.app.
#
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_src="$repo_root/app"
build_dir="$repo_root/build"
app_bundle="$build_dir/ClaudeStatusLight.app"

if ! command -v swift >/dev/null 2>&1; then
  echo "error: 'swift' not found. Install the Xcode Command Line Tools:" >&2
  echo "         xcode-select --install" >&2
  exit 1
fi

echo "==> Building release binary…"
(cd "$app_src" && swift build -c release)

bin_path="$(cd "$app_src" && swift build -c release --show-bin-path)/ClaudeStatusLight"
if [ ! -x "$bin_path" ]; then
  echo "error: expected binary not found at $bin_path" >&2
  exit 1
fi

echo "==> Assembling $app_bundle…"
rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS"
mkdir -p "$app_bundle/Contents/Resources"
cp "$bin_path" "$app_bundle/Contents/MacOS/ClaudeStatusLight"

cat > "$app_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ClaudeStatusLight</string>
    <key>CFBundleDisplayName</key>
    <string>Claude Status Light</string>
    <key>CFBundleIdentifier</key>
    <string>com.claude.statuslight</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeStatusLight</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <!-- Menu bar only: no Dock icon, no window. -->
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so Gatekeeper lets it run locally without a paid developer ID.
if command -v codesign >/dev/null 2>&1; then
  echo "==> Ad-hoc code signing…"
  codesign --force --deep --sign - "$app_bundle" >/dev/null 2>&1 || \
    echo "   (ad-hoc signing skipped; app will still run)"
fi

echo ""
echo "Done: $app_bundle"
echo ""
echo "Launch it now:      open \"$app_bundle\""
echo "Install to /Applications:  cp -R \"$app_bundle\" /Applications/"
echo "Add to Login Items: System Settings > General > Login Items > +"
