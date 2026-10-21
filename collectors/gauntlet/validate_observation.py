#!/usr/bin/env python3
"""Validate a Chief loop-run observation without third-party dependencies."""
from __future__ import annotations

import argparse
import json
import math
import re
from pathlib import Path
from typing import Any

CONTRACT_DIR = Path(__file__).resolve().parents[2] / "packages" / "contracts"
ROOT_SCHEMA = CONTRACT_DIR / "loop-run.schema.json"
SCHEMA_CACHE: dict[Path, dict[str, Any]] = {}


def _load_schema(path: Path) -> dict[str, Any]:
    path = path.resolve()
    if path not in SCHEMA_CACHE:
        SCHEMA_CACHE[path] = json.loads(path.read_text())
    return SCHEMA_CACHE[path]


def _is_type(value: Any, expected: str) -> bool:
    return {
        "null": value is None,
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "boolean": isinstance(value, bool),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": isinstance(value, (int, float)) and not isinstance(value, bool),
    }.get(expected, True)


def validate_schema(value: Any, schema: dict[str, Any], path: str = "$", schema_path: Path = ROOT_SCHEMA) -> list[str]:
    """Validate the JSON Schema subset used by Chief's dependency-free contracts."""
    if "$ref" in schema:
        target = (schema_path.parent / schema["$ref"]).resolve()
        return validate_schema(value, _load_schema(target), path, target)

    errors: list[str] = []
    expected = schema.get("type")
    if expected is not None:
        types = expected if isinstance(expected, list) else [expected]
        if not any(_is_type(value, item) for item in types):
            return [f"{path}: expected {' or '.join(types)}, got {type(value).__name__}"]
    if "const" in schema and value != schema["const"]:
        errors.append(f"{path}: expected constant {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {value!r} is outside the allowed vocabulary")

    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}: missing required property {key}")
        properties = schema.get("properties", {})
        for key, item in value.items():
            if key in properties:
                errors.extend(validate_schema(item, properties[key], f"{path}.{key}", schema_path))
            elif schema.get("additionalProperties") is False:
                errors.append(f"{path}: unknown property {key}")
            elif isinstance(schema.get("additionalProperties"), dict):
                errors.extend(validate_schema(item, schema["additionalProperties"], f"{path}.{key}", schema_path))
    elif isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            errors.append(f"{path}: expected at least {schema['minItems']} items")
        if "items" in schema:
            for index, item in enumerate(value):
                errors.extend(validate_schema(item, schema["items"], f"{path}[{index}]", schema_path))
    elif isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            errors.append(f"{path}: string is shorter than {schema['minLength']}")
        if "pattern" in schema and re.fullmatch(schema["pattern"], value) is None:
            errors.append(f"{path}: {value!r} does not match {schema['pattern']}")
    elif isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path}: {value} is below {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path}: {value} is above {schema['maximum']}")
    return errors


def validate_semantics(data: dict[str, Any]) -> list[str]:
    """Check links and derived progress that JSON Schema cannot express clearly."""
    errors: list[str] = []
    lanes: dict[str, dict[str, Any]] = {}
    stages: dict[tuple[str, str], dict[str, Any]] = {}
    rounds: dict[str, dict[str, Any]] = {}

    for lane in data.get("lanes", []):
        lane_id = lane.get("id")
        if lane_id in lanes:
            errors.append(f"duplicate lane id: {lane_id}")
        lanes[lane_id] = lane
        for stage in lane.get("stages", []):
            key = (lane_id, stage.get("id"))
            if key in stages:
                errors.append(f"duplicate stage id in lane: {lane_id}/{stage.get('id')}")
            stages[key] = stage
            summary = stage.get("roundSummary", {})
            observed, void = summary.get("observed", 0), summary.get("void", 0)
            current, cap = summary.get("current"), summary.get("cap")
            if void > observed:
                errors.append(f"{lane_id}/{stage.get('id')}: void rounds exceed observed rounds")
            if current is not None and cap is not None and current > cap:
                errors.append(f"{lane_id}/{stage.get('id')}: current round exceeds its cap")
            for round_item in stage.get("rounds", []):
                round_id = round_item.get("id")
                if round_id in rounds:
                    errors.append(f"duplicate round id: {round_id}")
                rounds[round_id] = round_item
                if current is not None and round_item.get("number") == current:
                    break
            else:
                if current is not None:
                    errors.append(f"{lane_id}/{stage.get('id')}: current round has no round record")

        progress = lane.get("progress", {})
        lane_stages = lane.get("stages", [])
        passed = sum(stage.get("status") == "passed" for stage in lane_stages)
        capped = sum(stage.get("status") == "capped" for stage in lane_stages)
        closed = sum(stage.get("status") in {"passed", "capped", "failed", "skipped"} for stage in lane_stages)
        completed = passed if progress.get("metric") == "passed" else closed
        expected_percent = round(completed * 100 / len(lane_stages), 1) if lane_stages else 0
        if progress.get("total") != len(lane_stages):
            errors.append(f"{lane_id}: progress total does not match stage count")
        if progress.get("passed") != passed or progress.get("capped") != capped:
            errors.append(f"{lane_id}: progress outcome counts do not match stage states")
        if progress.get("completed") != completed:
            errors.append(f"{lane_id}: completed count does not match {progress.get('metric')} states")
        if not math.isclose(progress.get("percent", -1), expected_percent, abs_tol=0.05):
            errors.append(f"{lane_id}: progress percent should be {expected_percent}")

    def check_link(link: dict[str, Any], label: str) -> None:
        lane_id, stage_id = link.get("laneId"), link.get("stageId")
        if lane_id not in lanes:
            errors.append(f"{label}: unknown lane {lane_id}")
        if stage_id is not None and (lane_id, stage_id) not in stages:
            errors.append(f"{label}: unknown stage {lane_id}/{stage_id}")
        round_id = link.get("roundId")
        if round_id is not None and round_id not in rounds:
            errors.append(f"{label}: unknown round {round_id}")

    for lane in lanes.values():
        for link in lane.get("dependsOn", []):
            check_link(link, f"lane {lane['id']} dependency")
        for stage in lane.get("stages", []):
            for link in stage.get("dependsOn", []):
                check_link(link, f"stage {lane['id']}/{stage['id']} dependency")
    for item in data.get("followOnWork", []):
        for link in item.get("dependsOn", []):
            check_link(link, f"follow-on {item.get('id')} dependency")
    for item_name in ("nativeSessions", "findings", "operatorDecisions"):
        for item in data.get(item_name, []):
            links = item.get("links", [])
            if isinstance(links, dict):
                links = [links]
            for link in links:
                check_link(link, f"{item_name} {item.get('id')}")

    evidence_ids = {item.get("id") for item in data.get("evidence", [])}
    session_ids = {item.get("id") for item in data.get("nativeSessions", [])}
    finding_ids = {item.get("id") for item in data.get("findings", [])}
    for round_item in rounds.values():
        for value in round_item.get("builderSessionIds", []) + round_item.get("criticSessionIds", []):
            if value not in session_ids:
                errors.append(f"round {round_item['id']}: unknown session {value}")
        for value in round_item.get("findingIds", []):
            if value not in finding_ids:
                errors.append(f"round {round_item['id']}: unknown finding {value}")
        for value in round_item.get("evidenceIds", []):
            if value not in evidence_ids:
                errors.append(f"round {round_item['id']}: unknown evidence {value}")
    for item_name in ("findings", "operatorDecisions"):
        for item in data.get(item_name, []):
            for value in item.get("evidenceIds", []):
                if value not in evidence_ids:
                    errors.append(f"{item_name} {item['id']}: unknown evidence {value}")

    for decision in data.get("operatorDecisions", []):
        option_ids = {option.get("id") for option in decision.get("options", [])}
        selected = decision.get("selectedOptionId")
        if selected is not None and selected not in option_ids:
            errors.append(f"operator decision {decision['id']}: selected option is not declared")
        if decision.get("status") == "pending" and selected is not None:
            errors.append(f"operator decision {decision['id']}: pending decision cannot have a selection")
        if decision.get("status") == "resolved" and selected is None:
            errors.append(f"operator decision {decision['id']}: resolved decision requires a selection")

    runtime = data.get("runtime", {})
    if runtime.get("pausedSecondsKnown") is False and runtime.get("pausedSeconds") is not None:
        errors.append("runtime: pausedSeconds must be null while its duration is unknown")
    if runtime.get("pausedSecondsKnown") is True and runtime.get("pausedSeconds") is None:
        errors.append("runtime: pausedSeconds is required when its duration is known")

    entities = {data.get("id"), *lanes, *rounds, *session_ids, *finding_ids, *evidence_ids}
    entities.update(stage.get("id") for stage in stages.values())
    entities.update(item.get("id") for item in data.get("operatorDecisions", []))
    event_ids: set[str] = set()
    for event in data.get("events", []):
        if event.get("id") in event_ids:
            errors.append(f"duplicate event id: {event.get('id')}")
        event_ids.add(event.get("id"))
        if event.get("entityId") not in entities:
            errors.append(f"event {event.get('id')}: unknown entity {event.get('entityId')}")
    return errors


def validate(data: dict[str, Any]) -> list[str]:
    return validate_schema(data, _load_schema(ROOT_SCHEMA)) + validate_semantics(data)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    data = json.loads(args.manifest.read_text())
    errors = validate(data)
    if errors:
        raise SystemExit("loop-run observation is invalid:\n  - " + "\n  - ".join(errors))
    print(f"valid chief.loop-run/v1: {data['id']}")


if __name__ == "__main__":
    main()
