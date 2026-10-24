#!/usr/bin/env python3
"""Run cargo check with a temporary external-bin placeholder."""
from __future__ import annotations

import subprocess
from pathlib import Path

from build_sidecar import target_triple

DESKTOP = Path(__file__).resolve().parents[1]
placeholder = DESKTOP / "src-tauri" / "binaries" / f"chiefd-{target_triple()}"


def main() -> None:
    created = not placeholder.exists()
    if created:
        placeholder.parent.mkdir(parents=True, exist_ok=True)
        placeholder.touch(mode=0o755)
    try:
        subprocess.run(
            ["cargo", "check", "--manifest-path", "src-tauri/Cargo.toml"],
            cwd=DESKTOP,
            check=True,
        )
    finally:
        if created:
            placeholder.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
