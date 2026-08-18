# The per-story diff-size budget

> **Status:** Current · **Updated:** 2026-08-17 · **Owner:** chief

Chief measures how large each **story's** change got, on the branch it is about to
merge, and says so. By default that is all it does — it reports and merges anyway. A
repo that wants teeth turns the budget into a hold that waits for `chief approve`, the
same hold an [overlap zone](overlap-zones.md) uses.

## Why size is measured at all

The merge floor (rebase → re-verify → `--no-ff`) is chief's correctness guarantee, and
nothing on this page touches it. The budget is a *policy* layer above it, and it exists
because of one empirical finding: in the AgenticFlict dataset, **larger diffs correlate
with higher merge-conflict probability**. Change size is not a proxy for quality — it is
the one variable an orchestrator directly controls, and chief controlled none of it: a
story could grow to two thousand lines and nothing anywhere said so.

## What is measured, in what units

The branch's real diff against `$CHIEF_BASE_BRANCH` — **the same scope the verify hook
is given** (`<base>...HEAD`, post-rebase) — decomposed **by story**.

The story is chief's unit of work and of review: one iteration, one story, one
`feat: [US-x] - Title` commit. So it is the unit a size budget has to be in. A tasklist
of six small end-to-end stories is exactly the shape the budget is trying to encourage;
judging it on its 2,000-line *total* would punish it for being right. The branch total
is reported for context and never trips anything.

Per story, chief records:

| | |
|---|---|
| `lines` | added + deleted, summed over the story's commits (a binary file contributes 0 — it has a size, but not one measured in lines) |
| `files` | distinct paths the story touched |
| `renames` | paths git's own `-M` rename detection resolved as a rename/move |
| `commits` | how many commits carried the story's id |

Commits whose subject carries no `[US-x]` id are grouped under the story id `-` and
reported the same way, so nothing measured goes missing.

## Settings

Per repo, in `.chief/config` (the environment wins over it). All optional; unset means
exactly the defaults shown.

```sh
CHIEF_DIFF_BUDGET=warn         # warn (default) · block · off
CHIEF_DIFF_BUDGET_LINES=400    # changed lines per story;  0 disables this axis
CHIEF_DIFF_BUDGET_FILES=20     # changed files per story;  0 disables this axis
```

A story is over budget when it exceeds **either** enabled axis.

### Why the default is `warn`, not `block`

A hard block by default would be wrong in the expensive direction. A rename sweep, a
codemod, a generated file and a genuine large refactor are all legitimately big, and a
gate that stops them is a gate an operator switches off — at which point it stops
reporting the case it was built for, too. So the default makes oversize **visible** and
merges anyway. `block` is available for repos that want the branch to wait.

| mode | what happens to an over-budget branch |
|---|---|
| `warn` *(default)* | Reported in the worker log, in the story's record, and in `chief ps` / `chief monitor`. **Merges.** |
| `block` | Everything `warn` does, and the branch is held in `awaiting-approval` — after a clean rebase and a green verify — until `chief approve <name>`. |
| `off` | Not measured. No record is written, and any stale one is removed. |

## Breadth vs growth — what the message distinguishes

"12 files" means two very different things, so the report names which one it is looking
at, on the evidence:

- **a rename/move sweep** — git's `-M` detection resolved a large share of the paths as
  renames. That is breadth, not growth.
- **wide but shallow** — many files, few lines each (`~9 line(s) per file across 14`).
  A sweep across a codebase, not one thing growing unbounded.
- **concentrated** — a few files gaining hundreds of lines each. This is the shape the
  budget is actually about, and the shape a smaller story would have avoided.

The report states the evidence and stops there. Whether the change was warranted is the
reader's judgement, and chief does not pretend to make it.

## Where the finding shows up

- **The worker log**, at the merge phase, right where the decision is made.
- **The story's own record.** Each story in the run's tasklist snapshot gains a
  `diffSize` object (`files`, `lines`, `renames`, `budget`, `overBudget`), and the
  snapshot is what `finalize_merged` copies into `tasks/<project>/completed/` — so the
  size a story shipped at outlives the run's state directory.
- **`chief ps` / `chief monitor`**, as a `diff budget: US-2 1842L/12F · budget 400L/20F
  per story (warn)` line on the tasklist's row. Under `warn` the branch merges, so this
  is the surface that matters: the row will read `done`, and the finding still shows.
- **The durable record** at `.chief/state/parallel/<name>.budget.json` — the full
  per-story measurement, rewritten at each merge attempt.

## Under `block`: one hold, one approval

An over-budget story under `block` contributes to the **same** merge-policy gate an
overlap zone does: one request file, one checksum-bound verdict, one `chief approve`.
A branch that trips a declared zone *and* a size budget is asked about **once**, and the
request lists both reasons. Everything in
[overlap zones → Approving](overlap-zones.md#approving) applies unchanged — including
that the verdict is bound to the changed-file list, so a branch that changes again is
asked again.

The order never varies: rebase → verify → *then* the question. A person is never asked
to bless a branch that has not already cleared every automated bar.

## Guidance: what the budget is really asking for

**Prefer several small end-to-end stories over one horizontal, layer-at-a-time story.**

The vertical slice — schema *and* logic *and* interface *and* test for one narrow
capability — is the shape that keeps a diff small without keeping it useless. Its
opposite, the horizontal slice ("story 1: all the types; story 2: all the handlers;
story 3: wire it up"), produces exactly the diffs this budget flags: nothing is
reviewable until the last story lands, nothing is verifiable in between, and the whole
tasklist's design risk arrives at once.

The economics are the argument. Reviewing 100–200 lines and resteering costs minutes,
and the correction lands before anything was built on top of it. Reviewing 2,000+ lines
costs an afternoon, and by then the wrong assumption is load-bearing — the choice is
between accepting it and unwinding a week. That asymmetry is the whole case for small
stories, and it is why chief's unit is one story per iteration in the first place. This
budget is only that principle made measurable.

Practical consequences when a story trips the budget:

- **Split it.** Two stories of 300 lines each are strictly better than one of 600, and
  chief's loop is built to run them back to back.
- **If it is a sweep, say so.** A rename sweep or a codemod is a legitimate large diff.
  Under `warn` it is a log line; under `block`, `chief approve -m "codemod: rename
  Foo→Bar across 40 files"` records exactly that, durably.
- **If it is growth, look at the story text.** A story that spans four layers usually
  says so in its acceptance criteria, and it was oversized before a line was written.

## What this is not

- **Not a quality metric.** Small is not correct; the budget only reports size. The
  measured quality axis is `engine/quality.sh` (see [the verify hook](verify-hook.md)).
- **Not a weakening of the floor.** It runs strictly after the rebase and the verify,
  and its only power is to withhold a merge, never to allow one.
- **Not a per-commit cop.** It never inspects a story mid-flight or rejects a commit;
  it measures the finished branch at the merge phase, where the numbers are final.
