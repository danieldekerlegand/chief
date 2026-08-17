# chief documentation

> **Status:** Current · **Updated:** 2026-08-14 · **Owner:** chief

**chief** is the autonomous tasklist runner every repo in this ecosystem is built with: you write `tasks/chief/*.json` and it drives an agent implement → verify → commit → merge, one story at a time, with worktree isolation.

The map. Structured per the ecosystem
[documentation standard](../../rosetta/docs/reference/documentation-standard.md) —
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
- [Cross-repo dependencies](reference/cross-repo-dependencies.md)
- [The event stream — chief's machine-readable status contract](reference/events.md)
- [Roadmap input contract (`chief gen`)](reference/roadmap-input.md)
- [Tasklist schema](reference/tasklist-schema.md)
- [The verify hook (`.chief/verify.sh`)](reference/verify-hook.md)

## Explanation

*understanding-oriented — why it is this way*

- [Drivers, scheduling, and the safety model](explanation/drivers-and-safety.md)
- [The research phase — buying the map once](research-phase.md)
- [Plan review — the checkpoint between criteria and code](plan-review.md)

## Decisions

*immutable; superseded by a successor, never edited in place*

- [Decision: chief stays CLI-only — the desktop GUI is chief-cloud's](decisions/desktop-gui-decision.md)
- [Decision: chief builds the overlap-zone registry; it does not bind a conflict predictor](decisions/conflict-predictor-adoption-decision.md)
