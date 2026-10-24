#!/bin/bash
# agents.sh — Hammer's two login items (launchd agents in ~/Library/LaunchAgents):
#   local.hammer          opens Hammer when you log in
#   local.hammer.updater  checks for updates at login and every 5 minutes (update.sh)
#
# Login Items in System Settings names an agent after the program it runs, so these
# run two tiny scripts in ~/Hammer/bin, "Hammer" and "Hammer Updates", rather than
# /usr/bin/open and /bin/bash (which it would list as "open" and "bash").
#
#   bash agents.sh           writes them and turns them on now (install-hammer.sh, and
#                            "Turn On…" in Hammer's menu); exits 1 if one stays off
#   bash agents.sh --files   only rewrites what changed; that takes effect at the next
#                            login (update.sh, which mustn't restart itself)

set -uo pipefail

BIN="$HOME/Hammer/bin"
AGENTS="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"
OPENER="$BIN/Hammer"
UPDATER="$BIN/Hammer Updates"

# write <file> <mode>: stdin to the file, if it's different. Says "changed" if it was.
write() {
  local new
  new="$(cat)"
  if [ -f "$1" ] && [ "$(cat "$1")" = "$new" ]; then return 0; fi
  mkdir -p "$(dirname "$1")" && printf '%s\n' "$new" > "$1.new" && chmod "$2" "$1.new" && mv -f "$1.new" "$1" \
    && echo changed
}

opener_changed="$(write "$OPENER" 755 <<'SCRIPT'
#!/bin/bash
# Opens Hammer when you log in (the login item local.hammer; see agents.sh).
pgrep -f "Hammer.app/Contents/MacOS/Hammer" >/dev/null 2>&1 && exit 0
exec open "$HOME/Applications/Hammer.app" --args --login
SCRIPT
)"
updater_changed="$(write "$UPDATER" 755 <<'SCRIPT'
#!/bin/bash
# Checks for Hammer updates (the login item local.hammer.updater; see agents.sh).
exec /bin/bash "$HOME/Hammer/repo/update.sh" "$@"
SCRIPT
)"

login_plist_changed="$(write "$AGENTS/local.hammer.plist" 644 <<PLIST
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
)"
updater_plist_changed="$(write "$AGENTS/local.hammer.updater.plist" 644 <<PLIST
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
)"

[ "${1:-}" = "--files" ] && exit 0

# load <label> <plist> <changed>: on, and running the latest definition.
load() {
  launchctl enable "$DOMAIN/$1" 2>/dev/null
  if launchctl print "$DOMAIN/$1" >/dev/null 2>&1; then
    [ -n "$3" ] || return 0
    launchctl bootout "$DOMAIN/$1" 2>/dev/null
  fi
  launchctl bootstrap "$DOMAIN" "$2" 2>/dev/null
  launchctl print "$DOMAIN/$1" >/dev/null 2>&1
}
off=0
load local.hammer "$AGENTS/local.hammer.plist" "$opener_changed$login_plist_changed" \
  || { echo "Opening at login is off."; off=1; }
load local.hammer.updater "$AGENTS/local.hammer.updater.plist" "$updater_changed$updater_plist_changed" \
  || { echo "Updates are off."; off=1; }
exit $off
