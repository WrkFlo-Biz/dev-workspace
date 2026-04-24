#!/usr/bin/env python3
"""
dws-phone-server — the VM side of the phone-control loop.

The iOS Shortcut polls this when the user taps a notification, picks up
the next queued action, and performs it locally on the phone. Exposed on
port 8081 of the VM; the Tailscale ACL is the only thing gating access.

Endpoints:
  GET  /health              -> server up, queue depth
  GET  /pending             -> next queued action for the phone, or
                               {"action":"none"} if empty. Pops from queue.
  POST /queue  {...}        -> append an action to the queue. Body is the
                               action dict (see ACTION SCHEMA below).
  POST /result {"id":"..."} -> phone reports result. Stored by id.
  GET  /results             -> dump recent results (debug)

ACTION SCHEMA sent to the phone:
  {"action":"open_url",  "url":"https://..."}
  {"action":"speak",     "text":"hello world"}
  {"action":"message",   "to":"+15555550123","body":"yo"}
  {"action":"copy",      "text":"paste-me"}
  {"action":"notify",    "title":"t","body":"b"}
  {"action":"none"}                # no work pending

Anything else: the Shortcut can add more branches as needed.
"""
import json
import os
import sys
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from datetime import datetime

PORT = int(os.environ.get("DWS_PHONE_PORT", "8081"))
QUEUE = deque()
RESULTS = deque(maxlen=50)

def now(): return datetime.utcnow().isoformat() + "Z"

class H(BaseHTTPRequestHandler):
    def _resp(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length).decode() if length else ""
        try:
            return json.loads(raw) if raw else {}
        except Exception:
            return {}

    def do_GET(self):
        if self.path == "/pending":
            item = QUEUE.popleft() if QUEUE else {"action": "none"}
            return self._resp(200, item)
        if self.path == "/health":
            return self._resp(200, {"ok": True, "queued": len(QUEUE), "time": now()})
        if self.path == "/results":
            return self._resp(200, {"ok": True, "results": list(RESULTS)})
        return self._resp(404, {"ok": False, "error": "unknown path"})

    def do_POST(self):
        data = self._read_body()
        if self.path == "/queue":
            if "action" not in data:
                return self._resp(400, {"ok": False, "error": "missing 'action'"})
            QUEUE.append(data)
            return self._resp(200, {"ok": True, "queued": len(QUEUE)})
        if self.path == "/result":
            RESULTS.append({"at": now(), **data})
            return self._resp(200, {"ok": True})
        return self._resp(404, {"ok": False, "error": "unknown path"})

    def log_message(self, fmt, *args):
        print(f"[{now()}] {self.address_string()} {fmt % args}", file=sys.stderr, flush=True)

if __name__ == "__main__":
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), H)
    print(f"[dws-phone-server] listening on 0.0.0.0:{PORT}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
