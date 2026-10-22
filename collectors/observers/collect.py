#!/usr/bin/env python3
"""Collect normalized telemetry from native tools without controlling them."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Sequence

from .base import BATCH_SCHEMA, ObserverAdapter, iso, utc_now
from .chief import ChiefAdapter
from .claude import ClaudeAdapter
from .codex import CodexAdapter
from .git import GitAdapter
from .tracker import TrackerAdapter


def collect(adapters: Sequence[ObserverAdapter]) -> dict:
    now = utc_now()
    batches = [adapter.collect(now) for adapter in adapters]
    observations = [item for batch in batches for item in batch.observations]
    return {
        "schema": "chief.observation-collection/1",
        "observedAt": iso(now),
        "adapters": [batch.to_dict() for batch in batches],
        "observations": [item.to_dict() for item in observations],
        "nativeSessions": [record for item in observations if (record := item.to_native_session())],
        "events": [record for item in observations if (record := item.to_normalized_event())],
        "summary": {
            "adapters": len(batches),
            "records": len(observations),
            "degraded": sum(batch.status == "degraded" for batch in batches),
            "unavailable": sum(batch.status == "unavailable" for batch in batches),
        },
    }


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--claude", action="store_true", help="read claude agents --json --all")
    result.add_argument("--codex-home", type=Path, help="read Codex's machine-readable session index")
    result.add_argument("--chief-runs", type=Path, help="read a Chief run registry and event logs")
    result.add_argument("--tracker-root", type=Path, action="append", default=[], help="scan a tracker root (repeatable)")
    result.add_argument("--git-root", type=Path, action="append", default=[], help="scan a repo or its immediate children (repeatable)")
    result.add_argument("--pretty", action="store_true")
    return result


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    adapters: list[ObserverAdapter] = []
    if args.claude:
        adapters.append(ClaudeAdapter())
    if args.codex_home:
        adapters.append(CodexAdapter(args.codex_home))
    if args.chief_runs:
        adapters.append(ChiefAdapter(args.chief_runs))
    if args.tracker_root:
        adapters.append(TrackerAdapter(args.tracker_root))
    if args.git_root:
        adapters.append(GitAdapter(args.git_root))
    if not adapters:
        parser().error("select at least one adapter")
    print(json.dumps(collect(adapters), indent=2 if args.pretty else None, sort_keys=args.pretty))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
