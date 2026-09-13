#!/usr/bin/env python3
"""Lead Finder web server (Python standard library only).

Serves index.html, runs lead_finder.sh jobs, and exposes saved results.

  APP_PASSWORD=secret python3 server.py            # listens on 127.0.0.1:8080
  HOST=0.0.0.0 PORT=8080 APP_PASSWORD=secret python3 server.py

Put it behind nginx + HTTPS on a VPS (see README). Basic auth is required.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from http.cookies import SimpleCookie
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parent
LEADS = ROOT / "leads"

# Load .env (KEY=value lines); real environment variables take precedence.
if (ROOT / ".env").is_file():
    for raw in (ROOT / ".env").read_text().splitlines():
        key, sep, val = raw.strip().partition("=")
        if sep and key and not key.startswith("#"):
            os.environ.setdefault(key.strip(), val.strip().strip('"').strip("'"))

HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8080"))
USER = os.environ.get("APP_USER", "admin")
PASSWORD = os.environ.get("APP_PASSWORD", "")
MAX_LEADS = int(os.environ.get("MAX_LEADS", "200"))
ANSI = re.compile(r"\x1b\[[0-9;]*m")

# Sessions: signed cookie "<expiry>.<hmac>". The key is derived from the password,
# so changing APP_PASSWORD (or SESSION_SECRET) logs everyone out. Survives restarts.
COOKIE = "lf_session"
SESSION_DAYS = int(os.environ.get("SESSION_DAYS", "7"))
SESSION_KEY = hashlib.sha256(f"{os.environ.get('SESSION_SECRET', '')}|{USER}|{PASSWORD}".encode()).digest()
FAILED = {}                      # ip -> [timestamps of failed logins]
MAX_FAILS, FAIL_WINDOW = 5, 600  # 5 failures per 10 minutes, per IP
fail_lock = threading.Lock()


def sign(expiry):
    return hmac.new(SESSION_KEY, str(expiry).encode(), hashlib.sha256).hexdigest()


def valid_session(token):
    expiry, _, sig = (token or "").partition(".")
    return expiry.isdigit() and int(expiry) > time.time() and hmac.compare_digest(sig, sign(expiry))

WA_MARKS = LEADS / "whatsapp_marks.json"   # number -> {"on_whatsapp": "yes"|"no", "contacted": "YYYY-MM-DD"}
WA_VALUES = {"on_whatsapp": {"", "yes", "no"}, "contacted": None}
marks_lock = threading.Lock()

jobs = {}            # id -> job dict
jobs_lock = threading.Lock()


def clean_text(value, field):
    value = str(value or "").strip()
    value = re.sub(r"[\x00-\x1f\x7f]", "", value)
    if not value or len(value) > 100:
        raise ValueError(f"{field} must be 1-100 characters")
    return value


def running_job():
    return next((j for j in jobs.values() if j["status"] == "running"), None)


def run_job(job):
    # Argument list, no shell: user input can never be interpreted as a command.
    cmd = [str(ROOT / "lead_finder.sh"), job["location"], job["category"], str(job["limit"])]
    try:
        proc = subprocess.Popen(cmd, cwd=ROOT, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, bufsize=1)
        for line in proc.stdout:
            # progress lines use \r; keep only the latest segment
            line = ANSI.sub("", line).rstrip("\n").split("\r")[-1]
            with jobs_lock:
                job["log"].append(line)
                m = re.search(r"JSON saved: (.+\.json)", line)
                if m:
                    job["result"] = str(Path(m.group(1)).resolve().relative_to(LEADS))
        code = proc.wait()
        job["status"] = "done" if code == 0 else "failed"
    except Exception as exc:  # noqa: BLE001
        job["log"].append(f"[server error] {exc}")
        job["status"] = "failed"
    job["finished"] = time.time()


def read_marks():
    try:
        return json.loads(WA_MARKS.read_text())
    except (OSError, ValueError):
        return {}


def list_results():
    files = []
    for f in sorted(LEADS.glob("*/*.json"), reverse=True):
        try:
            data = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        first = data[0] if data else {}
        files.append({
            "path": str(f.relative_to(LEADS)),
            "date": f.parent.name,
            "location": first.get("search_location", ""),
            "category": first.get("search_category", ""),
            "count": len(data),
        })
    return files


class Handler(BaseHTTPRequestHandler):
    server_version = "LeadFinder"

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} - {fmt % args}", flush=True)

    # --- helpers -----------------------------------------------------------
    def client_ip(self):
        return self.headers.get("X-Real-IP") or self.client_address[0]

    def is_https(self):
        return self.headers.get("X-Forwarded-Proto") == "https"

    def authorized(self):
        cookie = SimpleCookie(self.headers.get("Cookie", ""))
        if COOKIE in cookie and valid_session(cookie[COOKIE].value):
            return True
        header = self.headers.get("Authorization", "")  # Basic auth still works for scripts/curl
        if header.startswith("Basic "):
            try:
                user, _, pw = base64.b64decode(header[6:]).decode().partition(":")
            except ValueError:
                return False
            return hmac.compare_digest(user, USER) and hmac.compare_digest(pw, PASSWORD)
        return False

    def send(self, code, body, ctype="application/json", headers=()):
        if not isinstance(body, bytes):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def guard(self):
        if self.authorized():
            return True
        if urlparse(self.path).path.startswith("/api/"):
            self.send(401, {"error": "Please log in"})
        else:
            self.redirect("login")
        return False

    def set_cookie(self, value, max_age):
        secure = "; Secure" if self.is_https() else ""
        return ("Set-Cookie", f"{COOKIE}={value}; Path=/; Max-Age={max_age}; HttpOnly; SameSite=Strict{secure}")

    def login(self):
        ip, now = self.client_ip(), time.time()
        with fail_lock:
            recent = [t for t in FAILED.get(ip, []) if now - t < FAIL_WINDOW]
            FAILED[ip] = recent
            if len(recent) >= MAX_FAILS:
                wait = int(FAIL_WINDOW - (now - recent[0])) // 60 + 1
                return self.send(429, {"error": f"Too many attempts. Try again in {wait} min."})
        try:
            length = min(int(self.headers.get("Content-Length", 0)), 2_000)
            body = json.loads(self.rfile.read(length) or b"{}")
            user, pw = str(body.get("username", "")), str(body.get("password", ""))
        except (ValueError, TypeError):
            return self.send(400, {"error": "Invalid request"})
        if hmac.compare_digest(user, USER) and hmac.compare_digest(pw, PASSWORD):
            with fail_lock:
                FAILED.pop(ip, None)
            days = SESSION_DAYS if body.get("remember") else 1
            expiry = int(now) + days * 86400
            return self.send(200, {"ok": True}, headers=[self.set_cookie(f"{expiry}.{sign(expiry)}", days * 86400)])
        with fail_lock:
            FAILED.setdefault(ip, []).append(now)
        time.sleep(1)  # slow down guessing
        self.send(401, {"error": "Wrong username or password"})

    # --- routes ------------------------------------------------------------
    def do_GET(self):
        url = urlparse(self.path)
        if url.path in ("/login", "/login.html"):
            if self.authorized():
                return self.redirect("./")
            return self.send(200, (ROOT / "login.html").read_bytes(), "text/html; charset=utf-8")
        if not self.guard():
            return
        if url.path in ("/", "/index.html"):
            return self.send(200, (ROOT / "index.html").read_bytes(), "text/html; charset=utf-8")
        if url.path == "/api/whatsapp":
            with marks_lock:
                return self.send(200, read_marks())
        if url.path == "/api/files":
            return self.send(200, list_results())
        if url.path == "/api/file":
            rel = parse_qs(url.query).get("path", [""])[0]
            target = (LEADS / rel).resolve()
            if target.parent.parent != LEADS or target.suffix not in (".json", ".csv") or not target.is_file():
                return self.send(404, {"error": "not found"})
            ctype = "application/json" if target.suffix == ".json" else "text/csv"
            return self.send(200, target.read_bytes(), ctype)
        m = re.fullmatch(r"/api/jobs/([0-9a-f]{32})", url.path)
        if m:
            job = jobs.get(m.group(1))
            if not job:
                return self.send(404, {"error": "job not found"})
            since = int(parse_qs(url.query).get("since", ["0"])[0] or 0)
            with jobs_lock:
                return self.send(200, {k: job[k] for k in ("id", "status", "result")} |
                                 {"log": job["log"][since:], "next": len(job["log"])})
        self.send(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/api/login":
            return self.login()
        if path == "/api/logout":
            return self.send(200, {"ok": True}, headers=[self.set_cookie("", 0)])
        if not self.guard():
            return
        if path == "/api/clean":
            return self.clean()
        if path == "/api/whatsapp":
            return self.mark_whatsapp()
        if path != "/api/jobs":
            return self.send(404, {"error": "not found"})
        try:
            length = min(int(self.headers.get("Content-Length", 0)), 10_000)
            body = json.loads(self.rfile.read(length) or b"{}")
            location = clean_text(body.get("location"), "Location")
            category = clean_text(body.get("category"), "Category")
            limit = int(body.get("limit", 20))
            if not 1 <= limit <= MAX_LEADS:
                raise ValueError(f"Leads must be between 1 and {MAX_LEADS}")
        except (ValueError, TypeError) as exc:
            return self.send(400, {"error": str(exc)})

        with jobs_lock:
            if running_job():
                return self.send(409, {"error": "A search is already running. Wait for it to finish."})
            job = {"id": uuid.uuid4().hex, "status": "running", "location": location, "category": category,
                   "limit": limit, "log": [], "result": None, "started": time.time(), "finished": None}
            jobs[job["id"]] = job
        threading.Thread(target=run_job, args=(job,), daemon=True).start()
        self.send(202, {"id": job["id"]})

    def mark_whatsapp(self):
        """Save what you found when opening a chat: on WhatsApp yes/no, contacted date."""
        try:
            length = min(int(self.headers.get("Content-Length", 0)), 1_000)
            body = json.loads(self.rfile.read(length) or b"{}")
            number = str(body.get("number", ""))
            field, value = body.get("field"), str(body.get("value", ""))
            if not re.fullmatch(r"[0-9]{8,15}", number):
                raise ValueError("Invalid number")
            if field not in WA_VALUES:
                raise ValueError("Invalid field")
            if field == "on_whatsapp" and value not in WA_VALUES[field]:
                raise ValueError("Invalid value")
            if field == "contacted" and value and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
                raise ValueError("Invalid date")
        except (ValueError, TypeError) as exc:
            return self.send(400, {"error": str(exc)})
        with marks_lock:
            marks = read_marks()
            entry = marks.get(number, {})
            if value:
                entry[field] = value
            else:
                entry.pop(field, None)
            if entry:
                marks[number] = entry
            else:
                marks.pop(number, None)
            tmp = WA_MARKS.with_suffix(".tmp")
            tmp.write_text(json.dumps(marks, indent=1))
            tmp.replace(WA_MARKS)
        self.send(200, marks.get(number, {}))

    def clean(self):
        """Delete (or preview deleting) result folders older than N days."""
        try:
            length = min(int(self.headers.get("Content-Length", 0)), 1_000)
            body = json.loads(self.rfile.read(length) or b"{}")
            days = int(body.get("days", 30))
            if not 0 <= days <= 3650:
                raise ValueError("Days must be between 0 and 3650")
        except (ValueError, TypeError) as exc:
            return self.send(400, {"error": str(exc)})
        with jobs_lock:
            if running_job():
                return self.send(409, {"error": "A search is running. Clean up after it finishes."})
        cmd = [str(ROOT / "clean_leads.sh")] + (["--dry-run"] if body.get("dry_run") else []) + [str(days)]
        proc = subprocess.run(cmd, cwd=ROOT, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
        out = ANSI.sub("", proc.stdout + proc.stderr).strip().splitlines()
        self.send(200 if proc.returncode == 0 else 500, {"ok": proc.returncode == 0, "log": out})


def main():
    if not PASSWORD:
        raise SystemExit("Set APP_PASSWORD (e.g. in .env or the systemd unit) before starting the server.")
    LEADS.mkdir(exist_ok=True)
    print(f"Lead Finder running on http://{HOST}:{PORT} (user: {USER})", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
