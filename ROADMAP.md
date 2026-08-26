# chief — Roadmap

> The autonomous **tasklist runner** every sibling repo is built with: a stock-Bash engine + CLI
> that drives an AI coding agent through **implement → verify → commit → merge**, one user story at
> a time, with git-worktree-isolated parallelism and a serialized merge floor. North star: *turn a
> tasklist of user stories + acceptance criteria into merged, verified work with no silent bad
> merges — across any repo, any agent provider.*

**Status:** Shipping & self-hosting (**v0.9.1** — [`VERSION`](VERSION) is the source of truth; this
line is checked against it by `test/doc-sync.sh`) — the built program is **37/37 tasklists merged**
(`77`–`113`, every record in [`tasks/chief/completed/`](tasks/chief/completed/) stamped with a real
`mergedToMain`); the live head is iteration-outcome honesty and the gates around it ·
**Last updated:** 2026-08-26

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
- **Engine** — `engine/driver.sh` (scheduler + per-tasklist worker) · `agent.sh` (one iteration) ·
  `lib.sh` · `paths.sh` · `deps.sh` · `status.sh` · `live.sh` · `events.sh` · `monitor.sh` ·
  `reap.sh` · `sweep.sh` · `measure.sh` · `quality.sh` · `research.sh` · `review.sh` · `zones.sh` ·
  `mergequeue.sh` · `concurrency.sh` · `budget.sh` · `repeat.sh` · `retire.sh` · `decision.sh` ·
  `criteria.sh` · `crossrepo.sh` · `counterpart.sh` · `gen.sh` · `gitenv.sh` · `preset.sh` ·
  `terminal.sh`.
- **CLI** (`bin/chief`) — the dispatch table is 22 subcommands: `init · run · list · status · lint ·
  gen · ps · monitor · logs · events · usage · models · reap · quality · retire · approve · decide ·
  pause · resume · version · update · help`. `test/doc-sync.sh` asserts README's command table covers
  every one of them.
- **Multi-provider:** Claude Code (default), Devin, OpenCode, Amp and Codex via `--provider`/`--model`
  (or `CHIEF_PROVIDER`/`CHIEF_MODEL` in `.chief/config`, or the `--claude`/`--devin`/`--opencode`/
  `--amp`/`--codex` shortcuts); legacy `CHIEF_TOOL`/`--tool` still accepted. **All five are
  first-class** — one `_run_provider` dispatch case each, both validator lists in lockstep, a
  `chief models` case, and a `test/provider-conformance.sh` ROSTER line. That count is asserted, not
  claimed: the conformance harness fails on any drift between the two validator lists and the roster.
  Amp is its own dispatch case (never an alias); its CLI has no model selector, so `--model` is
  **refused** for it rather than ignored. Onboarding recipe:
  [`docs/guides/providers.md`](docs/guides/providers.md).
- **Safe by construction:** worktree isolation per tasklist, a serialized rebase → verify → `--no-ff`
  merge floor, a no-work guard (EMPTY-NO-WORK), verify-failure re-engagement, mid-merge crash
  recovery, a merge phase that no longer rebases in the operator's dirty checkout (`93`, `5396c32`),
  and orphan reaping that identifies its own processes rather than inferring orphanhood (`77`,
  `bd030a6`; `99`, `e6826b1`).
- **Gates beyond the test oracle:** the deterministic code-quality ratchet (`chief quality ratchet`,
  `88`, `8924a86`), the evidence rule that refuses to pass a story whose measurable criterion carries
  no observation (`98`, `482b5ef`), declared overlap zones that hold a green branch for `chief approve`
  (`91`, `55c2e89`), and the opt-in plan-review and research checkpoints (`89`, `2e64bff`; `90`,
  `e8a54ec`).
- **Observability:** host-wide run registry (`~/.chief/runs/`) surfaced by `chief ps`/`chief monitor`
  with provider + model shown; `chief logs [-f]` tails a run; `chief events` is the machine-readable
  NDJSON stream (`81`, `00db922`); `chief status` reports what is left and what can start now across a
  whole portfolio (`97`, `f8c03bf`); `chief usage` reports spend and limit history (`105`, `0a178b2`);
  `CHIEF_VERBOSE`/`--verbose`.
- **Embeddable:** a documented headless entry point and exit-code contract (`80`, `f694cce`), the
  event stream above, container-safe path/git resolution (`84`, `10cde32`), a per-run credential seam
  (`87`, `f765431`), a local-inference cost-avoidance preset (`82`, `4aeb51f`), and `chief gen` for
  roadmap → tasklist authoring (`83`, `3ca2edf`).
- **Self-installing/updating** via `install.sh` + `chief update`; CI (shellcheck + `bash -n` + the
  behavioral suite) runs on Ubuntu and macOS (bash 3.2 is the compatibility floor).
- **Chief program:** **37/37 authored tasklists merged** (`77`–`113`). Every record in
  [`tasks/chief/completed/`](tasks/chief/completed/) was checked on 2026-08-26 and carries a real
  `mergedToMain` sha; the band ran `bd030a6` (2026-08-01) through `716c9e4` (2026-08-26). Three
  tasklists are live and unmerged: `114` (this one), `115`, `116`.

---

## Milestones

One list, everything: shipped capabilities, the ongoing steady-state bars, and the modest planned
hardening. Chief was extracted from a production multi-tasklist setup, then generalized, so the
shipped rows are **capability bands, not a linear rewrite** — the earliest rows predate self-hosting
and carry no single tasklist. Status legend: **✅ shipped · 🚧 partial / ongoing · ⬜ planned**. The
Tasklist column names the Chief tasklist that delivered a row (✅, with its merge sha) or the
*(proposed)* one that would; **—** means the capability predates self-hosting or is continuous
steady-state, not a discrete tasklist.

### Core harness — ✅ shipped

| Status | Milestone | Tasklist |
|---|---|---|
| ✅ | Core loop — fresh-agent story loop (implement → verify → commit → `passes:true`), COMPLETE stop condition | — |
| ✅ | Worktree isolation — per-tasklist git worktree + gitignored `.chief/state/`; loops can't corrupt each other | — |
| ✅ | The merge floor — serialized rebase → re-verify → `--no-ff` merge; interference degrades to a caught failure, never a silent bad merge | — |
| ✅ | Concurrency scheduler — `-p N`, `dependsOn` ordering, `touches` conflict-domains, `chief run -n` dry-run waves | — |
| ✅ | Resume & resilience — branch reuse, dead-pid lock auto-clear, `RATE_LIMIT_RETRY` pause/resume, `RESET=1` | — |
| ✅ | Merge-safety hardening — no-work guard, verify-failure re-engagement, mid-merge crash recovery | — |
| ✅ | Orphan reaping — reap by cwd, argv `--chief-run` marker, and inherited `$CHIEF_RUN_ID` (belt-and-braces) | `77-reap-by-inherited-run-marker` · `bd030a6` |
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
| ✅ | Multi-provider — Claude / Devin / OpenCode / Amp / Codex selection + per-run model override; `chief models` | — |
| ✅ | Observability polish — `chief logs [-f]`, `--verbose`/`CHIEF_VERBOSE`, provider+model in `ps`/`monitor` | — |

### Install, test & CI — ✅ shipped

| Status | Milestone | Tasklist |
|---|---|---|
| ✅ | Self-install/update — `install.sh` (idempotent) + `chief update` (version-pinnable) | — |
| ✅ | Hermetic test suite — offline scripted-agent tests (smoke · ratelimit · monitor · noworkguard), CI on Ubuntu + macOS | — |

### Agent-output quality & alignment — ✅ shipped (`88`–`91`, 2026-08-12 → 08-17)

Added 2026-08-11 from the context-engineering / "software factory" research
(see [`../AGENTIC-ENGINEERING-ADVISORY.md`](../AGENTIC-ENGINEERING-ADVISORY.md)). The finding:
**chief's merge gate was a binary test oracle, which is exactly the reward shape the RLVR critique
indicts** — *"there is no penalty for eroding codebase maintainability"* — and chief had **no human
checkpoint between "acceptance criteria written" and "merged to main."** That is the lights-off
factory architecture, whose documented outcome is +242.7% incidents per PR and a rewrite after
~4 months. Chief already implemented the *good* half of the methodology by design (fresh agent per
story = intentional compaction, `progress.txt` artifacts, one-story units, filesystem resume); these
four rows closed the gaps, and they landed **before** the large backlogs below were executed, as
sequenced.

| Status | Milestone | Tasklist |
|---|---|---|
| ✅ | **Code-quality ratchet gate** — `verify.sh` gained a second, deterministic axis: complexity / duplication / decomposition metrics measured as **deltas vs. base**, ratchet semantics (may improve, may not regress), committed baseline + explicit `--write-baseline` re-baseline. No model judgment anywhere in the gate. Shipped as `chief quality ratchet` (`engine/quality.sh`) | `chief/88-code-quality-ratchet-gate` · `8924a86` |
| ✅ | **Plan-review checkpoint** — opt-in per tasklist: the agent emits a plan, a human approves/annotates, only an approved plan reaches code. Absent reviewer **parks** via the existing pause-drain semantics — never blocks the scheduler, never silently proceeds ([`docs/plan-review.md`](docs/plan-review.md)) | `chief/89-plan-review-checkpoint` · `2e64bff` |
| ✅ | **Research-phase artifact** — once per tasklist, sub-agents produce a structured, human-editable research document (target files, data flow, root cause, conventions) that every story then consumes; persisted and reused, never regenerated ([`docs/research-phase.md`](docs/research-phase.md)) | `chief/90-research-phase-artifact` · `e8a54ec` |
| ✅ | **Enforceable overlap zones + diff-size budget** — `touches` promoted from advisory hint to policy: domains declared in `.chief/zones.conf` hold a green, rebased branch for `chief approve`, with the approval bound by checksum to the change it approved; plus a per-story diff-size budget ([`docs/reference/overlap-zones.md`](docs/reference/overlap-zones.md), [`docs/reference/diff-budget.md`](docs/reference/diff-budget.md)) | `chief/91-enforceable-overlap-zones` · `55c2e89` |

> **Doctrine adopted alongside these:** [12-factor-agents](https://github.com/humanlayer/12-factor-agents)
> (chief already satisfies #6 launch/pause/resume, #8 own-your-control-flow, #10 small-focused-agents,
> #11 trigger-from-anywhere, #12 stateless-reducer); the **review-leverage hierarchy** (research > plan >
> code) as review policy; and the framing *"you don't have too many PRs, you have too many bad PRs"* for
> any throughput decision.

### Merge throughput — ✅ shipped (`92`, 2026-08-18), sequenced *after* the quality band as planned

Added 2026-08-11 by **decision D1** in `rosetta/strategy/DECISIONS.md` (private).
**Chief's merge floor is no longer unique** (finding F7): [Gastown](https://github.com/steveyegge/gastown)
(17,551★, MIT, active) ships a **Bors-style batch-then-bisect merge queue** — its "Refinery" batches
pending merge requests, rebases them as a stack on `main`, **verifies the batch tip once**, and on
failure **binary-bisects** to isolate the culprit, merging only the passers. That amortizes verification
across N merges instead of paying it N times, which is materially better at the ~360-tasklist scale this
portfolio is heading to.

**The decision was (a) opt-in mode, not replacement**, and that is how it shipped. The serialized
rebase → re-verify → `--no-ff` floor **stays the default and remains the correctness guarantee**;
batching is opted into per run (`chief run --merge-batch[=N]` / `CHIEF_MERGE_BATCH`), and a batch of
one *is* that floor. Two constraints were load-bearing and are encoded in `engine/mergequeue.sh`:
**bisect assumes deterministic verification** (`CHIEF_MERGE_BATCH_BISECT=0` opts out, and a confirming
run that disagrees with the bisect abandons it and re-runs every branch serially from the sha its
worker finished on); and `91`'s `review`-policy overlap zones must not be smuggled into `main` inside a
batch. Hence the sequencing: this ran **after `88`–`91`**, not beside them.

**What was adopted is one mechanism, not the project.** Gastown's own docs say it lacks
*dependency resolution across tasks* and acceptance-criteria ledgers — precisely chief's differentiators
(`dependsOn`/`touches` scheduling, the per-story `passes` ledger, the cross-repo run registry). Take the
Refinery's batching + bisect; keep everything else.

| Status | Milestone | Tasklist |
|---|---|---|
| ✅ | **Opt-in batch-then-bisect merge queue** — batch N merge-ready branches, verify the tip once, binary-bisect on failure and merge only the passers; default-off, serialized floor unchanged when absent; a bisect the confirming run contradicts is abandoned wholesale and every branch re-run serially · M/L | `chief/92-opt-in-batch-then-bisect-merge-queue` · `c5ada5a` |

### Hardening & breadth — ✅ shipped (`78`–`87`), two ongoing bars

The 2026-08-11 hardening band. Every discrete row in it merged on 2026-08-12; what remains under this
heading is the two **continuous** bars, which are upkeep and never become tasklists.

| Status | Milestone | Tasklist |
|---|---|---|
| ✅ | Rebase-refusal vs. real content-conflict disambiguation — the merge phase used to label **any** non-zero `git rebase` as `REBASE-CONFLICT`, so a worktree that merely *refused* / was dirty-or-locked masqueraded as a content collision; the two are now distinguished and a branch is not parked on a false positive · S/M | `chief/78-rebase-refusal-vs-conflict-disambiguation` · `b1303ce` |
| ✅ | Desktop monitor-app decision — **decided: chief is CLI-only.** No desktop app is planned or referenced here; the GUI monitoring surface (and any cross-host view) is chief-cloud's Tauri app over `chiefd`, which consumes chief's run registry + the `81` status stream. Rationale + reversal clause in [`docs/decisions/desktop-gui-decision.md`](docs/decisions/desktop-gui-decision.md) · S (decision) | `chief/79-desktop-monitor-app-decision` · `0bca7f1` |
| ✅ | Provider onboarding harness — [`docs/guides/providers.md`](docs/guides/providers.md) is the 10-item onboarding recipe, and `test/provider-conformance.sh` is the roster-driven scripted-fake harness (argv · prompt channel · model stance · completion, plus a drift guard over both validator lists), so a new agent CLI = one `_run_provider` dispatch case + one `ROSTER` line. **Amp settled: promoted**, first-class on every surface, with `--model` refused rather than ignored · S/M | `chief/85-provider-onboarding-harness` · `f5cc21d` |
| ✅ | Doc-sync gate — a grep-based, hermetic verify/CI check asserting README's version string == `VERSION` and the README command table covers every `bin/chief` subcommand (the exact drift class re-synced by hand on 2026-08-11, commit `995263c`). Extended in `114` to cover this file · S | `chief/86-doc-sync-gate` · `cb543cd` |
| 🚧 | Provider breadth — the multi-provider seam dispatches Claude / Devin / OpenCode / Amp / Codex, **all five first-class** (dispatch case · both validators · shorthand · `chief models` · conformance fixture); Amp takes no `--model` (its CLI has no selector, so chief refuses it). Keeping the `--provider` roster + model lists current as agent CLIs evolve is ongoing | — |
| 🚧 | bash-3.2 compatibility upkeep — hold the bash 3.2 + shellcheck-clean bar as the engine grows; CI on Ubuntu + macOS is the guard | — |

### Embeddable engine (Chief inside other projects) — ✅ shipped (`80`–`84`, `87`, 2026-08-12)

The **core of a cross-cutting program**: make chief invocable and observable as an *embedded
execution engine* inside sibling projects — Cuneiform Riju instances first, then the
Insimul / Formant / Lugh / Praxis / Vita vibe-coding surfaces. Before this band chief was driven only
through the interactive CLI (`bin/chief run`) with its state on the filesystem; a host app could tail
`~/.chief/runs/`, but there was no stable programmatic entry point, no structured event stream, and no
supported roadmap→tasklist path for an operator agent to call. This phase turned the existing engine
into something a parent process can start, watch, and feed — **without reimplementing the loop**. The
rows are additive seams around the shipped engine, not a rewrite.

| Status | Milestone | Tasklist |
|---|---|---|
| ✅ | Headless / library / programmatic invocation — `chief run --headless`: a stable non-interactive entry point, a `chief: run-id=…` line, a JSON outcome summary and a documented exit-code table ([`docs/guides/headless-invocation.md`](docs/guides/headless-invocation.md)) · M | `chief/80-headless-programmatic-invocation` · `f694cce` |
| ✅ | Machine-readable run + tasklist status stream — `chief events`: an append-only NDJSON stream of run / tasklist / story lifecycle transitions off the run registry, with optional nullable usage/cost/limit fields ([`docs/reference/events.md`](docs/reference/events.md)) · M | `chief/81-machine-readable-status-stream` · `00db922` |
| ✅ | OpenCode + self-hosted / local-inference presets ("cost-avoidance mode") — `chief run --local` points every agent turn at a local endpoint via the OpenCode dispatch, erroring rather than falling back to a paid one when unconfigured ([`docs/guides/local-inference-preset.md`](docs/guides/local-inference-preset.md)) · S/M | `chief/82-local-inference-cost-avoidance-preset` · `4aeb51f` |
| ✅ | Roadmap → tasklist generation helper — `chief gen <roadmap.json>` emits one schema-valid `tasks/chief/NN-slug.json` per roadmap item (numbered bands · `branchName` · `dependsOn`), callable by the operation agents embedding chief ([`docs/reference/roadmap-input.md`](docs/reference/roadmap-input.md)) · M | `chief/83-roadmap-to-tasklist-generator` · `3ca2edf` |
| ✅ | Run-inside-a-container — worktree / path / git assumptions hold inside a container or Riju workspace: `engine/paths.sh` resolves state with `$HOME` unset or read-only, `engine/gitenv.sh` handles a repo owned by another uid ([`docs/guides/containers.md`](docs/guides/containers.md)) · S/M | `chief/84-run-inside-a-container` · `10cde32` |
| ✅ | Account/credential selection seam — `chief run --account-env <file>` / `CHIEF_ACCOUNT_ENV_FILE`, applied around the provider invocation only, documented + hermetically tested, secrets never in logs/registry/state ([`docs/reference/account-credentials.md`](docs/reference/account-credentials.md)) · S/M | `chief/87-account-credential-seam` · `f765431` |

**Depends on:** none — chief is the provider here. **Consumed by** chief-cloud (the status stream)
and cuneiform / insimul / formant / lugh / praxis / vita (the embedding hosts).

### By design — never a tasklist

Deliberate non-goals, not backlog:

| Status | Milestone | Tasklist |
|---|---|---|
| ⬜ | No AI auto-conflict-resolution — a real content conflict stops that tasklist for a human, by design | never |
| ⬜ | `touches` tags stay advisory *by default* — the **merge floor**, not perfect tagging, is the correctness guarantee (under-tagging costs a wasted rebase, over-tagging costs parallelism; neither costs correctness). A project may opt a named domain into policy with `91`'s overlap zones; nothing is enforced that was not declared | never |
| ⬜ | Cross-host run aggregation — the monitor + registry stay per host/user; the fleet-wide view across machines is **chief-cloud's** (its daemon + control plane aggregate over chief's on-disk state and its `81` event stream), never a chief feature | never — chief-cloud's |

### Loose wishlist — ⬜ not yet scoped

Empty. No future threads are parked — chief is a tool and its scope stays deliberately small; every
known item is either an authored tasklist, an ongoing bar, or a **By design** non-goal above
(cross-host run aggregation moved there: it is chief-cloud's, not a chief convenience).

---

## Chief Tasklist Status

- **37/37 authored tasklists merged** (`77`–`113`). Records live in
  [`tasks/chief/completed/`](tasks/chief/completed/), each stamped with a `mergedToMain` sha; all 37
  were checked against git on 2026-08-26 and none is missing one. The band runs `bd030a6`
  (2026-08-01) → `716c9e4` (2026-08-26).
- **3 live tasklists** in [`tasks/chief/`](tasks/chief/): `114-the-roadmap-describes-a-program-that-ended`
  (this file), `115-a-gate-that-did-not-run-is-not-a-gate-that-passed`,
  `116-a-decision-tasklist-cannot-finish`.
- The two ongoing bars (provider breadth, bash-3.2 upkeep) are continuous upkeep, not discrete
  tasklists.
- Chief is self-hosting: new work is written as `tasks/chief/NN-slug.json` and driven with chief
  itself. A `completed/` record means it merged — verify actual engine changes, not just `passes`
  flags.

---

## Related Docs

Reference docs (living, kept in place):
- [`README.md`](README.md) — install, quickstart, concepts, command reference.
- [`CLAUDE.md`](CLAUDE.md) — engine layout, per-iteration contract, quality gates.
- [`docs/reference/tasklist-schema.md`](docs/reference/tasklist-schema.md) — the tasklist JSON format.
- [`docs/explanation/drivers-and-safety.md`](docs/explanation/drivers-and-safety.md) — sequential vs. parallel,
  `dependsOn`/`touches`/`warmup`, and the safety model.
- [`docs/reference/verify-hook.md`](docs/reference/verify-hook.md) — writing `verify.sh`, the merge gate.
- [`docs/reference/status.md`](docs/reference/status.md) — `chief status`: scope resolution, the blocked-edge
  aggregation, categories and park reasons.
- [`docs/reference/usage.md`](docs/reference/usage.md) — `chief usage`: spend, limit incidents, reset ETA.
- [`docs/reference/decision-tasklists.md`](docs/reference/decision-tasklists.md) — DECISION tasklists and `chief decide`.
- [`docs/guides/providers.md`](docs/guides/providers.md) — the provider onboarding recipe: every roster
  surface a new agent CLI must be wired into, and the limit-detection caveat.
- [`docs/guides/monitoring.md`](docs/guides/monitoring.md) — `chief ps`/`chief monitor` and the run registry.
- [`docs/guides/headless-invocation.md`](docs/guides/headless-invocation.md) — the embedding entry point.
- [`docs/reference/events.md`](docs/reference/events.md) — the NDJSON event stream.
- [`docs/reference/cross-repo-dependencies.md`](docs/reference/cross-repo-dependencies.md) — cross-repo `dependsOn`.
- [`examples/minimal/`](examples/minimal/) — a 3-tasklist demo you can `chief run -n`.
