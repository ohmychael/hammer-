#!/bin/bash
# install-hammer.sh — one-time setup. Installs Hammer from GitHub, starts it,
# opens it at login, and keeps it updated automatically from then on.
#
#   curl -fsSL https://raw.githubusercontent.com/ohmychael/hammer-/main/install-hammer.sh | bash
#
# Safe to run again; it just reinstalls the latest version.

set -euo pipefail
trap 'echo; echo "Something went wrong above. Copy everything in this window and paste it to Claude."' ERR

REPO_URL="https://github.com/ohmychael/hammer-.git"
DIR="$HOME/Hammer/repo"
AGENTS="$HOME/Library/LaunchAgents"
UID_NUM="$(id -u)"

step() { printf '\n==> %s\n' "$1"; }

# 1. Apple's command-line developer tools provide git and the Swift compiler.
if ! xcode-select -p >/dev/null 2>&1; then
  step "Installing Apple's command-line developer tools"
  xcode-select --install 2>/dev/null || true
  echo "Click Install in the window that just opened. When it finishes, run this same command again."
  exit 0
fi

# 2. Get the code (or bring an existing copy up to date).
step "Downloading Hammer"
mkdir -p "$HOME/Hammer"
if [ -d "$DIR/.git" ]; then
  git -C "$DIR" fetch --quiet origin main
  git -C "$DIR" reset --hard --quiet origin/main
else
  rm -rf "$DIR"
  git clone --quiet "$REPO_URL" "$DIR"
fi

# 3. Build and install the app.
step "Building Hammer"
bash "$DIR/build.sh"

# 4. Open Hammer at login.
step "Setting Hammer to open when you log in"
mkdir -p "$AGENTS"
cat > "$AGENTS/local.hammer.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.hammer</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/open</string><string>$HOME/Applications/Hammer.app</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST

# 5. Check for updates at login and every hour.
step "Turning on automatic updates"
cat > "$AGENTS/local.hammer.updater.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.hammer.updater</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$DIR/update.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>3600</integer>
  <key>StandardOutPath</key><string>$HOME/Hammer/update.log</string>
  <key>StandardErrorPath</key><string>$HOME/Hammer/update.log</string>
</dict>
</plist>
PLIST
launchctl bootout "gui/$UID_NUM/local.hammer.updater" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$AGENTS/local.hammer.updater.plist" 2>/dev/null || true

# 6. Pop the menu up next to the pointer so you can see it worked.
sleep 2
open "$HOME/Applications/Hammer.app"

echo
echo "Done. Hammer is running and will update itself from now on."
echo "Open its menu any time with Control-Option-H."
