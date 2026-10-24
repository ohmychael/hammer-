#!/bin/bash
# Runs the Bluetooth scenarios against GoveeBluetooth exactly as it is in Hammer.swift,
# using the stand-in CoreBluetooth in this folder. Needs Linux with Swift 5.9 or later
# (macOS's real CoreBluetooth would get in the way). Takes about 2 minutes, because the
# scenarios run in real time; they run side by side.
#   Tests/Bluetooth/run.sh              all scenarios
#   Tests/Bluetooth/run.sh phone storm  just these
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SWIFTC="${SWIFTC:-$(command -v swiftc)}"
[ -x "$SWIFTC" ] || { echo "swiftc not found (set SWIFTC=/path/to/swiftc)"; exit 1; }
RUNTIME="$(dirname "$(dirname "$SWIFTC")")/lib/swift/linux"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. The stand-in CoreBluetooth module.
mkdir -p "$WORK/mod"
"$SWIFTC" -emit-module -emit-library -module-name CoreBluetooth -parse-as-library \
  "$HERE/CoreBluetooth.swift" -emit-module-path "$WORK/mod/CoreBluetooth.swiftmodule" \
  -o "$WORK/mod/libCoreBluetooth.so" || exit 1

# 2. GoveeBluetooth, copied out of Hammer.swift unchanged except that Bluetooth
#    counts as available (the app checks its Info.plist). GoveeLight is in HammerCore.swift.
python3 - "$REPO/Hammer.swift" "$WORK/GB.swift" <<'PY' || exit 1
import sys
src = open(sys.argv[1]).read()
start = src.index('final class GoveeBluetooth')
end = src.index('\n}\n', start) + 3
cls = src[start:end]
check = 'Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil'
assert cls.count(check) == 1, "GoveeBluetooth.isAvailable changed; update run.sh"
cls = cls.replace(check, 'true')
open(sys.argv[2], 'w').write('import Foundation\nimport CoreBluetooth\n\n' + cls)
PY

# 3. Build and run.
"$SWIFTC" -I "$WORK/mod" -L "$WORK/mod" -lCoreBluetooth \
  "$REPO/HammerCore.swift" "$WORK/GB.swift" "$HERE/main.swift" -o "$WORK/scenarios" || exit 1
ALL="phone phone-long restart-busy first-run storm short-links discovery-once discovery-always
     discovery-hangs incompatible no-service busy-link slider reset bluetooth-off remove
     remove-connected neighbor blink echo steady two-bulbs silent first-drop dying-link
     delivered-then-drop blink-thrice launch-send reset-keeps alarm-phone gave-up limit
     blink-restores rescan-twice forget"
LIST="${*:-$ALL}"
mkdir -p "$WORK/out"
for s in $LIST; do
  (
    home="$(mktemp -d -p "$WORK")"          # each scenario gets its own saved settings
    HOME="$home" XDG_CONFIG_HOME="$home" LD_LIBRARY_PATH="$RUNTIME:$WORK/mod" \
      "$WORK/scenarios" "$s" > "$WORK/out/$s.txt" 2>&1
    echo $? > "$WORK/out/$s.code"
  ) &
done
wait
failed=0
for s in $LIST; do
  cat "$WORK/out/$s.txt"
  [ "$(cat "$WORK/out/$s.code")" = 0 ] || failed=$((failed + 1))
done
echo "$(echo $LIST | wc -w | tr -d ' ') scenarios, $failed failed"
[ "$failed" = 0 ]
