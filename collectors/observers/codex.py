"""Best-effort Codex session-index adapter with explicit liveness limits."""
from __future__ import annotations

from datetime import datetime
from pathlib import Path

from .base import Observation, ObservationBatch, file_time, freshness, load_json_lines, parse_time, utc_now


class CodexAdapter:
    name = "codex"

    def __init__(self, codex_home: Path, stale_seconds: int = 86_400) -> None:
        self.codex_home = codex_home.expanduser()
        self.index = self.codex_home / "session_index.jsonl"
        self.locks = self.codex_home / "thread-writer-locks"
        self.stale_seconds = stale_seconds

    def collect(self, now: datetime | None = None) -> ObservationBatch:
        observed_at = now or utc_now()
        batch = ObservationBatch(
            self.name, observed_at, status="degraded",
            capabilities={"sessionInventory": True, "liveness": False, "events": False},
            issues=[
                "Codex exposes no non-interactive active-session inventory in this install; "
                "index entries are reported with unknown status"
            ],
        )
        if not self.index.is_file():
            batch.status = "unavailable"
            batch.issues.append(f"session index not found: {self.index}")
            return batch
        rows, issues = load_json_lines(self.index)
        batch.issues.extend(issues)
        lock_ids = {path.stem for path in self.locks.glob("*.lock")} if self.locks.is_dir() else set()
        index_updated = file_time(self.index)
        for line_number, row in rows:
            session_id = str(row.get("id") or row.get("thread_id") or "").strip()
            if not session_id:
                batch.issues.append(f"ignored Codex index record without id at {self.index}:{line_number}")
                continue
            updated = parse_time(row.get("updated_at") or row.get("updatedAt")) or index_updated
            batch.observations.append(Observation(
                id=f"codex:{session_id}", kind="native-session", provider=self.name,
                status="unknown", source=f"{self.index}:{line_number}", observed_at=observed_at,
                title=str(row.get("thread_name") or row.get("name") or session_id),
                project_path=str(row.get("cwd")) if row.get("cwd") else None,
                worktree_path=str(row.get("worktree")) if row.get("worktree") else None,
                updated_at=updated,
                freshness_data=freshness(
                    observed_at, updated, self.stale_seconds,
                    reason="index age measures discoverability, not process liveness",
                ),
                attributes={
                    "writerLockObserved": session_id in lock_ids,
                    "liveness": "unknown",
                    "livenessReason": "a writer lock is not proof that a Codex turn is running",
                },
            ))
        return batch
