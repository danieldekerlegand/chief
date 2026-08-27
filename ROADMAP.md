# chief — Roadmap

> The autonomous **tasklist runner** every sibling repo is built with: a stock-Bash engine + CLI
> that drives an AI coding agent through **implement → verify → commit → merge**, one user story at
> a time, with git-worktree-isolated parallelism and a serialized merge floor. North star: *turn a
> tasklist of user stories + acceptance criteria into merged, verified work with no silent bad
> merges — across any repo, any agent provider.*

**Status:** Shipping & self-hosting (**v0.9.7** — [`VERSION`](VERSION) is the source of truth; this
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

One list, everything: shipped capability bands, the three tasklists in flight, the ongoing
steady-state bars, and the open threads that carry a recorded decision rather than a plan. Chief was extracted from a production multi-tasklist setup, then generalized, so the
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

### Operating the fleet — merge safety, durability & the evidence rule — ✅ shipped (`93`–`103`, 2026-08-17 → 08-20)

Eleven tasklists, and **not one of them came from a design wishlist** — every row was written from a
failure observed while chief was driving the portfolio, with the measurement in the tasklist. Three
threads run through the band: the **merge floor** meeting a real operator (`93`, `94`), the
**resources a run creates and never collects** (`95`, `99`, `102`, `103`), and the **evidence rule** —
chief refusing to record a pass it cannot check (`98`, `100`, `101`), which is the direct ancestor of
the iteration-outcome band below.

| Status | Milestone | Tasklist |
|---|---|---|
| ✅ | **Dirty-checkout merge safety** — the merge phase stopped rebasing in the *operator's* checkout, and a refused rebase is never re-dispatched to the agent. Two cuneiform tasklists had each finished every story, each failed to merge over one modified tracked file, and each burned 3/3 retries — six wasted iterations for work that was already done | `chief/93-dirty-checkout-merge-safety` · `5396c32` |
| ✅ | **Stall flag is run-state aware** — per-phase thresholds plus elapsed-in-phase shown routinely, so *slow* is distinguishable from *stuck*. Nine runs were stopped as "stalled"; **seven were working** (logs of 73 KB / 47 KB / 21 KB), flagged only because `provider-waiting` is the whole duration of an agent turn and had no clock beside it | `chief/94-stall-flag-is-run-state-aware` · `1ff485a` |
| ✅ | **Worktree build-artifact reaping** (`engine/sweep.sh`) — what chief *caused to be built* inside a worktree goes with the worktree, as a table of toolchain artifact dirs. A shared `CARGO_TARGET_DIR`, a symlink or a sibling worktree is refused with a stated reason, never followed. The trigger: a `target/` tree at **61 GB across 729,816 files** | `chief/95-worktree-build-artifact-reaping` · `25d1c3e` |
| ✅ | **Submodule story-progress durability** — for a `repo:<sub>` tasklist the tasklist lives in the parent and the work branch in the submodule, so neither side could record "2 of 3"; an insimul tasklist at 2/3 resumed at **0/3** onto a branch already carrying its own work. The per-tasklist snapshot outside the worktree is now the record | `chief/96-submodule-story-progress-durability` · `459767d` |
| ✅ | **`chief status`** — what is *left* and what can *start now*, across one repo or a whole tree of them: remaining live/parked, runnable vs. blocked, `--blocked` aggregating by edge (holds / releases / cascade), `--json`. It **is** the scheduler's own gate run in report mode (`engine/deps.sh`), because a second implementation would drift and then name work as startable that a run would refuse to start. Measured need: 312 remaining across 16 repos, 93 parked, 82 blocked ([`docs/reference/status.md`](docs/reference/status.md)) | `chief/97-tasklist-state-report` · `f8c03bf` |
| ✅ | **Unverified criteria must not pass** — the evidence rule: a story whose criteria state a checkable bar and whose `notes` carry no observed value is not a pass. Chief requires the measurement and never judges it. **Five stories in one day** had reported green against criteria that were not met, and 9 of 10 passing stories in that batch had empty `notes` | `chief/98-unverified-criteria-must-not-pass` · `482b5ef` |
| ✅ | **Reap must not infer orphanhood** — an unreadable registry stopped being evidence of orphanhood, and the test suite stopped running host-wide sweeps. Starting one chief tasklist had **killed every other chief run on the host** (cuneiform, vita, rosetta); only the tree the sweep executed inside survived. `test/bystander.sh` now proves a bystander lives | `chief/99-reap-must-not-infer-orphanhood` · `e6826b1` |
| ✅ | **Evidence checked at the iteration boundary** — the demotion moved from merge time (where the agent is already gone) to the boundary where the next turn can still act, and that turn is *told* what was demoted and why. Four tasklists across three repos had needed hand-rescue in a single day; none was a defect in the work | `chief/100-evidence-checked-at-the-iteration-boundary` · `826a2dc` |
| ✅ | **UNVERIFIED survives the resume** — the demotion used to live only in the worktree's runtime PRD, so the next run read an all-pass committed tasklist, skipped the agent, and re-failed identically forever (insimul `261`: three runs, same story, every time). The stop is now persisted beside the verify-failed log and read as a third re-engage arm | `chief/101-unverified-survives-the-resume` · `a9ba809` |
| ✅ | **Retired work must not leave a marker** (`engine/counterpart.sh`) — a placeholder tasklist for work owned by another repo declares its `downstreamCounterpart` as a *field*, and a merged counterpart with a live marker is reported by name in `chief lint` and `chief list`. **Five of koine's ten markers had already shipped** and every one was still counted as pending | `chief/102-retired-work-must-not-leave-a-marker` · `f3226e9` |
| ✅ | **Monitor must not outlive its terminal** — the `watch` arm checks its tty and its parent each tick and exits when either is gone, and `chief reap` gained a second kind (an abandoned *view*) reported separately from agent work. **Nine orphaned watchers**, PPID 1, oldest 11.5 hours, and `chief reap` had reported "no orphaned chief processes" while they ran | `chief/103-monitor-must-not-outlive-its-terminal` · `b093b9f` |

### Operator ergonomics — ✅ shipped (`104`–`109`, 2026-08-21 → 08-22)

**A single programme, not six errands: chief could already do the work and could not yet be
*operated*.** Each row closes a gap between something chief already knew and the operator who needed
to see or spend it — a usage ledger plumbed end to end that returned `null` for the default provider;
a decision that could be prepared and held for a human but had nowhere to land; a `list` whose live
work was 2% of its output; a `-p N` that bounded one run while five ran; a worktree reclaimed only by
a tasklist running *again*, which a merged tasklist never does.

| Status | Milestone | Tasklist |
|---|---|---|
| ✅ | **Claude turns report their usage** — the default provider is invoked so that real token/cost figures reach the `agent.turn` event, while the turn's human-readable output still reaches the log and the agent loop **unchanged** (a ledger bought by breaking completion detection is worse than `null`); a provider that prints nothing usage-shaped still yields `null`, cleanly | `chief/104-claude-turns-report-their-usage` · `c67379c` |
| ✅ | **`chief usage`** — spend and **rate-limit incident history** read back out of the event logs chief already writes: how often a limit was hit, how long was lost waiting, when the window resets. Deliberately not dependent on `104`, because on a subscription plan the useful question is *how close am I to the window* and **no provider CLI answers it**. Reads; never a second ledger ([`docs/reference/usage.md`](docs/reference/usage.md)) | `chief/105-chief-usage-reports-spend-and-limits` · `0a178b2` |
| ✅ | **Decision tasklists carry a verdict** — a park says what *kind* of park it is, a DECISION tasklist's deliverable is the operator's verdict rather than a merge, and `chief decide` records it and files the retirement. The agent prepares the decision and is structurally unable to make it. Measured: **20 parked tasklists referenced a decision and not one set `parkedReason`** ([`docs/reference/decision-tasklists.md`](docs/reference/decision-tasklists.md)) | `chief/106-decision-tasklists-carry-a-verdict` · `c2c30e4` |
| ✅ | **`chief list` / `chief ps -a` show what is live** — `list` defaults to live work as a table with a stable machine contract, and `ps -a` shows everything in flight (running + ready + blocked + parked). `97`'s boundary was kept: `list` stays per-tasklist, `status` stays aggregate, neither absorbs the other. In cuneiform the live work was **under 16% of 371 lines** | `chief/107-list-and-ps-show-what-is-live` · `522ee4c` |
| ✅ | **Concurrency is machine-wide** — `-p N` bounded one run while nothing bounded runs against each other, so five concurrent runs on a 14-core host reached **load average 62, 4.4× oversubscribed**, and one cuneiform iteration spent ~5 hours whose entire output was *"Gate is still on `engine-build` … Waiting"* behind three concurrent `verify.sh` processes. A machine-wide budget now defaults to the hardware, and contention is visible where the operator already looks ([`docs/reference/concurrency.md`](docs/reference/concurrency.md)) | `chief/108-concurrency-is-machine-wide` · `35d2568` |
| ✅ | **Reclaim a merged tasklist's worktree** — reclamation was keyed to a tasklist *running again*, which a merged one never does, and every removal was best-effort with its failure discarded. `~/.chief/worktrees` had reached **94 GB across 1,867 containers**, 1,857 of them dead shells, on a host at 84% full. Retirement now reclaims, a removal that loses is **reported** at every site, and a startup sweep bounds the debt earlier runs stranded | `chief/109-reclaim-a-merged-tasklists-worktree` · `3a26242` |

### Iteration-outcome honesty — ✅ shipped (`110`–`113`, 2026-08-22 → 08-26)

**One thesis, four measurements: chief learning to tell real progress from motion.** Every row is the
same defect in a different direction — chief's *iteration-outcome classifier* answering a question
about work with an observation about activity. A branch that changed nothing was verified as though
it had; an API that never took the turn was scored as an agent that got nowhere; a commit touching
only chief's own state files was scored as progress; and a story whose correct, measured answer was
`false` was re-driven forever because chief had exactly one notion of done. The band's asymmetry is
the point: the loop was rigorous about a false claim of **completion** (the no-work guard, `98`/`100`)
and accepted a false claim of **progress** without checking anything.

This is a **taxonomy**, and naming it is most of the value — `111` stops a run too *early*, `112` lets
one run *forever*, and the fix for either must not quietly redefine the other.

| Status | Milestone | Tasklist |
|---|---|---|
| ✅ | **A green branch should not be verified three times** — re-verification after a rebase stays (semantic staleness has no other detector); what ended is paying a full gate for a tree that **did not change**. A verify-result cache keyed on the tree, an approval that lands without a whole second run, the agent's own verify and the merge gate no longer two full runs of the same thing, `ps` no longer reporting a waiting branch as working, and a hold record that cannot outlive its branch. Measured: a 2h11m `-p1` run in which one already-green 4/4 branch took **~34 minutes to merge**, and a 3/3 branch paid **2 merge-phase verifies over 6 agent iterations** | `chief/110-a-green-branch-should-not-be-verified-three-times` · `22e70bd` |
| ✅ | **An API error is not a stall** — an iteration that never reached the model does not count as an attempt, a transient provider failure is **waited out** rather than fired into, and work already on disk is never described as no work. Measured on talos: three consecutive iterations whose entire output was `API Error: 529 Overloaded`, counted as no-progress, hit `stall 3/2`, and left INCOMPLETE a branch whose adopted upstream — 2,029 files — sat intact in the worktree ([`docs/reference/provider-unavailability.md`](docs/reference/provider-unavailability.md)) | `chief/111-an-api-error-is-not-a-stall` · `2df23f9` |
| ✅ | **A bookkeeping commit is not progress** — progress now means a story moved or **the product changed**; a legitimate bookkeeping commit is still allowed to happen, it just no longer buys an iteration, and the operator can see the difference without reading the log. Measured in formant: a tasklist blocked on a measurement only a human could take ran to **iteration 11 of a 5-iteration budget over 1h32m**, each extension bought by one of **five consecutive commits whose entire content was a re-check stamp** in `.chief/state/`, every one printed as `progress (0/2 passing). Continuing...` | `chief/112-a-bookkeeping-commit-is-not-progress` · `b5011ad` |
| ✅ | **A story may terminate false** — a story can declare that `false` is its *terminal* answer (`terminalFalse`, `engine/terminal.sh`), a tasklist that therefore cannot report all-stories-true is **detected and stopped** rather than run to the cap, and `chief retire --negative` files it without hand-editing JSON. Measured on cuneiform: a story whose criterion said in as many words that a failing verification stays `passes: false` was re-driven across **63 commits — 21 iterations in one run, 59 across the program, 42 consecutive identical measurements** — and the agent's terminal note (*"this tasklist can NEVER report all-stories-true … it needs MANUAL RETIREMENT"*) was correct and had no channel chief could hear ([`docs/reference/tasklist-schema.md`](docs/reference/tasklist-schema.md)) | `chief/113-a-story-may-terminate-false` · `716c9e4` |

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

### In flight — 🚧 authored, unmerged

The live head, and it is the same thesis as the `110`–`113` band above: **an outcome chief reports
must be an outcome chief checked.** Records are in [`tasks/chief/`](tasks/chief/); none carries a
`mergedToMain` yet.

| Status | Milestone | Tasklist |
|---|---|---|
| 🚧 | **The roadmap states what is true today** — this file. It documented the `77`–`92` era, claimed `v0.8.0` against a `VERSION` two minor releases ahead, listed 12 of 22 subcommands, and was silent on `93`–`113`; the fix includes extending the doc-sync gate to cover it, because the gate that would have caught this deliberately did not | `chief/114-the-roadmap-describes-a-program-that-ended` |
| 🚧 | **A gate that did not run is not a gate that passed** — every private repo in the portfolio had dead CI for an unknown period (an account-level billing block, byte-identical on all three), and vita's workflow triggers only `on: pull_request` while chief merges locally and pushes — so its CI had never run once, and a tasklist merged `auto-verified` on the premise that it had. Chief does not become a CI client; it refuses to let **absence read as success** | `chief/115-a-gate-that-did-not-run-is-not-a-gate-that-passed` |
| 🚧 | **A decision tasklist cannot finish** — `106` shipped the operator surface and the halt and never connected them: the verdict `chief decide` writes is read by nothing, the halt is unconditional on every later run, neither `--retire` nor `--unpark` fits, a decision tasklist that *carries code* (2,209 insertions in the first real one) has no path to merge after the verdict, and `AWAITING-DECISION` — a successful terminal state — is reported as a failure that blocks five dependents | `chief/116-a-decision-tasklist-cannot-finish` |

### Open threads — ⬜ parked, with conditions

Not a wishlist: each is a thread with a **recorded decision and a stated condition for re-opening**.
Chief is a tool and its scope stays deliberately small, so anything else known is either an authored
tasklist, an ongoing bar, or a **By design** non-goal above (cross-host run aggregation moved there:
it is chief-cloud's, not a chief convenience).

| Status | Thread | Disposition |
|---|---|---|
| ⬜ | **Binding a cross-worktree conflict predictor** behind the `touches` seam (Clash, Grove; ccswarm checked and excluded) | **Declined 2026-08-17, seam left open.** `touches` is consumed at *admission*, when the candidate branch has no worktree and no diff — a predictor derives its verdict from diffs between live worktrees and has nothing to read at that instant. Chief built the registry itself (`91`); a predictor could later supply *additional* zone matches at the merge-time seam as an optional input whose absence changes nothing, behind a config flag and an installed binary. Reversal conditions are recorded in [`docs/decisions/conflict-predictor-adoption-decision.md`](docs/decisions/conflict-predictor-adoption-decision.md) |
| ⬜ | **Desktop monitor app** | **Decided CLI-only** — see the `79` row above; the GUI surface is chief-cloud's ([`docs/decisions/desktop-gui-decision.md`](docs/decisions/desktop-gui-decision.md)) |

---

## Chief Tasklist Status

- **37/37 authored tasklists merged** (`77`–`113`). Records live in
  [`tasks/chief/completed/`](tasks/chief/completed/), each stamped with a `mergedToMain` sha; all 37
  were checked against git on 2026-08-26 and none is missing one. The band runs `bd030a6`
  (2026-08-01) → `716c9e4` (2026-08-26).
- The merged program reads as **five bands**, and the last three are named phases above rather than
  runs of numbers: `77`–`87` hardening & the embeddable engine · `88`–`92` agent-output quality then
  merge throughput · `93`–`103` operating the fleet (merge safety, durability, the evidence rule) ·
  `104`–`109` **operator ergonomics** · `110`–`113` **iteration-outcome honesty**.
- **3 live tasklists** in [`tasks/chief/`](tasks/chief/), rowed under *In flight* above:
  `114-the-roadmap-describes-a-program-that-ended` (this file),
  `115-a-gate-that-did-not-run-is-not-a-gate-that-passed`, `116-a-decision-tasklist-cannot-finish`.
  All three continue the `110`–`113` thesis: an outcome chief reports must be an outcome chief checked.
- The two ongoing bars (provider breadth, bash-3.2 upkeep) are continuous upkeep, not discrete
  tasklists, and the two **open threads** (conflict-predictor binding, desktop GUI) are decided-and-
  parked with reversal conditions in [`docs/decisions/`](docs/decisions/) — not unscoped wishes.
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
