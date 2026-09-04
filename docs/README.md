# chief documentation

> **Status:** Current · **Updated:** 2026-09-04 · **Owner:** chief

**chief** is the autonomous tasklist runner every repo in this ecosystem is built with: you write `tasks/chief/*.json` and it drives an agent implement → verify → commit → merge, one story at a time, with worktree isolation.

The map. Structured per the ecosystem documentation standard —
`rosetta/docs/reference/documentation-standard.md`, cited by path because it lives in
a sibling repository and no relative link to it resolves from a chief worktree —
**a document not linked here does not exist**.

## Guides

*task-oriented — how to do one thing*

- [Running chief in a container / Riju workspace](guides/containers.md)
- [Embedding chief — headless / programmatic invocation](guides/headless-invocation.md)
- [The local-inference preset — cost avoidance as a supported mode](guides/local-inference-preset.md)
- [Monitoring active runs](guides/monitoring.md)
- [Providers — the onboarding recipe](guides/providers.md)

## Reference

*information-oriented — what it is*

- [Account credentials — running under a designated provider account](reference/account-credentials.md)
- [Host-wide concurrency](reference/concurrency.md)
- [Cross-repo dependencies](reference/cross-repo-dependencies.md)
- [Decision tasklists](reference/decision-tasklists.md)
- [The per-story diff-size budget](reference/diff-budget.md)
- [The event stream — chief's machine-readable status contract](reference/events.md)
- [Overlap zones — where a green gate is not enough authority to merge](reference/overlap-zones.md)
- [Provider unavailability — an iteration that never reached the model](reference/provider-unavailability.md)
- [Roadmap input contract (`chief gen`)](reference/roadmap-input.md)
- [`chief status` — what is left, and what can start now](reference/status.md)
- [Tasklist schema](reference/tasklist-schema.md)
- [The verify hook (`.chief/verify.sh`)](reference/verify-hook.md)
- [`chief usage` — cost and rate-limit reporting from the event logs](reference/usage.md)

## Explanation

*understanding-oriented — why it is this way*

- [Drivers, scheduling, and the safety model](explanation/drivers-and-safety.md)
- [Dead-code audit — the inventory, and the searches behind it](explanation/dead-code-audit.md)
- [The research phase — buying the map once](research-phase.md)
- [Plan review — the checkpoint between criteria and code](plan-review.md)

## Decisions

*immutable; superseded by a successor, never edited in place*

- [Decision: chief stays CLI-only — the desktop GUI is chief-cloud's](decisions/desktop-gui-decision.md)
- [Decision: chief builds the overlap-zone registry; it does not bind a conflict predictor](decisions/conflict-predictor-adoption-decision.md)

## Structure — what is here, and the one declared exception

`docs/` uses four of the standard's seven directories — `guides/`, `reference/`,
`explanation/`, `decisions/`. `tutorials/`, `runbooks/` and `archive/` are absent
because they are empty, not because they are disallowed; the standard names the
vocabulary, and an empty directory is not a document. There is no directory here
outside that vocabulary.

**The exception, declared:** `research-phase.md` and `plan-review.md` sit at the
`docs/` root rather than under `reference/`. They are cited by **bare path** from
roughly thirty places in `bin/chief`, `engine/*.sh`, `test/*.sh` and
`templates/agent-context.md`, and `scripts/check-doc-links.mjs` gates every one of
those citations — so relocating the two files is an edit to `bin/` and `engine/`,
which `test/version-bump.sh` then requires be paid for with an engine `VERSION`
bump. Bumping the engine version to move a doc puts a change in the version signal
that no consumer of the engine can act on. The two files are linked above and
banner-stamped like every other document; the deviation is their path, and it is
recorded here rather than left for a reader to find and wonder about. Anyone
retiring this exception should do it in the same commit as a real engine change.

## Corrections of record — 2026-09-04

Tasklist `901-docs-tell-the-truth` read this documentation set against the tree
rather than against itself. Each correction to a `docs/` file is also stated **in
the document it corrects**, under its banner, in the house `> **Corrected <date>**`
form — this list is the index, not a second home for the reasoning. The two root
files carry no banner, so their corrections are recorded only here.

| Document | What was wrong |
|---|---|
| [`reference/events.md`](reference/events.md) | The catalogue was **eight events behind the engine** (41 emitted, 33 documented) and claimed one log per run when two operator commands now write fixed logs of their own. This file calls itself the contract, so an omission here is a transition a conforming consumer may ignore. |
| [`reference/tasklist-schema.md`](reference/tasklist-schema.md) | `category` — carried by 46 of this repo's 47 tasklists (the exception predates the check), rendered by `chief list`, aggregated by `chief status`, and a **merge blocker** here via `scripts/check-tasklist-categories.mjs` — was named zero times. The DECISION/research note was also stated twice, in two wordings that had begun to disagree. |
| [`guides/providers.md`](guides/providers.md) | Counted **four** providers; `codex` was promoted 2026-08-19 and the roster table was updated then while the prose around it was not — the doc whose job is to stop roster drift had drifted against its own table. Its `README.md` link also pointed at this file rather than the repo README. |
| [`../README.md`](../README.md) · [`../CLAUDE.md`](../CLAUDE.md) | Both restated the verdict-cache key as **three** components; it has been four (`tree · base · hook · subs`) since the submodule component was added. `reference/verify-hook.md` is now cited as the single home for that table. `CLAUDE.md`'s layout map was also missing **13 of 33** `engine/` files and **7 of 23** `bin/chief` subcommands. |

**`Updated:` stamps.** Six banners named a date older than the last change to what
the document says, by up to three weeks — `explanation/drivers-and-safety.md`,
`guides/headless-invocation.md`, `reference/roadmap-input.md`,
`reference/status.md`, `reference/cross-repo-dependencies.md` and
`reference/verify-hook.md`. Restamped from git. The rule, stated so the next sweep
applies the same one: **`Updated:` is the last change to what the document *says*.**
A path-only link repair is not that, which is why `guides/containers.md`,
`guides/local-inference-preset.md`, `reference/account-credentials.md` and
`decisions/desktop-gui-decision.md` still read 2026-08-14 although git touched them
on 2026-08-15 — that commit only repointed relative links broken by the Diataxis
restructure.

**Known-wrong text this sweep did not touch, and why.** The three-component cache
key is also written into `engine/instructions.md` (injected into every agent
prompt), `bin/chief`'s `chief verify` hint, and `engine/lib.sh`'s two
`verify SKIPPED` lines. All four are correct about *behaviour* and understate the
*key*. They were left because `test/version-bump.sh` scopes on `engine/`, `bin/`,
`scripts/` and `install.sh` by path — so correcting a comment there obliges an
engine `VERSION` bump, which is the same argument this file already makes for the
declared exception above: a version signal no engine consumer can act on. Retire
this alongside a real engine change.
