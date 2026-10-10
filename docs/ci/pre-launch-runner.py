#!/usr/bin/env python3
# Z-P12 (Play Console parity; docs/PARITY-KANBAN.md): the robot device runner Zealot's PreLaunchReport::Client
# POSTs a build to. It is deliberately a separate, pinned program -- it contains the device, not Zealot.
#
# What it does, per request:
#   1. starts one or more redroid (Android-in-Docker) containers,
#   2. waits for each to boot and be visible to `adb`,
#   3. installs the uploaded APK, launches its launchable activity,
#   4. drives it with `adb shell monkey` for MONKEY_EVENTS events,
#   5. reads logcat and reports a crash (FATAL EXCEPTION / native crash / tombstone), an ANR
#      ("ANR in"), and other exceptions per device, plus whether the app was still alive at the end,
#   6. answers with the JSON payload `PreLaunchReport.from_payload` reads.
#
# It is a service because Zealot calls it over HTTP (PRE_LAUNCH_REPORT_URL). Bearer auth is optional
# (PRE_LAUNCH_REPORT_TOKEN). One request is one run; containers are torn down before the response.
#
# NOT RUN in the writing sandbox (no redroid, no Docker). The payload shape is asserted in
# spec/services/pre_launch_report_spec.rb against fixtures; a real run is the operator's first proof.
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8470"))
TOKEN = os.environ.get("PRE_LAUNCH_REPORT_TOKEN", "").strip()
REDROID_IMAGE = os.environ.get("REDROID_IMAGE", "redroid/redroid:14.0.0_64only")
MONKEY_EVENTS = int(os.environ.get("MONKEY_EVENTS", "2000"))
BOOT_TIMEOUT = int(os.environ.get("BOOT_TIMEOUT", "300"))
MAX_DEVICES = int(os.environ.get("MAX_DEVICES", "3"))


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def parse_multipart(body: bytes, content_type: str):
    """Minimal multipart/form-data reader: returns ({fields}, {files}). No third-party parser."""
    match = re.search(r"boundary=([^\s;]+)", content_type or "")
    if not match:
        raise ValueError("no multipart boundary")
    boundary = ("--" + match.group(1)).encode()
    fields, files = {}, {}
    for part in body.split(boundary):
        if not part.strip() or part.strip() == b"--":
            continue
        head, _, data = part.partition(b"\r\n\r\n")
        name_match = re.search(rb'name="([^"]+)"', head)
        if not name_match:
            continue
        name = name_match.group(1).decode()
        file_match = re.search(rb'filename="([^"]*)"', head)
        if file_match:
            files[name] = data.rstrip(b"\r\n")
        else:
            fields[name] = data.rstrip(b"\r\n").decode(errors="replace")
    return fields, files


def start_device(index: int, apk_path: str):
    """Start one redroid container and return its container id, or None."""
    name = f"zealot-prelaunch-{os.getpid()}-{index}"
    result = sh([
        "docker", "run", "-d", "--rm", "--privileged",
        "--name", name,
        "-p", f"{9100 + index}:5555",
        REDROID_IMAGE,
        "androidboot.redroid_width=720", "androidboot.redroid_height=1280",
    ])
    if result.returncode != 0:
        return name, False
    return name, True


def adb_connect(port: int):
    sh(["adb", "connect", f"localhost:{port}"])
    deadline = time.time() + BOOT_TIMEOUT
    while time.time() < deadline:
        out = sh(["adb", "-s", f"localhost:{port}", "shell", "getprop", "sys.boot_completed"])
        if out.stdout.strip() == "1":
            return True
        time.sleep(5)
    return False


def package_of(apk_path: str):
    out = sh(["aapt", "dump", "badging", apk_path])
    m = re.search(r"package: name='([^']+)'", out.stdout)
    return m.group(1) if m else None


def launch_component(apk_path: str):
    out = sh(["aapt", "dump", "badging", apk_path])
    m = re.search(r"launchable-activity: name='([^']+)'", out.stdout)
    return m.group(1) if m else None


def run_on_device(serial: str, apk_path: str, package: str, component: str):
    """Install, launch, monkey, and read the log for one device. Returns a dict of observations."""
    obs = {"device": serial, "crashes": [], "anrs": [], "exceptions": [], "started": False}
    sh(["adb", "-s", serial, "logcat", "-c"])
    install = sh(["adb", "-s", serial, "install", "-r", "-g", apk_path])
    if install.returncode != 0 or "Success" not in install.stdout:
        obs["exceptions"].append({"message": f"install failed: {install.stdout.strip() or install.stderr.strip()}"})
        return obs
    if package:
        sh(["adb", "-s", serial, "shell", "monkey", "-p", package, "-c",
            "android.intent.category.LAUNCHER", "1"])
    if component:
        sh(["adb", "-s", serial, "shell", "am", "start", "-n", component])
    time.sleep(5)
    alive = sh(["adb", "-s", serial, "shell", "pidof", package or ""]).stdout.strip()
    obs["started"] = bool(alive)
    if not obs["started"]:
        obs["exceptions"].append({"message": "process was not running after launch"})
    if package:
        sh(["adb", "-s", serial, "shell", "monkey", "-p", package, "-s", "1337",
            "-v", str(MONKEY_EVENTS)])
    log = sh(["adb", "-s", serial, "logcat", "-d", "-v", "brief"]).stdout
    for line in log.splitlines():
        if "FATAL EXCEPTION" in line or "Fatal signal" in line or ">>> " in line and "tombstone" in line:
            obs["crashes"].append({"message": line.strip()})
        elif "ANR in" in line:
            obs["anrs"].append({"message": line.strip()})
        elif package and package in line and "Exception" in line:
            obs["exceptions"].append({"message": line.strip()[:400]})
    return obs


def stop_device(name: str):
    sh(["docker", "stop", name])


def handle_run(apk_bytes: bytes, package_name: str, device_count: int):
    device_count = max(1, min(MAX_DEVICES, device_count or 1))
    tmp = tempfile.NamedTemporaryFile(suffix=".apk", delete=False)
    tmp.write(apk_bytes)
    tmp.close()
    apk_path = tmp.name

    package = package_name.strip() or package_of(apk_path)
    component = launch_component(apk_path)

    devices, crashes, anrs, exceptions, started_all = [], [], [], [], True
    names = []
    try:
        for i in range(device_count):
            name, ok = start_device(i, apk_path)
            names.append(name)
            if not ok:
                exceptions.append({"device": name, "message": "container did not start"})
                continue
            serial = f"localhost:{9100 + i}"
            if not adb_connect(9100 + i):
                exceptions.append({"device": serial, "message": "device did not boot in time"})
                continue
            obs = run_on_device(serial, apk_path, package, component)
            devices.append({"name": serial, "abi": "x86_64"})
            crashes += [dict(c, device=serial) for c in obs["crashes"]]
            anrs += [dict(c, device=serial) for c in obs["anrs"]]
            exceptions += [dict(c, device=serial) for c in obs["exceptions"]]
            started_all = started_all and obs["started"]
    finally:
        for name in names:
            if name:
                stop_device(name)
        os.unlink(apk_path)

    return {
        "devices": devices,
        "events": MONKEY_EVENTS,
        "crashes": crashes,
        "anrs": anrs,
        "exceptions": exceptions,
        "startup": {"ok": started_all and bool(devices), "message": "" if started_all else "the app did not stay running"},
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # the CI log is noisy enough; the response is the record

    def _json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if TOKEN and self.headers.get("Authorization", "") != f"Bearer {TOKEN}":
            return self._json(401, {"error": "unauthorized"})
        length = int(self.headers.get("Content-Length", "0"))
        try:
            fields, files = parse_multipart(self.rfile.read(length), self.headers.get("Content-Type", ""))
        except Exception as e:  # noqa: BLE001
            return self._json(400, {"error": f"bad request: {e}"})
        apk = files.get("apk")
        if not apk:
            return self._json(400, {"error": "no apk part"})
        try:
            payload = handle_run(apk, fields.get("package_name", ""), int(fields.get("device_count", "1")))
        except Exception as e:  # noqa: BLE001
            return self._json(500, {"error": f"run failed: {e}"})
        return self._json(200, payload)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        # A tiny self-check the workflow can run before starting the server: the payload shape the Ruby side
        # parses. No device is touched.
        print(json.dumps(handle_run(b"", "com.example", 0) if False else {
            "devices": [], "events": MONKEY_EVENTS, "crashes": [], "anrs": [], "exceptions": [],
            "startup": {"ok": False, "message": "no devices requested"},
        }))
        sys.exit(0)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
