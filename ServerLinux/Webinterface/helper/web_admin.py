#!/usr/bin/env python3
import json
import os
import signal
import sys
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlsplit


def resource_root() -> Path:
    # PyInstaller legt --add-data Inhalte unter sys._MEIPASS ab.
    if getattr(sys, "frozen", False) and hasattr(sys, "_MEIPASS"):
        return Path(sys._MEIPASS)
    return Path(__file__).resolve().parent.parent


HOST = os.environ.get("CARRACHO_WEB_ADMIN_BIND", "127.0.0.1")
PORT = int(os.environ.get("CARRACHO_WEB_ADMIN_PORT", "6781"))
UPSTREAM = os.environ.get(
    "CARRACHO_HTTP_ADMIN_URL",
    "http://127.0.0.1:6780/api/v1",
).rstrip("/")
TOKEN = os.environ.get("CARRACHO_HTTP_ADMIN_TOKEN", "")
STATIC_DIR = resource_root() / "web"

if len(TOKEN.encode("utf-8")) < 24:
    print(
        "Fehler: CARRACHO_HTTP_ADMIN_TOKEN fehlt oder ist kürzer als 24 Bytes.",
        file=sys.stderr,
        flush=True,
    )
    sys.exit(2)

if not STATIC_DIR.is_dir():
    print(f"Fehler: Web-Ressourcen fehlen: {STATIC_DIR}", file=sys.stderr, flush=True)
    sys.exit(3)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class Handler(SimpleHTTPRequestHandler):
    server_version = "CarrachoWebAdmin/4.0"
    protocol_version = "HTTP/1.1"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(STATIC_DIR), **kwargs)

    def log_message(self, fmt, *args):
        sys.stderr.write("[web-admin] " + (fmt % args) + "\n")
        sys.stderr.flush()

    def _security_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; "
            "style-src 'self' 'unsafe-inline'; "
            "script-src 'self' 'unsafe-inline'; "
            "connect-src 'self'; "
            "img-src 'self' data:; "
            "base-uri 'none'; frame-ancestors 'none'",
        )
        self.send_header("Cache-Control", "no-store")

    def end_headers(self):
        self._security_headers()
        super().end_headers()

    def do_HEAD(self):
        if self.path == "/healthz":
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        super().do_HEAD()

    def do_GET(self):
        if self.path == "/healthz":
            payload = b'{"ok":true}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path.startswith("/proxy/"):
            self._proxy()
            return
        if self.path in ("/", "/admin", "/admin/"):
            self.path = "/index.html"
        super().do_GET()

    def do_POST(self):
        if self.path.startswith("/proxy/"):
            self._proxy()
            return
        self.send_error(404)

    def do_PATCH(self):
        if self.path.startswith("/proxy/"):
            self._proxy()
            return
        self.send_error(404)

    def do_DELETE(self):
        if self.path.startswith("/proxy/"):
            self._proxy()
            return
        self.send_error(404)

    def _upstream_headers(self, body):
        accept = self.headers.get("Accept", "application/json")
        headers = {
            "Authorization": f"Bearer {TOKEN}",
            "Accept": accept,
        }
        last_event_id = self.headers.get("Last-Event-ID")
        if last_event_id:
            headers["Last-Event-ID"] = last_event_id
        if body is not None:
            headers["Content-Type"] = self.headers.get(
                "Content-Type", "application/json"
            )
        return headers

    def _proxy(self):
        suffix = self.path[len("/proxy"):]
        parts = urlsplit(suffix)
        upstream_url = UPSTREAM + parts.path
        if parts.query:
            upstream_url += "?" + parts.query

        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else None
        headers = self._upstream_headers(body)
        wants_sse = (
            "text/event-stream" in headers.get("Accept", "")
            or parts.path.rstrip("/").endswith("/events")
        )

        req = urllib.request.Request(
            upstream_url,
            data=body,
            headers=headers,
            method=self.command,
        )

        try:
            timeout = 3600 if wants_sse else 30
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                content_type = resp.headers.get("Content-Type", "application/json")
                is_sse = "text/event-stream" in content_type
                self.send_response(resp.status)
                self.send_header("Content-Type", content_type)
                if is_sse:
                    self.send_header("Connection", "keep-alive")
                    self.end_headers()
                    try:
                        for line in resp:
                            self.wfile.write(line)
                            self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                    return

                payload = resp.read()
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                if payload:
                    self.wfile.write(payload)
        except urllib.error.HTTPError as exc:
            payload = exc.read()
            self.send_response(exc.code)
            self.send_header(
                "Content-Type",
                exc.headers.get("Content-Type", "application/json"),
            )
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if payload:
                self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:
            payload = json.dumps({
                "error": {
                    "code": "proxy_error",
                    "message": str(exc),
                }
            }).encode("utf-8")
            try:
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError):
                pass


def main():
    httpd = Server((HOST, PORT), Handler)

    def stop(_signum, _frame):
        # shutdown() darf nicht aus demselben serve_forever-Thread aufgerufen werden.
        import threading
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    print(f"Carracho Web Admin: http://{HOST}:{PORT}/", flush=True)
    print(f"API upstream:       {UPSTREAM}", flush=True)
    try:
        httpd.serve_forever(poll_interval=0.25)
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
