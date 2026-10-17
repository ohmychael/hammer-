#!/usr/bin/env python3
"""Stand-in for macOS's /usr/bin/security, for testing signing.sh: keychains are
JSON files, and the user keychain search list lives in $FAKE_STATE/search-list."""
import json, os, sys
STATE = os.environ["FAKE_STATE"]
LIST = os.path.join(STATE, "search-list")
with open(os.path.join(STATE, "security-log"), "a") as log:
    log.write(" ".join(a if not a.startswith("pass") else "…" for a in sys.argv[1:]) + "\n")

def read_list():
    return [l for l in open(LIST).read().split("\n") if l] if os.path.exists(LIST) else []

def keychain(path):
    return json.load(open(path)) if os.path.exists(path) else None

args = sys.argv[1:]
cmd = args[0]
def opt(flag):
    return args[args.index(flag) + 1] if flag in args else None

if cmd == "list-keychains":
    if "-s" in args:
        open(LIST, "w").write("\n".join(args[args.index("-s") + 1:]) + "\n")
    else:
        for path in read_list():
            print(f'    "{path}"')
elif cmd == "create-keychain":
    path = args[-1]
    if os.path.exists(path): sys.exit(48)
    json.dump({"password": opt("-p"), "imported": False, "partition": False}, open(path, "w"))
    entries = read_list() + [path]                                   # like macOS: added to the search list
    open(LIST, "w").write("\n".join(entries) + "\n")
elif cmd == "delete-keychain":
    path = args[-1]
    if not os.path.exists(path): sys.exit(50)
    os.remove(path)
    remaining = [p for p in read_list() if p != path]               # read before rewriting
    open(LIST, "w").write("".join(p + "\n" for p in remaining))
elif cmd == "set-keychain-settings":
    sys.exit(0 if keychain(args[-1]) else 50)
elif cmd == "unlock-keychain":
    kc = keychain(args[-1])
    sys.exit(0 if kc and kc["password"] == opt("-p") else 51)
elif cmd == "import":
    kc_path = opt("-k"); kc = keychain(kc_path)
    if not kc or not os.path.exists(args[1]) or opt("-T") is None: sys.exit(1)
    kc["imported"] = True
    kc["p12"] = open(args[1], "rb").read().hex()
    kc["p12pass"] = opt("-P")
    json.dump(kc, open(kc_path, "w"))
elif cmd == "set-key-partition-list":
    kc_path = args[-1]; kc = keychain(kc_path)
    if not kc or kc["password"] != opt("-k"): sys.exit(1)
    kc["partition"] = True
    json.dump(kc, open(kc_path, "w"))
else:
    sys.exit(2)
