"""Serve a local, read-only Jarvis Switch companion."""

import argparse
from http import HTTPStatus
from http.cookies import CookieError, SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hmac
import ipaddress
import json
import pathlib
import re
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit


_LEARN_CACHE = {"ts": 0.0, "body": None}
_LEARN_LOCK = threading.Lock()


def learning_snapshot(metrics_dir):
    """Optional read-only 24h learning, RSI benchmark & cleanup summary (15s TTL cache)."""
    if not metrics_dir:
        return None
    base = pathlib.Path(metrics_dir)
    metrics_p = base / "logs/run_metrics.jsonl"
    if not metrics_p.is_file():
        return None
    now = time.monotonic()
    with _LEARN_LOCK:
        if now - _LEARN_CACHE["ts"] < 15.0 and _LEARN_CACHE["body"] is not None:
            return _LEARN_CACHE["body"]
    cutoff_ms = int((time.time() - 24 * 3600) * 1000)
    total = fric = failed = 0
    try:
        for raw in metrics_p.read_text(errors="replace").splitlines():
            if not raw.strip():
                continue
            rec = json.loads(raw)
            if (rec.get("end_ms") or 0) < cutoff_ms:
                continue
            total += 1
            if (rec.get("friction_score") or 0) > 0:
                fric += 1
            if any(s in ("error", "aborted") for s in (rec.get("stop_reasons") or [])):
                failed += 1
    except Exception:
        pass
    last_date = None
    last_count = 0
    receipts_p = base / "logs/cleanup_receipts.jsonl"
    if receipts_p.is_file():
        try:
            by_date = {}
            for raw in receipts_p.read_text(errors="replace").splitlines()[-500:]:
                if not raw.strip():
                    continue
                rec = json.loads(raw)
                d = rec.get("date")
                if d:
                    by_date[d] = by_date.get(d, 0) + 1
            if by_date:
                last_date = max(by_date.keys())
                last_count = by_date[last_date]
        except Exception:
            pass
    projects_tracked = 0
    reg_p = base / "state/cleanup_registry.json"
    if reg_p.is_file():
        try:
            projects_tracked = len(json.loads(reg_p.read_text()).get("projects", {}))
        except Exception:
            pass
    eval_passed = eval_total = None
    eval_p = base / "logs/eval_history.jsonl"
    if eval_p.is_file():
        try:
            for raw in reversed(eval_p.read_text(errors="replace").splitlines()[-50:]):
                if not raw.strip():
                    continue
                rec = json.loads(raw)
                if rec.get("mode") == "full" and rec.get("note") != "reverted":
                    eval_passed = rec.get("passed")
                    eval_total = rec.get("total")
                    break
        except Exception:
            pass
    clean_pct = int(round(100 * (total - fric) / total)) if total else 100
    payload = json.dumps({
        "windowHours": 24,
        "totalRuns": total,
        "cleanPercent": clean_pct,
        "frictionRuns": fric,
        "failedRuns": failed,
        "lastCleanupDate": last_date,
        "lastCleanupCount": last_count,
        "projectsTracked": projects_tracked,
        "evalPassed": eval_passed,
        "evalTotal": eval_total,
    }, separators=(",", ":")).encode("utf-8")
    with _LEARN_LOCK:
        _LEARN_CACHE["ts"] = now
        _LEARN_CACHE["body"] = payload
    return payload


LAN_NETWORKS = tuple(map(ipaddress.ip_network, ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")))
ASSETS = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/styles.css": ("styles.css", "text/css; charset=utf-8"),
    "/icon.png": ("icons/app.png", "image/png"),
}
COOKIE = "jarvis_view"


class Monitor:
    """All viewers share a collector, which stops when the page is closed."""

    def __init__(self, command):
        self.command = command
        self.lock = threading.Lock()
        self.thread = None
        self.requested_at = 0.0
        self.sample = None
        self.sample_at = 0.0

    def current(self):
        with self.lock:
            now = time.monotonic()
            self.requested_at = now
            if self.thread is None:
                self.thread = threading.Thread(target=self.collect, name="jarvis-collector", daemon=True)
                self.thread.start()
            if now - self.sample_at < 3:
                return self.sample
            return None

    def collect(self):
        worker = None
        try:
            worker = subprocess.Popen(self.command, stdout=subprocess.PIPE)
            for line in worker.stdout:
                with self.lock:
                    now = time.monotonic()
                    if now - self.requested_at > 15:
                        break
                    if line.startswith(b"{"):
                        self.sample, self.sample_at = line, now
        finally:
            if worker is not None:
                if worker.poll() is None:
                    worker.terminate()
                    try:
                        worker.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        worker.kill()
                        worker.wait()
                worker.stdout.close()
            with self.lock:
                self.thread = None
                self.sample = None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "JarvisSwitch"
    sys_version = ""

    def log_message(self, format, *args):
        pass

    def send_body(self, status, body=b"", content_type="text/plain; charset=utf-8", session=False):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; "
            "connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'",
        )
        if session:
            self.send_header("Set-Cookie", f"{COOKIE}={self.server.token}; HttpOnly; SameSite=Strict; Path=/; Max-Age=31536000")
        self.end_headers()
        if body:
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def do_GET(self):
        host = self.headers.get("Host", "").lower()
        if host not in self.server.allowed_hosts:
            self.send_body(HTTPStatus.FORBIDDEN)
            return

        if self.server.tailnet_login and self.headers.get("Tailscale-User-Login") != self.server.tailnet_login:
            self.send_body(HTTPStatus.FORBIDDEN)
            return

        path = urlsplit(self.path).path
        if path == "/api/status":
            self.send_status()
            return
        if path == "/api/learning":
            self.send_learning()
            return
        asset = ASSETS.get(path)
        if re.fullmatch(r"/icons/[a-z_]+\.png", path):
            asset = (path[1:], "image/png")
        if asset is None:
            self.send_body(HTTPStatus.NOT_FOUND)
            return
        name, content_type = asset
        try:
            body = (self.server.assets / name).read_bytes()
        except FileNotFoundError:
            self.send_body(HTTPStatus.NOT_FOUND)
        else:
            self.send_body(HTTPStatus.OK, body, content_type)

    def _authorize(self):
        token = self.server.token.encode("ascii")
        header = self.headers.get("Authorization", "").encode("latin1")
        authorized_link = hmac.compare_digest(header, b"Bearer " + token)
        try:
            cookie = SimpleCookie(self.headers.get("Cookie", "")).get(COOKIE)
        except CookieError:
            cookie = None
        authorized_session = cookie is not None and hmac.compare_digest(cookie.value.encode("latin1"), token)
        ok = self.server.tailnet_login or authorized_link or authorized_session
        set_session = authorized_link and not authorized_session and not self.server.tailnet_login
        return ok, set_session

    def send_status(self):
        ok, set_session = self._authorize()
        if not ok:
            self.send_body(HTTPStatus.UNAUTHORIZED)
            return
        body = self.server.monitor.current()
        self.send_body(
            HTTPStatus.OK if body is not None else HTTPStatus.ACCEPTED,
            body if body is not None else b"{}",
            "application/json",
            session=set_session,
        )

    def send_learning(self):
        ok, set_session = self._authorize()
        if not ok:
            self.send_body(HTTPStatus.UNAUTHORIZED)
            return
        body = learning_snapshot(getattr(self.server, "metrics_dir", None))
        if body is None:
            self.send_body(HTTPStatus.NO_CONTENT, b"", "application/json", session=set_session)
            return
        self.send_body(HTTPStatus.OK, body, "application/json", session=set_session)


class Server(ThreadingHTTPServer):
    timeout = 0.5
    request_queue_size = 32
    tailnet_login = None
    metrics_dir = None

    def handle_error(self, request, client_address):
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionResetError, BrokenPipeError, TimeoutError)):
            return
        super().handle_error(request, client_address)

    def verify_request(self, request, client_address):
        request.settimeout(5)
        if self.tailnet_login:
            return ipaddress.ip_address(client_address[0]).is_loopback
        return any(ipaddress.ip_address(client_address[0]) in network for network in LAN_NETWORKS)


def lan_address(interface):
    result = subprocess.run(
        ["/usr/sbin/ipconfig", "getifaddr", interface], capture_output=True, text=True, timeout=3,
    )
    address = result.stdout.strip()
    if result.returncode == 0 and any(ipaddress.ip_address(address) in network for network in LAN_NETWORKS):
        return address
    return None


def start_tailnet_listener(path, token, assets, monitor, metrics_dir=None):
    settings = json.loads(path.read_bytes())
    host = settings["host"]
    server = Server(("127.0.0.1", settings["port"]), Handler)
    server.allowed_hosts = {host, host + ":443", host + ":80"}
    server.tailnet_login = settings["login"]
    server.token, server.assets, server.monitor, server.metrics_dir = token, assets, monitor, metrics_dir
    threading.Thread(target=server.serve_forever, name="jarvis-tailnet", daemon=True).start()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interface", required=True)
    parser.add_argument("--hostname", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--cron-db", required=True)
    parser.add_argument("--session-db", required=True)
    parser.add_argument("--metrics-dir", default=None, help="Optional assistant root containing logs/run_metrics.jsonl")
    args = parser.parse_args()

    root = pathlib.Path(__file__).resolve().parent
    token = (root / "viewer_key").read_text().strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]{43}", token):
        raise SystemExit("Invalid companion viewer key")
    monitor = Monitor([
        str(root / "JarvisSwitch.app/Contents/MacOS/JarvisSwitch"), "--companion-stream",
        "--cron-db", args.cron_db, "--session-db", args.session_db,
    ])
    tailnet = root / "tailnet.json"
    if tailnet.exists():
        start_tailnet_listener(tailnet, token, root / "web", monitor, metrics_dir=args.metrics_dir)
    while True:
        address = lan_address(args.interface)
        if address is None:
            time.sleep(5)
            continue
        with Server((address, args.port), Handler) as server:
            server.allowed_hosts = {f"{host.lower()}:{args.port}" for host in (address, args.hostname)}
            server.token, server.assets, server.monitor, server.metrics_dir = token, root / "web", monitor, args.metrics_dir
            check_at = time.monotonic() + 10
            while True:
                server.handle_request()
                if time.monotonic() >= check_at:
                    if lan_address(args.interface) != address:
                        break
                    check_at = time.monotonic() + 10


if __name__ == "__main__":
    main()
