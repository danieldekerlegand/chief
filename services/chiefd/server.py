#!/usr/bin/env python3
"""Local HTTP/SSE boundary between Chief data sources and observer clients.

chiefd deliberately reads an already-normalized portfolio snapshot. Collection and
agent execution stay outside this process, which makes it safe to run continuously.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import os
import platform
import signal
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlsplit

from .store import HistoryStore
from .collector import PortfolioRefresher

SERVICE_SCHEMA = "chief.observer/v1"
EVENT_SCHEMA = "chief.event/v1"
SERVICE_VERSION = "0.1.0"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 4174
ROOT = Path(__file__).resolve().parents[2]


def user_snapshot_path() -> Path:
    if platform.system() == "Darwin":
        data_home = Path.home() / "Library" / "Application Support" / "Chief Observatory"
    else:
        data_home = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "chief-observatory"
    return data_home / "snapshot.json"


def user_database_path() -> Path:
    return user_snapshot_path().with_name("chiefd.sqlite3")


def user_config_path() -> Path:
    return user_snapshot_path().with_name("portfolio.json")


def source_config_path() -> Path:
    configured = ROOT / "collectors" / "portfolio" / "portfolio.json"
    return configured if configured.exists() else configured.with_name("portfolio.example.json")


if getattr(sys, "frozen", False):
    DEFAULT_SNAPSHOT = user_snapshot_path()
    DEFAULT_STATIC_ROOT = Path(getattr(sys, "_MEIPASS")) / "chief-dashboard"
else:
    DEFAULT_SNAPSHOT = ROOT / "apps" / "portfolio" / "public" / "snapshot.json"
    DEFAULT_STATIC_ROOT = ROOT / "apps" / "portfolio" / "public"
ALLOWED_ORIGINS = {
    "http://localhost",
    "http://tauri.localhost",
    "https://tauri.localhost",
    "tauri://localhost",
}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass(frozen=True)
class Snapshot:
    body: bytes
    document: dict[str, Any]
    etag: str
    modified_ns: int
    modified_at: str


class SnapshotStore:
    """Validates and caches one collector-produced snapshot."""

    def __init__(self, path: Path):
        self.path = path.resolve()
        self._lock = threading.Lock()
        self._cached: Snapshot | None = None
        self._error: str | None = None

    @property
    def error(self) -> str | None:
        self.load()
        return self._error

    def load(self) -> Snapshot | None:
        with self._lock:
            try:
                stat = self.path.stat()
                if self._cached and self._cached.modified_ns == stat.st_mtime_ns:
                    return self._cached
                body = self.path.read_bytes()
                document = json.loads(body)
                if not isinstance(document, dict):
                    raise ValueError("snapshot root must be an object")
                digest = hashlib.sha256(body).hexdigest()
                modified = datetime.fromtimestamp(stat.st_mtime, timezone.utc).isoformat()
                self._cached = Snapshot(body, document, f'"{digest}"', stat.st_mtime_ns, modified)
                self._error = None
            except (OSError, ValueError, json.JSONDecodeError) as exc:
                self._cached = None
                self._error = str(exc)
            return self._cached

    def health(self) -> dict[str, Any]:
        snapshot = self.load()
        return {
            "available": snapshot is not None,
            "location": str(self.path),
            "etag": snapshot.etag if snapshot else None,
            "modifiedAt": snapshot.modified_at if snapshot else None,
            "error": self._error,
        }


class ChiefdHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        address: tuple[str, int],
        store: SnapshotStore,
        static_root: Path | None,
        poll_interval: float,
        quiet: bool,
        history: HistoryStore | None,
        refresher: PortfolioRefresher | None,
    ):
        self.store = store
        self.static_root = static_root.resolve() if static_root else None
        self.poll_interval = max(0.1, poll_interval)
        self.quiet = quiet
        self.history = history
        self.refresher = refresher
        self.started_at = time.monotonic()
        super().__init__(address, ChiefdHandler)


class ChiefdHandler(BaseHTTPRequestHandler):
    server: ChiefdHTTPServer
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:
        if not self.server.quiet:
            super().log_message(format, *args)

    def _origin(self) -> str | None:
        origin = self.headers.get("Origin")
        if not origin:
            return None
        if origin in ALLOWED_ORIGINS or origin.startswith("http://127.0.0.1:"):
            return origin
        return None

    def _headers(self, content_type: str, length: int | None = None) -> None:
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        origin = self._origin()
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
        if length is not None:
            self.send_header("Content-Length", str(length))

    def _json(self, status: HTTPStatus, document: Any, etag: str | None = None) -> None:
        body = json.dumps(document, separators=(",", ":"), ensure_ascii=False).encode()
        self.send_response(status)
        self._headers("application/json; charset=utf-8", len(body))
        if etag:
            self.send_header("ETag", etag)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_OPTIONS(self) -> None:  # noqa: N802 - stdlib callback name
        self.send_response(HTTPStatus.NO_CONTENT)
        origin = self._origin()
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Last-Event-ID, If-None-Match")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_HEAD(self) -> None:  # noqa: N802 - stdlib callback name
        self.do_GET()

    def do_GET(self) -> None:  # noqa: N802 - stdlib callback name
        path = urlsplit(self.path).path
        if path == "/health":
            self._health()
        elif path == "/api/v1/snapshot":
            self._snapshot()
        elif path == "/api/v1/events":
            self._events()
        elif path == "/api/v1/history":
            self._history()
        elif path == "/api/v1":
            self._json(
                HTTPStatus.OK,
                {
                    "schemaVersion": SERVICE_SCHEMA,
                    "endpoints": ["/health", "/api/v1/snapshot", "/api/v1/events", "/api/v1/history", "/api/v1/refresh"],
                },
            )
        else:
            self._static(path)

    def do_POST(self) -> None:  # noqa: N802 - stdlib callback name
        path = urlsplit(self.path).path
        if path != "/api/v1/refresh":
            self._json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        if self.headers.get("Origin") and self._origin() is None:
            self._json(HTTPStatus.FORBIDDEN, {"error": "origin_not_allowed"})
            return
        if self.server.refresher is None:
            self._json(HTTPStatus.CONFLICT, {"error": "collector_not_configured"})
            return
        refreshed = self.server.refresher.refresh()
        self._json(
            HTTPStatus.OK if refreshed else HTTPStatus.SERVICE_UNAVAILABLE,
            {"schemaVersion": SERVICE_SCHEMA, "refreshed": refreshed,
             "error": self.server.refresher.last_error},
        )

    def _health(self) -> None:
        snapshot = self.server.store.health()
        self._json(
            HTTPStatus.OK if snapshot["available"] else HTTPStatus.SERVICE_UNAVAILABLE,
            {
                "schemaVersion": SERVICE_SCHEMA,
                "service": "chiefd",
                "version": SERVICE_VERSION,
                "status": "ok" if snapshot["available"] else "degraded",
                "uptimeSeconds": round(time.monotonic() - self.server.started_at, 3),
                "observedAt": utc_now(),
                "snapshot": snapshot,
            },
        )

    def _snapshot_event(self, snapshot: Snapshot) -> dict[str, Any]:
        return {
            "schemaVersion": EVENT_SCHEMA,
            "kind": "snapshot.updated",
            "observedAt": utc_now(),
            "source": {"kind": "portfolio-snapshot", "location": str(self.server.store.path)},
            "snapshot": {"etag": snapshot.etag, "generatedAt": snapshot.document.get("generatedAt")},
        }

    def _record_snapshot(self, snapshot: Snapshot, event: dict[str, Any] | None = None) -> None:
        if self.server.history:
            record = event or self._snapshot_event(snapshot)
            self.server.history.record(snapshot.etag, record["observedAt"], snapshot.document, record)

    def _snapshot(self) -> None:
        snapshot = self.server.store.load()
        if snapshot is None:
            self._json(
                HTTPStatus.SERVICE_UNAVAILABLE,
                {
                    "schemaVersion": SERVICE_SCHEMA,
                    "error": "snapshot_unavailable",
                    "message": self.server.store.error,
                },
            )
            return
        self._record_snapshot(snapshot)
        if self.headers.get("If-None-Match") == snapshot.etag:
            self.send_response(HTTPStatus.NOT_MODIFIED)
            self.send_header("ETag", snapshot.etag)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(HTTPStatus.OK)
        self._headers("application/json; charset=utf-8", len(snapshot.body))
        self.send_header("ETag", snapshot.etag)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(snapshot.body)

    def _events(self) -> None:
        if self.command == "HEAD":
            self.send_response(HTTPStatus.METHOD_NOT_ALLOWED)
            self.send_header("Allow", "GET")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(HTTPStatus.OK)
        self._headers("text/event-stream; charset=utf-8")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        last_etag = self.headers.get("Last-Event-ID")
        last_heartbeat = 0.0
        try:
            while True:
                snapshot = self.server.store.load()
                if snapshot and snapshot.etag != last_etag:
                    event = self._snapshot_event(snapshot)
                    payload = json.dumps(event, separators=(",", ":"), ensure_ascii=False)
                    self._record_snapshot(snapshot, event)
                    self.wfile.write(
                        f"id: {snapshot.etag}\nevent: snapshot.updated\ndata: {payload}\n\n".encode()
                    )
                    self.wfile.flush()
                    last_etag = snapshot.etag
                    last_heartbeat = time.monotonic()
                elif time.monotonic() - last_heartbeat >= 15:
                    self.wfile.write(f": heartbeat {utc_now()}\n\n".encode())
                    self.wfile.flush()
                    last_heartbeat = time.monotonic()
                time.sleep(self.server.poll_interval)
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

    def _history(self) -> None:
        if self.server.history is None:
            self._json(HTTPStatus.OK, {"schemaVersion": SERVICE_SCHEMA, "events": []})
            return
        self._json(
            HTTPStatus.OK,
            {"schemaVersion": SERVICE_SCHEMA, "events": self.server.history.events()},
        )

    def _static(self, request_path: str) -> None:
        root = self.server.static_root
        if root is None:
            self._json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        relative = unquote(request_path).lstrip("/") or "index.html"
        candidate = (root / relative).resolve()
        try:
            candidate.relative_to(root)
        except ValueError:
            self._json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        if not candidate.is_file():
            self._json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        body = candidate.read_bytes()
        content_type = mimetypes.guess_type(candidate.name)[0] or "application/octet-stream"
        if content_type.startswith("text/") or content_type in {"application/javascript", "application/json"}:
            content_type += "; charset=utf-8"
        self.send_response(HTTPStatus.OK)
        self._headers(content_type, len(body))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)


class ChiefdServer:
    """Small lifecycle wrapper used by the CLI and hermetic tests."""

    def __init__(
        self,
        snapshot: Path = DEFAULT_SNAPSHOT,
        static_root: Path | None = DEFAULT_STATIC_ROOT,
        host: str = DEFAULT_HOST,
        port: int = DEFAULT_PORT,
        poll_interval: float = 1.0,
        quiet: bool = False,
        database: Path | None = None,
        collector_config: Path | None = None,
        bootstrap_config: bool = False,
        collect_interval: float = 30.0,
    ):
        self.httpd = ChiefdHTTPServer(
            (host, port), SnapshotStore(snapshot), static_root, poll_interval, quiet,
            HistoryStore(database) if database else None,
            PortfolioRefresher(collector_config, snapshot, bootstrap_config) if collector_config else None,
        )
        if self.httpd.refresher:
            self.httpd.refresher.refresh()
        self.collect_interval = max(5.0, collect_interval)
        self._collector_stop = threading.Event()
        self._collector_thread: threading.Thread | None = None
        self._persist_current()

    @property
    def address(self) -> tuple[str, int]:
        host, port = self.httpd.server_address[:2]
        return str(host), int(port)

    def serve_forever(self) -> None:
        if self.httpd.refresher:
            self._collector_thread = threading.Thread(target=self._collect_forever, daemon=True)
            self._collector_thread.start()
        self.httpd.serve_forever(poll_interval=0.25)

    def _collect_forever(self) -> None:
        while not self._collector_stop.wait(self.collect_interval):
            if self.httpd.refresher:
                self.httpd.refresher.refresh()
                self._persist_current()

    def _persist_current(self) -> None:
        snapshot = self.httpd.store.load()
        if snapshot and self.httpd.history:
            observed_at = utc_now()
            event = {
                "schemaVersion": EVENT_SCHEMA, "kind": "snapshot.updated", "observedAt": observed_at,
                "source": {"kind": "portfolio-snapshot", "location": str(self.httpd.store.path)},
                "snapshot": {"etag": snapshot.etag, "generatedAt": snapshot.document.get("generatedAt")},
            }
            self.httpd.history.record(snapshot.etag, observed_at, snapshot.document, event)

    def shutdown(self) -> None:
        self._collector_stop.set()
        self.httpd.shutdown()
        self.httpd.server_close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Serve Chief's local observation API")
    parser.add_argument("--host", default=os.environ.get("CHIEFD_HOST", DEFAULT_HOST))
    parser.add_argument("--port", type=int, default=int(os.environ.get("CHIEFD_PORT", DEFAULT_PORT)))
    parser.add_argument(
        "--snapshot", type=Path, default=Path(os.environ.get("CHIEFD_SNAPSHOT", DEFAULT_SNAPSHOT))
    )
    parser.add_argument(
        "--static-root",
        type=Path,
        default=Path(os.environ.get("CHIEFD_STATIC_ROOT", DEFAULT_STATIC_ROOT)),
        help="Portfolio web root; pass an empty CHIEFD_STATIC_ROOT to disable it",
    )
    parser.add_argument("--poll-interval", type=float, default=1.0)
    parser.add_argument("--collect-interval", type=float, default=30.0)
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument(
        "--database", type=Path, default=Path(os.environ.get("CHIEFD_DATABASE", user_database_path())),
        help="SQLite history projection",
    )
    parser.add_argument(
        "--collector-config", type=Path,
        default=Path(os.environ.get("CHIEFD_CONFIG", user_config_path() if getattr(sys, "frozen", False) else source_config_path())),
        help="Portfolio and native-observer source configuration",
    )
    return parser


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    static_root = args.static_root if str(args.static_root) else None
    service = ChiefdServer(
        snapshot=args.snapshot,
        static_root=static_root,
        host=args.host,
        port=args.port,
        poll_interval=args.poll_interval,
        quiet=args.quiet,
        database=args.database if str(args.database) else None,
        collector_config=args.collector_config,
        bootstrap_config=getattr(sys, "frozen", False),
        collect_interval=args.collect_interval,
    )
    host, port = service.address
    print(f"chiefd {SERVICE_VERSION}: http://{host}:{port}", flush=True)

    def stop(_signum: int, _frame: object) -> None:
        threading.Thread(target=service.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    try:
        service.serve_forever()
    finally:
        service.httpd.server_close()


if __name__ == "__main__":
    main(sys.argv[1:])
