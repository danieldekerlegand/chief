# Chief observability contracts

**Status:** Current · **Updated:** 2026-10-21 · **Owner:** chief

These JSON Schema contracts are Chief's portable boundary between coding harness adapters,
gauntlet trackers, private Rosetta data, and user interfaces. Each record carries a
`schemaVersion`; incompatible changes require a new version rather than changing the meaning of
an existing value.

| Contract | Version | Purpose |
|---|---|---|
| [`gauntlet.schema.json`](gauntlet.schema.json) | `chief.gauntlet/v1` | Human-approved loop definition and optional legacy-runner export |
| [`loop-run.schema.json`](loop-run.schema.json) | `chief.loop-run/v1` | One execution of a loop, including lane topology and runtime accounting |
| [`lane.schema.json`](lane.schema.json) | `chief.lane/v1` | Concurrent or sequential stream of stages within a run |
| [`stage.schema.json`](stage.schema.json) | `chief.stage/v1` | Stage lifecycle, dependencies, round cap, and outcome |
| [`round.schema.json`](round.schema.json) | `chief.round/v1` | One builder/critic attempt and its measurements |
| [`native-session.schema.json`](native-session.schema.json) | `chief.native-session/v1` | Provider-owned session correlated to observed work |
| [`finding.schema.json`](finding.schema.json) | `chief.finding/v1` | Critic defect, gap, blocker, risk, or observation |
| [`operator-decision.schema.json`](operator-decision.schema.json) | `chief.operator-decision/v1` | A choice reserved for the operator |
| [`evidence.schema.json`](evidence.schema.json) | `chief.evidence/v1` | Content-addressable or externally referenced proof |
| [`normalized-event.schema.json`](normalized-event.schema.json) | `chief.normalized-event/v1` | Provider-neutral lifecycle observation |

The root loop-run contract references the entity contracts rather than copying their definitions.
Records may also be stored and streamed independently. Provider-specific material belongs under
`extensions`, keyed by a namespaced provider identifier.
Native sessions may have an empty `links` array when a provider exposes a real session before
Chief has enough evidence to correlate it to a loop or lane. Adapters must preserve that unknown
state instead of dropping the session or inventing a relationship.

[`insimul-current-lanes.json`](fixtures/insimul-current-lanes.json) is the reference fixture for
two native Claude Code lanes reported on 2026-10-21. Validate it, including cross-record links and
derived counts, with:

```sh
python3 collectors/gauntlet/validate_observation.py \
  packages/contracts/fixtures/insimul-current-lanes.json
```
