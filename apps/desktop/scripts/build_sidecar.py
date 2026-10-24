#!/usr/bin/env python3
"""Build chiefd in the filename format expected by Tauri externalBin."""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

DESKTOP = Path(__file__).resolve().parents[1]
ROOT = DESKTOP.parents[1]
BINARIES = DESKTOP / "src-tauri" / "binaries"


def target_triple() -> str:
    machine = platform.machine().lower()
    system = platform.system()
    if system == "Darwin":
        return "aarch64-apple-darwin" if machine in {"arm64", "aarch64"} else "x86_64-apple-darwin"
    if system == "Linux":
        arch = "aarch64" if machine in {"arm64", "aarch64"} else "x86_64"
        libc = "musl" if platform.libc_ver()[0].lower() == "musl" else "gnu"
        return f"{arch}-unknown-linux-{libc}"
    raise SystemExit(f"unsupported sidecar build platform: {system} {machine}")


def main() -> None:
    try:
        import PyInstaller  # noqa: F401
    except ImportError as exc:
        raise SystemExit(
            "PyInstaller is required to package chiefd. Install it in an isolated build environment "
            "with `python3 -m pip install pyinstaller`."
        ) from exc

    BINARIES.mkdir(parents=True, exist_ok=True)
    name = f"chiefd-{target_triple()}"
    with tempfile.TemporaryDirectory(prefix="chiefd-bundle-") as temporary:
        temporary_path = Path(temporary)
        dashboard = temporary_path / "chief-dashboard"
        dashboard.mkdir()
        for source in (ROOT / "apps" / "portfolio" / "public").iterdir():
            if source.is_file() and source.name != "snapshot.json" and not source.name.startswith("."):
                shutil.copy2(source, dashboard / source.name)

        command = [
            sys.executable,
            "-m",
            "PyInstaller",
            "--onefile",
            "--clean",
            "--name",
            name,
            "--paths",
            str(ROOT),
            "--distpath",
            str(BINARIES),
            "--workpath",
            str(temporary_path / "work"),
            "--specpath",
            str(temporary_path / "spec"),
            "--add-data",
            f"{dashboard}{os.pathsep}chief-dashboard",
            "--add-data",
            f"{ROOT / 'packages' / 'contracts'}{os.pathsep}packages/contracts",
            str(ROOT / "services" / "chiefd" / "entrypoint.py"),
        ]
        subprocess.run(command, cwd=ROOT, check=True)
    print(BINARIES / name)


if __name__ == "__main__":
    main()
