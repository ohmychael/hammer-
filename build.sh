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

# Build for the macOS this Mac runs (what swiftc picks by default; said outright,
# and checked below, so an app this Mac can't open is never swapped in).
OS_VERSION="$(sw_vers -productVersion)"
TARGET="$(uname -m)-apple-macosx${OS_VERSION%%.*}.0"

# Is version $1 at most $2? (e.g. 26.0 and 26.6.1)
version_at_most() {
  local IFS=.
  local a=($1) b=($2) i
  for i in 0 1 2; do
    if [ "${a[$i]:-0}" -lt "${b[$i]:-0}" ]; then return 0; fi
    if [ "${a[$i]:-0}" -gt "${b[$i]:-0}" ]; then return 1; fi
  done
  return 0
}

# 1. Run the tests, then compile. Any failure stops here, before anything is replaced.
echo "Running tests..."
swiftc -O -target "$TARGET" "$REPO/HammerCore.swift" "$REPO/Monitor.swift" "$REPO/Player.swift" \
  "$REPO/Deliveries.swift" "$REPO/Tests/main.swift" -o "$BUILD/hammer-tests"
"$BUILD/hammer-tests"
swiftc -parse-as-library -O -target "$TARGET" "$REPO/Hammer.swift" "$REPO/HammerCore.swift" "$REPO/Monitor.swift" \
  "$REPO/MonitorMac.swift" "$REPO/Player.swift" "$REPO/PlayerMac.swift" "$REPO/EdgeMac.swift" \
  "$REPO/Deliveries.swift" "$REPO/DeliveryAlerts.swift" -o "$BUILD/Hammer"

# Never swap in an app this Mac can't open: check which macOS it was built for.
BUILT_FOR="$(vtool -show-build "$BUILD/Hammer" 2>/dev/null | awk '$1 == "minos" { print $2; exit }' || true)"
if [ -n "$BUILT_FOR" ] && ! version_at_most "$BUILT_FOR" "$OS_VERSION"; then
  echo "This build needs macOS $BUILT_FOR, but this Mac has $OS_VERSION, so the Hammer you have stays."
  exit 1
fi

# 2. Assemble the app next to the build, then swap it in.
STAGE="$BUILD/Hammer.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BUILD/Hammer" "$STAGE/Contents/MacOS/Hammer"
echo "$VERSION" > "$STAGE/Contents/Resources/VERSION"
cp "$REPO/PlayerScript.js" "$STAGE/Contents/Resources/PlayerScript.js"   # runs inside the YouTube player's page
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
  <key>NSAppleEventsUsageDescription</key><string>Hammer opens YouTube in your Microsoft Edge and keeps its window in the top-right corner. It never reads your tabs, cookies, passwords or history.</string>
</dict>
</plist>
PLIST
# Sign with the same local certificate every time, so macOS keeps Hammer's
# permissions (Bluetooth etc.) across updates; falls back to ad hoc (signing.sh).
source "$REPO/signing.sh"
sign_app "$STAGE"

if [ -d "$APP" ]; then
  existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$existing_id" != "$BUNDLE_ID" ]; then
    echo "There's a different app at $APP. Move or rename it, then try again."
    exit 1
  fi
fi

# The current Hammer is kept aside until the new one has opened; if macOS won't
# open the new one, the current one goes back, so you're never left without it.
PREVIOUS="$BUILD/Hammer-previous.app"
pkill -x Hammer 2>/dev/null || true
sleep 1
rm -rf "$PREVIOUS"
if [ -d "$APP" ]; then mv "$APP" "$PREVIOUS"; fi
mkdir -p "$(dirname "$APP")"
mv "$STAGE" "$APP"
if ! open "$APP"; then
  echo "macOS wouldn't open Hammer $VERSION (the error is just above)."
  if [ -d "$PREVIOUS" ]; then
    rm -rf "$APP"
    mv "$PREVIOUS" "$APP"
    open "$APP" || true
    echo "The Hammer you had is back."
  fi
  exit 3
fi
rm -rf "$PREVIOUS"
cp "$BUILD/Hammer" "$HOME_DIR/Hammer"          # for Terminal commands: ~/Hammer/Hammer

echo "Hammer $VERSION installed (built for macOS ${BUILT_FOR:-?} on $OS_VERSION)."
