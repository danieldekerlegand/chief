# Gauntlets in Chief

**Status:** Foundation implemented · **Updated:** 2026-10-21 · **Owner:** chief

Chief already supplies the execution substrate a gauntlet needs: fresh provider turns,
isolated worktrees, dependency-aware tasklists, host-wide concurrency limits, provider
selection, pause/resume, verification and merges. `chief ps`, `chief monitor`, `chief logs`
and `chief events` supply live and machine-readable monitoring. Chief invokes Claude Code,
Codex and the other supported CLIs; it does not reproduce their sessions, tools, delegation,
authentication or permission systems.

The gauntlet layer owns coordination metadata: modules, critic roles, rubrics, wave and stall
rules, operator requests, constraints and the relationship between a definition and its runs.
Its portable input is [`gauntlet.schema.json`](../packages/contracts/gauntlet.schema.json).

## Native execution path

1. Re-verify a proposal and record operator approval. Collection never makes a proposal runnable.
2. Render modules into Chief's existing roadmap contract and call `chief gen`; dependencies and
   conflict domains map to `dependsOn` and `touches` on normal, reviewable tasklists.
3. Run builders with `chief run --provider claude|codex -p N`. The selected CLI owns the agent
   runtime and may use its native delegation features when the module asks for them.
4. Run critics as fresh provider turns against builder evidence. Their verdicts cannot bypass
   repository verification or Chief's merge floor.
5. Feed `chief events` and tracker manifests to the portfolio UI. The event stream and tracker
   are live authority; Rosetta remains history and proposed backlog.

`npm run gauntlet:format -- definition.json -o roadmap.json` validates operator approval and
emits Chief's existing roadmap input. `chief gen roadmap.json` then creates the tasklists. A
future wave controller can call `chief run --headless` and consume `chief events`; it must never spawn
providers itself. Provider behavior and future Claude Code or Codex improvements remain inside
their native harnesses.

## Portfolio projection

The collector reads Rosetta's compendium index into `gauntlets[]`. Definitions stay separate
from live runs, carry refresh and fact-check dates, and mark every proposal `approvalRequired`.
The Gauntlets view is a reference surface rather than a scheduler or launch button.
