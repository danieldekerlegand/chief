"""Shared, deliberately small contract for read-only observation adapters.

The adapter contract is Python rather than a public storage schema on purpose.  It
lets chiefd evolve its persistence independently while every source reports the
same facts and uncertainty today.
"""
from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Protocol, Sequence

UTC = timezone.utc
OBSERVATION_SCHEMA = "chief.observation/1"
BATCH_SCHEMA = "chief.observation-batch/1"
KNOWN_STATUSES = {
    "active", "waiting", "paused", "blocked", "complete", "failed", "gone", "unknown"
}
NATIVE_SESSION_STATUS = {
    "active": "active", "waiting": "waiting", "paused": "paused",
    "complete": "complete", "failed": "failed", "gone": "stopped", "unknown": "unknown",
    "blocked": "unknown",
}
CONTRACT_PROVIDER = {"claude-code": "claude", "codex": "codex", "chief-legacy": "chief"}
CONTRACT_ATTRIBUTION = {
    "claude-code": "provider-cli", "codex": "provider-cli", "chief-legacy": "chief-legacy",
    "tracker-files": "tracker", "git": "git",
}


def utc_now() -> datetime:
    return datetime.now(UTC)


def iso(value: datetime) -> str:
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


def parse_time(value: Any) -> datetime | None:
    """Parse common provider timestamps without guessing local time zones."""
    if isinstance(value, (int, float)):
        # Claude's startedAt is epoch milliseconds. Epoch seconds stay seconds.
        seconds = value / 1000 if value > 10_000_000_000 else value
        try:
            return datetime.fromtimestamp(seconds, UTC)
        except (OverflowError, OSError, ValueError):
            return None
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(UTC)


def file_time(path: Path) -> datetime | None:
    try:
        return datetime.fromtimestamp(path.stat().st_mtime, UTC)
    except OSError:
        return None


def freshness(
    observed_at: datetime,
    source_updated_at: datetime | None,
    threshold_seconds: int | None,
    *,
    reason: str = "",
) -> dict[str, Any]:
    if source_updated_at is None or threshold_seconds is None:
        return {
            "state": "unknown",
            "sourceUpdatedAt": iso(source_updated_at) if source_updated_at else None,
            "ageSeconds": None,
            "thresholdSeconds": threshold_seconds,
            "reason": reason or "the source exposes no freshness signal",
        }
    age = max(0, int((observed_at - source_updated_at).total_seconds()))
    return {
        "state": "stale" if age > threshold_seconds else "fresh",
        "sourceUpdatedAt": iso(source_updated_at),
        "ageSeconds": age,
        "thresholdSeconds": threshold_seconds,
        "reason": reason,
    }


@dataclass
class Observation:
    id: str
    kind: str
    provider: str
    status: str
    source: str
    observed_at: datetime
    title: str = ""
    project_path: str | None = None
    worktree_path: str | None = None
    started_at: datetime | None = None
    ended_at: datetime | None = None
    updated_at: datetime | None = None
    freshness_data: dict[str, Any] = field(default_factory=dict)
    attributes: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        status = self.status if self.status in KNOWN_STATUSES else "unknown"
        return {
            "schema": OBSERVATION_SCHEMA,
            "id": self.id,
            "kind": self.kind,
            "provider": self.provider,
            "status": status,
            "title": self.title,
            "projectPath": self.project_path,
            "worktreePath": self.worktree_path,
            "startedAt": iso(self.started_at) if self.started_at else None,
            "endedAt": iso(self.ended_at) if self.ended_at else None,
            "updatedAt": iso(self.updated_at) if self.updated_at else None,
            "observedAt": iso(self.observed_at),
            "freshness": self.freshness_data or freshness(self.observed_at, None, None),
            "attributes": self.attributes,
            "provenance": {"adapter": self.provider, "source": self.source},
        }

    def to_native_session(self) -> dict[str, Any] | None:
        """Project a discovered native session into the public portable contract."""
        if self.kind != "native-session":
            return None
        links = self.attributes.get("links", [])
        if not isinstance(links, list):
            links = []
        return {
            "schemaVersion": "chief.native-session/v1",
            "id": self.id,
            "provider": CONTRACT_PROVIDER.get(self.provider, "other"),
            "externalId": self.id.partition(":")[2] or self.id,
            "status": NATIVE_SESSION_STATUS.get(self.status, "unknown"),
            "observedAt": iso(self.observed_at),
            "attribution": CONTRACT_ATTRIBUTION.get(self.provider, "inferred"),
            "worktree": self.worktree_path,
            "branch": self.attributes.get("branch"),
            "links": links,
            "extensions": {
                "title": self.title,
                "projectPath": self.project_path,
                "startedAt": iso(self.started_at) if self.started_at else None,
                "endedAt": iso(self.ended_at) if self.ended_at else None,
                "updatedAt": iso(self.updated_at) if self.updated_at else None,
                "freshness": self.freshness_data or freshness(self.observed_at, None, None),
                "source": self.source,
                "native": {key: value for key, value in self.attributes.items() if key != "links"},
            },
        }

    def to_normalized_event(self) -> dict[str, Any] | None:
        """Project a native event without inventing lane/stage correlation."""
        if self.kind != "activity-event":
            return None
        event_type = str(self.attributes.get("event") or self.title or "observation.unknown").lower()
        run_id = self.attributes.get("runId")
        return {
            "schemaVersion": "chief.normalized-event/v1",
            "id": self.id,
            "eventType": event_type,
            "entityType": "loop-run",
            "entityId": f"chief:{run_id}" if run_id else self.id,
            "occurredAt": iso(self.updated_at) if self.updated_at else None,
            "observedAt": iso(self.observed_at),
            "source": {
                "adapter": self.provider,
                "attribution": CONTRACT_ATTRIBUTION.get(self.provider, "inferred"),
                "cursor": self.source,
            },
            "data": self.attributes,
            "extensions": {"freshness": self.freshness_data},
        }


@dataclass
class ObservationBatch:
    adapter: str
    observed_at: datetime
    status: str = "ok"
    observations: list[Observation] = field(default_factory=list)
    issues: list[str] = field(default_factory=list)
    capabilities: dict[str, bool] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema": BATCH_SCHEMA,
            "adapter": self.adapter,
            "observedAt": iso(self.observed_at),
            "status": self.status,
            "capabilities": self.capabilities,
            "issues": self.issues,
            "observations": [item.to_dict() for item in self.observations],
        }


class ObserverAdapter(Protocol):
    name: str

    def collect(self, now: datetime | None = None) -> ObservationBatch: ...


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str = ""


CommandRunner = Callable[[Sequence[str]], CommandResult]


def subprocess_runner(argv: Sequence[str]) -> CommandResult:
    try:
        result = subprocess.run(
            list(argv), text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=15, check=False,
        )
    except FileNotFoundError as exc:
        raise RuntimeError(f"command unavailable: {argv[0]}") from exc
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"command timed out: {argv[0]}") from exc
    return CommandResult(result.returncode, result.stdout, result.stderr)


def load_json_lines(path: Path) -> tuple[list[tuple[int, dict[str, Any]]], list[str]]:
    rows: list[tuple[int, dict[str, Any]]] = []
    issues: list[str] = []
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError as exc:
        return [], [f"cannot read {path}: {exc}"]
    for line_number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except ValueError:
            issues.append(f"ignored malformed JSON at {path}:{line_number}")
            continue
        if isinstance(value, dict):
            rows.append((line_number, value))
        else:
            issues.append(f"ignored non-object JSON at {path}:{line_number}")
    return rows, issues
