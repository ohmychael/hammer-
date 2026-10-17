#!/bin/bash
# update.sh — checks GitHub for a newer Hammer and installs it.
# Runs by itself every hour (and at login), or from Hammer's "Check for Updates".
#   --manual   also show a notification when Hammer is already up to date

set -uo pipefail

REPO="$HOME/Hammer/repo"
LOCK="/tmp/hammer-update.lock"
MANUAL=false
[ "${1:-}" = "--manual" ] && MANUAL=true

notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"Hammer\"" >/dev/null 2>&1 || true
}

# One update at a time.
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK"' EXIT

cd "$REPO" || exit 1
if ! git fetch --quiet origin main; then
  $MANUAL && notify "Couldn't reach GitHub. Check your internet connection."
  exit 0
fi

if [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ]; then
  echo "$(date): up to date ($(git rev-parse --short HEAD))"
  $MANUAL && notify "Hammer is up to date."
  exit 0
fi

previous="$(git rev-parse HEAD)"
git reset --hard --quiet origin/main
echo "$(date): updating to $(git rev-parse --short HEAD)"

if /bin/bash "$REPO/build.sh"; then
  notify "Hammer updated to $(git rev-parse --short HEAD)."
else
  # Keep the working version; try this update again next time.
  git reset --hard --quiet "$previous"
  echo "$(date): build failed, kept $(git rev-parse --short HEAD)"
  notify "An update failed to build, so Hammer kept the current version."
fi
