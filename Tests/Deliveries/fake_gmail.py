#!/usr/bin/env python3
"""A small stand-in for Gmail's IMAP server, for testing Hammer's delivery alerts.

It speaks enough IMAP for what Hammer sends through curl: CAPABILITY, LOGIN,
AUTHENTICATE PLAIN, SELECT/EXAMINE, STATUS, UID SEARCH (a UID range plus Gmail's
X-GM-RAW "subject:(...)"), UID FETCH of header fields, NOOP and LOGOUT.

    fake_gmail.py PORT MAILBOX.json LOG.txt

MAILBOX.json: {"password": "...", "uidvalidity": 1, "messages": [{"uid": 5,
"headers": "From: ...\\r\\nSubject: ...\\r\\n"}]}. It is re-read on every
connection, so a test can add mail between checks. Every command is appended to
LOG.txt, and any fetch that would mark a message as read is logged as "SEEN-SET".
"""
import asyncio, base64, email.header, json, re, shlex, sys

PORT, MAILBOX, LOG = int(sys.argv[1]), sys.argv[2], sys.argv[3]
CAPS = ("IMAP4rev1 UNSELECT IDLE NAMESPACE QUOTA ID XLIST CHILDREN X-GM-EXT-1 UIDPLUS "
        "ENABLE MOVE CONDSTORE ESEARCH UTF8=ACCEPT LITERAL- SPECIAL-USE AUTH=XOAUTH2 AUTH=PLAIN SASL-IR")


def log(line):
    with open(LOG, "a") as f:
        f.write(line + "\n")


def load():
    with open(MAILBOX) as f:
        return json.load(f)


def uid_set(spec, uids):
    """'3', '3:7', '3:*', '1,4,9' -> the matching UIDs that exist."""
    top = max(uids) if uids else 0
    wanted = set()
    for part in spec.split(","):
        if ":" in part:
            a, b = part.split(":")
            a = top if a == "*" else int(a)
            b = top if b == "*" else int(b)
            lo, hi = min(a, b), max(a, b)
            wanted |= {u for u in uids if lo <= u <= hi}
        else:
            n = top if part == "*" else int(part)
            if n in uids:
                wanted.add(n)
    return sorted(wanted)


def subject_of(headers):
    """The decoded subject, the way Gmail's search sees it."""
    m = re.search(r"^Subject:(.*(?:\r?\n[ \t].*)*)", headers, re.I | re.M)
    if not m:
        return ""
    raw = re.sub(r"\r?\n[ \t]+", " ", m.group(1)).strip()
    return str(email.header.make_header(email.header.decode_header(raw)))


async def handle(reader, writer):
    box = load()
    authed = False
    selected = False

    async def send(text):
        writer.write(text.encode() if isinstance(text, str) else text)
        await writer.drain()

    await send("* OK Gimap ready for requests from 127.0.0.1\r\n")
    while True:
        raw = await reader.readline()
        if not raw:
            break
        line = raw.decode(errors="replace").rstrip("\r\n")
        log(line if "AUTHENTICATE" not in line and "LOGIN" not in line.upper() else line.split(" ")[0] + " <login>")
        parts = line.split(" ", 2)
        if len(parts) < 2:
            await send("* BAD bad command\r\n")
            continue
        tag, cmd = parts[0], parts[1].upper()
        rest = parts[2] if len(parts) > 2 else ""

        if cmd == "CAPABILITY":
            await send(f"* CAPABILITY {CAPS}\r\n{tag} OK Thats all she wrote!\r\n")
        elif cmd == "LOGIN":
            m = re.match(r'"?([^" ]+)"? "?([^"]*)"?', rest)
            ok = m and m.group(2) == box["password"]
            if ok:
                authed = True
                await send(f"{tag} OK user authenticated (Success)\r\n")
            else:
                await send(f"{tag} NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n")
        elif cmd == "AUTHENTICATE":
            args = rest.split(" ")
            if args[0].upper() != "PLAIN":
                await send(f"{tag} NO unsupported mechanism\r\n")
                continue
            if len(args) > 1:
                blob = args[1]
            else:
                await send("+ \r\n")
                blob = (await reader.readline()).decode().strip()
            try:
                _, user, password = base64.b64decode(blob).decode().split("\x00")
            except Exception:
                await send(f"{tag} BAD invalid SASL\r\n")
                continue
            if password == box["password"]:
                authed = True
                await send(f"{tag} OK {user} authenticated (Success)\r\n")
            else:
                await send(f"{tag} NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n")
        elif cmd in ("SELECT", "EXAMINE"):
            if not authed:
                await send(f"{tag} NO not logged in\r\n")
                continue
            uids = [m["uid"] for m in box["messages"]]
            selected = True
            mode = "READ-ONLY" if cmd == "EXAMINE" else "READ-WRITE"
            await send("* FLAGS (\\Answered \\Flagged \\Draft \\Deleted \\Seen)\r\n"
                       f"* OK [UIDVALIDITY {box['uidvalidity']}] UIDs valid.\r\n"
                       f"* {len(uids)} EXISTS\r\n* 0 RECENT\r\n"
                       f"* OK [UIDNEXT {max(uids, default=0) + 1}] Predicted next UID.\r\n"
                       f"{tag} OK [{mode}] INBOX selected. (Success)\r\n")
        elif cmd == "STATUS":
            if not authed:
                await send(f"{tag} NO not logged in\r\n")
                continue
            uids = [m["uid"] for m in box["messages"]]
            await send(f'* STATUS "INBOX" (UIDNEXT {max(uids, default=0) + 1} UIDVALIDITY {box["uidvalidity"]})\r\n'
                       f"{tag} OK Success\r\n")
        elif cmd == "UID":
            if not (authed and selected):
                await send(f"{tag} NO select a mailbox first\r\n")
                continue
            sub, args = (rest.split(" ", 1) + [""])[:2]
            uids = [m["uid"] for m in box["messages"]]
            if sub.upper() == "SEARCH":
                m = re.match(r"UID (\S+)(.*)", args, re.I)
                hits = uid_set(m.group(1), uids) if m else uids
                raw_query = re.search(r'X-GM-RAW "((?:[^"\\]|\\.)*)"', args, re.I)
                if raw_query:
                    query = raw_query.group(1).replace('\\"', '"')
                    words = re.search(r"subject:\((.*)\)", query)
                    terms = [w.lower() for w in (shlex.split(words.group(1)) if words else []) if w.upper() != "OR"]
                    by_uid = {x["uid"]: x for x in box["messages"]}
                    hits = [u for u in hits
                            if any(re.search(rf"\b{re.escape(t)}\b", subject_of(by_uid[u]["headers"]), re.I)
                                   for t in terms)]
                await send(f"* SEARCH{''.join(' ' + str(u) for u in hits)}\r\n{tag} OK SEARCH completed (Success)\r\n")
            elif sub.upper() == "FETCH":
                spec, what = args.split(" ", 1)
                if "BODY[" in what.upper() and "BODY.PEEK[" not in what.upper():
                    log("SEEN-SET")
                fields = re.search(r"HEADER\.FIELDS \(([^)]*)\)", what, re.I)
                names = [n.lower() for n in fields.group(1).split()] if fields else []
                out = b""
                for seq, msg in enumerate(box["messages"], start=1):
                    if msg["uid"] not in uid_set(spec, uids):
                        continue
                    kept, current = [], None
                    for hline in msg["headers"].replace("\r\n", "\n").split("\n"):
                        if hline[:1] in (" ", "\t") and current is not None:
                            if current:
                                kept.append(hline)
                            continue
                        name = hline.split(":", 1)[0].lower()
                        current = name in names
                        if current:
                            kept.append(hline)
                    data = ("\r\n".join(kept) + "\r\n\r\n").encode()
                    label = f"BODY[HEADER.FIELDS ({fields.group(1).upper()})]" if fields else "BODY[]"
                    out += f"* {seq} FETCH (UID {msg['uid']} {label} {{{len(data)}}}\r\n".encode() + data + b")\r\n"
                await send(out + f"{tag} OK Success\r\n".encode())
            else:
                await send(f"{tag} BAD unsupported\r\n")
        elif cmd == "NOOP":
            await send(f"{tag} OK Success\r\n")
        elif cmd == "LOGOUT":
            await send(f"* BYE LOGOUT Requested\r\n{tag} OK 73 good day (Success)\r\n")
            break
        else:
            await send(f"{tag} BAD Unknown command\r\n")
    writer.close()


async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", PORT)
    async with server:
        await server.serve_forever()

asyncio.run(main())
