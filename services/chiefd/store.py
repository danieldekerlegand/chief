"""Durable, local history for observer snapshots and lifecycle events."""
from __future__ import annotations

import json
import hashlib
import sqlite3
import threading
from pathlib import Path
from typing import Any


class HistoryStore:
    """Append-only SQLite projection. It never mutates provider or tracker state."""

    def __init__(self, path: Path):
        self.path = path.resolve()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        with self._connect() as db:
            db.executescript(
                """
                CREATE TABLE IF NOT EXISTS snapshots (
                  etag TEXT PRIMARY KEY,
                  fingerprint TEXT UNIQUE,
                  observed_at TEXT NOT NULL,
                  generated_at TEXT,
                  document TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS events (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  etag TEXT NOT NULL UNIQUE,
                  observed_at TEXT NOT NULL,
                  kind TEXT NOT NULL,
                  payload TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS events_observed_at ON events(observed_at DESC);
                """
            )
            columns = {row[1] for row in db.execute("PRAGMA table_info(snapshots)")}
            if "fingerprint" not in columns:
                db.execute("ALTER TABLE snapshots ADD COLUMN fingerprint TEXT")
                db.execute("CREATE UNIQUE INDEX IF NOT EXISTS snapshots_fingerprint ON snapshots(fingerprint)")

    @staticmethod
    def _fingerprint(document: dict[str, Any]) -> str:
        volatile = {"generatedAt", "observedAt", "updatedAt", "sourceUpdatedAt", "ageSeconds"}
        def stable(value: Any) -> Any:
            if isinstance(value, dict):
                return {key: stable(item) for key, item in sorted(value.items()) if key not in volatile}
            if isinstance(value, list):
                return [stable(item) for item in value]
            return value
        encoded = json.dumps(stable(document), separators=(",", ":"), ensure_ascii=False)
        return hashlib.sha256(encoded.encode()).hexdigest()

    def _connect(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.path, timeout=5)
        db.execute("PRAGMA journal_mode=WAL")
        return db

    def record(self, etag: str, observed_at: str, document: dict[str, Any], event: dict[str, Any]) -> bool:
        encoded = json.dumps(document, separators=(",", ":"), ensure_ascii=False)
        event_encoded = json.dumps(event, separators=(",", ":"), ensure_ascii=False)
        fingerprint = self._fingerprint(document)
        with self._lock, self._connect() as db:
            cursor = db.execute(
                "INSERT OR IGNORE INTO snapshots(etag, fingerprint, observed_at, generated_at, document) VALUES(?,?,?,?,?)",
                (etag, fingerprint, observed_at, document.get("generatedAt"), encoded),
            )
            if cursor.rowcount > 0:
                db.execute(
                    "INSERT OR IGNORE INTO events(etag, observed_at, kind, payload) VALUES(?,?,?,?)",
                    (etag, observed_at, event.get("kind", "snapshot.updated"), event_encoded),
                )
            for native in document.get("events", []):
                event_id = str(native.get("id") or "unknown")
                db.execute(
                    "INSERT OR IGNORE INTO events(etag, observed_at, kind, payload) VALUES(?,?,?,?)",
                    (f"native:{event_id}", native.get("observedAt") or observed_at,
                     native.get("eventType", "native.observed"),
                     json.dumps(native, separators=(",", ":"), ensure_ascii=False)),
                )
            db.execute(
                "DELETE FROM snapshots WHERE etag NOT IN (SELECT etag FROM snapshots ORDER BY rowid DESC LIMIT 100)"
            )
            db.execute(
                "DELETE FROM events WHERE kind = 'snapshot.updated' AND etag NOT IN (SELECT etag FROM snapshots)"
            )
            return cursor.rowcount > 0

    def events(self, limit: int = 100) -> list[dict[str, Any]]:
        bounded = max(1, min(limit, 1000))
        with self._lock, self._connect() as db:
            rows = db.execute(
                "SELECT payload FROM events ORDER BY id DESC LIMIT ?", (bounded,)
            ).fetchall()
        return [json.loads(row[0]) for row in rows]
