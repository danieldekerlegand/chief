# Drivers, scheduling, and the safety model

> **Status:** Current · **Updated:** 2026-08-14 · **Owner:** chief

`chief run` uses one driver; `-p N` (`--parallel`) sets max concurrency (default 1
= sequential). Every tasklist — even at `-p 1` — runs in its own **git worktree**
(isolated HEAD/index/working tree + gitignored `.chief/state`), so agent loops
never corrupt each other. The base branch is touched only in a **serialized merge
phase**, one tasklist at a time.

## Scheduling

A pending tasklist launches only when all three hold:
1. fewer than `N` are running,
2. every `dependsOn` entry is recorded merged, and
3. none of its `touches` domains overlaps a currently-running tasklist.

`chief run -n` (DRY_RUN) prints the resulting waves without git or agents — use it
to sanity-check deps/conflicts before a real run.

- **dependsOn** = *ordering* (B needs A's result first).
- **touches** = *conflict domains* (A and B edit the same area, even with no
  ordering between them). These are different constraints. "No dep" does **not**
  mean "won't collide" — that's what `touches` is for.

Coarse domains over-serialize (safe, less parallelism); fine domains parallelize
more (may cost a wasted rebase if wrong — never correctness). Start coarse, split
as you learn real file overlaps.

### The under-tagged-`touches` audit

Getting `touches` wrong is asymmetric. Over-tagging shows up immediately in
`chief run -n`'s wave plan; **under-tagging is invisible** — two tasklists edit the
same file, share no domain, and you only find out when one of them loses a whole
run to a rebase conflict, with nothing naming the other half of the pair.

So every run reports it. The driver already knows which tasklists were **running
concurrently** (recorded at launch) and what each branch **actually changed**
(`git diff --name-only <merge-base>..<branch>`, recorded after the agent phase, so
branches that end `INCOMPLETE` or conflict are covered too). Crossing the two, any
**co-scheduled pair that overlaps on a file while sharing no domain** is printed as
a WARNING in the end-of-run summary — and, as soon as it is knowable, in the worker
log of the second of the pair to merge:

```
   ⚠ WARNING — under-tagged touches: ir-voting-and-artifacts + studioos-trigger-surface ran concurrently and both changed:
        · studio-os.ccl
        ir-voting-and-artifacts touches: [ir docs]
        studioos-trigger-surface touches: [studioos-data]
        Fix: give them a shared touches domain (or a dependsOn edge) so the
        scheduler stops co-scheduling them — docs/drivers-and-safety.md.
```

**Acting on one:** add the missing shared domain to both tasklists (they collide
but have no ordering), or a `dependsOn` edge (one genuinely needs the other's
result first). Either way the scheduler stops co-scheduling them and the wasted
rebase — or the conflict — does not recur.

The audit is **reporting only**: it never changes scheduling, merge behavior, or a
status value, and a run with no overlap prints nothing new. It is the reason the
safety model can keep saying "under-tagging only costs a wasted rebase" — the cost
is now attributable instead of anonymous. State lives in the run's state dir
(`.chief/state/parallel/`): `.cosched` (the concurrency relation), `<name>.touches`
(captured at launch — a merged tasklist is retired, so its JSON is gone by summary
time) and `<name>.files`.

## The safety floor (why parallel is safe)

Before merging, each finished branch is **rebased onto the latest base**, then
**re-verified** (`verify.sh`) against it. Only a clean, green branch merges, and
merges are serialized. Therefore:
- file overlap two "disjoint" tasklists actually have → a **rebase conflict**
  (caught; the branch is left for a human), and
- semantic staleness (B built on a base A later changed) → a **verify failure**
  (caught).

Interference degrades to a caught failure and a wasted rebase — **never a silent
bad merge**. There is no AI auto-conflict-resolution: conflicts stop the tasklist.
Over-tagging `touches` only costs parallelism; under-tagging only costs a rebase —
and the run summary now names the pair that under-tagged (see the audit above).

Two more guards back this up:

- **No-work guard (`EMPTY-NO-WORK`).** Pass-flags in JSON can lie: an agent might
  emit `<promise>COMPLETE</promise>` and mark every story `passes:true` while
  committing nothing (a stale/wrong tasklist misfire). Before merging, the driver
  checks the branch actually diverges from base (`git diff BASE...branch`). An empty
  branch is **never** merged (a `--no-ff` merge would otherwise forge an empty merge
  commit) or retired — it's marked `EMPTY-NO-WORK` and its dependents stay blocked.
- **Persisted verify failures re-engage the agent.** A branch that completes all
  stories but fails the post-rebase verify would otherwise loop forever
  (skip-agent → re-verify → fail). Instead the verify output is saved to
  `snapshots/<name>.verify-failed.log` and injected into the next run's
  `progress.txt`, so the agent is re-run to **fix** the failure (it won't re-report
  COMPLETE until the checks pass). Cleared on a clean merge.

- **Base integration (`INTEGRATE-BASE.md`).** The floor above catches
  drift, but only at the very end, where a conflict costs the whole tasklist. Most
  of that drift is avoidable: a branch resumed from a prior run starts exactly as
  far behind as it stopped, and a branch that is *running* falls further behind
  every time the serialized merge phase lands a sibling. So the driver integrates
  at the two moments an agent is still around to help — **at pickup** (before the
  agent loop starts) and **at each iteration boundary** (between the agent's
  iterations, never inside one). Both call the same step: measure `branch..base`
  and, if it is behind, rebase the worktree onto the
  latest base. A clean rebase is silent (one log line: `rebased <branch> onto
  <base> (<n> commits behind)`); a conflicting one is **aborted** — the branch is
  left untouched, clean and attached — and an `INTEGRATE-BASE.md` note is written
  next to the runtime `prd.json` (gitignored) naming the base, the behind count and
  the conflicted files. Its instruction is injected into the agent's `progress.txt`
  the same way a persisted verify failure is: integrating the base is the agent's
  **first** task that iteration, ahead of any user story. The note asks for a
  `git rebase`, not a `git merge` — the merge phase rebases the branch again, and a
  rebase drops merge commits and replays the originals, so a resolution recorded in
  a merge commit would be discarded and the same conflict would return.
  A branch whose stories all pass but which cannot rebase is **not** skipped
  straight to the merge phase (which is already known to conflict); the agent is
  re-engaged to integrate first. Nothing here fails a tasklist and nothing here
  resolves a conflict on its own — the merge phase stays the unchanged safety floor.
  The **iteration-boundary** pass is the same step, throttled: the worker remembers
  the base tip it last integrated against (`.chief/state/.integrated-base` in the
  worktree), so a boundary where base hasn't moved costs one `rev-parse` and
  nothing else, and a moved base is integrated exactly once. A worktree that is
  mid-rebase or carries uncommitted tracked changes is skipped and re-checked at
  the next boundary (a `git rebase` would only refuse). This bounds divergence to
  **one iteration's** worth of sibling merges instead of a whole run's.

- **Conflict forensics (`<name>.rebase-conflict.md`).** Integration removes most of
  the drift, but a conflict can still reach the merge phase — an agent that ran out
  of iterations before acting on its `INTEGRATE-BASE.md`, or a sibling that merged
  during the agent's last turn. The engine still refuses to auto-resolve it; what it
  does is record what it knew at that instant, before `rebase --abort` throws the
  index away: the conflicted paths, and for each of them the commits that landed on
  base since this branch forked, with chief's own auto-merge commits
  (`Merge <branch> (chief, auto-verified)`) resolved to the **sibling tasklist name**
  that produced them — the likely collider. It lands in
  `snapshots/<name>.rebase-conflict.md` (or `<name>.merge-conflict.md` for the final
  `--no-ff` merge), the worker log and the `.status` line point at it, and a later
  successful merge clears it. Status *values* are unchanged. See
  [`failure-recovery-runbook.md`](failure-recovery-runbook.md) §2.

- **Refusal is not conflict (`REBASE-REFUSED`).** A non-zero `git rebase` is only a
  *content* collision when git leaves **≥1 unmerged path** behind. Git also refuses
  outright — a work repo with uncommitted tracked changes, a leftover
  `rebase-merge`/`rebase-apply`/`MERGE_HEAD`/`CHERRY_PICK_HEAD` state, a repo it will
  not operate on (dubious ownership) — and those leave **zero** conflicted paths. The
  merge phase pre-flights those causes before rebasing and, on a failure, lets the
  index decide the arm: unmerged paths → `REBASE-CONFLICT` (forensics as above);
  none → `REBASE-REFUSED <cause>`, quoting git's own refusal. A refusal merges
  nothing and rewrites nothing — the branch is exactly as the agent left it — and it
  is deliberately **not retryable**: the repo needs a human, not another agent run.
  It writes its own note, `snapshots/<name>.rebase-refused.md` (not a
  `.rebase-conflict.md`, which would assert a collision that never happened): the
  cause, `git status --short` at that instant, and the cause-specific command that
  clears it — `git rebase --abort`, `git stash`, `safe.directory` — followed by the
  rebase that must run clean before chief will merge. A later clean merge clears it,
  and so does a real conflict (each failure arm removes the other's stale note).
  A branch **strictly ahead** of base (base is an ancestor → the replay is a no-op)
  skips the rebase altogether: git would only have to open the repo to say "up to
  date", and that is the one place an environment fault could turn a guaranteed
  no-op into a non-zero exit — the field case this whole path comes from.

Terminal per-tasklist statuses: `MERGED @<sha>`, `COMPLETE-UNMERGED`, `INCOMPLETE`,
`EMPTY-NO-WORK`, `WORKTREE-FAILED`, `CHECKOUT-FAILED`, `REBASE-CONFLICT`,
`REBASE-REFUSED`, `VERIFY-FAILED`, `MERGE-CONFLICT`.

## Interruptions & resume

A run stopped partway — Ctrl-C, token/quota exhaustion, lost connectivity, a crash
— is safe to just re-run. On the next `chief run`:

- an existing `chief/<name>` branch is **reused**, not force-deleted. If every
  story already passes on it, the agent is skipped and it goes straight to
  verify+merge; if it's partially done, a worktree is attached to the branch and
  only the **remaining** stories run (state seeded from the branch's committed
  tasklist, so completed work is never redone).
  A branch that marks all stories done but has **no commits vs base** (a false
  all-pass), or that has a **persisted verify failure**, is not skipped — the agent
  is re-run to produce/fix the real work.
- a reused branch is **brought up to date with the base before the agent starts**
  (pickup-time integration, above), so a prior run's drift isn't carried into this
  one. A branch already at the base tip costs one `rev-list` and nothing else.
- the single-driver lock **auto-clears** when its owner pid is dead (no manual
  `rmdir`), and orphaned agent loops from the dead run are reaped (below).
- if a crash left the **base** working tree stranded on a `chief/*` branch (killed
  mid-merge/rebase), `AUTO_RECOVER` (default on) aborts the in-progress
  rebase/merge, commits any stray WIP onto that branch, and restores the base
  branch — so the next run isn't hard-blocked. `AUTO_RECOVER=0` opts out.
- `RESET=1 chief run` forces the old fresh-from-base behavior, discarding a
  branch's partial progress.

Mid-run token/usage limits are handled one level down, inside the agent loop
(`RATE_LIMIT_RETRY`, default on): it sleeps until the limit resets and resumes the
same story rather than failing the tasklist.

What the interrupt itself does — what it reaps, and when the records go — is the
next section.

## Pausing a run: the operator's quota lever

Chief already pauses *itself* on a Claude usage limit. `chief pause` is the other
half — a **human** saying "stop spending agent turns on this repo, I need the quota
elsewhere" — and the two are deliberately separate holds:

| | usage-limit window | operator pause |
|---|---|---|
| flag | `.chief/state/parallel/.limit-pause-until` | `.chief/state/parallel/.paused` |
| armed by | the driver, from the limit message | `chief pause` |
| lifted by | **Chief**, when the window resets | **only** `chief resume` |
| scheduler state | `rate-limited` | `paused` |
| bounded? | yes — a reset ETA, and `RATE_LIMIT_REDISPATCH_MAX` re-dispatches | no — a human decision has no deadline |

Neither ever reads or writes the other's flag, and an operator pause never touches
`<name>.retries` — spending the usage-limit self-heal budget on a manual pause would
let a few pauses silently exhaust it. With **both** armed the run stays held until
the window resets *and* someone runs `chief resume`.

```sh
chief pause          # arm this repo            chief pause  --all   # every run in the registry
chief resume         # lift it + re-arm parks   chief resume --all
```

Both are idempotent (a no-op exits 0 and says so) and work with **no run active** —
pausing an idle repo pre-arms it, and `chief run` on a pre-armed repo reports the
pause instead of launching.

**It drains; it does not kill.** `Ctrl-C` (or `POST /api/run/{pid}/stop`) forfeits
the iteration in flight. A pause withholds *agent turns* and nothing else:

- **withheld** — no further tasklist launches (the scheduler's launch gate is
  re-checked every pass, so a pause armed mid-run stops the *next* launch too), and
  no new agent iteration starts.
- **still allowed** — the iteration already in flight runs to completion, so its
  commits land; and a tasklist whose agent loop has **already finished** still runs
  verify and merges. That work is agent-free, and parking it would strand a finished
  branch — blocking its dependents for an unbounded hold.

**The checkpoints are the correctness story.** The pause is consulted at exactly one
place inside a worker: the **top of the agent loop, between iterations** (before the
iteration counter moves, after the previous iteration's boundary hook has run) —
`agent.sh` exits `3` there, and the driver parks the tasklist. There is deliberately
**no checkpoint** between commit and merge, mid-rebase, mid-verify or mid-merge:
nothing downstream of the agent loop is reachable from that check, so a pause can
never leave a work repo mid-rebase, a worktree half-merged, or a branch
committed-but-unrecorded. Nothing is ever half-done for a human to untangle.

A drained tasklist parks in the non-terminal state `paused` (status `PAUSED n/total`)
with its **branch and its worktree kept**. `dep_broken()` ignores `paused` exactly as
it ignores `rate-limited`, so dependents stay `pending` rather than cascading to
`blocked`, and the run summary lists parks under their own heading — never among the
failures:

```
   ⏸ OPERATOR PAUSE — 1 tasklist(s) PARKED (not failed, not blocked): 73-operator-pause-resume
    · 73-operator-pause-resume        PAUSED 3/4 — branch + worktree kept
    Nothing is half-done: no tasklist was stopped mid-rebase, mid-verify or mid-merge.
    Resume where they stopped (their committed passes state):  chief resume  &&  chief run
```

The run then **ends** — it does not idle on the pause. An unbounded hold must not
keep `driver.lock` against a future run, so the driver releases it and exits **0**
(paused, not failed). `chief resume` clears the flag and flips every `paused`
tasklist back to `pending`; the next `chief run` picks each up through the ordinary
RESUME path (§ Interruptions & resume) from its **committed passes state**, with the
branch reused and nothing rebuilt.

Scope: this is the engine + CLI + `chief ps`.
routes and in the frontends is a follow-on. `test/pause.sh` locks the semantics down
end-to-end (hermetic: fake `claude`, temp prefixes).

## Teardown: what a Ctrl-C reaps, and in what order

**The invariant, in one sentence: Chief never removes the record of a run that is
still running.** The bug this rule exists for did the exact inverse — `driver.sh`
trapped `EXIT` only, and that trap dropped `driver.lock` and the `<pid>.run` file and
nothing else, so a Ctrl-C deleted the *bookkeeping* while the worker subshells,
`agent.sh` and the tool below them kept going: an unsupervised agent spending quota
that `chief ps` then reported as `no active runs`.

The driver traps `INT`, `TERM` and `HUP` (and still `EXIT`, idempotently). Teardown
runs in this order, and the order is the contract:

1. **Wait out a critical section.** A worker marks `<state>/<name>.critical` for as
   long as its work repo is inside checkout → rebase → verify → merge. An interrupt
   there is what strands a repo needing manual `git rebase --abort`, so teardown
   waits up to `CHIEF_TEARDOWN_CRITICAL_GRACE` (120s) for it to reach a safe point.
2. **Reap the worker tree** — driver subshells, `agent.sh` frames, the tool and
   whatever it spawned — found by **parentage**, not argv (`chief_scan_descendants`;
   see below for why argv cannot find them). Escalating and bounded: `TERM` first,
   then `KILL` after `CHIEF_TEARDOWN_GRACE` (10s), so a wedged agent can never make
   the interrupt hang. A process reparented mid-reap (a tool whose `agent.sh` parent
   died first) stays on the target list rather than silently escaping.
3. **Repair any repo the interrupt caught mid-operation** — abort the rebase/merge,
   park stray work as a `wip(chief):` commit *on the feature branch*, restore the
   base branch. A Ctrl-C never leaves a repo needing git surgery by hand.
4. **Only then release the records**: `driver.lock`, the merge/worktree locks, the
   `<pid>.run` file. If anything outlived both `TERM` and `KILL`, teardown **refuses
   to release** and says so — an orphan that is still spending is far less dangerous
   while it is still visible to `chief ps`.

A **second interrupt** during teardown collapses every grace period and hard-kills
immediately. (It is seen at all only because the handler itself does nothing but bump
a counter — bash will not dispatch a repeat of a signal while its own handler runs —
and because every scheduler wait is sliced into 1s steps, which bounds how long two
interrupts can be coalesced into one.)

Note that the reap uses `TERM`/`KILL`, never `INT`: a background command started by a
non-interactive shell has `SIGINT` set to `SIG_IGN`, and a signal ignored on entry
cannot be trapped or reset. Every worker subshell — and `agent.sh` and the tool below
it — inherits that, so a Ctrl-C delivered to the process group is ignored by exactly
the processes that need to die. That is the mechanism behind the observed orphan.

The same rule has a corollary for the driver itself: a driver **started** with `SIGINT`
already ignored — launched as a background job by a non-interactive parent (a script,
a service manager, chief's own verify hook) rather than from a terminal — cannot trap
`INT` at all, so a Ctrl-C in that context is a no-op. `TERM` and `HUP` are unaffected
and produce the identical teardown, which is what `kill <pid>` and a service manager
send anyway. It matters for testing more than for operating: `test/teardown.sh` runs
inside chief's own verify hook, several frames below a `run_worker … &` subshell, so it
re-execs itself once through `perl` to restore the default disposition before it signals
anything — otherwise its Ctrl-C would be delivered to nobody and the driver would look
like it had survived the interrupt.

`test/teardown.sh` drives all of this against a real run whose agent turn never ends
and whose tool ignores `TERM`, and asserts the ordering *directly* — sampling records
and processes throughout the teardown, so a refactor that restores the inversion
fails there instead of regressing silently.

## Orphans: how chief work is identified, and how it's stopped

An **orphan** is agent work that is still running — still spending account quota —
with no live, registered run behind it: a driver killed with `SIGKILL`, a terminal
closed on an older engine, a crash between the reap and the record.

**Identification never uses argv paths.** `driver.sh`, `agent.sh` and
`claude --dangerously-skip-permissions --print` carry no worktree path on their
command line; only their transient children (a pytest, a build) do. A sweep matching
the worktree path therefore killed the leaves and left the engine above them alive to
spawn more. Two durable markers replace it:

- **cwd** — every process in an agent tree runs *inside* the run's worktree
  (`$CHIEF_PREFIX/worktrees/<repo>-<cksum>/<tasklist>`). Not in argv, but in the
  process table (`/proc/<pid>/cwd`, or `lsof -d cwd` on macOS). The worktree root is
  chief's own directory, so a match there is chief's work by construction — and the
  path names the repo and tasklist it belonged to.
- **the run marker** — `--chief-run=<repo>-<cksum>-<epoch>-<pid>`, stamped by
  `driver.sh` on its own argv (it re-execs once to place it, keeping its pid) and on
  every `agent.sh` frame, and exported as `$CHIEF_RUN_ID` to the whole tree. This is
  what catches the driver itself, whose cwd is wherever the operator was standing.
  The `<repo>-<cksum>` prefix is what scopes a sweep to **one** repo's runs.

Anything below a matched process is included through parentage, so a build that
wandered off into a temp dir is not missed.

**What a sweep must never touch** — the protected set, computed before *and* again
after the scan (so a live run that starts a fresh agent turn mid-scan can't be
mistaken for an orphan): a registered live run (its driver pid **and** every
descendant), a driver still holding its repo's `driver.lock` (an unregistered live
driver is a bookkeeping bug, not a licence to kill work), this process and its
ancestors, another user's processes, and anything outside `$CHIEF_PREFIX/worktrees`
— including your own `claude` sessions. `test/reapscope.sh` asserts each of these.

**Where the sweep runs.** At driver startup, scoped to that repo (it holds the
driver lock, so nothing legitimate is using them) — and, because waiting for someone
to re-run the stranded repo is exactly how an orphan spends for hours unwatched, on
demand from anywhere:

```
chief reap -n     # report what would be reaped: repo, tasklist, pid, command
chief reap        # stop it: TERM, then KILL after --grace N seconds (default 5)
```

Both paths are loud: every pid is named, with what it was and why it was matched,
before a signal is sent. A silent `kill -9` sweep is indistinguishable from a crash
to whoever is watching.

## The registry tells the truth in both directions

`chief ps` / `chief monitor` read the host-wide run registry (`~/.chief/runs`), one
`<pid>.run` file per live driver. A run file whose pid is **dead** has always been
pruned on sight. The inverse — a driver that is **alive with no run file** — had no
check at all, and it is the one that hurt: the field report behind this work read
`no active runs` while an agent was mid-iteration, spending quota nothing watched.

A live driver is identified the same way an orphan is, plus one extra fact: the run
id **ends in the pid of the driver that minted it**. Its `run_worker` subshells are
forks and carry its argv verbatim, and every `agent.sh` frame is stamped with the
same id — but only one marked process has a pid equal to the id's last field, and
that one is the driver. Its repo comes from the id's `<cksum>` (the checksum of the
repo's absolute path), resolved through the known-repos registry — which also scopes
the check to this `$CHIEF_PREFIX`, so a hermetic test never reports your real runs
and your real `chief ps` never reports a test's.

An unregistered driver is reported, never hidden — with the repo, the tasklists in
flight and their scheduler states, what `driver.lock` says about it, and the pid to
kill:

```
CHIEF · 0 active run(s) · ⚠ 1 unregistered · 2026-07-31 19:40:02

⚠ 1 unregistered driver(s) — alive, but missing from the run registry (~/.chief/runs):
   ⚠ chief  (pid 40321 · run chief-2915283-1753996812-40321)
     /Users/you/Development/chief
       ↳ in flight: 75-teardown-and-orphan-integrity  running
       ↳ driver.lock is GONE — only this check stands between it and a second driver
       ↳ stop it:  kill 40321    then:  chief reap    (reaps whatever it leaves behind)
```

**One driver per repo is enforced against the process, not just the lock.**
`driver.lock` is a file, and a driver outliving its records is exactly the failure
mode above — so `chief run` also asks the process table, scoped by this repo's run
marker, and **refuses** to start when a live driver for the repo exists that the lock
does not name. Two drivers on one repo would race its branches, worktrees, index and
merges. `CHIEF_ALLOW_SECOND_DRIVER=1` overrides (it doesn't make it safe).

This changes nothing for the ordinary crash: a `SIGKILL`ed run leaves orphaned
*agent* loops, not a live driver, so the stale-lock steal and the startup reap
behave exactly as before.

## Resource notes

`-p N` runs N agents + N verification passes concurrently — watch CPU and your
AI-tool usage limits. If two tasklists' checks bind the same fixed port, give them
a shared `touches` domain so they serialize. A fresh worktree has no gitignored
build deps — use `warmup` (e.g. `npm ci`, `uv sync`) to provision them per worktree.
