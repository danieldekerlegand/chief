# Plan review — the checkpoint between criteria and code

Chief's default loop goes straight from a story's acceptance criteria to a commit.
That is the right shape for most tasklists, and it is why the default here is **off**.
But it means the first human-readable artifact of a large or architectural story is
the diff — and by then the misunderstanding has already been written down a few
hundred times.

**Plan review** is the opt-in checkpoint that fixes that. When a tasklist sets
`"review": "plan"`, each story gets one extra turn *before* any edit: the agent writes
a structured **plan artifact** — the files it will touch, what each change is, and the
checks it will run — **a human approves it**, and only then does the agent implement.
The leverage is the point: steering a ten-line plan is cheap, and it is upstream of
every line the plan would have produced.

```
story  ──►  PLAN turn  ──►  human verdict  ──►  IMPLEMENT turn  ──►  commit
              (agent)        (plannotator)         (agent)
                  ▲                │
                  └── annotated ───┘   bounded by CHIEF_REVIEW_MAX_ROUNDS
                                   │
                                   └── no reviewer ──► PARKED (AWAITING-REVIEW)
```

Everything below is what the engine does today. Enabling it is a one-word,
reviewable diff on the tasklist; nothing changes for a tasklist that does not.

## The review-leverage hierarchy — why a plan and not the code

Review time is not fungible. The same half hour buys wildly different amounts of
correctness depending on *which artifact* you spend it on, because each one sits
upstream of a different volume of generated code:

| you review | you catch | it would have become |
|---|---|---|
| **research** — what the system actually does, what the requirement actually means | a misunderstanding of the problem | **thousands** of lines built on a wrong premise |
| **plan** — which files move, what each change is, how it will be checked | a wrong seam, a missed call site, a check that proves nothing | **hundreds** of lines of the wrong change |
| **code** — the diff | a bug on a line | **that line** — the ratio is 1:1 |

Reviewing code is the *most expensive* place to find a design mistake and the *last*
place you can. That is the whole argument for this phase, and the reason the industry
shorthand is "thirty minutes of planning saves hours of review".

Chief guarded none of the three: its loop went from acceptance criteria straight to a
commit, and the first thing a human saw was the diff. This checkpoint adds the
**middle** rung — the cheapest one with a mechanical artifact to hang a verdict on. A
plan is short, it is structured (files, changes, checks), and a person can be wrong
about it out loud in one sentence. Research review has no such artifact yet; code
review already has git.

The corollary matters as much as the rationale: **the leverage is only worth an
iteration when there is a design to get wrong.** Below, "when to turn it on".

## Enabling it

```jsonc
{
  "branchName": "chief/42-storage-rewrite",
  "review": "plan",          // "plan" | "none" (default "none")
  "userStories": [ … ]
}
```

`$CHIEF_REVIEW` overrides the tasklist for one run (`CHIEF_REVIEW=plan`,
`CHIEF_REVIEW=none`) — the seam a host embedding chief uses. Any value other than
`plan` is off.

## When to turn it on (and when not to)

The default is off because most work does not need it. The research this phase comes
from puts roughly **40% of agent tasks in the one-shot bucket** — small, obvious,
done in a turn — with the rest split between medium tasks that benefit from a plan
and large ones that are unsafe without one. Plan review costs **one extra iteration
per story** plus a human's attention, so spend it where a wrong design is expensive
and skip it where the design is not in question.

**Turn it on for:**

- **Architectural tasklists** — a new seam, a trait/interface extraction, a storage
  or protocol change. The plan *is* the decision; the code is transcription.
- **Wide blast radius** — a change that touches many call sites, or one whose
  rollback is a migration.
- **Ambiguous criteria** — a story you could satisfy three different ways, where the
  cheap way is wrong. The plan is where you find out which one the agent picked.
- **A tasklist that already went wrong once.** A branch that came back `INCOMPLETE`
  or was thrown away is a tasklist whose plan nobody saw.

**Leave it off for:**

- **One-shots** — one file, one obvious change, criteria that read like the diff.
- **Mechanical refactors** — a rename, a move, a lint fix. There is no design to
  review; there is a test suite, which is a better reviewer than a person here.
- **Docs and config.** The artifact and the review are the same document.
- **Unattended runs you will not be watching.** An enabled tasklist with nobody in
  front of the machine parks and waits (below) — correct, but it means an overnight
  run stops on it. Enable it on the tasklists you intend to sit with.

Mixing is the normal case: enable it on the two architectural tasklists in a roadmap
and leave the other dozen alone. `touches`/`dependsOn` scheduling is unchanged, so a
parked review-enabled tasklist never holds up the ones that are not.

## The plan artifact

One file per story, written by the PLAN turn:

```
.chief/state/plans/<story-id>.plan.json
```

`.chief/state/` is the same gitignored, filesystem-resumable state the runtime PRD and
the progress log live in, so the path honours `$CHIEF_STATE_DIR` when a project
relocates it. Inside the driver, that resolves per-worktree — plans are as isolated as
everything else a parallel run touches.

```json
{
  "story": "US-3",
  "summary": "Move the blob index behind a trait so the S3 and local backends stop diverging.",
  "changes": [
    { "path": "src/store/mod.rs",   "action": "modify", "change": "Extract the four index methods into a `BlobIndex` trait; keep the concrete struct as the local impl." },
    { "path": "src/store/s3.rs",    "action": "create", "change": "S3 impl of `BlobIndex`, sharing the retry helper already in `net::retry`." },
    { "path": "src/store/legacy.rs","action": "delete", "change": "Dead since the v2 migration; its one caller moves to the trait." }
  ],
  "verification": [
    { "phase": "build", "command": "cargo build" },
    { "phase": "test",  "command": "cargo test store::" }
  ]
}
```

Required, and checked by the engine:

| field | rule |
|---|---|
| `story` | must equal the id of the story being planned |
| `summary` | non-empty string |
| `changes` | non-empty array; each entry has `path`, `action` (`create`/`modify`/`delete`), and `change`, all non-empty |
| `verification` | non-empty array; each entry has `phase` and `command`, both non-empty |

Extra keys (`risks`, `openQuestions`, `alternatives`) are preserved and shown to a
reviewer. They are the right place for a decision the plan is genuinely unsure about.

## What a PLAN turn is, and what it costs

- It is **one iteration**, taken from the same budget as any other, and it happens
  only for a story whose plan is not already on disk and valid.
- The agent is told to write the artifact and **nothing else** — no edits, no commits,
  no `passes` flips. A completion token emitted on a plan turn is ignored and said out
  loud in the log, because a plan turn cannot finish a tasklist.
- It is **idempotent across restarts**. The decision "plan or implement?" is re-derived
  each iteration from state on disk (the tasklist's `review` field, and whether the
  artifact exists and parses), so a resumed run never re-buys a plan it already has.
  The driver mirrors `plans/` into `.chief/state/snapshots/<name>.plans/` after every
  worker, and restores it when seeding the worktree — so the plan survives the
  worktree being rebuilt, not just the process dying.

## The verdict: approval, by plannotator

**The review surface is adopted, not built.**
[plannotator](https://github.com/backnotprop/plannotator) (Apache-2.0 OR MIT) is a
local browser annotation surface that already does this job — and already hooks
Claude Code and OpenCode, two of chief's four providers. Chief does not vendor it,
wrap its UI, or reimplement any of it. It calls the **one-shot approval gate**
plannotator documents:

```sh
plannotator annotate <plan.md> --gate --json --require-approval --result-file <out.json>
```

and reads the JSON that command emits:

| the reviewer clicked | JSON | chief does |
|---|---|---|
| **Approve** | `{"decision":"approved"}` | the next turn implements exactly that plan |
| **Annotate** | `{"decision":"annotated","feedback":"…"}` | records the notes, **deletes the plan**, and re-plans with the notes in the prompt |
| **Dismiss** / no answer | `{"decision":"dismissed"}` / nothing | parks (see below) — a non-answer is never a yes |

Chief renders its JSON artifact to markdown first (`<story-id>.plan.md`, next to the
plan) because that is what a person annotates: a table of files and changes, the
verification the agent is committing to, any `risks`/`openQuestions` it declared, and
every previous round's feedback so a reviewer can see whether the re-plan answered
them.

`$CHIEF_REVIEWER` may name a different program, but **the contract is the one above** —
a reviewer chief can talk to is a program that speaks plannotator's annotate gate.

### Knobs

All optional, all defaulting to the unattended-safe value. Settable in the
environment or in `.chief/config`.

| variable | default | what it does |
|---|---|---|
| `CHIEF_REVIEWER` | `plannotator` | the reviewer program |
| `CHIEF_REVIEW_TIMEOUT` | `900` | seconds to wait for a verdict. **`0` never launches a reviewer at all** and parks immediately — the honest setting for CI |
| `CHIEF_REVIEW_MAX_ROUNDS` | `3` | annotate → re-plan rounds per story before chief stops spending turns |
| `CHIEF_REVIEW_NONINTERACTIVE` | unset | `1` declares the host has nobody in front of it (`$CI` does the same) |

plannotator's own gate is deliberately long-running (its shipped hooks use a four-day
timeout) because human review is. Chief cannot hold a worker slot on that, so it
enforces `CHIEF_REVIEW_TIMEOUT` itself and terminates the reviewer's whole process
group when the window closes. A killed reviewer is a park, never an approval.

## When nobody is there: AWAITING-REVIEW

This is the part that has to be right, because chief's whole character is unattended
and resumable. **An unreachable reviewer is not an approval, and it is not an error
either.** It PARKS the tasklist — the same drain the operator pause already uses,
in its own state so `chief ps` can say which of the three holds is on it.

Five things park a story: no reviewer on `PATH`, `CHIEF_REVIEW_TIMEOUT=0`, a
non-interactive host (`$CI` / `CHIEF_REVIEW_NONINTERACTIVE`), a review window that
elapses with no verdict, and an annotate → re-plan budget that runs out.

| surface | value |
|---|---|
| `agent.sh` exit code | `5` |
| `<name>.status` | `AWAITING-REVIEW <passing>/<total>` |
| scheduler state | `awaiting-review` — **non-terminal**, like `paused` and `rate-limited` |
| `chief ps` / `monitor` | `⏸` with the label `in-review` |
| headless `outcome` / exit | `awaiting-review` / `7` (work withheld, not broken) |
| events | `story.awaiting-review` then `tasklist.awaiting-review` |

What that buys, concretely:

- **The scheduler is never blocked.** Siblings keep running; only this tasklist waits.
- **Dependents are not cascaded to `blocked`** — a tasklist waiting on a person is
  unfinished work with an intact branch, not broken work.
- **Nothing is half-done.** The park happens at an iteration boundary, before any
  edit; the branch, the worktree, the plan and every annotation are kept.
- **Finished work still finishes.** The park withholds *agent turns*. A tasklist that
  already has every story passing goes on to verify+merge exactly as it would have —
  parking it would strand a mergeable branch (and its dependents) on an unbounded
  human decision.

### An approval is asked for once

The verdict lands in `.chief/state/plans/<story-id>.review.json`, next to the plan:

```json
{ "story": "US-3", "reviewer": "plannotator", "decision": "approved",
  "plan": "2551321789-239", "at": 1786548139,
  "rounds": [ { "round": 1, "decision": "annotated", "feedback": "the S3 path is missing", "at": … },
              { "round": 2, "decision": "approved",  "feedback": "",                       "at": … } ] }
```

Because it is a file — and because the driver mirrors `plans/*.json` into
`.chief/state/snapshots/<name>.plans/` and restores it when the worktree is seeded —
an approval survives process death, a usage-limit sleep, an operator pause and a
rebuilt worktree. A resumed run reads it and implements; it does not ask again.

`plan` is a checksum of the plan artifact the verdict was given for. A story that
gets re-planned after annotations cannot inherit the approval of the plan it
replaced — which is the one way "don't re-ask" could otherwise wave through code
nobody agreed to. `rounds` is append-only: it is the reviewer's side of the
conversation, and it is what the next PLAN turn is briefed with.

## When the plan is malformed

A plan turn that writes no artifact, or one that fails the table above, **stops the
tasklist**. It does not fall through to implementation — that is the single outcome
the whole checkpoint exists to prevent.

| surface | value |
|---|---|
| `agent.sh` exit code | `4` |
| `<name>.status` | `PLAN-INVALID <passing>/<total>` |
| scheduler state | `failed` (branch **and** worktree kept for re-engagement) |
| `chief ps` / `monitor` phase | `plan-invalid` |
| headless `outcome` | `plan-invalid` |
| events | `story.plan-invalid` (story scope) then `tasklist.plan-invalid` (tasklist scope) |

It is deliberately **not** retried, by either the loop or the scheduler's
retry-on-failure budget. The three statuses that are retried (`VERIFY-FAILED`,
`MERGE-CONFLICT`, `REBASE-CONFLICT`) are transient-shaped. A plan that would not form
is usually a story whose criteria the agent could not turn into a file list — another
attempt spends a turn to reach the same wall, and buries the one signal worth reading.
Fix the story text (or the plan) and re-run; the branch is exactly where it was.

A successful plan turn is the mirror image: phase `plan-ready`, a `story.plan-ready`
event, the stall counter reset, and the next iteration puts it in front of a human.

## Related

- `test/plan-review.sh` — the hermetic proof of all three paths (approved · sent back
  within budget · nobody there), with a scripted fake reviewer speaking the annotate
  gate above. It is in the merge gate for any branch that touches the engine.
- [tasklist-schema.md](tasklist-schema.md) — the rest of the tasklist fields
- [events.md](events.md) — the `story.plan-*` / `tasklist.plan-invalid` contract
- [monitoring.md](monitoring.md) — the phase vocabulary `chief ps` renders
