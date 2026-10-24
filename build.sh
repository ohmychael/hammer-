#!/bin/bash
# build.sh — compiles Hammer from this folder and installs ~/Applications/Hammer.app.
# Used by both install-hammer.sh and update.sh. If the build fails, the Hammer
# you already have keeps running untouched.
#
# Exit codes: 0 installed; 1 this version doesn't build or pass its tests;
# 3 built, but it didn't open or start (the one you had is back); 4 a problem with
# this Mac, not the update (tools, disk space, another app in the way): what to do
# is in ~/Hammer/.retry-later, and it's tried again later.
#   build.sh --restore   only puts back a Hammer that an update cut off part-way
#                        had set aside, and starts it (update.sh, before going online)

set -euo pipefail

if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then echo "No home folder (HOME isn't set)."; exit 1; fi
REPO="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$HOME/Hammer"
BUILD="$HOME_DIR/build"
APP="$HOME/Applications/Hammer.app"
STAGE="$BUILD/Hammer.app"
PREVIOUS="$BUILD/Hammer-previous.app"  # the Hammer you had, while a new one is tried
SWAPPING="$BUILD/.swapping"            # while the app is being swapped
LAUNCHED="$HOME_DIR/.launched"         # Hammer writes its version here once it has started
BUSY="$HOME_DIR/.busy"                 # Hammer is busy: a dialog, or its YouTube player (its PID, then why)
RETRY="$HOME_DIR/.retry-later"
BUNDLE_ID="local.hammer"
PLISTBUDDY="${HAMMER_PLISTBUDDY:-/usr/libexec/PlistBuddy}"   # tests swap in stand-ins
PERL="${HAMMER_PERL:-perl}"
TESTS_LIMIT="${HAMMER_TESTS_LIMIT:-600}"                    # seconds
VERSION=""                             # from git, once the developer tools are known to work
VERSION_DATE=""
built=no                               # becomes yes once the slow part (compiling) has started

mkdir -p "$BUILD"

# Runs a command, stopping it after $1 seconds (it then exits with 142). Without
# perl, it just runs the command.
limit() {
  if command -v "$PERL" >/dev/null 2>&1; then
    "$PERL" -e 'alarm shift; exec @ARGV or die "$ARGV[0]: $!\n"' "$@"
  else
    shift; "$@"
  fi
}

free_kb() { df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 { print $4 }'; }
low_on_space() { local free; free="$(free_kb)"; [ -n "$free" ] && [ "$free" -lt 1048576 ]; }

# The commit checked out, read from .git without running git (on a Mac without the
# developer tools, /usr/bin/git asks to install them).
head_commit() {
  local head ref
  head="$(cat "$REPO/.git/HEAD" 2>/dev/null)" || return 0
  case "$head" in
    "ref: "*)
      ref="${head#ref: }"
      cat "$REPO/.git/$ref" 2>/dev/null || awk -v r="$ref" '$2 == r { print $1 }' "$REPO/.git/packed-refs" 2>/dev/null
      ;;
    *) echo "$head" ;;
  esac
}

# retry_later <message> <detail>: a problem with this Mac. Exits 4. update.sh waits
# an hour before building that version again if the build had already started.
retry_later() {
  printf '%s\n%s\n%s\n%s\n' "${VERSION:-$(head_commit)}" "$1" "$2" "$built" > "$RETRY" 2>/dev/null || true
  echo "$2"
  exit 4
}
no_space() { retry_later "Can't update: your Mac is almost full" "Free up about 1 GB, and Hammer will update itself."; }

# --- Putting things back

valid_app() { [ -x "$1/Contents/MacOS/Hammer" ] && [ -f "$1/Contents/Info.plist" ]; }

# discard <folder>: out of the way at once (a rename), then deleted, so being
# stopped part-way never leaves a half-deleted app where an app is expected.
discard() {
  [ -e "$1" ] || return 0
  local trash="$BUILD/.trash.$$.$RANDOM"
  mv "$1" "$trash" && rm -rf "$trash"
}

stop_hammer() {   # stops Hammer and waits until it has quit
  pkill -x Hammer 2>/dev/null || true
  for ((i = 0; i < 10; i++)); do pgrep -x Hammer >/dev/null 2>&1 || return 0; sleep 0.5; done
  pkill -9 -x Hammer 2>/dev/null || true
  sleep 0.5
}

# bring_back: the Hammer you had (set aside) back in place. If what's in its place
# can't be moved away, both are left as they are (never one inside the other).
bring_back() {
  discard "$APP" || true
  if [ -e "$APP" ]; then
    echo "Couldn't move ~/Applications/Hammer.app out of the way, so the Hammer you had stays set aside (tried again next time)."
    return 1
  fi
  mkdir -p "$(dirname "$APP")" && mv "$PREVIOUS" "$APP"
}

# An update cut off part-way (a logout, a shutdown) can leave the Hammer you had set
# aside, with a new one that never started, or nothing, in its place. This puts it
# back and starts it. The only good copy is never deleted.
restore() {
  local reopen=false done=true
  if [ -e "$SWAPPING" ]; then
    reopen=true
    if valid_app "$PREVIOUS"; then
      echo "An update was cut off part-way, so the Hammer you had is going back."
      stop_hammer
      bring_back || done=false
    fi
  elif ! valid_app "$APP" && valid_app "$PREVIOUS"; then
    echo "Hammer was set aside by an update that was cut off; putting it back."
    reopen=true
    bring_back || done=false
  fi
  if $done; then rm -f "$SWAPPING"; fi   # otherwise the next run tries again
  if $reopen && valid_app "$APP" && ! pgrep -x Hammer >/dev/null 2>&1; then open "$APP" --args --login || true; fi
}

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
    echo "The update stopped part-way."
    restore
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

rm -rf "$BUILD"/.trash.*              # left by a run stopped while deleting
restore
[ "${1:-}" = --restore ] && exit 0

# 0. Problems with the Mac, before anything is built.
developer="$(xcode-select -p 2>/dev/null || true)"
if [ -z "$developer" ] || [ ! -d "$developer" ] || ! xcrun --find swiftc >/dev/null 2>&1; then
  retry_later "Can't update: developer tools missing" \
    "Apple's command-line tools need reinstalling. In Terminal, run: xcode-select --install"
fi
VERSION="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo dev)"
VERSION_DATE="$(git -C "$REPO" log -1 --date=short --format=%cd 2>/dev/null || true)"
if low_on_space; then no_space; fi
if [ -d "$APP" ]; then
  existing_id="$("$PLISTBUDDY" -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [ -n "$existing_id" ] && [ "$existing_id" != "$BUNDLE_ID" ]; then
    retry_later "Can't update: another app is in the way" \
      "There's a different app at ~/Applications/Hammer.app. Move or rename it, and Hammer will install."
  fi
fi
apps_folder="$(dirname "$APP")"
if { [ -e "$APP" ] && [ ! -w "$APP" ]; } || { [ -d "$apps_folder" ] && [ ! -w "$apps_folder" ]; } || [ ! -w "$BUILD" ]; then
  retry_later "Can't update: Hammer.app belongs to another user" \
    "Hammer isn't allowed to replace ~/Applications/Hammer.app (it was probably copied there as another user). In Terminal, run: sudo chown -R $(id -un) ~/Applications/Hammer.app ~/Applications"
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
built=yes
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
  retry_later "Can't update: the tools are newer than macOS" \
    "This Mac's command-line tools build for macOS $BUILT_FOR, but it runs macOS $OS_VERSION. Update macOS, or reinstall the command-line tools that match it: xcode-select --install"
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
  <key>NSAppleEventsUsageDescription</key><string>Hammer opens YouTube in your Microsoft Edge and keeps its window in the top-right corner. Its scripts tell Hammer only which window that is and where; your tabs' addresses, cookies, passwords and history never reach Hammer.</string>
</dict>
</plist>
PLIST
# Sign with the same local certificate every time, so macOS keeps Hammer's
# permissions (Bluetooth etc.) across updates; falls back to ad hoc (signing.sh).
source "$REPO/signing.sh"
sign_app "$STAGE"

# 3. Wait until you're done: not while one of Hammer's dialogs is open or its own
# YouTube player is open or playing (Hammer keeps ~/Hammer/.busy then, with its
# PID and why). At most 30 minutes.
hammer_busy() {
  local pid
  pid="$(sed -n 1p "$BUSY" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o comm= 2>/dev/null | grep -q 'Hammer$'
}
if hammer_busy; then
  why="$(sed -n 2p "$BUSY" 2>/dev/null | tr -cd '[:alnum:] ,.-' || true)"   # it may be gone already
  echo "Hammer is busy (${why:-in use}), so the update waits until you're done (at most 30 minutes)."
  if [ -n "${HAMMER_STATUS_FILE:-}" ]; then
    printf 'state=waiting\ntime=%s\nversion=%s\nmessage=%s\ndetail=\n' "$(date +%s)" "$VERSION" \
      "Update ready · installs when you're done" \
      > "$HAMMER_STATUS_FILE.tmp" && mv -f "$HAMMER_STATUS_FILE.tmp" "$HAMMER_STATUS_FILE" || true
  fi
  for ((i = 0; i < 360; i++)); do hammer_busy || break; sleep 5; done
fi

# 4. Swap it in. The current Hammer is kept aside until the new one has started
# (it writes ~/Hammer/.launched); if it doesn't, the current one goes back, so
# you're never left without it.
# The new Hammer must say it has started (within 20 s), then keep running for
# another 20 s: most of its work with your lights, monitor and Gmail happens in
# its first seconds, so a version that crashes there goes back too.
STAY=20
started() {
  local i
  for ((i = 0; i < 40; i++)); do
    [ "$(sed -n 1p "$LAUNCHED" 2>/dev/null)" = "$VERSION" ] && break
    sleep 0.5
  done
  if [ "$i" -ge 40 ]; then
    echo "Hammer $VERSION opened but didn't finish starting within 20 seconds."
    return 1
  fi
  for ((i = 0; i < STAY; i++)); do
    sleep 1
    if ! pgrep -x Hammer >/dev/null 2>&1; then
      echo "Hammer $VERSION started, then quit within $STAY seconds."
      return 1
    fi
  done
}
put_back() {
  stop_hammer
  if valid_app "$PREVIOUS"; then
    bring_back || return 0             # still swapping: finish tries once more, and keeps the note
    open "$APP" --args --login || true
    echo "The Hammer you had is back."
  fi
  swapping=false
  rm -f "$SWAPPING"
}

discard "$PREVIOUS"   # left over from before; the app in place is the one to keep
swapping=true
touch "$SWAPPING"
stop_hammer
if [ -e "$APP" ]; then mv "$APP" "$PREVIOUS"; fi
mkdir -p "$apps_folder"
mv "$STAGE" "$APP"
stop_hammer           # in case Hammer was opened again meanwhile (at login), from the old copy
rm -f "$LAUNCHED"
if ! open "$APP" --args --login; then
  echo "macOS wouldn't open Hammer $VERSION (the error is just above)."
  put_back
  exit 3
fi
if ! started; then
  put_back
  exit 3
fi
# It started: this is the one to keep, from here on, whatever happens.
swapping=false
rm -f "$SWAPPING" "$RETRY"
discard "$PREVIOUS"

# For Terminal commands: ~/Hammer/Hammer. A new file moved into place, since
# overwriting a binary in place can get it killed ("Killed: 9").
if cp "$BUILD/Hammer" "$HOME_DIR/.Hammer.new" && mv -f "$HOME_DIR/.Hammer.new" "$HOME_DIR/Hammer"; then :; else
  rm -f "$HOME_DIR/.Hammer.new"
  echo "Couldn't update ~/Hammer/Hammer (for Terminal commands); the app is fine."
fi

echo "Hammer $VERSION installed (built for macOS ${BUILT_FOR:-?} on $OS_VERSION)."
