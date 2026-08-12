# Monitoring active runs

Every `chief run` registers itself in a **host-wide run registry** so you can see
what's happening across *all* your repos from anywhere — not just the terminal a
run is printing to. Two commands read it:

```sh
chief ps                 # one-shot table of active runs
chief monitor            # the same view, refreshing in place (Ctrl-C to exit)
chief monitor 5          # refresh every 5s (default 2s)
```

Example:

```text
CHIEF · 2 active run(s) · 2026-07-15 14:03:11

my-api  (pid 12345 · -p3 · claude · 12m · →main)
  /Users/me/dev/my-api
   ● auth                   running   2/4     chief/auth
       ↳ claude-waiting for 40s · US-3 · iter 5 · 12s ago
       ↳ US-2 done: added refresh-token rotation; see api/auth/*.ts
   ⚠ search                 running   1/6     chief/search
       ↳ verifying for 41m · US-2 · iter 3 · ⚠ stalled — no activity for 38m
   ⏸ billing                paused    3/5     chief/billing
       ↳ paused: usage limit — retry at 15:10 (28m) · re-dispatch 1/3 · paused 32m · 32m ago
   ○ web                    pending   0/3     chief/web

web  (pid 12346 · -p2 · claude · 3m · →main)
  /Users/me/dev/web
   ● nav-redesign           running   1/3     chief/nav-redesign
```

Columns, per tasklist: **state glyph + label** (`running`/`done`/`failed`/
`blocked`/`pending`/`paused` on a usage limit/`paused-op` on an operator pause),
**stories passing/total**, and the **branch**.
Beneath a live tasklist come up to two dim `↳` lines: **what it is doing right
now** (the liveliness record, below) and the latest note the agent appended to its
`progress.txt`.

## Is it working, or is it hung?

The coarse word `running` can't answer that — it says a worker exists, not that it
is making progress. So each live tasklist also writes a small **liveliness record**
next to its state file (`.chief/state/parallel/<name>.live.json`, gitignored, never
committed) that `chief ps`/`chief monitor` render as the first `↳` line:

| Field | Shown as | Written by |
|---|---|---|
| `phase` | the fine-grained sub-phase, verbatim | agent: `agent-turn`, `claude-waiting`, `writing`, `rate-limited-waiting`, `stalled`, `operator-paused`, `complete` · driver: `worktree`, `warmup`, `merge-wait`, `rebasing`, `verifying`, `merging`, `merged`, `rate-limited`, `operator-paused`, … |
| `phase_since` | `verifying for 41m` — elapsed **in this phase** | bumped only when the phase actually changes |
| `story` / `iter` | `US-3 · iter 5` | the agent loop, each iteration |
| `stall` / `waits` | `stall 2` | the agent loop's no-progress and limit-wait counters |
| `passing` / `total` | the progress column, when no `prd.json` is readable | agent + driver |
| `retry_at` | the retry ETA on a paused row | the driver's usage-limit self-heal |
| `heartbeat` | `12s ago` — time since the run last did *anything* | **every** write; an in-turn ticker keeps it moving through a long `claude` call |

That gives three buckets you can tell apart at a glance, straight down the glyph
column:

- **`●` actively progressing** — a phase and a recent heartbeat.
- **`⚠` stalled / at-risk** — the scheduler still says `running`, but the heartbeat
  is older than **`CHIEF_STALE_SECONDS`** (default **900**, i.e. 15 min). The row
  says so in words (`⚠ stalled — no activity for 38m`), so `chief ps | grep stalled`
  works in a script.
- **`⏸` paused** — quiet *on purpose*, so it is never flagged stalled no matter how
  old the heartbeat is. Two different things pause a tasklist, and the next section
  is about telling them apart.

## Two pauses, one glyph — which one is holding the run?

`⏸` covers a **usage-limit** pause (state `rate-limited` — Chief waits out the
window and re-dispatches, see [Interruptions & resume](drivers-and-safety.md#interruptions--resume)) and an **operator**
pause (state `paused` — a human ran [`chief pause`](drivers-and-safety.md#pausing-a-run-the-operators-quota-lever),
and only `chief resume` lifts it). Confusing them is the difference between "wait 28
minutes" and "wait for a person", so the label and the note say which:

```text
my-api  (pid 12345 · -p2 · claude · 41m · →main)
  /Users/me/dev/my-api
   ⏸ OPERATOR PAUSE armed 6m ago — no tasklist launches, no new agent iterations · lift: chief resume
     ↳ draining: search — each stops at its next iteration boundary, then parks
   ⏸ usage-limit window until 15:10 (28m) — Chief waits this one out itself
     ↳ BOTH holds are armed — lifting either one alone changes nothing
   ⏸ auth                   paused-op 3/5     chief/auth
       ↳ paused: operator hold (chief pause) — armed 14:31 · branch + worktree kept · resume: chief resume · usage-limit window also armed until 15:10
   ⏸ billing                paused    2/4     chief/billing
       ↳ paused: usage limit — retry at 15:10 (28m) · re-dispatch 1/3 · paused 28m · 28m ago
   ● search                 running   1/6     chief/search
```

- The **holds banner** under the run header names every hold armed on that repo —
  read from `.chief/state/parallel/.paused` and `.limit-pause-until` — plus, while a
  pause is armed, which workers are still **draining** (each stops at its next
  iteration boundary; one already past its agent loop finishes verify+merge). With
  both armed it says so outright, because lifting either alone changes nothing.
- A parked tasklist reads **`paused-op`** (grep-able, distinct from the usage
  limit's `paused`) and its note carries what was kept and the command that picks it
  back up, not an ETA — Chief will never lift this one by itself.
- Neither pause ever borrows a failure glyph, and neither is flagged stalled.

Raise the threshold when your verify hook is legitimately slow — a driver phase has
no ticker, so a `npm ci` + `cargo build` verify can go quiet for minutes:

```sh
CHIEF_STALE_SECONDS=2700 chief monitor    # 45 min before a run reads as stalled
```

Everything here is **optional in every direction**: a tasklist with no record (an
older engine, a run that hasn't started) simply renders the row it always did — no
extra `↳` line, and *never* a stall flag, because an unknown age must not manufacture
an alarm.


## How it works

- The registry lives at `~/.chief/runs/` (override with `CHIEF_RUNS`). When a
  driver starts a real run it writes one small `<pid>.run` file there — absolute
  pointers to the repo, its state dir, and the scheduled tasklists — and deletes
  it on exit (including Ctrl-C and crashes caught by the shell).
- `chief ps`/`chief monitor` read those files and, for each one, read the live
  per-tasklist scheduler state under `<repo>/.chief/state/` — the coarse
  `<name>.state` word plus the `<name>.live.json` liveliness record above. Story
  counts come from the running worktree's `prd.json` (mid-run), the pre-merge
  snapshot, or the committed tasklist — whichever exists (and the record's own
  `passing`/`total` as a jq-free fallback).
- The record is written **atomically** (temp + `mv`) and read-modify-write, so the
  agent (iteration/story/turn fields) and the driver (worktree/verify/merge/limit
  phases) can own disjoint fields of the same file from different processes.
- A run file whose owning **pid is dead** (e.g. `kill -9`, a power loss) is
  **pruned on sight** the next time you run `chief ps`/`chief monitor`, so the
  view never shows ghosts.

The registry is read-only from the monitor's side — it never touches a run. It's
safe to run `chief ps` as often as you like, from any directory, while runs are in
flight.

## Is there a GUI?

**Not in chief — by design.** `chief ps` / `chief monitor` / `chief logs` are the
monitoring surface this repo ships, and the run registry above is deliberately plain
files so *anything* can read it. The desktop **GUI** — and the cross-host, many-repo
aggregation a fleet view needs — belongs to **chief-cloud**, the separate control
plane, whose Tauri app builds over that data via its `chiefd` daemon. chief stays
daemon-free and GUI-free; keeping the registry (and the machine-readable status
stream) stable and documented is its side of that seam. See
[`desktop-gui-decision.md`](desktop-gui-decision.md) for the full decision and
rationale.

## Notes

- `chief ps` is plain text when piped (no color/ANSI), so `chief ps | grep …`
  works cleanly in scripts.
- Dry runs (`chief run -n`) don't register — they spawn nothing.
- The registry is per host/user. Runs on other machines don't appear.
