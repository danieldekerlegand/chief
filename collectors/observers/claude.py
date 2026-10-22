"""Claude Code background-agent inventory adapter."""
from __future__ import annotations

import json
from datetime import datetime
from typing import Any

from .base import (
    CommandRunner, Observation, ObservationBatch, freshness, parse_time,
    subprocess_runner, utc_now,
)

STATUS = {
    "busy": "active",
    "running": "active",
    "idle": "waiting",
    "waiting": "waiting",
    "paused": "paused",
    "completed": "complete",
    "complete": "complete",
    "failed": "failed",
    "error": "failed",
    "stopped": "gone",
}


class ClaudeAdapter:
    name = "claude-code"

    def __init__(self, runner: CommandRunner = subprocess_runner) -> None:
        self.runner = runner

    def collect(self, now: datetime | None = None) -> ObservationBatch:
        observed_at = now or utc_now()
        batch = ObservationBatch(
            self.name, observed_at,
            capabilities={"sessionInventory": True, "liveness": True, "events": False},
        )
        try:
            result = self.runner(("claude", "agents", "--json", "--all"))
        except RuntimeError as exc:
            batch.status = "unavailable"
            batch.issues.append(str(exc))
            return batch
        if result.returncode != 0:
            batch.status = "unavailable"
            message = result.stderr.strip().splitlines()[-1] if result.stderr.strip() else "unknown error"
            batch.issues.append(f"claude agents failed ({result.returncode}): {message}")
            return batch
        try:
            rows = json.loads(result.stdout)
        except ValueError:
            batch.status = "degraded"
            batch.issues.append("claude agents returned malformed JSON")
            return batch
        if not isinstance(rows, list):
            batch.status = "degraded"
            batch.issues.append("claude agents returned a JSON value other than an array")
            return batch
        for position, row in enumerate(rows):
            if not isinstance(row, dict):
                batch.status = "degraded"
                batch.issues.append(f"ignored non-object Claude record at index {position}")
                continue
            session_id = str(row.get("sessionId") or "").strip()
            if not session_id:
                batch.status = "degraded"
                batch.issues.append(f"ignored Claude record without sessionId at index {position}")
                continue
            raw_status = str(row.get("status") or "").lower()
            started = parse_time(row.get("startedAt"))
            ended = parse_time(row.get("endedAt"))
            # This command is a live inventory. Its observation is fresh even when
            # the session itself is old or terminal.
            batch.observations.append(Observation(
                id=f"claude:{session_id}", kind="native-session", provider=self.name,
                status=STATUS.get(raw_status, "unknown"), source="claude agents --json --all",
                observed_at=observed_at, title=str(row.get("name") or session_id),
                project_path=str(row.get("cwd")) if row.get("cwd") else None,
                worktree_path=str(row.get("worktree")) if row.get("worktree") else None,
                started_at=started, ended_at=ended, updated_at=observed_at,
                freshness_data=freshness(observed_at, observed_at, 60, reason="live Claude inventory"),
                attributes=_attributes(row, raw_status),
            ))
        return batch


def _attributes(row: dict[str, Any], raw_status: str) -> dict[str, Any]:
    result: dict[str, Any] = {"nativeStatus": raw_status or None}
    for source, target in (("pid", "pid"), ("kind", "sessionKind"), ("model", "model")):
        if row.get(source) is not None:
            result[target] = row[source]
    return result
