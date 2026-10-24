#!/bin/bash
# Tests/Update/run.sh — plays out updates and installs in a sandbox: update.sh,
# build.sh, install-hammer.sh and agents.sh run for real, with real git against a
# local stand-in for GitHub, and stand-ins (shims/) for swiftc, open, pkill,
# launchctl, codesign and the rest. HOME is a temporary folder: nothing outside it
# is touched, and no real open, pkill or launchctl ever runs.
# Runs on Linux or a Mac in about a minute (bash, git and perl; python3 and openssl
# for one signing scenario):
#   Tests/Update/run.sh                     everything
#   Tests/Update/run.sh restart-loop busy   just these
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hammer-update-tests.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
holders=()
cleanup() {
  local pid
  for pid in "${holders[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT

export HOME="$WORK/home" TMPDIR="$WORK/tmp" FAKE="$WORK/fake" FAKE_LOG="$WORK/fake/events.log"
export FAKE_OSASCRIPT="$WORK/osascript-calls"
export PATH="$HERE/shims:/usr/bin:/bin"
export HAMMER_SECURITY=/bin/false HAMMER_OPENSSL=/bin/false HAMMER_CODESIGN="$HERE/shims/codesign"
export HAMMER_PLISTBUDDY="$HERE/shims/PlistBuddy"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
unset HAMMER_STATUS_FILE HAMMER_TESTS_LIMIT HAMMER_SIGN_LIMIT HAMMER_REPO_URL HAMMER_SIGN_DIR

# Safety first: every tool that could touch the real Mac must be a stand-in.
for tool in open pkill pgrep launchctl osascript xcrun xcode-select swiftc codesign iconutil vtool sw_vers df sleep; do
  if [ "$(command -v "$tool")" != "$HERE/shims/$tool" ]; then
    echo "Stopped: $tool would be $(command -v "$tool"), not the stand-in."; exit 1
  fi
done
case "$HOME" in "$WORK"/home) ;; *) echo "Stopped: HOME isn't the sandbox."; exit 1 ;; esac

failed=0
passed=0
failures=""
scenario=""
check() {
  if eval "$1"; then
    passed=$((passed + 1)); echo "  ok   $2"
  else
    failed=$((failed + 1)); echo "  FAIL $2"
    failures="$failures  FAIL [$scenario] $2 (elapsed ${elapsed:-?} s)
"
    echo "       events: $(tr '\n' ';' < "$FAKE_LOG")"
    echo "       output: $(tail -8 "$WORK/out.txt" 2>/dev/null | tr '\n' ';')"
  fi
}

# --- The world: a stand-in GitHub, your Mac's ~/Hammer, Hammer A installed and running.

commit() {   # commit <message>: a new commit on GitHub's main; prints its short hash
  ( cd "$WORK/work" && echo "// $1" >> Hammer.swift && git add -A && git commit -qm "$1" && git push -q origin main )
  git -C "$WORK/work" rev-parse --short HEAD
}

reset_world() {
  local f
  for f in "${holders[@]:-}"; do [ -n "$f" ] && kill "$f" 2>/dev/null; done
  holders=()
  rm -rf "$HOME" "$FAKE" "$TMPDIR" "$WORK/origin.git" "$WORK/offline.git" "$WORK/work"
  mkdir -p "$HOME/Applications" "$FAKE" "$TMPDIR"
  : > "$FAKE_LOG"
  git init -q --bare "$WORK/origin.git"
  git -C "$WORK/origin.git" symbolic-ref HEAD refs/heads/main
  git init -q "$WORK/work"
  ( cd "$WORK/work"
    git checkout -q -b main
    cp "$REPO/build.sh" "$REPO/update.sh" "$REPO/signing.sh" "$REPO/agents.sh" "$REPO/install-hammer.sh" .
    for f in Hammer HammerCore Monitor MonitorMac Player PlayerMac EdgeMac Deliveries DeliveryAlerts UpdatesMac; do
      echo "// $f" > "$f.swift"
    done
    echo "// player" > PlayerScript.js
    mkdir -p Tests && echo "// tests" > Tests/main.swift
    git add -A && git commit -qm "A" && git remote add origin "$WORK/origin.git" && git push -q origin main )
  A="$(git -C "$WORK/work" rev-parse --short HEAD)"
  git clone -q "$WORK/origin.git" "$HOME/Hammer/repo"
  if ! bash "$HOME/Hammer/repo/build.sh" > "$WORK/out.txt" 2>&1; then
    echo "  (the first install failed)"; cat "$WORK/out.txt"; exit 1
  fi
  : > "$FAKE_LOG"
}

# upd [args]: runs update.sh the way launchd does, as its own process group (so a
# stand-in "logout" can stop the whole update), and waits until all of it has finished.
upd() {
  local start=$SECONDS pid i
  perl -e 'setpgrp(0, 0); exec @ARGV' /bin/bash "$HOME/Hammer/repo/update.sh" "$@" > "$WORK/out.txt" 2>&1 &
  pid=$!
  wait "$pid"
  echo $? > "$WORK/exit.txt"
  for ((i = 0; i < 100; i++)); do
    ps -A -o pgid= | awk -v g="$pid" '$1 == g { found = 1 } END { exit !found }' || break
    perl -e 'select(undef, undef, undef, 0.1)'
  done
  elapsed=$((SECONDS - start))
}

install() {   # runs install-hammer.sh as from curl, with GitHub being the stand-in
  HAMMER_REPO_URL="$WORK/origin.git" bash "$REPO/install-hammer.sh" > "$WORK/out.txt" 2>&1
  echo $? > "$WORK/exit.txt"
}

# A process that holds the update lock (as a running update would) for $1 seconds.
hold_lock() {
  perl -e 'select(undef, undef, undef, $ARGV[0])' "$1" &
  holders+=($!)
  mkdir -p "$HOME/Hammer/.update.lock"
  printf '%s\n%s\n' "$!" "$(ps -o lstart= -p "$!")" > "$HOME/Hammer/.update.lock/pid"
}

# A "Hammer" that's busy (YouTube is open) for $1 seconds: a copy of sleep named Hammer.
busy_hammer() {
  local real
  for real in /bin/sleep /usr/bin/sleep; do [ -x "$real" ] && break; done
  mkdir -p "$WORK/bin" && /bin/cp "$real" "$WORK/bin/Hammer"
  "$WORK/bin/Hammer" "$1" &
  holders+=($!)
  printf '%s\nYouTube\n' "$!" > "$HOME/Hammer/.busy"
}

app_version() { cat "$HOME/Applications/Hammer.app/Contents/Resources/VERSION" 2>/dev/null || echo none; }
running() { cat "$FAKE/running" 2>/dev/null || echo nothing; }
state() { sed -n 's/^state=//p' "$HOME/Hammer/update-status" 2>/dev/null; }
message() { sed -n 's/^message=//p' "$HOME/Hammer/update-status" 2>/dev/null; }
detail() { sed -n 's/^detail=//p' "$HOME/Hammer/update-status" 2>/dev/null; }
exit_was() { [ "$(cat "$WORK/exit.txt")" = "$1" ]; }
said() { grep -q -- "$1" "$WORK/out.txt"; }
happened() { grep -q -- "$1" "$FAKE_LOG"; }
times() { grep -c -- "$1" "$FAKE_LOG"; }
builds() { grep -c -- "swiftc -> Hammer " "$FAKE_LOG"; }
failed_version() { cat "$HOME/Hammer/.failed-build" 2>/dev/null || echo -; }
age() { perl -e 'utime(time - $ARGV[0] * 60, time - $ARGV[0] * 60, $ARGV[1])' "$1" "$2"; }   # age <minutes> <file>

# --- Scenarios

scenario_update() {
  echo "[an update]"
  B="$(commit "Lights: faster")"
  upd
  check '[ "$(app_version)" = "$B" ] && [ "$(running)" = "$B" ]' "the new version is installed and running"
  check 'happened "pkill -x Hammer (stopped $A)" && happened "open OK ($B) --login"' "the old one stopped, the new one opened with --login (no menu popping up)"
  check '[ "$(state)" = updated ] && [ "$(message)" = "Updated to $B" ] && [ "$(detail)" = "Lights: faster" ]' \
    "status: updated, with what's new (Hammer turns that into its notification)"
  check '[ ! -e "$HOME/Hammer/build/Hammer-previous.app" ] && [ ! -e "$HOME/Hammer/build/.swapping" ] && [ ! -e "$HOME/Hammer/.update.lock" ]' \
    "nothing left over: no app set aside, no swap marker, no lock"
  check '[ "$(times "swift5")" = 2 ]' "tests and app built with -swift-version 5"
  check '[ -s "$HOME/Applications/Hammer.app/Contents/Resources/Hammer.icns" ] && grep -q "<key>CFBundleIconFile</key><string>Hammer</string>" "$HOME/Applications/Hammer.app/Contents/Info.plist"' \
    "the app has its icon"
  check '[ "$(cat "$HOME/Applications/Hammer.app/Contents/Resources/VERSION-DATE")" = "$(git -C "$WORK/work" log -1 --date=short --format=%cd)" ]' \
    "and the day its version was made"
  check '[ -x "$HOME/Hammer/Hammer" ]' "the Terminal binary is in place"
  upd
  check '[ "$(state)" = current ] && [ "$(message)" = "Up to date" ] && [ "$(builds)" = 1 ]' "the next check: up to date, nothing rebuilt"
}

scenario_restart_loop() {
  echo "[1: git can't check out the update (a git still running, a full disk)]"
  B="$(commit B)"
  touch "$HOME/Hammer/repo/.git/index.lock"
  upd; upd
  check '[ "$(builds)" = 0 ] && [ "$(times pkill)" = 0 ] && [ "$(running)" = "$A" ]' \
    "no rebuild of the old commit, no restart, no \"updated\" (twice)"
  check '[ "$(state)" = retry ] && [ "$(failed_version)" = - ]' "says it'll try again, without blaming the version"
  age 20 "$HOME/Hammer/repo/.git/index.lock"
  upd
  check '[ "$(app_version)" = "$B" ] && said "removed a .git/index.lock"' \
    "an index.lock left for 20 minutes is cleared (and logged), and the update goes through"
}

scenario_swap_fails() {
  echo "[2: moving the new app into place fails]"
  B="$(commit B)"
  FAKE_MV_FAIL_STAGE=1 upd
  check '[ "$(app_version)" = "$A" ] && [ "$(running)" = "$A" ]' "the Hammer you had is back, and running"
  check '[ "$(failed_version)" = - ] && [ "$(state)" = retry ]' "not blocked as a bad version; tried again later"
  upd
  check '[ "$(builds)" = 1 ] && said "trying again later"' "not rebuilt every few minutes"
  upd --manual
  check '[ "$(app_version)" = "$B" ] && [ "$(running)" = "$B" ]' "Check for Updates tries again (and it works)"
}

scenario_killed_mid_swap() {
  echo "[2: killed mid-swap (SIGKILL at logout), then offline at the next login]"
  B="$(commit B)"
  FAKE_KILL_AT_APPS=KILL upd
  check 'exit_was 137 && [ "$(app_version)" = none ] && [ "$(running)" = nothing ]' "(set-up: no Hammer left at all)"
  mv "$WORK/origin.git" "$WORK/offline.git"
  upd
  check '[ "$(app_version)" = "$A" ] && [ "$(running)" = "$A" ] && happened "open OK ($A) --login"' \
    "the next run puts back the Hammer you had and starts it, offline"
  check '[ "$(state)" = offline ] && [ "$(message)" = "Can'"'"'t reach GitHub" ]' "then says it can't reach GitHub"
  mv "$WORK/offline.git" "$WORK/origin.git"
  upd
  check '[ "$(app_version)" = "$B" ] && [ "$(running)" = "$B" ]' "the killed run's lock blocks nothing: back online, it updates"
}

scenario_logout_mid_swap() {
  echo "[2: a logout (SIGTERM) mid-swap]"
  B="$(commit B)"
  FAKE_KILL_AT_APPS=TERM upd
  check '[ "$(app_version)" = "$A" ] && [ "$(running)" = "$A" ] && [ ! -e "$HOME/Hammer/build/.swapping" ]' \
    "the Hammer you had goes back at once, and runs"
  check '[ "$(failed_version)" = - ]' "not blocked as a bad version"
  upd
  check '[ "$(app_version)" = "$B" ]' "the next run updates"
}

scenario_lock() {
  echo "[2, 8: the update lock, and Check for Updates while an update runs]"
  B="$(commit B)"
  hold_lock 60
  touch "$HOME/Hammer/.manual-check"
  upd
  check '[ "$(builds)" = 0 ] && [ -e "$HOME/Hammer/.manual-check" ]' \
    "another update holds the lock: this one stops, and keeps the Check for Updates request"
  kill "${holders[0]}"; wait "${holders[0]}" 2>/dev/null
  upd
  check '[ "$(app_version)" = "$B" ] && [ ! -e "$HOME/Hammer/.manual-check" ] && [ ! -e "$HOME/Hammer/.update.lock" ]' \
    "a lock whose run has died is cleared; the request is handled, the lock let go"
  C="$(commit C)"
  mkdir -p "$HOME/Hammer/.update.lock"
  printf '%s\nMon Jan  1 00:00:00 2001\n' "$$" > "$HOME/Hammer/.update.lock/pid"
  upd
  check '[ "$(app_version)" = "$C" ]' "a lock naming a PID that's now another process (after a restart) is cleared too"
}

scenario_installer() {
  echo "[3: running install-hammer.sh again while an update runs]"
  B="$(commit B)"
  hold_lock 1
  FAKE_SLEEP_SCALE=0.05 FAKE_SWIFTC_HOOK='bash "$HOME/Hammer/repo/update.sh" >> "$FAKE/meanwhile.txt" 2>&1' install
  check 'exit_was 0 && said "Waiting for an update" && [ "$(app_version)" = "$B" ] && [ "$(running)" = "$B" ]' \
    "it waits for the update to finish, then installs"
  check '[ "$(builds)" = 1 ] && ! grep -q updating "$FAKE/meanwhile.txt"' \
    "updates that start meanwhile stop at once (it holds the lock): one build, nothing deleted under it"
  check '[ ! -e "$HOME/Hammer/.update.lock" ] && [ -f "$FAKE/loaded/local.hammer" ] && [ -f "$FAKE/loaded/local.hammer.updater" ]' \
    "then lets the lock go, with both login items on"
  check 'happened "brought the running Hammer $B forward$"' "and opens Hammer without --login, so its menu pops up"
  check '[ "$(state)" = current ]' "the menu says it's up to date"
}

scenario_fresh_install() {
  echo "[a first install]"
  rm -rf "$HOME/Hammer" "$HOME/Applications/Hammer.app"; rm -f "$FAKE/running"
  install
  check 'exit_was 0 && [ "$(app_version)" = "$A" ] && [ "$(running)" = "$A" ]' "installs Hammer and starts it"
  check '[ -x "$HOME/Hammer/bin/Hammer" ] && [ -f "$FAKE/loaded/local.hammer.updater" ]' "with its login items"
  rm -rf "$HOME/Hammer" "$HOME/Applications/Hammer.app"; rm -f "$FAKE/running"
  FAKE_CLT_BROKEN=1 install
  check 'exit_was 0 && happened "xcode-select --install" && [ "$(app_version)" = none ]' \
    "command-line tools broken: asks to reinstall them first"
}

scenario_crash_at_launch() {
  echo "[4: the new version opens, but doesn't stay up]"
  B="$(commit B)"
  FAKE_CRASH_VERSION="$B" upd
  check '[ "$(app_version)" = "$A" ] && [ "$(running)" = "$A" ] && said "didn.t finish starting"' \
    "it never says it has started: the Hammer you had is back, and running"
  check '[ "$(failed_version)" = "$B" ] && [ "$(state)" = failed ] && [ "$(message)" = "Update didn'"'"'t open" ]' \
    "that version is marked as failed"
  C="$(commit C)"
  FAKE_OPEN_FAIL_VERSION="$C" upd
  check '[ "$(app_version)" = "$A" ] && [ "$(running)" = "$A" ] && [ "$(failed_version)" = "$C" ]' \
    "macOS refuses to open it: the same"
}

scenario_open_during_swap() {
  echo "[4: the login item opens the old Hammer just as it's swapped]"
  B="$(commit B)"
  FAKE_OPEN_DURING_SWAP=1 upd
  check 'happened "login item opens Hammer mid-swap" && [ "$(running)" = "$B" ] && [ "$(state)" = updated ]' \
    "the old copy is stopped again right before opening, so the new one really starts"
}

scenario_mac_problems() {
  echo "[5: problems with the Mac, not the update]"
  B="$(commit B)"
  FAKE_CLT_BROKEN=1 upd
  check '[ "$(state)" = retry ] && [[ "$(detail)" == *"xcode-select --install"* ]]' \
    "command-line tools broken by a macOS upgrade: says how to fix them (not \"check your internet\")"
  check '[ "$(builds)" = 0 ] && [ "$(failed_version)" = - ] && [ "$(git -C "$HOME/Hammer/repo" rev-parse --short origin/main)" = "$A" ]' \
    "…runs no git, builds nothing, blames no version"
  FAKE_NO_CLT=1 upd
  check '[ "$(state)" = retry ] && [[ "$(detail)" == *"xcode-select --install"* ]]' "the tools removed: the same"
  FAKE_FREE_KB=200000 upd
  check '[ "$(state)" = retry ] && [[ "$(message)" == *"almost full"* ]] && [ "$(builds)" = 0 ]' \
    "almost out of space: says so, builds nothing"
  FAKE_MINOS=28.0 upd
  check '[ "$(app_version)" = "$A" ] && [ "$(running)" = "$A" ] && [ "$(failed_version)" = - ] && [ "$(state)" = retry ]' \
    "tools that build for a newer macOS (the minos check): not blamed on the version"
  upd
  check '[ "$(builds)" = 1 ] && said "trying again later"' "…and not rebuilt every 5 minutes"
  upd --manual
  check '[ "$(app_version)" = "$B" ]' "Check for Updates tries again at once"
  C="$(commit C)"
  FAKE_SWIFTC_FAIL=1 FAKE_SWIFTC_HOOK='echo 100 > "$FAKE/free-kb"' upd
  rm -f "$FAKE/free-kb"
  check '[ "$(failed_version)" = - ] && [ "$(state)" = retry ] && [[ "$(message)" == *"almost full"* ]]' \
    "the disk fills up during the build: also not blamed on the version"
  D="$(commit D)"
  : > "$FAKE_LOG"
  sed -i.bak 's|<string>local.hammer</string>|<string>com.example.other</string>|' "$HOME/Applications/Hammer.app/Contents/Info.plist"
  upd
  check '[ "$(state)" = retry ] && [[ "$(detail)" == *"different app"* ]] && [ "$(builds)" = 0 ] && [ "$(times pkill)" = 0 ]' \
    "another app at ~/Applications/Hammer.app: left alone, and says so"
}

scenario_hangs() {
  echo "[5: a step that hangs]"
  B="$(commit B)"
  HAMMER_TESTS_LIMIT=1 FAKE_TESTS_HANG=1 upd
  check '[ "$elapsed" -lt 15 ] && [ "$(state)" = failed ] && [ "$(app_version)" = "$A" ] && [ "$(running)" = "$A" ]' \
    "tests that never finish are stopped after their time limit; the current Hammer keeps running"
  check 'said "didn.t finish within"' "…and the log says why"
  HAMMER_SIGN_LIMIT=1 FAKE_CODESIGN_SLEEP=30 upd --manual
  check '[ "$elapsed" -lt 15 ] && [ "$(app_version)" = "$B" ]' "codesign hanging is stopped too, and the update still installs"
}

scenario_login_items() {
  echo "[6: the login items]"
  bash "$HOME/Hammer/repo/agents.sh" > "$WORK/out.txt" 2>&1
  check '[ $? = 0 ] && [ -f "$FAKE/loaded/local.hammer" ] && [ -f "$FAKE/loaded/local.hammer.updater" ]' "both set up and on"
  check '[ -x "$HOME/Hammer/bin/Hammer" ] && [ -x "$HOME/Hammer/bin/Hammer Updates" ]' \
    "they run scripts named Hammer and Hammer Updates (the names Login Items shows)"
  check 'grep -q "<string>$HOME/Hammer/bin/Hammer Updates</string>" "$HOME/Library/LaunchAgents/local.hammer.updater.plist" && ! grep -qE "/bin/bash|/usr/bin/open" "$HOME/Library/LaunchAgents/"*.plist' \
    "not bash or open"
  if command -v plutil >/dev/null 2>&1; then
    check 'plutil -lint "$HOME/Library/LaunchAgents/local.hammer.plist" "$HOME/Library/LaunchAgents/local.hammer.updater.plist" >/dev/null' \
      "valid property lists (plutil)"
  fi
  : > "$FAKE_LOG"
  bash "$HOME/Hammer/repo/agents.sh" >/dev/null 2>&1
  check '! happened bootout && ! happened bootstrap' "set up again with nothing changed: nothing restarted"
  bash "$HOME/Hammer/repo/agents.sh" --files >/dev/null 2>&1
  check '! happened bootout && ! happened bootstrap' "--files: no launchctl"
  rm -f "$FAKE/running"; : > "$FAKE_LOG"
  "$HOME/Hammer/bin/Hammer"
  check '[ "$(running)" = "$A" ] && happened "open OK ($A) --login"' "Hammer (at login) opens Hammer, quietly"
  : > "$FAKE_LOG"
  "$HOME/Hammer/bin/Hammer"
  check '[ ! -s "$FAKE_LOG" ]' "…and does nothing if it's already running"
  rm -f "$HOME/Hammer/update-status"
  "$HOME/Hammer/bin/Hammer Updates" >/dev/null 2>&1
  check '[ "$(state)" = current ]' "Hammer Updates runs update.sh"
  mkdir -p "$FAKE/btm-off" && touch "$FAKE/btm-off/local.hammer.updater" && rm -f "$FAKE/loaded/local.hammer.updater"
  bash "$HOME/Hammer/repo/agents.sh" > "$WORK/out.txt" 2>&1
  check '[ $? = 1 ] && said "Updates are off"' "switched off in Login Items: it says so (and Hammer shows where to turn it on)"
}

scenario_login_items_move() {
  echo "[6: an install from before, whose login items run bash and open]"
  mkdir -p "$HOME/Library/LaunchAgents"
  printf '<plist><dict><key>Label</key><string>local.hammer.updater</string><key>ProgramArguments</key><array><string>/bin/bash</string><string>%s</string></array></dict></plist>\n' \
    "$HOME/Hammer/repo/update.sh" > "$HOME/Library/LaunchAgents/local.hammer.updater.plist"
  B="$(commit B)"
  upd
  check 'grep -q "Hammer Updates" "$HOME/Library/LaunchAgents/local.hammer.updater.plist" && [ -x "$HOME/Hammer/bin/Hammer Updates" ]' \
    "update.sh moves them to the named scripts"
  check '! happened bootout && ! happened bootstrap && [ "$(app_version)" = "$B" ]' \
    "without restarting itself (they take effect at the next login), and still updates"
}

scenario_cli_binary() {
  echo "[8: the Terminal binary ~/Hammer/Hammer]"
  local before after
  before="$(ls -i "$HOME/Hammer/Hammer" | awk '{ print $1 }')"
  B="$(commit B)"
  upd
  after="$(ls -i "$HOME/Hammer/Hammer" | awk '{ print $1 }')"
  check '[ -n "$before" ] && [ "$before" != "$after" ]' "replaced by a new file, not overwritten in place"
  C="$(commit C)"
  FAKE_CP_FAIL_CLI=1 upd
  check '[ "$(state)" = updated ] && [ "$(app_version)" = "$C" ] && said "Couldn.t update ~/Hammer/Hammer"' \
    "copying it fails: the update still counts"
}

scenario_local_edits() {
  echo "[8: edits made in ~/Hammer/repo]"
  echo "# my tweak" >> "$HOME/Hammer/repo/signing.sh"
  B="$(commit B)"
  upd
  check 'said "replacing local edits in .*signing.sh" && [ "$(app_version)" = "$B" ]' "replaced by the update, and the log says which"
}

scenario_signing_logout() {
  echo "[8: a logout while signing]"
  if ! command -v python3 >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
    echo "  skip (needs python3 and openssl)"; return
  fi
  export FAKE_STATE="$WORK/signing"
  mkdir -p "$FAKE_STATE"
  printf '%s\n' "$HOME/Library/Keychains/login.keychain-db" > "$FAKE_STATE/search-list"
  B="$(commit B)"
  HAMMER_SECURITY="$REPO/Tests/Signing/fake_security.py" HAMMER_OPENSSL="$(command -v openssl)" FAKE_CODESIGN_TERM=1 upd
  check 'happened "SIGTERM to the update" && ! grep -q hammer-signing "$FAKE_STATE/search-list"' \
    "the signing keychain is taken off your keychain list"
  check '[ "$(app_version)" = "$A" ] && [ "$(running)" = "$A" ]' "and the Hammer you had is untouched, running"
  unset FAKE_STATE
}

scenario_busy() {
  echo "[10: Hammer is busy (a dialog, or YouTube)]"
  B="$(commit B)"
  busy_hammer 2
  FAKE_SLEEP_SCALE=0.05 upd
  check 'said "waits until you.re done" && [ "$elapsed" -ge 2 ] && [ "$(app_version)" = "$B" ] && [ "$(running)" = "$B" ]' \
    "the update is built, waits until you're done, then installs"
  C="$(commit C)"
  busy_hammer 300
  upd
  check '[ "$(app_version)" = "$C" ]' "still busy after 30 minutes: it installs anyway"
  D="$(commit D)"
  printf '999999\nYouTube\n' > "$HOME/Hammer/.busy"
  upd
  check '! said "waits until" && [ "$(app_version)" = "$D" ]' "a note left by a Hammer that has quit is ignored"
}

scenario_no_icon() {
  echo "[11: the icon can't be made]"
  B="$(commit B)"
  FAKE_ICON_FAIL=1 upd
  check '[ "$(app_version)" = "$B" ] && [ ! -e "$HOME/Applications/Hammer.app/Contents/Resources/Hammer.icns" ] && ! grep -q CFBundleIconFile "$HOME/Applications/Hammer.app/Contents/Info.plist"' \
    "Hammer draws no icon: built without one"
  C="$(commit C)"
  FAKE_ICONUTIL_FAIL=1 upd
  check '[ "$(app_version)" = "$C" ] && ! grep -q CFBundleIconFile "$HOME/Applications/Hammer.app/Contents/Info.plist"' \
    "iconutil fails: the same"
}

scenario_bad_version() {
  echo "[working as before: a version that doesn't build]"
  B="$(commit B)"
  FAKE_SWIFTC_FAIL=1 upd
  check '[ "$(failed_version)" = "$B" ] && [ "$(state)" = failed ] && [ "$(times pkill)" = 0 ] && [ "$(running)" = "$A" ]' \
    "marked as failed; the current Hammer was never touched"
  upd
  check 'said "failed before" && [ "$(times "swiftc -> hammer-tests")" = 1 ]' "not retried every few minutes"
  FAKE_TESTS_EXIT=1 upd --manual
  check '[ "$(failed_version)" = "$B" ] && [ "$(app_version)" = "$A" ]' "a failing test stops it too"
  upd --manual
  check '[ "$(app_version)" = "$B" ] && [ "$(failed_version)" = - ]' "Check for Updates retries it"
}

all=(update restart_loop swap_fails killed_mid_swap logout_mid_swap lock installer fresh_install crash_at_launch
     open_during_swap mac_problems hangs login_items login_items_move cli_binary local_edits signing_logout busy
     no_icon bad_version)
chosen=("$@")
[ ${#chosen[@]} -gt 0 ] || chosen=("${all[@]}")
for name in "${chosen[@]}"; do
  name="${name//-/_}"
  if ! declare -F "scenario_$name" >/dev/null; then echo "No scenario $name. There are: ${all[*]//_/-}"; exit 2; fi
  reset_world
  scenario="$name"
  elapsed=""
  "scenario_$name"
done

echo "[nothing used osascript (Hammer posts the notifications)]"
check '[ ! -s "$FAKE_OSASCRIPT" ]' "no osascript"

echo
printf '%s' "$failures"
if [ "$failed" = 0 ]; then echo "All $passed update checks passed."; else echo "$failed of $((passed + failed)) update checks FAILED."; fi
exit $((failed > 0))
