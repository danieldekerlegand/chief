# chief — Roadmap

> The autonomous **tasklist runner** every sibling repo is built with: a stock-Bash engine + CLI
> that drives an AI coding agent through **implement → verify → commit → merge**, one user story at
> a time, with git-worktree-isolated parallelism and a serialized merge floor. North star: *turn a
> tasklist of user stories + acceptance criteria into merged, verified work with no silent bad
> merges — across any repo, any agent provider.*

**Status:** Shipping & self-hosting (v0.8.0 — see [`VERSION`](VERSION)) — in active hardening + provider-breadth mode · **Last updated:** 2026-08-11

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
- **Engine** (`engine/driver.sh` · `agent.sh` · `monitor.sh` · `lib.sh` · `live.sh` · `reap.sh`) +
  **CLI** (`bin/chief`): `init · run · list · ps · monitor · logs · models · reap · pause · resume
  · version · update`.
- **Multi-provider:** Claude Code (default), Devin, OpenCode, and Amp via `--provider`/`--model`
  (or `CHIEF_PROVIDER`/`CHIEF_MODEL` in `.chief/config`, or the `--claude`/`--devin`/`--opencode`/
  `--amp` shortcuts); legacy `CHIEF_TOOL`/`--tool` still accepted. All four are **first-class**:
  one `_run_provider` dispatch case each, both validator lists in lockstep, a `chief models` case,
  and a conformance fixture. Amp is its own dispatch case (never an alias); its CLI has no model
  selector, so `--model` is **refused** for it rather than ignored. Onboarding recipe:
  [`docs/providers.md`](docs/providers.md).
- **Safe by construction:** worktree isolation per tasklist, a serialized rebase → verify → merge
  floor, a no-work guard (EMPTY-NO-WORK), verify-failure re-engagement, mid-merge crash recovery,
  and orphan reaping keyed on the inherited `$CHIEF_RUN_ID` (`77`, merged).
- **Observability:** host-wide run registry (`~/.chief/runs/`) surfaced by `chief ps`/`chief monitor`
  with provider + model shown; `chief logs [-f]` tails a run; `CHIEF_VERBOSE`/`--verbose`.
- **Self-installing/updating** via `install.sh` + `chief update`; CI (shellcheck + `bash -n` + the
  behavioral suite) runs on Ubuntu and macOS (bash 3.2 is the compatibility floor).
- **Chief program:** 1/1 built-program tasklists merged (`77`); 15 proposed forward tasklists authored (`tasks/chief/*.json`, `passes:false`, unrun) — pending a run, not merged. The runnable head is the **agent-output quality & alignment** band (`88`–`91`), which should land before large tasklist backlogs are executed; the opt-in merge queue (`92`) is deliberately sequenced *behind* it.

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
| ✅ | Operator pause/resume — `chief pause`/`chief resume` (`--all` = fleet-wide) with **drain** semantics: the iteration in flight runs to completion, a finished agent loop still verifies + merges, the rest park as `paused` with branch + worktree kept | — |
| ✅ | Liveliness records — a per-tasklist fine-grained record (`engine/live.sh`: iteration · story · phase · last activity) next to the coarse state, surfaced by `chief ps`/`chief monitor` so "running" vs. hung is visible | — |
| ✅ | Driver-level usage-limit re-dispatch — the scheduler waits out a `rate-limited` tasklist and re-dispatches it itself, bounded by `RATE_LIMIT_REDISPATCH_MAX` (no operator needed; separate from the per-worker `RATE_LIMIT_RETRY` knobs) | — |
| ✅ | Bounded failed-tasklist retry — integration failures (VERIFY-FAILED / MERGE-CONFLICT / REBASE-CONFLICT) re-arm as `pending` up to `RETRY_MAX` total attempts, shown in `ps`/`monitor`; production failures stay failed | — *(shipped as engine work, commit `90dfc27`)* |

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

### Agent-output quality & alignment — ⬜ **highest priority**

Added 2026-08-11 from the context-engineering / "software factory" research
(see [`../AGENTIC-ENGINEERING-ADVISORY.md`](../AGENTIC-ENGINEERING-ADVISORY.md)). The finding:
**chief's merge gate is a binary test oracle, which is exactly the reward shape the RLVR critique
indicts** — *"there is no penalty for eroding codebase maintainability"* — and chief has **no human
checkpoint between "acceptance criteria written" and "merged to main."** That is the lights-off
factory architecture, whose documented outcome is +242.7% incidents per PR and a rewrite after
~4 months. Chief already implements the *good* half of the methodology by design (fresh agent per
story = intentional compaction, `progress.txt` artifacts, one-story units, filesystem resume); these
four rows close the gaps. **Run these before executing large tasklist backlogs.**

| Status | Milestone | Tasklist |
|---|---|---|
| ⬜ | **Code-quality ratchet gate** — give `verify.sh` a second, deterministic axis: complexity / duplication / decomposition / dependency-graph metrics measured as **deltas vs. base**, ratchet semantics (may improve, may not regress), committed baseline + explicit re-baseline. No model judgment anywhere in the gate. Modeled on talos's ratchet and SlopCodeBench's 41 deterministic measures · M/L | `chief/88-code-quality-ratchet-gate` *(proposed)* |
| ⬜ | **Plan-review checkpoint** — opt-in per tasklist: the agent emits a plan, a human approves/annotates, only an approved plan reaches code. Review surface is **adopted, not built** ([plannotator](https://github.com/backnotprop/plannotator), Apache-2.0/MIT, already hooks Claude Code + OpenCode). Absent reviewer **parks** via the existing pause-drain semantics — never blocks the scheduler, never silently proceeds · M/L | `chief/89-plan-review-checkpoint` *(proposed)* |
| ⬜ | **Research-phase artifact** — once per tasklist, sub-agents produce a structured, human-editable research document (target files, data flow, root cause, conventions) that every story then consumes. The highest-leverage review point ("a misunderstanding generates *thousands* of bad lines") and a compaction artifact that buys back per-story context · M | `chief/90-research-phase-artifact` *(proposed)* |
| ⬜ | **Enforceable overlap zones + diff-size budget** — promote `touches` from advisory hint to policy: declared high-impact domains require human approval even on a green gate (the merge floor catches textual conflict, not cross-branch *design* divergence); plus a per-story diff-size budget, since larger diffs measurably raise conflict probability (AgenticFlict) · M | `chief/91-enforceable-overlap-zones` *(proposed)* |

> **Doctrine adopted alongside these:** [12-factor-agents](https://github.com/humanlayer/12-factor-agents)
> (chief already satisfies #6 launch/pause/resume, #8 own-your-control-flow, #10 small-focused-agents,
> #11 trigger-from-anywhere, #12 stateless-reducer); the **review-leverage hierarchy** (research > plan >
> code) as review policy; and the framing *"you don't have too many PRs, you have too many bad PRs"* for
> any throughput decision.

### Merge throughput — ⬜ proposed, sequenced *after* the quality band

Added 2026-08-11 by **decision D1** in [`../ADOPT-DECIDE-REGISTER.md`](../ADOPT-DECIDE-REGISTER.md).
**Chief's merge floor is no longer unique** (finding F7): [Gastown](https://github.com/steveyegge/gastown)
(17,551★, MIT, active) ships a **Bors-style batch-then-bisect merge queue** — its "Refinery" batches
pending merge requests, rebases them as a stack on `main`, **verifies the batch tip once**, and on
failure **binary-bisects** to isolate the culprit, merging only the passers. That amortizes verification
across N merges instead of paying it N times, which is materially better at the ~360-tasklist scale this
portfolio is heading to.

**The decision was (a) opt-in mode, not replacement.** The serialized rebase → re-verify → `--no-ff`
floor **stays the default and remains the correctness guarantee**; batching is opted into per run.
Two constraints are load-bearing and are encoded in the tasklist: **bisect assumes deterministic
verification**, and `88`'s ratchet adds a non-boolean, path-dependent axis whose delta measured on a
*batch tip* is **not trivially attributable to one branch** — so the tasklist must either attribute it
mechanically or reject the batch wholesale and fall back to serialized; and `91`'s `review`-policy
overlap zones must not be smuggled into `main` inside a batch. Hence the sequencing: this runs **after
`88`–`91`**, not beside them.

**What is being adopted is one mechanism, not the project.** Gastown's own docs say it lacks
*dependency resolution across tasks* and acceptance-criteria ledgers — precisely chief's differentiators
(`dependsOn`/`touches` scheduling, the per-story `passes` ledger, the cross-repo run registry). Take the
Refinery's batching + bisect; keep everything else.

| Status | Milestone | Tasklist |
|---|---|---|
| ⬜ | **Opt-in batch-then-bisect merge queue** — batch N merge-ready branches, verify the tip once, binary-bisect on failure and merge only the passers; default-off, serialized floor unchanged when absent; flaky-gate detection falls back to serialized; ratchet regressions are attributed per-branch or the batch is rejected wholesale; `review`-zone branches never ride a batch · M/L | `chief/92-opt-in-batch-then-bisect-merge-queue` *(proposed)* |

### Planned / hardening — ⬜ modest, capability-oriented

Chief is shipping and self-hosting; remaining work is hardening and breadth, not core function. The
concrete items are self-hosted tasklists (numbered from the current max, `77`); the two
ongoing bars are continuous upkeep, not discrete tasklists.

| Status | Milestone | Tasklist |
|---|---|---|
| ⬜ | Rebase-refusal vs. real content-conflict disambiguation — the merge phase labels **any** non-zero `git rebase` as `REBASE-CONFLICT` (`engine/driver.sh` §1492), so a worktree that merely *refuses* / is dirty-or-locked masquerades as a content collision (a spurious failure observed in practice); distinguish the two so a branch isn't parked on a false positive · S/M | `chief/78-rebase-refusal-vs-conflict-disambiguation` *(proposed)* |
| ✅ | Desktop monitor-app decision — **decided: chief is CLI-only.** No desktop app is planned or referenced here; the GUI monitoring surface (and any cross-host view) is chief-cloud's Tauri app over `chiefd`, which consumes chief's run registry + the `81` status stream. Rationale + reversal clause in [`docs/desktop-gui-decision.md`](docs/desktop-gui-decision.md) · S (decision) | `chief/79-desktop-monitor-app-decision` |
| 🚧 | Provider breadth — the multi-provider seam dispatches Claude / Devin / OpenCode / Amp, all four first-class (dispatch case · both validators · shorthand · `chief models` · conformance fixture); Amp takes no `--model` (its CLI has no selector, so chief refuses it). Keeping the `--provider` roster + model lists current as agent CLIs evolve is ongoing | — |
| ✅ | Provider onboarding harness — [`docs/providers.md`](docs/providers.md) is the 10-item onboarding recipe, and `test/provider-conformance.sh` is the roster-driven scripted-fake harness (argv · prompt channel · model stance · completion, plus a drift guard over both validator lists), so a new agent CLI = one `_run_provider` dispatch case + one `ROSTER` line. **Amp settled: promoted**, first-class on every surface, with `--model` refused rather than ignored · S/M | `chief/85-provider-onboarding-harness` |
| ⬜ | Doc-sync gate — a grep-based, hermetic verify/CI check asserting README's version string == `VERSION` and the README command table covers every `bin/chief` subcommand (the exact drift class re-synced by hand on 2026-08-11, commit `995263c`) · S | `chief/86-doc-sync-gate` *(proposed)* |
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
| ⬜ | Machine-readable run + tasklist status stream — emit structured (JSON) run / tasklist / story lifecycle events off the run registry so an external UI (chief-cloud, or a host like Cuneiform) can visualize complete vs. incomplete work live; includes optional, nullable usage/cost/limit fields when the provider exposes them (the data source chief-cloud's `82` cost ledger persists) · M | `chief/81-machine-readable-status-stream` *(proposed)* |
| ⬜ | OpenCode + self-hosted / local-inference presets ("cost-avoidance mode") — first-class, preset-driven config that points heavy agentic testing at local inference via the existing OpenCode dispatch (accepting lower coding quality to avoid API cost); document the local-inference path as a supported mode · S/M | `chief/82-local-inference-cost-avoidance-preset` *(proposed)* |
| ⬜ | Roadmap → tasklist generation helper — a supported way to turn a product roadmap into `tasks/chief/NN-slug.json` tasklists programmatically (numbered bands · `branchName` · `dependsOn`), callable by the operation agents embedding chief · M | `chief/83-roadmap-to-tasklist-generator` *(proposed)* |
| ⬜ | Run-inside-a-container — make the worktree / path / git assumptions hold when chief runs inside a container or Riju workspace, so an embedded run behaves the same as a host run · S/M | `chief/84-run-inside-a-container` *(proposed)* |
| ⬜ | Account/credential selection seam — start a run *under a designated account*: a per-run credential env file (`chief run --account-env <file>` / `CHIEF_ACCOUNT_ENV_FILE`) applied around the provider invocation only, documented + hermetically tested, secrets never in logs/registry/state; the runner-side prerequisite chief-cloud's `91-account-pooling-and-capacity-balancing` builds on (chief does no pooling itself) · S/M | `chief/87-account-credential-seam` *(proposed)* |

**Depends on:** none — chief is the provider here. **Consumed by** chief-cloud (the status stream)
and cuneiform / insimul / formant / lugh / praxis / vita (the embedding hosts).

### By design — never a tasklist

Deliberate non-goals, not backlog:

| Status | Milestone | Tasklist |
|---|---|---|
| ⬜ | No AI auto-conflict-resolution — a real content conflict stops that tasklist for a human, by design | never |
| ⬜ | `touches` tags stay advisory — the **merge floor**, not perfect tagging, is the correctness guarantee (under-tagging costs a wasted rebase, over-tagging costs parallelism; neither costs correctness) | never |
| ⬜ | Cross-host run aggregation — the monitor + registry stay per host/user; the fleet-wide view across machines is **chief-cloud's** (its daemon + control plane aggregate over chief's on-disk state and, once `81` lands, its event stream), never a chief feature | never — chief-cloud's |

### Loose wishlist — ⬜ not yet scoped

Empty. No future threads are parked — chief is a tool and its scope stays deliberately small; every
known item is either an authored tasklist, an ongoing bar, or a **By design** non-goal above
(cross-host run aggregation moved there: it is chief-cloud's, not a chief convenience).

---

## Chief Tasklist Status

- **1/1 built-program tasklists merged** (`77-reap-by-inherited-run-marker`); **15 proposed forward
  tasklists authored** (`tasks/chief/*.json`, `passes:false`, unrun) — pending a run, not merged.
  Records live in [`tasks/chief/completed/`](tasks/chief/completed/) (each stamped `mergedToMain`).
- **15 proposed tasklists** (`chief/78`–`chief/92`) back the quality & alignment band, the
  Planned / hardening rows, the Embeddable-engine phase, and the merge-throughput row above —
  **now authored** (`tasks/chief/*.json`, `passes:false`, unrun); numbered from the current max (`77`).
  **Priority order:** `88`–`91` (quality & alignment) first — they change how every later tasklist
  is gated and reviewed — then `92` (opt-in batch-then-bisect), which `dependsOn` `88` and `91`
  because it has to say what a ratchet delta and an overlap-zone approval mean inside a batch.
  The two ongoing bars (provider breadth, bash-3.2 upkeep) are continuous upkeep,
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
- [`docs/providers.md`](docs/providers.md) — the provider onboarding recipe: every roster
  surface a new agent CLI must be wired into, and the limit-detection caveat.
- [`docs/monitoring.md`](docs/monitoring.md) — `chief ps`/`chief monitor` and the run registry.
- [`docs/cross-repo-dependencies.md`](docs/cross-repo-dependencies.md) — cross-repo `dependsOn`.
- [`examples/minimal/`](examples/minimal/) — a 3-tasklist demo you can `chief run -n`.
