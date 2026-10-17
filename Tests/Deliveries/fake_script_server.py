#!/usr/bin/env python3
"""A stand-in for a deployed Google Apps Script web app, for testing Hammer.

    fake_script_server.py PORT STATE.json LOG.txt

Like Google, /macros/s/<id>/exec answers with a redirect to /macros/echo?…, which
returns what the script would. STATE.json (re-read on every request) says what
that is: {"key": "...", "account": "...", "emails": [...], "mode": "ok"} where
mode can also be "signin" (deployment not open to Anyone), "notfound",
"unsaved" (doGet missing), "busy" (HTTP 503), "gmail" (the script's Gmail error)
or "permission" (Gmail access not granted). Like the script, an `after` (seconds)
leaves out emails dated before it.
Each request's path is logged to LOG.txt with the key masked.
"""
import json, re, sys
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs, urlencode

PORT, STATE, LOG = int(sys.argv[1]), sys.argv[2], sys.argv[3]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, status, body, kind="application/json", headers=None):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        state = json.load(open(STATE))
        url = urlparse(self.path)
        query = parse_qs(url.query)
        with open(LOG, "a") as f:
            f.write(re.sub(r"key=[0-9a-f]+", "key=…", self.path) + "\n")
        mode = state.get("mode", "ok")
        if url.path.startswith("/macros/s/") and url.path.endswith("/exec"):
            if mode == "notfound":
                return self.send(404, "<html>Sorry, unable to open the file at this time.</html>", "text/html")
            if mode == "signin":
                return self.send(302, "", "text/html", {"Location": "/accounts/signin"})
            echo = "/macros/echo?" + urlencode({"user_content_key": "abc123", "lib": "M1",
                                                "k": query.get("key", [""])[0],
                                                "after": query.get("after", ["0"])[0]})
            return self.send(302, "", "text/html", {"Location": echo})
        if url.path == "/accounts/signin":
            return self.send(200, "<html><title>Sign in - Google Accounts</title>accounts.google.com</html>", "text/html")
        if url.path == "/macros/echo":
            if mode == "busy":
                return self.send(503, "<html>Service unavailable</html>", "text/html")
            if mode == "unsaved":
                return self.send(200, "<html>Script function not found: doGet</html>", "text/html")
            if query.get("k", [""])[0] != state["key"]:
                return self.send(200, json.dumps({"ok": False, "error": "key"}))
            if mode == "gmail":
                return self.send(200, json.dumps({"ok": False, "error": "gmail", "message": "Service invoked too many times"}))
            if mode == "permission":
                return self.send(200, json.dumps({"ok": False, "error": "permission",
                                                  "message": "Exception: You do not have permission to call GmailApp.search"}))
            after = float(query.get("after", ["0"])[0] or 0)
            emails = [e for e in state["emails"]
                      if datetime.fromisoformat(e["date"].replace("Z", "+00:00")).timestamp() >= after]
            return self.send(200, json.dumps({"ok": True, "version": 2, "account": state["account"], "emails": emails}))
        return self.send(404, "not found", "text/plain")


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
