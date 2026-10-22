"""Read Chief's existing run registry and append-only event logs."""
from __future__ import annotations

import os
from datetime import datetime
from pathlib import Path
from typing import Callable

from .base import Observation, ObservationBatch, file_time, freshness, load_json_lines, parse_time, utc_now

TERMINAL = {
    "merged": "complete", "no-work": "complete", "conflict": "failed",
    "verify-failed": "failed", "failed": "failed", "interrupted": "failed",
    "paused": "paused",
}
EVENT_STATUS = {
    "running": "active", "pending": "waiting", "rate-limited": "paused",
    "paused": "paused", "blocked": "blocked", "awaiting-review": "blocked",
    "awaiting-approval": "blocked", "awaiting-decision": "blocked",
    "done": "complete", "merged": "complete", "retired": "complete",
    "failed": "failed", "provider-unavailable": "blocked",
}


def process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except (ProcessLookupError, ValueError, OSError):
        return False


class ChiefAdapter:
    name = "chief-legacy"

    def __init__(
        self,
        runs_dir: Path,
        *,
        stale_seconds: int = 900,
        event_limit: int = 1_000,
        alive: Callable[[int], bool] = process_alive,
    ) -> None:
        self.runs_dir = runs_dir.expanduser()
        self.stale_seconds = stale_seconds
        self.event_limit = event_limit
        self.alive = alive

    def collect(self, now: datetime | None = None) -> ObservationBatch:
        observed_at = now or utc_now()
        batch = ObservationBatch(
            self.name, observed_at,
            capabilities={"sessionInventory": True, "liveness": True, "events": True},
        )
        if not self.runs_dir.is_dir():
            batch.status = "unavailable"
            batch.issues.append(f"Chief runs directory not found: {self.runs_dir}")
            return batch

        run_files = sorted(self.runs_dir.glob("*.run"))
        run_ids: set[str] = set()
        for path in run_files:
            fields = _key_values(path)
            run_id = fields.get("runid") or path.stem
            run_ids.add(run_id)
            try:
                pid = int(path.stem)
            except ValueError:
                pid = 0
            is_alive = bool(pid and self.alive(pid))
            event_path = Path(fields.get("events") or self.runs_dir / f"{run_id}.events.jsonl")
            last_event = _last_event(event_path)
            raw_state = str(last_event.get("state") or "") if last_event else ""
            raw_event = str(last_event.get("event") or "") if last_event else ""
            if raw_event == "run.finished":
                status = TERMINAL.get(raw_state, "unknown")
            else:
                status = "active" if is_alive else "gone"
            event_updated = parse_time(last_event.get("ts")) if last_event else None
            updated = event_updated or file_time(event_path) or file_time(path)
            batch.observations.append(Observation(
                id=f"chief:{run_id}", kind="legacy-run", provider=self.name,
                status=status, source=str(path), observed_at=observed_at,
                title=Path(fields.get("repo") or run_id).name,
                project_path=fields.get("repo"), started_at=parse_time(_number(fields.get("started"))),
                updated_at=updated,
                freshness_data=freshness(
                    observed_at, updated, self.stale_seconds,
                    reason="registry/event age; process liveness is reported separately",
                ),
                attributes={
                    "pid": pid or None, "processAlive": is_alive, "nativeState": raw_state or None,
                    "lastEvent": raw_event or None, "provider": fields.get("provider"),
                    "model": fields.get("model"), "parallel": _number(fields.get("parallel")),
                    "baseBranch": fields.get("base"), "tasklists": fields.get("names", "").split(),
                    "eventsPath": str(event_path),
                },
            ))

        for path in sorted(self.runs_dir.glob("*.events.jsonl")):
            rows, issues = load_json_lines(path)
            batch.issues.extend(issues)
            if len(rows) > self.event_limit:
                rows = rows[-self.event_limit:]
                batch.status = "degraded"
                batch.issues.append(f"limited {path} to its last {self.event_limit} events")
            for line_number, event in rows:
                event_name = str(event.get("event") or "unknown")
                run_id = str(event.get("runId") or path.name.removesuffix(".events.jsonl"))
                timestamp = parse_time(event.get("ts")) or file_time(path)
                native_state = str(event.get("state") or "")
                batch.observations.append(Observation(
                    id=f"chief-event:{run_id}:{line_number}", kind="activity-event",
                    provider=self.name, status=EVENT_STATUS.get(native_state, "unknown"),
                    source=f"{path}:{line_number}", observed_at=observed_at,
                    title=event_name, updated_at=timestamp,
                    freshness_data=freshness(
                        observed_at, timestamp, self.stale_seconds,
                        reason="event age is not run liveness",
                    ),
                    attributes={
                        "runId": event.get("runId"), "event": event_name,
                        "nativeState": event.get("state"), "tasklist": event.get("name"),
                        "story": event.get("story"), "detail": event.get("detail"),
                        "usage": event.get("usage"), "limit": event.get("limit"),
                        "hasRegistryEntry": run_id in run_ids,
                    },
                ))
        if batch.issues and batch.status == "ok":
            batch.status = "degraded"
        return batch


def _key_values(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        return result
    for line in lines:
        if "=" in line:
            key, value = line.split("=", 1)
            result[key] = value
    return result


def _last_event(path: Path) -> dict:
    if not path.is_file():
        return {}
    rows, _ = load_json_lines(path)
    return rows[-1][1] if rows else {}


def _number(value: str | None) -> int | float | None:
    if value is None:
        return None
    try:
        parsed = float(value)
    except ValueError:
        return None
    return int(parsed) if parsed.is_integer() else parsed
