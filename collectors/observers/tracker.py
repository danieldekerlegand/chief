"""Generic filesystem tracker adapter.

Tracker files are observed, never rewritten. Known JSON fields are projected and
everything else remains in the source document.
"""
from __future__ import annotations

import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable

from .base import Observation, ObservationBatch, file_time, freshness, parse_time, utc_now

STATUS = {
    "running": "active", "active": "active", "in progress": "active", "busy": "active",
    "queued": "waiting", "pending": "waiting", "not started": "waiting", "proposed": "waiting",
    "paused": "paused", "rate limited": "paused", "rate-limited": "paused",
    "blocked": "blocked", "awaiting decision": "blocked", "decision required": "blocked",
    "done": "complete", "complete": "complete", "completed": "complete", "passed": "complete",
    "failed": "failed", "error": "failed", "incomplete": "failed", "capped": "failed",
}


class TrackerAdapter:
    name = "tracker-files"

    def __init__(
        self,
        roots: Iterable[Path],
        *,
        stale_seconds: int = 86_400,
        names: tuple[str, ...] = ("state.json", "ledger.json", "RUNNING.md"),
    ) -> None:
        self.roots = [path.expanduser() for path in roots]
        self.stale_seconds = stale_seconds
        self.names = names

    def collect(self, now: datetime | None = None) -> ObservationBatch:
        observed_at = now or utc_now()
        batch = ObservationBatch(
            self.name, observed_at,
            capabilities={"sessionInventory": False, "liveness": False, "events": False},
        )
        existing = [root for root in self.roots if root.exists()]
        missing = [root for root in self.roots if not root.exists()]
        if missing:
            batch.issues.extend(f"tracker root not found: {path}" for path in missing)
        if not existing:
            batch.status = "unavailable"
            return batch

        paths: set[Path] = set()
        for root in existing:
            if root.is_file():
                paths.add(root)
            else:
                for name in self.names:
                    paths.update(root.rglob(name))
        for path in sorted(paths):
            if path.suffix.lower() == ".json":
                self._collect_json(path, observed_at, batch)
            else:
                self._collect_markdown(path, observed_at, batch)
        if batch.issues:
            batch.status = "degraded"
        return batch

    def _collect_json(self, path: Path, now: datetime, batch: ObservationBatch) -> None:
        try:
            value = json.loads(path.read_text(errors="replace"))
        except (OSError, ValueError) as exc:
            batch.issues.append(f"cannot parse tracker {path}: {exc}")
            return
        records = _records(value)
        for position, row in enumerate(records):
            native_status = _status_value(row)
            updated = _updated(row) or file_time(path)
            identifier = str(row.get("id") or row.get("runId") or row.get("key") or "").strip()
            suffix = identifier or (str(position) if len(records) > 1 else path.parent.name)
            progress = row.get("progress")
            attributes: dict[str, Any] = {
                "nativeStatus": native_status or None,
                "progress": progress if isinstance(progress, (int, float)) else None,
            }
            for key in ("lane", "stage", "round", "wave", "summary", "current"):
                if row.get(key) is not None and isinstance(row[key], (str, int, float, bool)):
                    attributes[key] = row[key]
            batch.observations.append(Observation(
                id=f"tracker:{path.resolve()}:{suffix}", kind="tracker-state",
                provider=self.name, status=_normalize_status(native_status), source=str(path),
                observed_at=now, title=str(row.get("title") or row.get("name") or identifier or path.parent.name),
                project_path=str(row.get("projectPath")) if row.get("projectPath") else None,
                worktree_path=str(row.get("worktree")) if row.get("worktree") else None,
                started_at=parse_time(row.get("startedAt") or row.get("started")), updated_at=updated,
                freshness_data=freshness(
                    now, updated, self.stale_seconds,
                    reason="tracker-declared update time, falling back to file modification time",
                ),
                attributes=attributes,
            ))

    def _collect_markdown(self, path: Path, now: datetime, batch: ObservationBatch) -> None:
        try:
            text = path.read_text(errors="replace")
        except OSError as exc:
            batch.issues.append(f"cannot read tracker {path}: {exc}")
            return
        heading = re.search(r"^#\s+(.+)$", text, re.MULTILINE)
        updated = file_time(path)
        batch.observations.append(Observation(
            id=f"tracker:{path.resolve()}", kind="tracker-document", provider=self.name,
            status="unknown", source=str(path), observed_at=now,
            title=heading.group(1).strip() if heading else path.stem, updated_at=updated,
            freshness_data=freshness(
                now, updated, self.stale_seconds,
                reason="document modification age; prose is not interpreted as live state",
            ),
            attributes={"liveness": "unknown"},
        ))


def _records(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, list):
        return [row for row in value if isinstance(row, dict)]
    if not isinstance(value, dict):
        return []
    for key in ("runs", "sessions", "items", "entries"):
        if isinstance(value.get(key), list):
            return [row for row in value[key] if isinstance(row, dict)]
    return [value]


def _status_value(row: dict[str, Any]) -> str:
    value = row.get("status")
    if isinstance(value, dict):
        value = value.get("state") or value.get("value")
    return str(value or row.get("state") or "").strip()


def _normalize_status(value: str) -> str:
    lowered = re.sub(r"[_-]+", " ", value.lower()).strip()
    exact = STATUS.get(lowered)
    if exact:
        return exact
    # Some established trackers use a human sentence instead of a state enum. Only
    # accept explicit lifecycle phrases; mentions such as "nothing is running" or
    # one paused lane must not decide the whole tracker's state.
    if re.match(r"^(closed|complete(?:d)?|finished|retired)\b", lowered):
        return "complete"
    if re.search(r"\b(merge complete|polish pass complete|stop condition was met)\b", lowered):
        return "complete"
    if re.search(r"\b(run resumed|loop resumed)\b", lowered):
        return "active"
    if re.match(r"^paused\b", lowered):
        return "paused"
    if re.search(r"\b(one )?decision (is )?needed\b|\bawaiting (an? )?operator decision\b", lowered):
        return "blocked"
    return "unknown"


def _updated(row: dict[str, Any]) -> datetime | None:
    for key in ("updatedAt", "updated_at", "updated", "lastUpdated", "last_updated"):
        parsed = parse_time(row.get(key))
        if parsed:
            return parsed
    return None
