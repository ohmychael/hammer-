#!/bin/bash
# update.sh — installs the newest Hammer from GitHub if it isn't installed yet.
#
# Runs as its own background job (launchd: local.hammer.updater) at login, every
# hour, and when you choose "Check for Updates" in Hammer's menu. Because it's
# separate from Hammer, it keeps going while it restarts Hammer.
#   --manual   (or the flag file Hammer leaves) also shows a notification when
#              there's nothing new

set -uo pipefail

HAMMER="$HOME/Hammer"
REPO="$HAMMER/repo"
APP="$HOME/Applications/Hammer.app"
LOCK="/tmp/hammer-update.lock"
FLAG="$HAMMER/.manual-check"
FAILED="$HAMMER/.failed-build"

MANUAL=false
if [ "${1:-}" = "--manual" ] || [ -f "$FLAG" ]; then MANUAL=true; fi
rm -f "$FLAG"

notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"Hammer\"" >/dev/null 2>&1 || true
}

# One update at a time. A lock older than 15 minutes is left over from an
# interrupted run, so clear it.
if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then rmdir "$LOCK" 2>/dev/null; fi
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

cd "$REPO" || exit 1
if ! git fetch --quiet origin main; then
  $MANUAL && notify "Couldn't reach GitHub. Check your internet connection."
  exit 0
fi

latest="$(git rev-parse --short origin/main)"
installed="$(cat "$APP/Contents/Resources/VERSION" 2>/dev/null || echo none)"

# Compare with what's actually installed, so an interrupted install is retried.
if [ "$installed" = "$latest" ]; then
  echo "$(date): up to date ($installed)"
  $MANUAL && notify "Hammer is up to date."
  exit 0
fi

# Don't retry a version that already failed to build every hour; wait for a fix
# (or a manual check).
if ! $MANUAL && [ "$(cat "$FAILED" 2>/dev/null)" = "$latest" ]; then
  echo "$(date): $latest failed to build before; waiting for a newer version"
  exit 0
fi

echo "$(date): updating $installed -> $latest"
git reset --hard --quiet origin/main
if /bin/bash "$REPO/build.sh"; then
  rm -f "$FAILED"
  notify "Hammer updated to $latest."
else
  echo "$latest" > "$FAILED"
  echo "$(date): build failed for $latest; still running $installed"
  notify "An update failed to build, so Hammer kept the current version."
fi
