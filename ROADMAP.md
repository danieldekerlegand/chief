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
- **Chief program:** 1/1 built-program tasklists merged (`77`); 7 proposed forward tasklists authored (`tasks/chief/*.json`, `passes:false`, unrun) — pending a run, not merged.

---

## Milestones

One list, everything: shipped capabilities, the ongoing steady-state bars, and the modest planned
hardening. Chief was extracted from a production multi-tasklist setup, then generalized, so the
shipped rows are **capability bands, not a linear rewrite** — most predate self-hosting and carry no
single tasklist. Status legend: **✅ shipped · 🚧 partial / ongoing · ⬜ planned**. The Tasklist
column names the Chief tasklist that delivered a row (✅) or the *(proposed)* one that would; **—**
means the capability predates self-hosting or is continuous steady-state, not a discrete tasklist.

### Core harness — ✅ shipped

| Status | Milestone | Tasklist |
|---|---|---|
| ✅ | Core loop — fresh-agent story loop (implement → verify → commit → `passes:true`), COMPLETE stop condition | — |
| ✅ | Worktree isolation — per-tasklist git worktree + gitignored `.chief/state/`; loops can't corrupt each other | — |
| ✅ | The merge floor — serialized rebase → re-verify → `--no-ff` merge; interference degrades to a caught failure, never a silent bad merge | — |
| ✅ | Concurrency scheduler — `-p N`, `dependsOn` ordering, `touches` conflict-domains, `chief run -n` dry-run waves | — |
| ✅ | Resume & resilience — branch reuse, dead-pid lock auto-clear, `RATE_LIMIT_RETRY` pause/resume, `RESET=1` | — |
| ✅ | Merge-safety hardening — no-work guard, verify-failure re-engagement, mid-merge crash recovery | — |
| ✅ | Orphan reaping — reap by cwd, argv `--chief-run` marker, and inherited `$CHIEF_RUN_ID` (belt-and-braces) | `77-reap-by-inherited-run-marker` |

### Fabric, breadth & observability — ✅ shipped

| Status | Milestone | Tasklist |
|---|---|---|
| ✅ | Host-wide monitor — run registry + `chief ps`/`chief monitor`, pruning dead runs | — |
| ✅ | Cross-repo deps — wait on another repo's tasklist via `"<repo>:<tasklist>"` | — |
| ✅ | Nested submodules — merge bumps submodule pointers at every level, fails loudly on breakage | — |
| ✅ | Multi-provider — Claude / Devin / OpenCode selection + per-run model override; `chief models` | — |
| ✅ | Observability polish — `chief logs [-f]`, `--verbose`/`CHIEF_VERBOSE`, provider+model in `ps`/`monitor` | — |

### Install, test & CI — ✅ shipped

| Status | Milestone | Tasklist |
|---|---|---|
| ✅ | Self-install/update — `install.sh` (idempotent) + `chief update` (version-pinnable) | — |
| ✅ | Hermetic test suite — offline scripted-agent tests (smoke · ratelimit · monitor · noworkguard), CI on Ubuntu + macOS | — |

### Planned / hardening — ⬜ modest, capability-oriented

Chief is shipping and self-hosting; remaining work is hardening and breadth, not core function. The
two concrete items would be self-hosted tasklists (numbered from the current max, `77`); the two
ongoing bars are continuous upkeep, not discrete tasklists.

| Status | Milestone | Tasklist |
|---|---|---|
| ⬜ | Rebase-refusal vs. real content-conflict disambiguation — the merge phase labels **any** non-zero `git rebase` as `REBASE-CONFLICT` (`engine/driver.sh` §1492), so a worktree that merely *refuses* / is dirty-or-locked masquerades as a content collision (a spurious failure observed in practice); distinguish the two so a branch isn't parked on a false positive · S/M | `chief/78-rebase-refusal-vs-conflict-disambiguation` *(proposed)* |
| ⬜ | Desktop monitor-app decision — resolve the referenced-but-absent `app/` desktop GUI over the run registry: either land a thin monitor app or drop the reference · S (decision) / M (if built) | `chief/79-desktop-monitor-app-decision` *(proposed)* |
| 🚧 | Provider breadth — the multi-provider seam (Claude / Devin / OpenCode / Amp) is shipped; keeping the `--provider` roster + model lists current as agent CLIs evolve is ongoing | — |
| 🚧 | bash-3.2 compatibility upkeep — hold the bash 3.2 + shellcheck-clean bar as the engine grows; CI on Ubuntu + macOS is the guard | — |

### Embeddable engine (Chief inside other projects) — ⬜ proposed

The **core of a cross-cutting program**: make chief invocable and observable as an *embedded
execution engine* inside sibling projects — Cuneiform Riju instances first, then the
Insimul / Formant / Lugh / Praxis / Vita vibe-coding surfaces. Today chief is driven through the
interactive CLI (`bin/chief run`) and its state lives on the filesystem; a host app can already tail
`~/.chief/runs/`, but there is no stable programmatic entry point, no structured event stream, and no
supported roadmap→tasklist path for an operator agent to call. This phase turns the existing engine
(`engine/driver.sh` scheduler+worker, `engine/agent.sh` iteration, the `--provider` seam that already
dispatches OpenCode) into something a parent process can start, watch, and feed — **without
reimplementing the loop**. The rows are additive seams around the shipped engine, not a rewrite.

| Status | Milestone | Tasklist |
|---|---|---|
| ⬜ | Headless / library / programmatic invocation — a stable non-interactive entry point + documented exit contract so a host app can start a `driver.sh` run and read its result without the interactive `bin/chief` CLI (env/flags in, deterministic exit codes + run-id out) · M | `chief/80-headless-programmatic-invocation` *(proposed)* |
| ⬜ | Machine-readable run + tasklist status stream — emit structured (JSON) run / tasklist / story lifecycle events off the run registry so an external UI (chief-cloud, or a host like Cuneiform) can visualize complete vs. incomplete work live · M | `chief/81-machine-readable-status-stream` *(proposed)* |
| ⬜ | OpenCode + self-hosted / local-inference presets ("cost-avoidance mode") — first-class, preset-driven config that points heavy agentic testing at local inference via the existing OpenCode dispatch (accepting lower coding quality to avoid API cost); document the local-inference path as a supported mode · S/M | `chief/82-local-inference-cost-avoidance-preset` *(proposed)* |
| ⬜ | Roadmap → tasklist generation helper — a supported way to turn a product roadmap into `tasks/chief/NN-slug.json` tasklists programmatically (numbered bands · `branchName` · `dependsOn`), callable by the operation agents embedding chief · M | `chief/83-roadmap-to-tasklist-generator` *(proposed)* |
| ⬜ | Run-inside-a-container — make the worktree / path / git assumptions hold when chief runs inside a container or Riju workspace, so an embedded run behaves the same as a host run · S/M | `chief/84-run-inside-a-container` *(proposed)* |

**Depends on:** none — chief is the provider here. **Consumed by** chief-cloud (the status stream)
and cuneiform / insimul / formant / lugh / praxis / vita (the embedding hosts).

### By design — never a tasklist

Deliberate non-goals, not backlog:

| Status | Milestone | Tasklist |
|---|---|---|
| ⬜ | No AI auto-conflict-resolution — a real content conflict stops that tasklist for a human, by design | never |
| ⬜ | `touches` tags stay advisory — the **merge floor**, not perfect tagging, is the correctness guarantee (under-tagging costs a wasted rebase, over-tagging costs parallelism; neither costs correctness) | never |

### Loose wishlist — ⬜ not yet scoped

No large future threads are parked — chief is a tool and its scope stays deliberately small. The one
genuinely-open minor thread, noted in passing: **cross-host run aggregation** — the monitor +
registry are per host/user today, so runs on other machines don't appear; a shared/aggregated view
would be a convenience, not a correctness need.

---

## Chief Tasklist Status

- **1/1 built-program tasklists merged** (`77-reap-by-inherited-run-marker`); **7 proposed forward
  tasklists authored** (`tasks/chief/*.json`, `passes:false`, unrun) — pending a run, not merged.
  Records live in [`tasks/chief/completed/`](tasks/chief/completed/) (each stamped `mergedToMain`).
- **7 proposed tasklists** (`chief/78`–`chief/84`) back the Planned / hardening rows + the Embeddable-engine phase above
  — **now authored** (`tasks/chief/*.json`, `passes:false`, unrun); numbered from the
  current max (`77`). The two ongoing bars (provider breadth, bash-3.2 upkeep) are continuous upkeep,
  not discrete tasklists.
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
