#!/usr/bin/env python3
"""Stand-in for /usr/bin/codesign: signing with "Hammer Local Signing" works only
from a keychain on the search list that has the identity imported with codesign
allowed; ad hoc always works. FAKE_REFUSE=1 makes certificate signing fail, and
FAKE_VERIFY_FAIL=1 makes --verify fail."""
import json, os, sys
args = sys.argv[1:]
STATE = os.environ["FAKE_STATE"]
with open(os.path.join(STATE, "codesign-log"), "a") as log:
    log.write(" ".join(args) + "\n")
app = args[-1]
record = os.path.join(app, "signature")
if "--verify" in args:
    if os.environ.get("FAKE_VERIFY_FAIL") == "1": sys.exit(1)
    sys.exit(0 if os.path.exists(record) else 1)
name = args[args.index("--sign") + 1]
if name == "-":
    open(record, "w").write("adhoc")
    sys.exit(0)
if os.environ.get("FAKE_REFUSE") == "1": sys.exit(1)
kc_path = args[args.index("--keychain") + 1]
# Like the real codesign: --keychain only narrows the search, so the keychain has
# to be on the user's search list too.
listed = open(os.path.join(STATE, "search-list")).read().split("\n")
if kc_path not in listed: sys.exit(1)
kc = json.load(open(kc_path))
if not (kc["imported"] and kc["partition"]): sys.exit(1)
open(os.path.join(STATE, "signed-while-listed"), "w").write("yes")
open(record, "w").write("certificate")
