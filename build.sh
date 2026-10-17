#!/bin/bash
# build.sh — compiles Hammer from this folder and installs ~/Applications/Hammer.app.
# Used by both install-hammer.sh and update.sh. If the build fails, the Hammer
# you already have keeps running untouched.

set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$HOME/Hammer"
BUILD="$HOME_DIR/build"
APP="$HOME/Applications/Hammer.app"
BUNDLE_ID="local.hammer"
VERSION="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo dev)"

mkdir -p "$BUILD"

# 1. Run the tests, then compile. Any failure stops here, before anything is replaced.
echo "Running tests..."
swiftc -O "$REPO/HammerCore.swift" "$REPO/Tests/main.swift" -o "$BUILD/hammer-tests"
"$BUILD/hammer-tests"
swiftc -parse-as-library -O "$REPO/Hammer.swift" "$REPO/HammerCore.swift" -o "$BUILD/Hammer"

# 2. Assemble the app next to the build, then swap it in.
STAGE="$BUILD/Hammer.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BUILD/Hammer" "$STAGE/Contents/MacOS/Hammer"
echo "$VERSION" > "$STAGE/Contents/Resources/VERSION"
cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Hammer</string>
  <key>CFBundleDisplayName</key><string>Hammer</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Hammer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Hammer looks for your Govee lights on your Wi-Fi network.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Hammer controls your Govee bulbs over Bluetooth.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$STAGE" >/dev/null 2>&1 || true   # local signature so macOS will run it

if [ -d "$APP" ]; then
  existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$existing_id" != "$BUNDLE_ID" ]; then
    echo "There's a different app at $APP. Move or rename it, then try again."
    exit 1
  fi
fi

pkill -x Hammer 2>/dev/null || true
sleep 1
rm -rf "$APP"
mkdir -p "$(dirname "$APP")"
mv "$STAGE" "$APP"
cp "$BUILD/Hammer" "$HOME_DIR/Hammer"          # for Terminal commands: ~/Hammer/Hammer
open "$APP"

echo "Hammer $VERSION installed."
