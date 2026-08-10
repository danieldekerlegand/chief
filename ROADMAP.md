# chief — Roadmap

> The autonomous **tasklist runner** every sibling repo is built with: a stock-Bash engine + CLI
> that drives an AI coding agent through **implement → verify → commit → merge**, one user story at
> a time, with git-worktree-isolated parallelism and a serialized merge floor. North star: *turn a
> tasklist of user stories + acceptance criteria into merged, verified work with no silent bad
> merges — across any repo, any agent provider.*

**Status:** Shipping & self-hosting (v0.7.36) — in active hardening + provider-breadth mode · **Last updated:** 2026-08-10

This is the single canonical roadmap. Chief is a tool, not a product, and is **self-hosting** — its
own work is driven by chief against tasklists in [`tasks/chief/`](tasks/chief/); this file tracks
shipped capabilities vs. planned harness improvements and maps them to those tasklist IDs.

---

## Vision & Scope

Chief is the **harness**, not a product. You write a tasklist — an ordered list of `userStories`,
each with explicit `acceptanceCriteria` — and chief loops fresh agent instances through them:
implement one story, run the project's `verify.sh` gate, commit, flip `passes:true`, repeat, then
rebase → re-verify → merge the branch onto the base. Independent tasklists run concurrently, each in
its own git worktree, gated by a dependency + conflict-domain scheduler.

**In scope:** the project-agnostic engine (driver/scheduler, per-tasklist agent loop, worktree
isolation, the safe merge floor, the host-wide run monitor), the `chief` CLI, `chief init`
scaffolding templates, multi-provider agent support, and the hermetic test suite.
**Out of scope:** product or ecosystem logic (chief runs *other* repos' tasklists; it never
implements their work) and contract definitions (those live in `koine`).

## Current State

- **Runs on stock bash 3.2+ · git · jq** (`node` optional; `jq` fallback for everything). No build
  step, no daemon, no root. State lives on the filesystem, so an interrupted run just resumes.
- **Engine** (`engine/driver.sh` · `agent.sh` · `monitor.sh` · `lib.sh` · `reap.sh`) + **CLI**
  (`bin/chief`): `init · run · list · ps · monitor · logs · models · version · update`.
- **Multi-provider:** Claude Code (default), Devin, and OpenCode via `--provider`/`--model` (or
  `CHIEF_PROVIDER`/`CHIEF_MODEL` in `.chief/config`); legacy `CHIEF_TOOL`/`--tool` still accepted.
- **Safe by construction:** worktree isolation per tasklist, a serialized rebase → verify → merge
  floor, a no-work guard (EMPTY-NO-WORK), verify-failure re-engagement, mid-merge crash recovery,
  and orphan reaping keyed on the inherited `$CHIEF_RUN_ID` (`77`, merged).
- **Observability:** host-wide run registry (`~/.chief/runs/`) surfaced by `chief ps`/`chief monitor`
  with provider + model shown; `chief logs [-f]` tails a run; `CHIEF_VERBOSE`/`--verbose`.
- **Self-installing/updating** via `install.sh` + `chief update`; CI (shellcheck + `bash -n` + the
  behavioral suite) runs on Ubuntu and macOS (bash 3.2 is the compatibility floor).
- **Chief program:** 1 tasklist merged (`77`); **nothing pending**.

---

## Milestones

Chief was extracted from a production multi-tasklist setup, then generalized. Phases are
capability bands, not a linear rewrite.

| Phase | Capability | Status |
|---|---|---|
| Core loop | fresh-agent story loop (implement → verify → commit → `passes:true`), COMPLETE stop condition | ✅ |
| Worktree isolation | per-tasklist git worktree + gitignored `.chief/state/`; loops can't corrupt each other | ✅ |
| The merge floor | serialized rebase → re-verify → `--no-ff` merge; interference degrades to a caught failure, never a silent bad merge | ✅ |
| Concurrency scheduler | `-p N`, `dependsOn` ordering, `touches` conflict-domains, `chief run -n` dry-run waves | ✅ |
| Resume & resilience | branch reuse, dead-pid lock auto-clear, `RATE_LIMIT_RETRY` pause/resume, `RESET=1` | ✅ |
| Merge-safety hardening | no-work guard, verify-failure re-engagement, mid-merge crash recovery | ✅ |
| Orphan reaping | reap by cwd, argv `--chief-run` marker, and inherited `$CHIEF_RUN_ID` (belt-and-braces) | ✅ `77-reap-by-inherited-run-marker` |
| Host-wide monitor | run registry + `chief ps`/`chief monitor`, pruning dead runs | ✅ |
| Cross-repo deps | wait on another repo's tasklist via `"<repo>:<tasklist>"` | ✅ |
| Nested submodules | merge bumps submodule pointers at every level, fails loudly on breakage | ✅ |
| Multi-provider | Claude / Devin / OpenCode selection + per-run model override; `chief models` | ✅ |
| Observability polish | `chief logs [-f]`, `--verbose`/`CHIEF_VERBOSE`, provider+model in `ps`/`monitor` | ✅ |
| Self-install/update | `install.sh` (idempotent) + `chief update` (version-pinnable) | ✅ |
| Hermetic test suite | offline scripted-agent tests (smoke · ratelimit · monitor · noworkguard), CI on Ubuntu+macOS | ✅ |
| Rebase-refusal disambiguation | tell a worktree-refused rebase apart from a real content conflict | ⬜ planned (see Remaining) |
| Desktop monitor app | GUI for monitoring/managing jobs | ⬜ planned (README references `app/`; not yet in-tree) |

---

## Remaining / Next

Chief is shipping and self-hosting; remaining work is hardening and breadth, not core function.

1. **Rebase-refusal vs. real conflict** ⬜ (one-off, next hardening tasklist) — the merge phase can
   report a spurious `REBASE-CONFLICT` when the worktree merely *refuses* a rebase; distinguish that
   from a genuine content conflict so branches aren't parked on a false positive.
2. **Desktop monitor/management app** ⬜ (one-off) — README points at `app/` for a GUI over the run
   registry; the directory isn't in-tree yet. Either land it or drop the reference.
3. **Provider breadth — ongoing** 🚧 — keep the `--provider` roster current as agent CLIs evolve
   (Claude / Devin / OpenCode today; new providers behind the same seam).
4. **Compatibility floor upkeep — ongoing** 🚧 — hold the bash 3.2 + shellcheck-clean bar as the
   engine grows; CI on Ubuntu + macOS is the guard.

### Known limits (by design)
- Parallel drivers rely on the **merge floor**, not perfect `touches` tags: under-tagging costs a
  wasted rebase, over-tagging costs parallelism — neither costs correctness.
- No AI auto-conflict-resolution: a real conflict stops that tasklist for a human.
- The monitor + registry are **per host/user**; runs on other machines don't appear.

---

## Chief Tasklist Status

- **1/1 tasklist merged** (`77-reap-by-inherited-run-marker`); **0 pending**. Records live in
  [`tasks/chief/completed/`](tasks/chief/completed/) (each stamped `mergedToMain`).
- Chief is self-hosting: new work is written as `tasks/chief/NN-slug.json` and driven with chief
  itself. A `completed/` record means it merged — verify actual engine changes, not just `passes`
  flags.

---

## Related Docs

Reference docs (living, kept in place):
- [`README.md`](README.md) — install, quickstart, concepts, command reference.
- [`CLAUDE.md`](CLAUDE.md) — engine layout, per-iteration contract, quality gates.
- [`docs/tasklist-schema.md`](docs/tasklist-schema.md) — the tasklist JSON format.
- [`docs/drivers-and-safety.md`](docs/drivers-and-safety.md) — sequential vs. parallel,
  `dependsOn`/`touches`/`warmup`, and the safety model.
- [`docs/verify-hook.md`](docs/verify-hook.md) — writing `verify.sh`, the merge gate.
- [`docs/monitoring.md`](docs/monitoring.md) — `chief ps`/`chief monitor` and the run registry.
- [`docs/cross-repo-dependencies.md`](docs/cross-repo-dependencies.md) — cross-repo `dependsOn`.
- [`examples/minimal/`](examples/minimal/) — a 3-tasklist demo you can `chief run -n`.
