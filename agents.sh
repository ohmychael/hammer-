#!/bin/bash
# agents.sh — Hammer's two login items (launchd agents in ~/Library/LaunchAgents):
#   local.hammer          opens Hammer when you log in
#   local.hammer.updater  checks for updates at login and every 5 minutes (update.sh)
#
# Login Items in System Settings names an agent after the program it runs, so these
# run two tiny scripts in ~/Hammer/bin, "Hammer" and "Hammer Updates", rather than
# /usr/bin/open and /bin/bash (which it would list as "open" and "bash").
#
#   bash agents.sh --install  sets both up and turns them on (install-hammer.sh)
#   bash agents.sh            sets them up again and turns them on ("Turn On…" in
#                             Hammer's menu); exits 1 if one stays off. Opening at
#                             login only if you still have it (deleting its file is
#                             how you'd turn it off for good).
#   bash agents.sh --files    only rewrites the ones you have, if they changed; that
#                             takes effect at the next login (update.sh, which mustn't
#                             restart itself)

set -uo pipefail

if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then echo "No home folder (HOME isn't set)."; exit 1; fi
MODE="${1:-}"
BIN="$HOME/Hammer/bin"
AGENTS="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"
OPENER="$BIN/Hammer"
UPDATER="$BIN/Hammer Updates"
LOGIN_PLIST="$AGENTS/local.hammer.plist"
UPDATER_PLIST="$AGENTS/local.hammer.updater.plist"

# write <file> <mode>: stdin to the file, if it's different. Says "changed" if it was.
write() {
  local new
  new="$(cat)"
  if [ -f "$1" ] && [ "$(cat "$1")" = "$new" ]; then return 0; fi
  mkdir -p "$(dirname "$1")" && printf '%s\n' "$new" > "$1.new" && chmod "$2" "$1.new" && mv -f "$1.new" "$1" \
    && echo changed
}

opener_script() {
  cat <<'SCRIPT'
#!/bin/bash
# Opens Hammer when you log in (the login item local.hammer; see agents.sh).
pgrep -f "Hammer.app/Contents/MacOS/Hammer" >/dev/null 2>&1 && exit 0
exec open "$HOME/Applications/Hammer.app" --args --login
SCRIPT
}
updater_script() {
  cat <<'SCRIPT'
#!/bin/bash
# Checks for Hammer updates (the login item local.hammer.updater; see agents.sh).
exec /bin/bash "$HOME/Hammer/repo/update.sh" "$@"
SCRIPT
}
login_plist() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.hammer</string>
  <key>ProgramArguments</key>
  <array><string>$OPENER</string></array>
  <key>RunAtLoad</key><true/>
  <key>AssociatedBundleIdentifiers</key><string>local.hammer</string>
</dict>
</plist>
PLIST
}
updater_plist() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.hammer.updater</string>
  <key>ProgramArguments</key>
  <array><string>$UPDATER</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>300</integer>
  <key>StandardOutPath</key><string>$HOME/Hammer/update.log</string>
  <key>StandardErrorPath</key><string>$HOME/Hammer/update.log</string>
  <key>AssociatedBundleIdentifiers</key><string>local.hammer</string>
</dict>
</plist>
PLIST
}

# Which ones: opening at login only if you have it (or on install); updates always,
# except that --files never adds one.
want_login=false
want_updater=true
if [ "$MODE" = --install ] || [ -f "$LOGIN_PLIST" ]; then want_login=true; fi
if [ "$MODE" = --files ] && [ ! -f "$UPDATER_PLIST" ]; then want_updater=false; fi

login_changed=""
updater_changed=""
if $want_login; then
  login_changed="$(opener_script | write "$OPENER" 755)$(login_plist | write "$LOGIN_PLIST" 644)"
fi
if $want_updater; then
  updater_changed="$(updater_script | write "$UPDATER" 755)$(updater_plist | write "$UPDATER_PLIST" 644)"
fi

[ "$MODE" = --files ] && exit 0

# load <label> <plist> <changed>: on, and running the latest definition.
load() {
  local i
  launchctl enable "$DOMAIN/$1" 2>/dev/null
  if launchctl print "$DOMAIN/$1" >/dev/null 2>&1; then
    [ -n "$3" ] || return 0
    launchctl bootout "$DOMAIN/$1" 2>/dev/null
  fi
  # Right after a bootout, launchd can still be letting go of it: try for a few seconds.
  for i in 1 2 3 4 5; do
    launchctl bootstrap "$DOMAIN" "$2" 2>/dev/null && break
    sleep 1
  done
  launchctl print "$DOMAIN/$1" >/dev/null 2>&1
}
off=0
if $want_login; then
  load local.hammer "$LOGIN_PLIST" "$login_changed" || { echo "Opening at login is off."; off=1; }
fi
load local.hammer.updater "$UPDATER_PLIST" "$updater_changed" || { echo "Updates are off."; off=1; }
exit $off
