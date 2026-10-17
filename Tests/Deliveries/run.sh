#!/bin/bash
# Tests for delivery alerts, end to end. Needs Swift 5.9+ and python3; runs on Linux
# (or a Mac). Takes about 15 seconds.
#  1. checker: Deliveries.swift's IMAP code over a real socket to fake_gmail.py
#     (new mail, read flags untouched, wrong password, no server, silent server).
#  2. watcher: DeliveryAlerts.swift's DeliveryWatcher run for real, with stand-ins
#     for Apple's frameworks (AppleStandIns.swift) and the Keychain tool
#     (fake_security.py). Hammer.swift's Deliveries menu code is type-checked too.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SWIFTC="${SWIFTC:-$(command -v swiftc)}"
[ -x "$SWIFTC" ] || { echo "swiftc not found (set SWIFTC=/path/to/swiftc)"; exit 1; }
RUNTIME="$(dirname "$(dirname "$SWIFTC")")/lib/swift/linux"
WORK="$(mktemp -d)"
cleanup() { kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# The Mac-only code, with what Linux lacks taken out: framework imports, @objc,
# and #selector (the stand-ins provide the rest).
python3 - "$REPO" "$WORK" <<'PY' || exit 1
import re, sys
repo, work = sys.argv[1], sys.argv[2]
def linuxify(text):
    for name in ("AppKit", "Network", "UserNotifications"):
        text = text.replace(f"import {name}\n", "")
    text = text.replace("@objc ", "")
    return re.sub(r"#selector\(\w+(\(_:\))?\)", 'Selector("x")', text)
alerts = open(f"{repo}/DeliveryAlerts.swift").read()
open(f"{work}/Alerts.swift", "w").write("import Foundation\n" + linuxify(alerts))
app = open(f"{repo}/Hammer.swift").read()
start = app.index("    // MARK: Deliveries (see DeliveryAlerts.swift")
end = app.index("    // MARK: Light modes (for the checkmarks)")
open(f"{work}/Menu.swift", "w").write('''import Foundation
@MainActor final class MenuShell {
    private func label(_ t: String) -> NSMenuItem { NSMenuItem(title: t, action: nil, keyEquivalent: "") }
    private func hint(_ t: String) -> NSMenuItem { label(t) }
    private func action(_ t: String, _ s: Selector, lightID: String? = nil) -> NSMenuItem {
        NSMenuItem(title: t, action: s, keyEquivalent: "") }
    private func clockTime(_ d: Date) -> String { "" }
    private func rebuildMenuSoon() {}
''' + linuxify(app[start:end]) + "}\n")
PY

echo "Building..."
"$SWIFTC" -O "$REPO/HammerCore.swift" "$REPO/Deliveries.swift" "$HERE/SocketTransport.swift" \
  "$HERE/checker/main.swift" -o "$WORK/checker" || exit 1
mkdir -p "$WORK/w" && cp "$HERE/watcher/main.swift" "$WORK/w/main.swift"
"$SWIFTC" "$HERE/AppleStandIns.swift" "$REPO/HammerCore.swift" "$REPO/Deliveries.swift" "$WORK/Alerts.swift" \
  "$WORK/Menu.swift" "$HERE/SocketTransport.swift" "$WORK/w/main.swift" -o "$WORK/watcher" || exit 1

PORT=$((20000 + RANDOM % 20000)); DEAD=$((PORT + 1)); SILENT=$((PORT + 2)); PORT2=$((PORT + 3))
echo '{"password": "abcdefghijklmnop", "uidvalidity": 7, "messages": []}' > "$WORK/box.json"
echo '{"password": "abcdefghijklmnop", "uidvalidity": 3, "messages": [{"uid": 100, "headers": "From: a@b.com\r\nSubject: Your package was delivered\r\n"}]}' > "$WORK/box2.json"
python3 "$HERE/fake_gmail.py" "$PORT" "$WORK/box.json" "$WORK/log.txt" &
python3 "$HERE/fake_gmail.py" "$PORT2" "$WORK/box2.json" "$WORK/log2.txt" &
python3 -c "
import socket
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $SILENT)); s.listen(5)
held = []
while True:
    c, _ = s.accept(); held.append(c)      # accept, then never say anything
" &
sleep 1

failed=0
echo "== checker"
LD_LIBRARY_PATH="$RUNTIME" "$WORK/checker" "$PORT" "$WORK/box.json" "$WORK/log.txt" "$DEAD" "$SILENT" || failed=1
echo "== watcher"
HOME="$WORK" XDG_CONFIG_HOME="$WORK" FAKE_KEYCHAIN="$WORK/keychain.json" LD_LIBRARY_PATH="$RUNTIME" \
  "$WORK/watcher" "$PORT2" "$WORK/box2.json" "$HERE/fake_security.py" || failed=1
[ "$failed" = 0 ] && echo "All delivery tests passed." || echo "Delivery tests FAILED."
exit $failed
