#!/bin/bash
# install-hammer.sh — one-time setup. Installs Hammer from GitHub, starts it,
# opens it at login, and keeps it updated automatically from then on.
#
#   curl -fsSL https://raw.githubusercontent.com/ohmychael/hammer-/main/install-hammer.sh | bash
#
# Safe to run again; it just reinstalls the latest version.

set -euo pipefail
trap 'echo; echo "Something went wrong above. Copy everything in this window and paste it to Claude."' ERR

REPO_URL="${HAMMER_REPO_URL:-https://github.com/ohmychael/hammer-.git}"   # tests use a local copy
DIR="$HOME/Hammer/repo"
LOCK="$HOME/Hammer/.update.lock"       # shared with update.sh: one install or update at a time

step() { printf '\n==> %s\n' "$1"; }

# 1. Apple's command-line developer tools provide git and the Swift compiler.
if ! xcode-select -p >/dev/null 2>&1; then
  step "Installing Apple's command-line developer tools"
  xcode-select --install 2>/dev/null || true
  echo "Click Install in the window that just opened. When it finishes, run this same command again."
  exit 0
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  step "Apple's command-line developer tools need reinstalling (this happens after some macOS updates)"
  xcode-select --install 2>/dev/null || true
  echo "Click Install in the window that just opened. When it finishes, run this same command again."
  exit 0
fi

# 2. Wait for an update that's running to finish, then keep updates off until this is done.
mkdir -p "$HOME/Hammer"
holder_alive() {
  local pid started
  pid="$(sed -n 1p "$LOCK/pid" 2>/dev/null)"
  started="$(sed -n 2p "$LOCK/pid" 2>/dev/null)"
  if [ -z "$pid" ]; then [ -n "$(find "$LOCK" -maxdepth 0 -mmin -1 2>/dev/null)" ]; return; fi
  kill -0 "$pid" 2>/dev/null && [ "$(ps -o lstart= -p "$pid" 2>/dev/null)" = "$started" ]
}
waited=0
until mkdir "$LOCK" 2>/dev/null; do
  if ! holder_alive; then rm -rf "$LOCK"; continue; fi
  if [ "$waited" = 0 ]; then step "Waiting for an update that's running to finish"; fi
  if [ "$waited" -ge 3600 ]; then echo "It's still running after an hour. Restart your Mac, then try again."; exit 1; fi
  sleep 5
  waited=$((waited + 5))
done
printf '%s\n%s\n' "$$" "$(ps -o lstart= -p $$)" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

# 3. Get the code (or bring an existing copy up to date).
step "Downloading Hammer"
if [ -d "$DIR/.git" ]; then
  if [ -n "$(find "$DIR/.git/index.lock" -mmin +10 2>/dev/null)" ]; then rm -f "$DIR/.git/index.lock"; fi
  git -C "$DIR" fetch --quiet origin main
  git -C "$DIR" reset --hard --quiet origin/main
else
  rm -rf "$DIR"
  git clone --quiet "$REPO_URL" "$DIR"
fi

# 4. Build and install the app.
step "Building Hammer"
bash "$DIR/build.sh"
rm -f "$HOME/Hammer/.failed-build"

# 5. Open Hammer at login, and check for updates at login and every 5 minutes
# (Hammer also asks every 2 minutes). In Login Items these are "Hammer" and "Hammer Updates".
step "Setting Hammer to open when you log in, and to update itself"
bash "$DIR/agents.sh" || echo "Turn them on in System Settings → General → Login Items (Allow in the Background)."
printf 'state=current\ntime=%s\nmessage=Up to date\ndetail=\n' "$(date +%s)" > "$HOME/Hammer/update-status"

# 6. Pop the menu up next to the pointer so you can see it worked.
open "$HOME/Applications/Hammer.app"

echo
echo "Done. Hammer is running and will update itself from now on."
echo "Open its menu any time with Control-Option-H."
