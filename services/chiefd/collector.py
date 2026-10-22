"""In-process, read-only portfolio refresh used by the desktop sidecar."""
from __future__ import annotations

import json
import os
import threading
from pathlib import Path
from typing import Any

from collectors.portfolio.collect import collect


def default_config(path: Path) -> dict[str, Any]:
    development = Path.home() / "Development"
    rosetta = development / "rosetta"
    return {
        "workspace": {"name": "Development", "root": str(development)},
        "private": {
            "root": str(rosetta),
            "competitors": "strategy/COMPETITORS.md",
            "ideas": "portfolio/ideas.json",
            "gauntlets": "docs/reference/gauntlet-loops/README.md",
            "runs": "portfolio/runs/*.json",
            "loopRuns": "portfolio/loop-runs/*.json",
            "research": "portfolio/sources/*.json",
        },
        "trackers": [{"kind": "vibe-trackers", "root": "~/vibe-trackers"}],
        "observers": {
            "claude": True,
            "codexHome": "~/.codex",
            "chiefRuns": "~/.chief/runs",
            "trackerRoots": ["~/insimul-loops/trackers", "~/vibe-trackers"],
            "gitRoots": [str(development)],
        },
        "scan": {"exclude": [], "roadmap_names": ["ROADMAP.md", "roadmap.md", "Roadmap.md"]},
    }


class PortfolioRefresher:
    def __init__(self, config_path: Path, snapshot_path: Path, bootstrap: bool = False):
        self.config_path = config_path.resolve()
        self.snapshot_path = snapshot_path.resolve()
        self._lock = threading.Lock()
        self.last_error: str | None = None
        if bootstrap and not self.config_path.exists():
            self.config_path.parent.mkdir(parents=True, exist_ok=True)
            self.config_path.write_text(json.dumps(default_config(self.config_path), indent=2) + "\n")

    def refresh(self) -> bool:
        with self._lock:
            try:
                document = collect(self.config_path)
                self.snapshot_path.parent.mkdir(parents=True, exist_ok=True)
                temporary = self.snapshot_path.with_suffix(self.snapshot_path.suffix + ".tmp")
                temporary.write_text(json.dumps(document, indent=2) + "\n")
                os.replace(temporary, self.snapshot_path)
                self.last_error = None
                return True
            except (OSError, ValueError, KeyError) as exc:
                self.last_error = str(exc)
                return False
