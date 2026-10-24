#!/bin/bash
# build.sh — compiles Hammer from this folder and installs ~/Applications/Hammer.app.
# Used by both install-hammer.sh and update.sh. If the build fails, the Hammer
# you already have keeps running untouched.
#
# Exit codes: 0 installed; 1 this version doesn't build or pass its tests;
# 3 built, but it didn't open or start (the one you had is back); 4 a problem with
# this Mac, not the update (tools, disk space, another app in the way): what to do
# is in ~/Hammer/.retry-later, and it's tried again later.

set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$HOME/Hammer"
BUILD="$HOME_DIR/build"
APP="$HOME/Applications/Hammer.app"
STAGE="$BUILD/Hammer.app"
PREVIOUS="$BUILD/Hammer-previous.app"
SWAPPING="$BUILD/.swapping"            # while the app is being swapped (update.sh checks it)
LAUNCHED="$HOME_DIR/.launched"         # Hammer writes its version here once it has started
BUSY="$HOME_DIR/.busy"                 # Hammer: a dialog or YouTube is open (its PID, then why)
RETRY="$HOME_DIR/.retry-later"
BUNDLE_ID="local.hammer"
PLISTBUDDY="${HAMMER_PLISTBUDDY:-/usr/libexec/PlistBuddy}"   # tests swap in stand-ins
TESTS_LIMIT="${HAMMER_TESTS_LIMIT:-600}"                    # seconds
VERSION="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo dev)"
VERSION_DATE="$(git -C "$REPO" log -1 --date=short --format=%cd 2>/dev/null || true)"

mkdir -p "$BUILD"

# Runs a command, stopping it after $1 seconds (it then exits with 142).
limit() { perl -e 'alarm shift; exec @ARGV or die "$ARGV[0]: $!\n"' "$@"; }

free_kb() { df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 { print $4 }'; }
low_on_space() { local free; free="$(free_kb)"; [ -n "$free" ] && [ "$free" -lt 1048576 ]; }

# retry_later <message> <detail>: a problem with this Mac. Exits 4.
retry_later() {
  printf '%s\n%s\n%s\n' "$VERSION" "$1" "$2" > "$RETRY" 2>/dev/null || true
  echo "$2"
  exit 4
}
no_space() { retry_later "Can't update: your Mac is almost full" "Free up about 1 GB, and Hammer will update itself."; }

# Whatever way this script ends (an error, or stopped by a logout), a Hammer is in
# place and running, and the signing keychain is off your keychain list.
swapping=false
finish() {
  local result=$?
  set +e
  trap '' TERM HUP INT                 # finish putting things back, even if asked again
  declare -F signing_cleanup >/dev/null && signing_cleanup
  if $swapping; then
    swapping=false
    echo "The update stopped part-way, so the Hammer you had is going back."
    if [ -d "$PREVIOUS" ]; then
      pkill -x Hammer 2>/dev/null
      rm -rf "$APP" && mkdir -p "$(dirname "$APP")" && mv "$PREVIOUS" "$APP"
    fi
    [ -d "$APP" ] && ! pgrep -x Hammer >/dev/null 2>&1 && open "$APP" --args --login
    rm -f "$SWAPPING"
    if [ "$result" = 1 ]; then
      retry_later "Can't update: couldn't swap in the new version" \
        "Hammer couldn't replace itself (is your Mac almost full?). It will try again later."
    fi
  fi
  if [ "$result" = 1 ] && low_on_space; then no_space; fi
  exit "$result"
}
trap finish EXIT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 130' INT

# 0. Problems with the Mac, before anything is built.
if ! xcrun --find swiftc >/dev/null 2>&1; then
  retry_later "Can't update: developer tools missing" \
    "Apple's command-line tools need reinstalling. In Terminal, run: xcode-select --install"
fi
if low_on_space; then no_space; fi
if [ -d "$APP" ]; then
  existing_id="$("$PLISTBUDDY" -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$existing_id" != "$BUNDLE_ID" ]; then
    retry_later "Can't update: another app is in the way" \
      "There's a different app at ~/Applications/Hammer.app. Move or rename it, and Hammer will install."
  fi
fi

# Build for the macOS this Mac runs (what swiftc picks by default; said outright,
# and checked below, so an app this Mac can't open is never swapped in).
OS_VERSION="$(sw_vers -productVersion)"
TARGET="$(uname -m)-apple-macosx${OS_VERSION%%.*}.0"
SWIFT=(swiftc -swift-version 5 -O -target "$TARGET")

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
limit 1200 "${SWIFT[@]}" "$REPO/HammerCore.swift" "$REPO/Monitor.swift" "$REPO/Player.swift" \
  "$REPO/Deliveries.swift" "$REPO/Tests/main.swift" -o "$BUILD/hammer-tests" || exit 1
if limit "$TESTS_LIMIT" "$BUILD/hammer-tests"; then :; else
  result=$?
  [ "$result" = 142 ] && echo "The tests didn't finish within $((TESTS_LIMIT / 60)) minutes."
  exit 1
fi
limit 1200 "${SWIFT[@]}" -parse-as-library "$REPO/Hammer.swift" "$REPO/HammerCore.swift" "$REPO/Monitor.swift" \
  "$REPO/MonitorMac.swift" "$REPO/Player.swift" "$REPO/PlayerMac.swift" "$REPO/EdgeMac.swift" \
  "$REPO/Deliveries.swift" "$REPO/DeliveryAlerts.swift" "$REPO/UpdatesMac.swift" -o "$BUILD/Hammer" || exit 1

# Never swap in an app this Mac can't open: check which macOS it was built for.
BUILT_FOR="$(vtool -show-build "$BUILD/Hammer" 2>/dev/null | awk '$1 == "minos" { print $2; exit }' || true)"
if [ -n "$BUILT_FOR" ] && ! version_at_most "$BUILT_FOR" "$OS_VERSION"; then
  echo "This build needs macOS $BUILT_FOR, but this Mac has $OS_VERSION, so the Hammer you have stays."
  retry_later "Can't update: the tools build for a newer macOS" \
    "This Mac's command-line tools built Hammer for macOS $BUILT_FOR, but it has $OS_VERSION. Update them in System Settings → General → Software Update."
fi

# 2. Assemble the app next to the build.
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BUILD/Hammer" "$STAGE/Contents/MacOS/Hammer"
echo "$VERSION" > "$STAGE/Contents/Resources/VERSION"
echo "$VERSION_DATE" > "$STAGE/Contents/Resources/VERSION-DATE"
cp "$REPO/PlayerScript.js" "$STAGE/Contents/Resources/PlayerScript.js"   # runs inside the YouTube page

# The app icon, drawn by the new Hammer itself. Without it, Hammer just has no icon.
ICON_KEY=""
rm -rf "$BUILD/Hammer.iconset"
if limit 60 "$BUILD/Hammer" make-icon "$BUILD/Hammer.iconset" >/dev/null 2>&1 \
   && limit 60 iconutil -c icns "$BUILD/Hammer.iconset" -o "$STAGE/Contents/Resources/Hammer.icns" >/dev/null 2>&1 \
   && [ -s "$STAGE/Contents/Resources/Hammer.icns" ]; then
  ICON_KEY="<key>CFBundleIconFile</key><string>Hammer</string>"
  echo "Icon: made."
else
  rm -f "$STAGE/Contents/Resources/Hammer.icns"
  echo "Icon: couldn't be made, so this build has none."
fi

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
  $ICON_KEY
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

# 3. Wait until you're done: not while a Hammer dialog is open or YouTube is
# showing or playing (Hammer keeps ~/Hammer/.busy then). At most 30 minutes.
hammer_busy() {
  local pid
  pid="$(sed -n 1p "$BUSY" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o comm= 2>/dev/null | grep -q 'Hammer$'
}
if hammer_busy; then
  echo "Hammer is in use ($(sed -n 2p "$BUSY" 2>/dev/null)), so the update waits until you're done (at most 30 minutes)."
  if [ -n "${HAMMER_STATUS_FILE:-}" ]; then
    printf 'state=waiting\ntime=%s\nmessage=%s\ndetail=\n' "$(date +%s)" "Update ready · installs when you're done" \
      > "$HAMMER_STATUS_FILE.tmp" && mv -f "$HAMMER_STATUS_FILE.tmp" "$HAMMER_STATUS_FILE" || true
  fi
  for ((i = 0; i < 360; i++)); do hammer_busy || break; sleep 5; done
fi

# 4. Swap it in. The current Hammer is kept aside until the new one has started
# (it writes ~/Hammer/.launched); if it doesn't, the current one goes back, so
# you're never left without it.
stop_hammer() {
  pkill -x Hammer 2>/dev/null || true
  for ((i = 0; i < 10; i++)); do pgrep -x Hammer >/dev/null 2>&1 || return 0; sleep 0.5; done
  pkill -9 -x Hammer 2>/dev/null || true
  sleep 0.5
}
started() {   # the new Hammer said it has started, and it's still running
  for ((i = 0; i < 40; i++)); do
    if [ "$(sed -n 1p "$LAUNCHED" 2>/dev/null)" = "$VERSION" ]; then
      sleep 1
      pgrep -x Hammer >/dev/null 2>&1
      return
    fi
    sleep 0.5
  done
  return 1
}
put_back() {
  stop_hammer
  if [ -d "$PREVIOUS" ]; then
    rm -rf "$APP"
    mv "$PREVIOUS" "$APP"
    open "$APP" --args --login || true
    echo "The Hammer you had is back."
  fi
}

swapping=true
touch "$SWAPPING"
stop_hammer
rm -rf "$PREVIOUS"
if [ -d "$APP" ]; then mv "$APP" "$PREVIOUS"; fi
mkdir -p "$(dirname "$APP")"
mv "$STAGE" "$APP"
stop_hammer           # in case Hammer was opened again meanwhile (at login), from the old copy
rm -f "$LAUNCHED"
if ! open "$APP" --args --login; then
  echo "macOS wouldn't open Hammer $VERSION (the error is just above)."
  put_back
  swapping=false; rm -f "$SWAPPING"
  exit 3
fi
if ! started; then
  echo "Hammer $VERSION opened but didn't finish starting within 20 seconds."
  put_back
  swapping=false; rm -f "$SWAPPING"
  exit 3
fi
rm -rf "$PREVIOUS"
swapping=false
rm -f "$SWAPPING" "$RETRY"

# For Terminal commands: ~/Hammer/Hammer. A new file moved into place, since
# overwriting a binary in place can get it killed ("Killed: 9").
if cp "$BUILD/Hammer" "$HOME_DIR/.Hammer.new" && mv -f "$HOME_DIR/.Hammer.new" "$HOME_DIR/Hammer"; then :; else
  rm -f "$HOME_DIR/.Hammer.new"
  echo "Couldn't update ~/Hammer/Hammer (for Terminal commands); the app is fine."
fi

echo "Hammer $VERSION installed (built for macOS ${BUILT_FOR:-?} on $OS_VERSION)."
