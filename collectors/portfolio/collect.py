#!/usr/bin/env python3
"""Build a portable Chief portfolio snapshot from local, read-only sources."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

STATUS = {
    "✅": "complete", "done": "complete", "complete": "complete", "completed": "complete",
    "🚧": "active", "active": "active", "running": "active", "in progress": "active",
    "⬜": "planned", "planned": "planned", "proposed": "planned", "queued": "planned",
    "blocked": "blocked", "paused": "blocked", "reject": "blocked",
}


def run_git(repo: Path, *args: str) -> str:
    try:
        return subprocess.run(["git", "-C", str(repo), *args], check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=8).stdout.strip()
    except (subprocess.SubprocessError, OSError):
        return ""


def stable_id(*parts: str) -> str:
    return hashlib.sha1("\0".join(parts).encode()).hexdigest()[:12]


def clean(text: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[`*_]", "", text)).strip()


def status_of(text: str) -> str:
    lowered = clean(text).lower()
    for token, status in STATUS.items():
        if token in text or token in lowered:
            return status
    return "unknown"


def roadmap_items(repo: Path, project: str, names: list[str]) -> tuple[list[dict[str, Any]], str | None]:
    roadmap = next((repo / name for name in names if (repo / name).is_file()), None)
    if not roadmap:
        return [], None
    items = []
    for line_no, line in enumerate(roadmap.read_text(errors="replace").splitlines(), 1):
        if not line.lstrip().startswith("|"):
            continue
        cells = [clean(x) for x in line.strip().strip("|").split("|")]
        if len(cells) < 2 or set("".join(cells)) <= {"-", ":", " "}:
            continue
        status_index = next((i for i, cell in enumerate(cells[:2]) if status_of(cell) != "unknown"), None)
        if status_index is None:
            continue
        title = next((cell for i, cell in enumerate(cells) if i != status_index and len(cell) > 3), "")
        if not title or title.lower() in {"milestone", "status", "tasklist"}:
            continue
        items.append({"id": stable_id(project, str(line_no), title), "project": project, "status": status_of(cells[status_index]), "title": title, "source": f"{roadmap}:{line_no}", "evidence": " | ".join(cells[status_index + 1:])[:500]})
    return items, str(roadmap)


def active_tasklists(repo: Path) -> list[Path]:
    root = repo / "tasks" / "chief"
    return sorted(p for p in root.glob("*.json") if p.is_file()) if root.is_dir() else []


def scan_projects(root: Path, exclude: set[str], roadmap_names: list[str]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    projects, roadmap = [], []
    for git_dir in sorted(root.glob("*/.git")):
        repo, name = git_dir.parent, git_dir.parent.name
        if name in exclude:
            continue
        items, roadmap_path = roadmap_items(repo, name, roadmap_names)
        roadmap.extend(items)
        last = run_git(repo, "log", "-1", "--format=%cI%x00%h%x00%s").split("\0")
        dirty_lines = run_git(repo, "status", "--short").splitlines()
        tasks = active_tasklists(repo)
        worktrees = run_git(repo, "worktree", "list", "--porcelain").count("worktree ")
        latest_when = last[0] if len(last) == 3 else ""
        recent = False
        if latest_when:
            try:
                recent = (datetime.now(timezone.utc) - datetime.fromisoformat(latest_when)).days <= 14
            except ValueError:
                pass
        projects.append({
            "id": name, "name": name, "path": str(repo), "description": last[2] if len(last) == 3 else "",
            "tags": [],
            "activity": {"branch": run_git(repo, "branch", "--show-current"), "lastCommitAt": latest_when, "lastCommit": last[1] if len(last) == 3 else "", "dirtyFiles": len(dirty_lines), "activeTasklists": len(tasks), "worktrees": worktrees, "iterating": bool(tasks or worktrees > 1 or recent)},
            "roadmap": {"source": roadmap_path or "", "total": len(items), "complete": sum(x["status"] == "complete" for x in items), "active": sum(x["status"] == "active" for x in items), "planned": sum(x["status"] in {"planned", "unknown", "blocked"} for x in items)},
        })
    return projects, roadmap


def parse_competitors(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        return []
    project = "portfolio"
    findings = []
    for line_no, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
        heading = re.match(r"^###\s+([a-z0-9_-]+)\s+—", line, re.I)
        if heading:
            project = heading.group(1).lower()
            continue
        if not line.startswith("| **"):
            continue
        cells = [clean(x) for x in line.strip().strip("|").split("|")]
        if len(cells) < 3 or cells[0].lower() == "project":
            continue
        summary = cells[-2] if len(cells) > 3 else cells[-1]
        verdict = cells[-1] if len(cells) > 3 else "known"
        findings.append({"id": stable_id(project, cells[0]), "project": project, "title": cells[0], "status": verdict.upper()[:80], "summary": summary[:800], "source": f"{path}:{line_no}", "url": "", "features": []})
    return findings


def parse_ideas(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        return []
    data = json.loads(path.read_text())
    return data.get("ideas", data) if isinstance(data, dict) else data


def external_runs(private_root: Path, pattern: str) -> list[dict[str, Any]]:
    runs = []
    for path in sorted(private_root.glob(pattern)):
        try:
            data = json.loads(path.read_text())
        except (ValueError, OSError):
            continue
        for run in data.get("runs", []) if isinstance(data, dict) else []:
            if not isinstance(run, dict):
                continue
            item = dict(run)
            item.setdefault("progress", None)
            item.setdefault("updated", str(data.get("updated", "")))
            item.setdefault("media", [])
            runs.append(item)
    return runs


def research_sources(private_root: Path, pattern: str) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    sources, research = [], []
    for path in sorted(private_root.glob(pattern)):
        try:
            data = json.loads(path.read_text())
        except (ValueError, OSError):
            continue
        coverage = data.get("coverage", {}) if isinstance(data, dict) else {}
        summary = ", ".join(f"{key}={value}" for key, value in coverage.items())
        sources.append({"id": data.get("id", f"research:{path.stem}"), "kind": "research", "location": str(path), "status": "ok", "message": summary})
        for item in data.get("items", []):
            analysis = item.get("analysis", {})
            research.append({
                "id": f"{data.get('id', path.stem)}:{item.get('id', '')}", "sourceId": data.get("id", path.stem),
                "position": item.get("positionNewestFirst"), "title": item.get("title", item.get("id", "Untitled")),
                "url": item.get("url", ""), "thumbnail": item.get("thumbnail", ""), "durationSeconds": item.get("durationSeconds"),
                "transcript": item.get("transcript", {}), "status": analysis.get("status", "pending"),
                "summary": analysis.get("summary", ""), "lessons": analysis.get("lessons", []), "actions": analysis.get("actions", []),
                "visualReview": analysis.get("visualReview", []), "source": str(path),
            })
    return sources, research


def tracker_runs(root: Path) -> list[dict[str, Any]]:
    runs = []
    if not root.is_dir():
        return runs
    nav = {}
    nav_path = root / "nav.json"
    if nav_path.is_file():
        try:
            nav_data = json.loads(nav_path.read_text())
            for item in nav_data.get("nav", []) + nav_data.get("archived", []):
                if isinstance(item, dict):
                    nav[item.get("key") or item.get("id")] = item.get("url", "")
        except (ValueError, OSError):
            pass
    for state_path in sorted(root.glob("*/state.json")):
        try:
            state = json.loads(state_path.read_text())
        except (ValueError, OSError):
            continue
        key = state_path.parent.name
        progress = state.get("progress")
        if not isinstance(progress, (int, float)):
            milestones = state.get("milestones", [])
            if milestones:
                done = sum(str(x.get("status", "")).lower() in {"done", "pass", "complete", "completed"} for x in milestones if isinstance(x, dict))
                progress = round(done * 100 / len(milestones))
            else:
                progress = None
        shots = state.get("shots", [])
        media = [{"kind": "image", "uri": str((state_path.parent / shot.get("file", "")).resolve()), "caption": shot.get("caption", "")} for shot in shots if isinstance(shot, dict) and shot.get("file")]
        status_text = state.get("status", state.get("summary", ""))
        runs.append({"id": f"vibe:{key}", "project": state.get("project", "insimul"), "title": state.get("title", key), "status": status_of(str(status_text)), "progress": progress, "updated": str(state.get("updated", "")), "summary": clean(str(status_text))[:1000], "source": str(state_path), "url": nav.get(key, ""), "media": media})
    return runs


def collect(config_path: Path) -> dict[str, Any]:
    config = json.loads(config_path.read_text())
    workspace = config["workspace"]
    root = Path(workspace["root"]).expanduser().resolve()
    exclude = set(config.get("scan", {}).get("exclude", []))
    names = config.get("scan", {}).get("roadmap_names", ["ROADMAP.md"])
    projects, roadmap = scan_projects(root, exclude, names)
    sources = [{"id": "workspace", "kind": "git-workspace", "location": str(root), "status": "ok"}]
    private = config.get("private", {})
    private_root = Path(private.get("root", "")).expanduser()
    competitor_path = private_root / private.get("competitors", "")
    ideas_path = private_root / private.get("ideas", "")
    competitors = parse_competitors(competitor_path)
    ideas = parse_ideas(ideas_path)
    if private:
        sources.append({"id": "private", "kind": "private-workspace", "location": str(private_root), "status": "ok" if private_root.exists() else "missing"})
    runs = external_runs(private_root, private.get("runs", "portfolio/runs/*.json")) if private else []
    research_sources_found, research = research_sources(private_root, private.get("research", "portfolio/sources/*.json")) if private else ([], [])
    sources.extend(research_sources_found)
    for index, tracker in enumerate(config.get("trackers", [])):
        tracker_root = Path(tracker["root"]).expanduser()
        found = tracker_runs(tracker_root)
        runs.extend(found)
        sources.append({"id": f"tracker-{index}", "kind": tracker.get("kind", "tracker"), "location": str(tracker_root), "status": "ok" if tracker_root.exists() else "missing", "message": f"{len(found)} runs"})
    return {"schemaVersion": "chief.portfolio/v1", "generatedAt": datetime.now(timezone.utc).isoformat(), "workspace": {"name": workspace.get("name", root.name), "root": str(root)}, "projects": projects, "roadmap": roadmap, "competitors": competitors, "ideas": ideas, "runs": runs, "research": research, "sources": sources}


def main() -> None:
    here = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=Path(__file__).with_name("portfolio.json"))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    config_path = args.config if args.config.exists() else Path(__file__).with_name("portfolio.example.json")
    snapshot = collect(config_path)
    config = json.loads(config_path.read_text())
    output = args.output or (here / config["workspace"].get("output", "apps/portfolio/public/snapshot.json"))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(snapshot, indent=2) + "\n")
    print(f"wrote {output}: {len(snapshot['projects'])} projects, {len(snapshot['roadmap'])} roadmap items, {len(snapshot['runs'])} runs")


if __name__ == "__main__":
    main()
