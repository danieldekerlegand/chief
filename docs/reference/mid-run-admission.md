# Mid-run admission — offering work to a live run

> **Status:** Current · **Updated:** 2026-09-17 · **Owner:** chief

A run's work set used to be frozen at launch. `chief offer` widens it.

```
chief offer [--parked] <tasklist> […]
```

## The trade this removes

Reported by an operator on 2026-09-16. A run was working through seven tasklists;
four more were authored while it ran. There was no way to add them, and
`driver.lock` is one driver per repo — so a second `chief run` is refused. The
operator killed a live run, discarding an in-flight agent turn, purely to widen the
set.

That was a bad trade the tool offered, not a mistake somebody made.

## It offers; the run admits

`chief offer` checks the name and records a **request**. The run reads it at its next
**wave boundary** — the point the scheduler already decides what to launch — and
admits it there.

The check runs in **both** places, deliberately. At the keyboard, so an operator is
told no immediately rather than minutes later in a log. Again at admission, because
the gap between the two is a gap in which the tasklist can be parked, edited, or
merged by a sibling run. Both askings call the same function
(`admit_check`, `engine/admit.sh`) — a second copy of these rules would drift, and the
first thing it would drift into is admitting work the run then refuses to start.

So what the command promises is that the name was legal **when asked** and that the
request is durably recorded. It does not promise the tasklist has joined.

## The admission rules

A tasklist may join only if it would have been legal at launch:

| Rule | Refusal |
|---|---|
| it is not already in this run | `already in this run` |
| it is not already recorded done | `already recorded done — <record> carries mergedToMain` |
| the file exists | `no such tasklist: tasks/chief/<name>.json, and no merged record either` |
| it is not parked | `parked: <parkedReason>` — `--parked` waives it, exactly as `chief run --parked` does |
| it passes `chief lint` | `failed lint: <the first finding>` |
| its dependencies can be satisfied — by something **merged**, or by something **in the widened run** | `dependency "<dep>" …`, with the reason |

The dependency rule reads the **widened** set, and each accepted name joins the set
the next one is checked against — so `chief offer 10-alpha 11-beta` is legal when
`11-beta` depends on `10-alpha`, and the newcomer waits for its own dependency under
the ordinary scheduling rules. A dependency that is a live tasklist neither merged nor
in the run is refused with the fix rather than the classification: offer both.

Every refusal names its reason, at the moment of the request, before anything is
scheduled. The command exits non-zero if any name was refused.

`test/admission-refusals.sh` exercises each of those refusals as its own case — plus
the one the table cannot show, a request arriving once the run has stopped scheduling
— and proves the rules are load-bearing rather than decorative: against a copy of the
engine with `admit_check` neutered, every one of them is accepted instead, and the
parked tasklist a real run refuses is admitted, runs and merges.

## What an admitted tasklist gets

The same thing a name typed on the command line gets, and that is three things rather
than one:

- **The launch treatment.** Its scheduler state is initialised and its stale per-run
  files are cleared — the stall flag, the retry and attempt counters, the `.why` from a
  previous run, the worker log. A newcomer merely appended to the run's set inherits
  every one of them, and the run then reads a retry budget that is already spent and
  prints, in its own summary, the reason for a block that never happened in it.
- **The unmet-dependency pre-check.** The same one every launch name goes through. Its
  verdict can be `blocked`, which is a real outcome and not a contradiction: admission
  asks whether the dependency is merged or in the widened set, and this asks whether
  what is in the set can still *complete* — a dependency that has already failed, been
  blocked or been declined passes the first and fails this. Blocked (not left pending)
  so the reason is stated and cascades, exactly as at launch.
- **The accounting.** It appears everywhere the launch set appears: the end-of-run
  summary, the outcome word and exit code, the headless JSON summary, and the run's
  registry entry — which is where `chief ps` and `chief monitor` draw every row from,
  so a tasklist admitted but absent there would run and merge invisibly.

It is **appended** to the set, so the launch loop — which reads that set in order —
considers it last: a newcomer takes its place under the existing dependency and
conflict-domain rules and never jumps a wave.

## Timing, and what is never touched

Admission happens at a wave boundary — never inside the merge phase, never while a
worker is mid-iteration. In-flight work is untouched by construction: nothing in the
admission path reads or writes a running tasklist's branch, worktree or iteration
counter. `test/mid-run-admission.sh` asserts that from the worker's own side: it
offers a tasklist from *inside* a live agent turn and compares the running tasklist's
branch, worktree and iteration counter either side of the admission.

The window **opens** when the scheduler enters its loop and **shuts** when it leaves
it. Those two points are not decoration:

- Before the window opens and after it shuts there is no set to widen — there is a run
  computing its outcome, and the summary, the outcome word and the exit code are all
  derived from the set as it then stands. A request arriving then is refused with that
  reason rather than half-joining a finished run.
- A request is addressed to **one run**, by pid. A request made of a run that has since
  ended is stale by construction (one driver per repo, and `driver.lock` enforces it):
  the next run drops it and says so. Widening a run with a request an operator made of
  a different one is the silent auto-scan this feature refuses to be.

Refusing when no run is scheduling is **cheap**: nothing is written and no state is
touched.

## What it is not

- **Not a second driver.** `driver.lock` stays one-per-repo. The merge phase serialises
  against a moving base branch, and two drivers would race it.
- **Not a filesystem watcher.** A run that silently absorbed whatever appeared in
  `tasks/chief/` would make `chief run 310 311` mean something other than what the
  operator typed. The request is always explicit.
- **Not a re-prioritisation.** A newcomer takes its place under the unchanged
  dependency and conflict-domain rules and never jumps a wave.
- **Not a raised ceiling.** `-p N` and the host-wide machine budget
  ([`concurrency.md`](concurrency.md)) bound concurrency exactly as before. Admitting
  work adds to what is *waiting*, never to what may run at once.

Also unchanged mid-run: the base branch, the provider and model, `-p N`, and the
machine budget. Those are properties of the run, fixed when it started.

## Where the request lives

`<repo>/.chief/state/admit/` — the run's `open` marker (pid, PID namespace, run id,
event log, and the set it is carrying) and one `<name>.req` per outstanding request
(who asked, when, which run, whether a park was waived).

It is under `.chief/state/` and not in the tasklist JSON for the reason every piece
of durable chief state is: an operator-authored field in a tasklist file is either
discarded by the reconcile step's isolation guard or collides at rebase with the
branch's own edit to the pass flags. `.chief/state/` is gitignored and survives both.

Taking a request **removes** it: a request chief has answered — admitted or refused —
is never answered again at the next poll.

## Events

Three, in the run's own NDJSON log ([`events.md`](events.md)):
`tasklist.offered` when the request is recorded, then `tasklist.admitted` or
`tasklist.admission-refused` when the run reaches it. `tasklist.offered` is distinct
from the merge queue's `tasklist.queued` in both subject and direction — that one is
the merge queue taking a finished tasklist, this one is a person handing a run work it
did not start with.
