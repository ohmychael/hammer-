#!/usr/bin/env python3
# Stand-in for macOS's /usr/bin/security, for the watcher test: generic passwords
# kept in the JSON file named by $FAKE_KEYCHAIN. Handles the commands Hammer uses,
# including "security -i" reading commands from standard input.
import json, os, sys, shlex
STORE = os.environ["FAKE_KEYCHAIN"]
def load():
    try: return json.load(open(STORE))
    except Exception: return {}
def save(d): json.dump(d, open(STORE, "w"))
def opts(args):
    o = {}; i = 0
    while i < len(args):
        if args[i].startswith("-") and i + 1 < len(args) and not args[i+1].startswith("-"): o[args[i]] = args[i+1]; i += 2
        else: o[args[i]] = True; i += 1
    return o
def do(args):
    cmd, o = args[0], opts(args[1:])
    d = load(); key = o.get("-s", "") + "|" + o.get("-a", "")
    if cmd == "add-generic-password":
        if key in d and "-U" not in o: return 45
        d[key] = o["-w"]; save(d); return 0
    if cmd == "find-generic-password":
        if key not in d: return 44
        print(d[key]); return 0
    if cmd == "delete-generic-password":
        if key not in d: return 44
        del d[key]; save(d); return 0
    return 1
args = sys.argv[1:]
if args == ["-i"]:
    for line in sys.stdin:
        if line.strip(): do(shlex.split(line))
    sys.exit(0)
sys.exit(do(args))
