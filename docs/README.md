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
