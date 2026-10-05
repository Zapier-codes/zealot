#!/usr/bin/env python3
"""Stub of the Render API routes the Task 40 scripts use. Test tool only (Task 40n-h); it is not Render.
   python3 mock_render.py PORT MODE LOGFILE
MODE: auto   a variable change starts a deploy by itself
      silent a variable change starts nothing; POST /deploys starts one (the 2026-10-05 behavior)
      never  nothing ever starts a deploy (POST is accepted and ignored)
      fail   the new deploy ends build_failed
      late   a second deploy appears right after the first one is live (two quick variable changes)"""
import json, sys, itertools
from http.server import BaseHTTPRequestHandler, HTTPServer
PORT, MODE, LOG = int(sys.argv[1]), sys.argv[2], sys.argv[3]
SVC = "srv-test"
ENV = {k: v for k, v in [
    ("RELEASE_STORAGE_ADAPTER", "github"), ("R2_STAGING_BUCKET", "zealot-staging"),
    ("R2_STAGING_ENDPOINT", "https://r2.example"), ("R2_STAGING_ACCESS_KEY_ID", "akid"),
    ("R2_STAGING_SECRET_ACCESS_KEY", "sak"), ("CI_OIDC_AUDIENCE", "https://zealot.example"),
    ("CI_COMPILE_DISPATCH_TOKEN", "t1"), ("CI_COMPILE_CALLBACK_TOKEN", "t2"),
    ("CI_COMPILE_EXPECT_CERT_SHA256", "a" * 64), ("GITHUB_STORAGE_REPO", "o/r"), ("GITHUB_STORAGE_TOKEN", "t3")]}
ids = itertools.count(1)
deploys = [{"id": "dep-old", "status": "live", "seq": []}]   # newest first
late_pending = [MODE == "late"]

def new_deploy():
    seq = ["build_failed"] if MODE == "fail" else ["update_in_progress", "update_in_progress", "live"]
    deploys.insert(0, {"id": f"dep-new{next(ids)}", "status": "queued", "seq": seq})
    for d in deploys[1:]:
        if d["status"] == "live": d["status"] = "deactivated"
        break

def advance():
    d = deploys[0]
    if d["seq"]:
        d["status"] = d["seq"].pop(0)
    elif d["status"] == "live" and late_pending[0] and d["id"] != "dep-old":
        late_pending[0] = False; new_deploy()

def log(m): open(LOG, "a").write(m + "\n")

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body):
        b = json.dumps(body).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def body(self):
        n = int(self.headers.get("Content-Length") or 0); return json.loads(self.rfile.read(n) or b"{}")
    def do_GET(self):
        p = self.path.split("?")[0]
        if p == f"/v1/services/{SVC}/env-vars":
            return self.send(200, [{"envVar": {"key": k, "value": v}, "cursor": k} for k, v in ENV.items()])
        if p == f"/v1/services/{SVC}/deploys":
            advance(); n = int(self.path.split("limit=")[1].split("&")[0]) if "limit=" in self.path else 20
            return self.send(200, [{"deploy": {"id": d["id"], "status": d["status"]}, "cursor": d["id"]} for d in deploys[:n]])
        self.send(404, {})
    def do_PUT(self):
        key = self.path.rsplit("/", 1)[1]; ENV[key] = self.body().get("value", ""); log(f"PUT {key}")
        if MODE in ("auto", "fail", "late"): new_deploy()
        self.send(200, {"key": key})
    def do_POST(self):
        log("POST deploy")
        if MODE != "never": new_deploy()
        self.send(201, {"id": deploys[0]["id"]})

HTTPServer(("127.0.0.1", PORT), H).serve_forever()
