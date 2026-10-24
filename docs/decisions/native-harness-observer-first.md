# Decision: Chief observes native coding harnesses first

**Status:** Accepted · **Date:** 2026-10-21

Chief's primary product is a local development-operations observatory. Claude Code, Codex,
OpenCode, and other coding harnesses own their agent sessions, delegation, context, worktrees,
repair loops, and provider-specific controls. Chief discovers and correlates that work across
projects without inserting its own scheduler into the middle of a successful native loop.

This decision supersedes the execution-first path in
[Gauntlets in Chief](../gauntlet-integration.md), amends the engine emphasis in
[the development-operations monorepo decision](portfolio-monorepo.md), and supersedes the product
boundary in [the desktop GUI decision](desktop-gui-decision.md). Those documents remain as the
record of why the earlier boundaries were chosen.

## Product boundary

| Component | Owns |
|---|---|
| Native coding harness | Agents, sessions, delegation, context, tools, worktrees, and its own loop |
| Gauntlet workspace | Goal, lanes, stages, critic rubric, stop rules, findings, decisions, and evidence |
| Chief observatory | Discovery, normalization, correlation, history, freshness, notifications, and analytics |
| Rosetta workspace data | Private proposals, strategy, research, and the human-readable gauntlet compendium |
| Project repository | Code, verification policy, roadmap, and durable outcomes |

Chief must be able to discover a session that Chief did not launch. Provider adapters are
read-only by default and normalize only facts that their source can support. A missing provider
field remains unknown; it is not inferred from a branch name, stale tracker, or prior run.

## Legacy runner

`chief run`, tasklists, the Bash scheduler, and the roadmap formatter remain supported. They are
useful for existing projects and deterministic tasklist-shaped work, but they are a compatibility
execution path rather than the default gauntlet architecture. Chief does not remove, silently
migrate, or weaken the verification and merge guarantees of an existing runner workflow.

The `chief.gauntlet/v1` formatter is therefore an export: after explicit operator approval it can
translate a definition into legacy Chief tasklists. A gauntlet definition, an observed run, and a
native provider session remain separate records. Merely collecting a proposed definition never
starts work.

## Stable observation model

Chief assigns stable IDs and records the following separately:

- loop definition and loop run;
- lane, stage, and critic round;
- native provider session;
- finding and operator decision;
- evidence artifact and normalized lifecycle event.

The versioned contracts live in [`packages/contracts`](../../packages/contracts/README.md). Source
adapters may retain provider-specific payloads, but the portable fields cannot depend on one
provider's internal protocol. Live tracker data wins over the compendium for execution state; the
compendium remains the authority for the proposal and its original prompt.

## Desktop direction

The observatory may ship as a menu-bar or system-tray application from this monorepo. A local
daemon and SQLite projection can support it without becoming dependencies of the Bash runner.
The application presents status and deep-links into the native harness. Starting, resuming,
stopping, approving, or merging work is a distinct capability and must never be implied by a
read-only observation.

## Consequences

- Provider improvements flow through without Chief reimplementing their agent managers.
- The same run can include Claude Code, Codex, OpenCode, and file-based tracker observations.
- Status carries provenance and observation time so stale reports are visible.
- Runtime and pause time are separate measurements; unknown pause duration stays unknown.
- A capped stage is closed but not passed, and an operator decision is not treated as a task.
- Chief's legacy runner can continue to evolve for its existing users without defining the new
  observatory's data model.
