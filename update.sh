#!/bin/bash
# update.sh — installs the newest Hammer from GitHub if it isn't installed yet.
#
# Runs as its own background job (launchd: local.hammer.updater) at login and
# every 5 minutes; Hammer also starts it every 2 minutes and when you choose
# "Check for Updates". Because it's separate from Hammer, it keeps going while it
# restarts Hammer.
#   --manual   (or the flag file Hammer leaves) also retries a version that failed
#
# What it last did goes in ~/Hammer/update-status, which Hammer's menu shows and
# turns into notifications:
#   state=current|updated|updating|waiting|checking|offline|failed|retry
#   time=<seconds since 1970>   message=<short, for the menu>   detail=<for the notification>

set -uo pipefail

HAMMER="$HOME/Hammer"
REPO="$HAMMER/repo"
APP="$HOME/Applications/Hammer.app"
BUILD="$HAMMER/build"
PREVIOUS="$BUILD/Hammer-previous.app"
SWAPPING="$BUILD/.swapping"          # build.sh: an app swap is under way
LOCK="$HAMMER/.update.lock"          # held by this or install-hammer.sh; holds the PID
FLAG="$HAMMER/.manual-check"         # Hammer: "Check for Updates" was chosen
FAILED="$HAMMER/.failed-build"       # a version that didn't build or open
RETRY="$HAMMER/.retry-later"         # build.sh: a version that hit a problem with this Mac
STATUS="$HAMMER/update-status"

MANUAL=false
if [ "${1:-}" = "--manual" ] || [ -f "$FLAG" ]; then MANUAL=true; fi

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# status <state> <message> [<detail>]
status() {
  { echo "state=$1"; echo "time=$(date +%s)"; echo "message=$2"; echo "detail=${3:-}"; } > "$STATUS.tmp" \
    && mv -f "$STATUS.tmp" "$STATUS"
}

# What's wrong with this Mac's tools or disk, if anything: "message|detail".
mac_problem() {
  local dev free
  dev="$(xcode-select -p 2>/dev/null)"
  if [ -z "$dev" ] || [ ! -d "$dev" ] || ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Can't update: developer tools missing|Apple's command-line tools need reinstalling. In Terminal, run: xcode-select --install"
    return
  fi
  free="$(df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  if [ -n "$free" ] && [ "$free" -lt 1048576 ]; then
    echo "Can't update: your Mac is almost full|Free up about 1 GB, and Hammer will update itself."
  fi
}

# One run at a time. The lock holds the PID (and start time) of the run that has it,
# so a lock left by a run that was killed (logout, shutdown) doesn't block anything.
lock_holder_alive() {
  local pid started
  pid="$(sed -n 1p "$LOCK/pid" 2>/dev/null)"
  started="$(sed -n 2p "$LOCK/pid" 2>/dev/null)"
  if [ -z "$pid" ]; then                                   # being taken right now
    [ -n "$(find "$LOCK" -maxdepth 0 -mmin -1 2>/dev/null)" ]
    return
  fi
  kill -0 "$pid" 2>/dev/null && [ "$(ps -o lstart= -p "$pid" 2>/dev/null)" = "$started" ]
}
mkdir -p "$HAMMER"
if ! mkdir "$LOCK" 2>/dev/null; then
  lock_holder_alive && exit 0          # the request flag stays, for the next run
  log "cleared a lock left by an update that was cut off"
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || exit 0
fi
printf '%s\n%s\n' "$$" "$(ps -o lstart= -p $$)" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT
rm -f "$FLAG"                          # it's ours now: this run reports

# An update cut off mid-swap (logout, shutdown) can leave the app moved aside, or a
# new one that was never checked. Put the one you had back and start it, even offline.
cut_off=false
if [ -e "$SWAPPING" ]; then
  cut_off=true
  if [ -d "$PREVIOUS" ]; then
    log "an update was cut off mid-way; putting back the Hammer you had"
    pkill -x Hammer 2>/dev/null
    rm -rf "$APP" && mkdir -p "$(dirname "$APP")" && mv "$PREVIOUS" "$APP"
  fi
elif [ ! -d "$APP" ] && [ -d "$PREVIOUS" ]; then
  cut_off=true
  log "Hammer was moved aside by an update that was cut off; putting it back"
  mkdir -p "$(dirname "$APP")" && mv "$PREVIOUS" "$APP"
fi
rm -f "$SWAPPING"
if $cut_off && [ -d "$APP" ] && ! pgrep -x Hammer >/dev/null 2>&1; then open "$APP" --args --login; fi

# A signing step that was killed can leave Hammer's keychain on your keychain list.
if [ -f "$REPO/signing.sh" ]; then
  ( source "$REPO/signing.sh" && signing_unlist "$SIGN_DIR/hammer-signing.keychain-db" ) >/dev/null 2>&1
fi

cd "$REPO" || { log "no copy of Hammer's code at $REPO"; exit 1; }

# Keep the login items' names and settings current (they take effect at the next login).
if [ -f "$HOME/Library/LaunchAgents/local.hammer.updater.plist" ] && [ -f "$REPO/agents.sh" ]; then
  /bin/bash "$REPO/agents.sh" --files || log "couldn't update the login items"
fi

# Problems with the Mac itself aren't the update's fault: say how to fix them and try again later.
problem="$(mac_problem)"
if [ -n "$problem" ]; then
  log "${problem#*|}"
  status retry "${problem%%|*}" "${problem#*|}"
  exit 0
fi

$MANUAL && status checking "Checking…"
if ! git fetch --quiet origin main; then
  log "couldn't reach GitHub"
  status offline "Can't reach GitHub" "Check your internet connection, then try again."
  exit 0
fi

latest="$(git rev-parse --short origin/main)"
installed="$(cat "$APP/Contents/Resources/VERSION" 2>/dev/null || echo none)"
subject="$(git log -1 --format=%s origin/main 2>/dev/null)"

# Compare with what's actually installed, so an interrupted install is retried.
if [ "$installed" = "$latest" ]; then
  log "up to date ($installed)"
  status current "Up to date"
  exit 0
fi

# Don't keep retrying a version that already failed; wait for a fix (or a manual check).
if ! $MANUAL && [ "$(cat "$FAILED" 2>/dev/null)" = "$latest" ]; then
  log "$latest failed before; waiting for a newer version"
  exit 0
fi
# One that hit a problem with this Mac is tried again after an hour (or on a manual check).
if ! $MANUAL && [ "$(sed -n 1p "$RETRY" 2>/dev/null)" = "$latest" ] \
   && [ -n "$(find "$RETRY" -mmin -60 2>/dev/null)" ]; then
  log "$latest: $(sed -n 3p "$RETRY"); trying again later"
  exit 0
fi

# A git that was killed leaves .git/index.lock behind, and every git command after it fails.
if [ -n "$(find .git/index.lock -mmin +10 2>/dev/null)" ]; then
  log "removed a .git/index.lock left by a git that was cut off"
  rm -f .git/index.lock
fi
edits="$(git status --porcelain --untracked-files=no 2>/dev/null | tr '\n' ' ')"
[ -n "$edits" ] && log "replacing local edits in $REPO: $edits"
if ! git reset --hard --quiet origin/main || [ "$(git rev-parse --short HEAD)" != "$latest" ]; then
  log "couldn't check out $latest; keeping $installed"
  status retry "Can't update: couldn't get the new files" "Hammer will try again in a few minutes. The log is in ~/Hammer/update.log."
  exit 0
fi

log "updating $installed -> $latest ($subject)"
status updating "Updating…" "$subject"
rm -f "$RETRY"
HAMMER_STATUS_FILE="$STATUS" /bin/bash "$REPO/build.sh"
result=$?
if [ $result -eq 0 ]; then
  rm -f "$FAILED"
  status updated "Updated to $latest" "$subject"
elif [ $result -eq 3 ]; then
  # Built, but it didn't open or start; build.sh put the previous one back (and said why, above).
  echo "$latest" > "$FAILED"
  log "$latest didn't open; put $installed back"
  status failed "Update didn't open" "macOS wouldn't start Hammer's update, so the version you had is back."
elif [ $result -eq 4 ]; then
  # A problem with this Mac (build.sh said which, in .retry-later); not the update's fault.
  log "$latest: $(sed -n 3p "$RETRY" 2>/dev/null); trying again later"
  status retry "$(sed -n 2p "$RETRY" 2>/dev/null)" "$(sed -n 3p "$RETRY" 2>/dev/null)"
elif [ $result -ge 128 ]; then
  log "the update was stopped (signal $((result - 128))); trying again later"
  status retry "Update was interrupted" "Hammer will try again in a few minutes."
else
  echo "$latest" > "$FAILED"
  log "build failed for $latest; still running $installed"
  status failed "Update failed to build" "Hammer kept the version you have. The log is in ~/Hammer/update.log."
fi
exit 0
