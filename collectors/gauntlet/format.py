#!/usr/bin/env python3
"""Validate a Chief gauntlet definition and render modules for `chief gen`."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

PROVIDERS = {"claude", "codex", "devin", "opencode", "amp"}


def validate(data: dict) -> list[str]:
    errors = []
    if data.get("schemaVersion") != "chief.gauntlet/v1": errors.append("schemaVersion must be chief.gauntlet/v1")
    for key in ["id", "project", "goal"]:
        if not isinstance(data.get(key), str) or not data[key].strip(): errors.append(f"{key} must be a non-empty string")
    if data.get("approval") != "granted": errors.append("approval must be granted before tasklists can be formatted")
    modules = data.get("modules")
    if not isinstance(modules, list) or not modules: errors.append("modules must be a non-empty array"); modules = []
    ids = [m.get("id") for m in modules if isinstance(m, dict)]
    if len(ids) != len(set(ids)): errors.append("module ids must be unique")
    for index, module in enumerate(modules):
        if not isinstance(module, dict): errors.append(f"modules[{index}] must be an object"); continue
        for key in ["id", "title", "description"]:
            if not isinstance(module.get(key), str) or not module[key].strip(): errors.append(f"modules[{index}].{key} must be a non-empty string")
        unknown = set(module.get("dependsOn", [])) - set(ids)
        if unknown: errors.append(f"modules[{index}].dependsOn names unknown modules: {', '.join(sorted(unknown))}")
        provider = module.get("harness", {}).get("provider", "claude")
        if provider not in PROVIDERS: errors.append(f"modules[{index}] has unsupported provider {provider}")
    critics = data.get("critics")
    if not isinstance(critics, list) or not critics: errors.append("critics must be a non-empty array")
    elif any(c.get("freshContext") is not True for c in critics if isinstance(c, dict)): errors.append("every critic must require freshContext")
    return errors


def render(data: dict) -> dict:
    items, titles = [], {m["id"]: re.sub(r"^-|-$", "", re.sub(r"[^a-z0-9]+", "-", m["title"].lower()))[:48].rstrip("-") for m in data["modules"]}
    for module in data["modules"]:
        acceptance = module.get("acceptance", [])
        description = module["description"]
        if acceptance: description += " Acceptance: " + "; ".join(acceptance)
        harness = module.get("harness", {"provider": "claude"})
        description += f" Native harness: {harness.get('provider', 'claude')}"
        if harness.get("model"): description += f" ({harness['model']})"
        items.append({"title": module["title"], "description": description,
            "deps": [titles[x] for x in module.get("dependsOn", [])], "touches": module.get("touches", [])})
    return {"phases": [{"name": f"Gauntlet {data['id']} modules", "items": items}]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("definition", type=Path)
    parser.add_argument("--output", "-o", type=Path)
    args = parser.parse_args()
    data = json.loads(args.definition.read_text())
    errors = validate(data)
    if errors: raise SystemExit("gauntlet format refused:\n  - " + "\n  - ".join(errors))
    output = json.dumps(render(data), indent=2) + "\n"
    if args.output: args.output.write_text(output)
    else: print(output, end="")


if __name__ == "__main__": main()
