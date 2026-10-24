"""Git repository and worktree discovery adapter."""
from __future__ import annotations

from datetime import datetime
from pathlib import Path
from typing import Iterable

from .base import CommandRunner, Observation, ObservationBatch, freshness, parse_time, subprocess_runner, utc_now


class GitAdapter:
    name = "git"

    def __init__(
        self,
        roots: Iterable[Path],
        *,
        stale_seconds: int = 1_209_600,
        runner: CommandRunner = subprocess_runner,
    ) -> None:
        self.roots = [path.expanduser() for path in roots]
        self.stale_seconds = stale_seconds
        self.runner = runner

    def collect(self, now: datetime | None = None) -> ObservationBatch:
        observed_at = now or utc_now()
        batch = ObservationBatch(
            self.name, observed_at,
            capabilities={"sessionInventory": False, "liveness": False, "events": False},
        )
        repos = self._repositories(batch)
        if not repos and not any(root.exists() for root in self.roots):
            batch.status = "unavailable"
            return batch
        for repo in repos:
            self._collect_repo(repo, observed_at, batch)
        if batch.issues and batch.status == "ok":
            batch.status = "degraded"
        return batch

    def _repositories(self, batch: ObservationBatch) -> list[Path]:
        repos: set[Path] = set()
        for root in self.roots:
            if not root.exists():
                batch.issues.append(f"Git root not found: {root}")
                continue
            if (root / ".git").exists():
                repos.add(root.resolve())
                continue
            if not root.is_dir():
                continue
            for child in root.iterdir():
                if child.is_dir() and (child / ".git").exists():
                    repos.add(child.resolve())
        return sorted(repos)

    def _git(self, repo: Path, *args: str):
        return self.runner(("git", "-C", str(repo), *args))

    def _collect_repo(self, repo: Path, now: datetime, batch: ObservationBatch) -> None:
        log = self._git(repo, "log", "-1", "--format=%cI%x00%h%x00%s")
        if log.returncode != 0:
            batch.issues.append(f"cannot inspect Git repository {repo}: {log.stderr.strip()}")
            return
        parts = log.stdout.strip().split("\0")
        updated = parse_time(parts[0]) if parts and parts[0] else None
        branch = self._git(repo, "branch", "--show-current")
        dirty = self._git(repo, "status", "--short")
        batch.observations.append(Observation(
            id=f"git-repo:{repo}", kind="repository", provider=self.name,
            status="unknown", source=str(repo / ".git"), observed_at=now,
            title=repo.name, project_path=str(repo), updated_at=updated,
            freshness_data=freshness(
                now, updated, self.stale_seconds,
                reason="last commit age is repository activity, not agent liveness",
            ),
            attributes={
                "branch": branch.stdout.strip() if branch.returncode == 0 else None,
                "lastCommit": parts[1] if len(parts) > 1 else None,
                "lastCommitSubject": parts[2] if len(parts) > 2 else None,
                "dirtyFiles": len(dirty.stdout.splitlines()) if dirty.returncode == 0 else None,
            },
        ))
        worktrees = self._git(repo, "worktree", "list", "--porcelain")
        if worktrees.returncode != 0:
            batch.issues.append(f"cannot list Git worktrees for {repo}: {worktrees.stderr.strip()}")
            return
        for row in _worktrees(worktrees.stdout):
            path = Path(row["worktree"])
            wt_dirty = self._git(path, "status", "--short")
            wt_branch = row.get("branch", "").removeprefix("refs/heads/") or None
            batch.observations.append(Observation(
                id=f"git-worktree:{path}", kind="worktree", provider=self.name,
                status="unknown", source=f"git -C {repo} worktree list --porcelain",
                observed_at=now, title=path.name, project_path=str(repo), worktree_path=str(path),
                updated_at=updated,
                freshness_data=freshness(
                    now, updated, self.stale_seconds,
                    reason="worktree has no native heartbeat; repository commit age is a weak proxy",
                ),
                attributes={
                    "branch": wt_branch, "head": row.get("HEAD"), "detached": "detached" in row,
                    "bare": "bare" in row, "locked": row.get("locked"),
                    "prunable": row.get("prunable"),
                    "dirtyFiles": len(wt_dirty.stdout.splitlines()) if wt_dirty.returncode == 0 else None,
                    "liveness": "unknown",
                },
            ))


def _worktrees(text: str) -> list[dict[str, str]]:
    result: list[dict[str, str]] = []
    row: dict[str, str] = {}
    for line in [*text.splitlines(), ""]:
        if not line:
            if row.get("worktree"):
                result.append(row)
            row = {}
            continue
        key, _, value = line.partition(" ")
        row[key] = value
    return result
