# Overlap zones — where a green gate is not enough authority to merge

Chief's correctness guarantee is the **merge floor**: before anything reaches the base
branch it is rebased onto the latest base, re-verified, and merged `--no-ff`. Textual
interference between parallel branches surfaces as a rebase conflict; staleness
surfaces as a verify failure. Interference degrades to a caught failure, never a silent
merge. That floor is unchanged by everything on this page.

It is also blind to one thing. Parallel agents each hold a *different slice of context*,
so two branches can produce individually correct code whose **designs disagree** — one
adds a queue, the other adds a second queue for the same events; one widens a schema
column, the other adds a parallel table. Nothing collides. Both rebase clean. Both
verify green. The result is still wrong, and it is wrong at the level of intent, which
is where a person has standing and a test does not.

An **overlap zone** is a domain a repo declares as one where that outcome is
unacceptable. A branch that changed one is held *after* the floor has run, and merges
only when a human says yes.

## The registry

One file per repo: `.chief/zones.conf` (override the path with `$CHIEF_ZONES`). It is
scaffolded by `chief init` with every line commented out — **a repo with no zones
behaves exactly as it did before this feature existed**, down to the merge phase's
output. One zone per line; `#` starts a comment:

```
<policy>   <matcher>              [reason — printed wherever the zone is reported]

review     path:src/schema/       the data model two agents must not diverge on
review     path:*/migrations/*    schema migrations, in any package
review     touches:auth
serialize  path:docs/             documented, scheduled apart, merged as usual
```

### Policies

| policy | what it does |
|---|---|
| `serialize` | Today's behaviour, exactly. The scheduler already refuses to co-run two tasklists that share a `touches` domain; declaring a `serialize` zone documents the domain and makes it visible in the run log. **The merge phase is unchanged.** |
| `review` | Serialize *and* require an explicit human approval before the merge — however green the gate came back. The branch lands in the `awaiting-approval` state and merges only on `chief approve`. |

### Matchers

| matcher | matched against |
|---|---|
| `path:<glob>` | Each repo-relative path the branch actually changed — `git diff --name-only <base>...HEAD`, the same scope the verify hook uses. `*` crosses `/`, so `engine/*.sh` also covers `engine/x/y.sh`; a trailing `/` means "everything beneath this directory". |
| `touches:<domain>` | An exact `touches` domain name from the tasklist JSON. |

**Path matchers are the load-bearing half, and that is deliberate.** A tasklist's
`touches` entries are frequently *conceptual tags* — a real one declared
`cuneiform-engine` and `render-goldens`, neither of which is a path, neither of which
matches anything lexically. A registry keyed on tags alone is therefore invisible in
exactly the case it exists for. Keying on the branch's real changed files is what makes
a zone catch the tasklist that never named it. Use `touches:` only where your tags
really are domains, as a second key on top.

For a `repo:<sub>` (submodule) tasklist the registry is still the project's
`.chief/zones.conf`, and `path:` patterns are matched against paths as the *submodule*
reports them — i.e. relative to the submodule root, not to the project.

A malformed line is reported on stderr (into the worker log, next to the decision) and
ignored. A registry typo never takes down a run.

## What happens to a held branch

The order matters, and it is fixed:

1. The worker finishes its stories and acquires the merge lock.
2. **The floor runs first** — rebase onto the latest base, then the verify hook.
   A branch that fails either one never reaches the zone check at all; it is a
   `REBASE-CONFLICT` / `VERIFY-FAILED` exactly as before.
3. The rebased branch's real changed files are matched against the registry.
4. No `review` zone matched → it merges, unchanged.
5. A `review` zone matched → the run writes an approval **request** and parks the
   tasklist in state `awaiting-approval`.

So a person is only ever asked about a branch that has already cleared every automated
bar. Approval is asked **for** the gate, never **instead of** it.

The park keeps the branch — rebased onto the latest base and verified. It is the one
chief park whose worktree is already gone: the merge phase removes the worktree to free
the branch for checkout, before any of this. Nothing is half-done; a resumed run
rebuilds the worktree it needs.

`awaiting-approval` is **non-terminal and not a failure**. Dependents stay `pending`
rather than cascading to `blocked`, the scheduler carries on with the siblings, the run
summary reports it apart from the failures, and a headless run exits `7` (held), not a
failure code.

## Approving

```
chief approve                 # what is waiting, and why
chief approve --list          # the same
chief approve 91-zones        # release it
chief approve 91-zones -m "checked against 88's queue design"
chief run                     # the next run merges it without asking again
```

`chief ps` / `chief monitor` show the hold as `zone-hold` with the zones that matched
and the command to release it.

### The verdict is durable, and bound to what it approved

The approval is a JSON file in the driver's state directory
(`.chief/state/parallel/<name>.zone-approval.json`), written next to the request the run
produced. That location is deliberate: it outlives the process, the run, and the
worktree — which is deleted and rebuilt by every run — so an approval given once is
never asked for twice, across process death, a usage-limit sleep, an operator pause or
a restart.

It carries a `change` checksum over **the branch's changed-file list plus the zones that
matched**, and the merge phase re-derives that checksum before accepting the approval.
Two consequences, both intended:

- Approving a branch does not pre-approve whatever it does next. If the branch changes
  again, the question is asked again.
- Widening the registry onto a branch re-asks, even if that branch was approved for a
  narrower set of zones.

`chief approve` never pre-approves: it refuses a name with no request on disk, because
until the floor has run there is nothing to approve.

## Overlap-zone approval vs plan review — two decisions, two times

Chief has a second, entirely separate human checkpoint: the opt-in **plan review**
(`docs/plan-review.md`), enabled per tasklist. They never double-prompt, because they
are asked at different times about different things:

| | plan review | overlap-zone approval |
|---|---|---|
| **When** | Before the first line of code, per story | After the last one, once per merge |
| **Enabled by** | `"review": "plan"` on the tasklist (opt-in per tasklist) | A `review` zone in `.chief/zones.conf` matching what the branch changed (per repo, per change) |
| **The question** | "Is this the right plan to implement?" | "Does this finished, green change agree with what else landed?" |
| **What it sees** | A rendered plan artifact — no code yet | A branch, rebased onto the latest base, verified green |
| **Park state** | `awaiting-review` (`in-review` in `ps`) | `awaiting-approval` (`zone-hold` in `ps`) |
| **Released by** | A reviewer verdict (`plannotator`, or `$CHIEF_REVIEWER`) | `chief approve <name>` |

With both enabled on the same tasklist you are asked twice over its lifetime — once
before it writes code and once before its finished branch merges — and never twice about
the same thing. An approved plan is not an approved merge: what the branch became is the
subject of the second question, and it is the only one the first could not have seen.

## The other rule in the same layer: the diff-size budget

The merge phase asks **one** policy question, and two rules answer it. The second is the
per-story [diff-size budget](diff-budget.md): chief measures every branch's diff against
the base, decomposed by story, and — under `CHIEF_DIFF_BUDGET=block` — an oversized story
holds the branch exactly as a `review` zone does.

They are unified at the gate rather than stacked as two checkpoints because they are the
same question — *this branch is green and still needs a person* — so a branch that trips
a declared zone **and** a size budget is asked about once, on one request file, with one
checksum-bound verdict and one `chief approve`. The request lists both reasons; a budget
hold appears in it as `budget:lines` or `budget:files` next to any zones that matched.

## What this is not

- **Not a conflict predictor.** Chief evaluated binding one and declined
  ([`docs/decisions/conflict-predictor-adoption-decision.md`](../decisions/conflict-predictor-adoption-decision.md)):
  every one it assessed predicts *collision*, which the merge floor already determines
  by real rebase, and none detects design divergence, which is what this page is about.
- **Not a weakening of the floor.** Nothing here can let something merge that the floor
  would have stopped; the check runs strictly after it, and its only power is to withhold.
- **Not a scheduling change.** `touches` remains what it was: a hint the scheduler uses
  to avoid wasted rebase churn ([`../explanation/drivers-and-safety.md`](../explanation/drivers-and-safety.md)).
  A `serialize` zone changes nothing at all; a `review` zone changes only whether a
  green branch may merge unattended.
