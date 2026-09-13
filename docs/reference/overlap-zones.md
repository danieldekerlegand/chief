# Overlap zones — where a green gate is not enough authority to merge

> **Status:** Current · **Updated:** 2026-09-12 · **Owner:** chief

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

review     surface:src/schema/*.ts:^export[ ]+(type|interface)   the declared shape, not its readers
```

### Policies

| policy | what it does |
|---|---|
| `serialize` | Today's behaviour, exactly. The scheduler already refuses to co-run two tasklists that share a `touches` domain; declaring a `serialize` zone records the domain in a file a human reviews, next to the ones that do hold a merge. It prints nothing and changes nothing at run time — **the merge phase is unchanged**, which is what `test/overlap-zones.sh` PART A asserts. |
| `review` | Serialize *and* require an explicit human approval before the merge — however green the gate came back. The branch lands in the `awaiting-approval` state and merges only on `chief approve`. |

### Matchers

| matcher | matched against |
|---|---|
| `path:<glob>` | Each repo-relative path the branch actually changed — `git diff --name-only <base>...HEAD`, the same scope the verify hook uses. `*` crosses `/`, so `engine/*.sh` also covers `engine/x/y.sh`; a trailing `/` means "everything beneath this directory". |
| `touches:<domain>` | An exact `touches` domain name from the tasklist JSON. |
| `surface:<glob>:<ere>` | **The same glob, narrowed to what within those files is load-bearing.** It matches only when the branch's diff to a matching file *adds or removes* a line matching `<ere>` — so adding a routine consumer under a watched path does not hold, and rewriting the declaration it calls does. Split at the **first** colon, so a glob may not contain one. See [Narrowing a rule](#narrowing-a-rule-what-within-the-path-is-load-bearing). |

**Path matchers are the load-bearing half, and that is deliberate.** A tasklist's
`touches` entries are frequently *conceptual tags* — a real one declared
`cuneiform-engine` and `render-goldens`, neither of which is a path, neither of which
matches anything lexically. A registry keyed on tags alone is therefore invisible in
exactly the case it exists for. Keying on the branch's real changed files is what makes
a zone catch the tasklist that never named it. Use `touches:` only where your tags
really are domains, as a second key on top.

### Narrowing a rule: what within the path is load-bearing

A `path:` glob is **file-level**, and a file is often the wrong unit for the question
being asked. A zone that watches `engine/*.sh` because the scheduler's *contract* is
where two agents' designs must not diverge also fires on a branch that added a routine
consumer three directories down: same file set, entirely different risk. Every hold then
looks alike, and a hold that looks like every other hold is approved unread — which is
worse than no hold, because it manufactures a record of a review that did not happen.
That is what happened on 2026-09-10, when every `review` rule in two downstream
registries was rewritten to `serialize` in a single day.

So a zone can say what **within** the watched path it cares about:

```
review  path:engine/*.sh                              # every change under the path
review  surface:engine/*.sh:^[a-z_][a-z_0-9]*\(\)      # …only its function declarations
review  surface:engine/driver.sh:^AGENT_RC_           # …only the contended exit-code namespace
```

- **It reads the diff, not the file.** Matching the ERE against the file as it now
  stands would hold every branch that touched a file which *happens to contain* a
  declaration — the file-level rule again, wearing a regex. The changed lines are the
  only reading under which "added a consumer" and "changed the contract" differ.
- **Both signs count.** A removal is a change to a surface exactly as an addition is;
  deleting a declaration is the most consequential edit to one. A pure move therefore
  holds, which is the right answer — the declaration's home changed.
- **The whole matcher is one whitespace-free token**, for all three forms: the reason
  begins at the next space. An ERE needing a literal space writes it as the bracket
  expression `[ ]`. Spelled with a real space it still *compiles*, shorter than
  intended, with the remainder read as prose — the one mistake in this format that is
  not reported.
- **It fails closed.** If the branch's diff cannot be read, or the module is not
  sourced, the rule falls back to plain `path:<glob>` matching — the old, coarser rule,
  never *no* rule. A review gate that silently stops holding has disarmed itself.
- **A malformed `surface:` line is reported on stderr and skipped**, like any other
  registry typo, and the run carries on.

#### The old forms keep their meaning, exactly

`surface:` is a **third matcher beside** `path:` and `touches:`, never a
reinterpretation of either. A registry using only the old two evaluates today's rules
against today's inputs and produces today's holds, byte for byte, and a repo with no
`zones.conf` still behaves exactly as it did before any of this existed.

**Re-arming stays a one-word edit.** A rule that was costing more than it caught became
`serialize`; it re-arms by putting `review` back, with nothing else about the line
changed. Narrowing it with `surface:` is a *separate, opt-in* edit you can make when you
choose — and a disarmed registry can re-arm first and narrow later, or not at all.

#### Choose the surface by measuring it, not by taste

`scripts/zone-friction.sh` replays a before/after registry pair over a repo's
first-parent merges and reports **both directions** — the holds that survive the
narrowing, and the holds released — using the gate's own matcher, read-only:

```
bash scripts/zone-friction.sh before.conf after.conf --repo . --rev main
```

Both directions matter, because **a rule that holds nothing is ignored exactly as a rule
that holds everything is.** Measured over chief's own 54 merges (2026-08-01 → 09-12):

| zone | before | after | released |
|---|---|---|---|
| `path:engine/driver.sh` → `surface:engine/driver.sh:^AGENT_RC_` | 31 holds | 4 | **27 (87%)** |
| `path:engine/*.sh` → `surface:engine/*.sh:^[a-z_][a-z_0-9]*\(\)` | 47 holds | 43 | 4 (8%) |

The first is the shape to write: the agent exit-code namespace is a genuinely contended
declaration — two parallel tasklists claiming the same number is a design collision no
gate catches — and the four merges it still holds are exactly the four that claimed a
code. The second is the shape to avoid: in a repo whose every tasklist authors engine
functions, "any declaration" is the coarse glob spelled longer, and it still asks about
79% of merges. **Name the contended declaration, not every declaration** — and check it
against your own history before arming the rule, because which one you have written is
not visible by reading it.

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

### What a hold says

A hold is only worth its friction if it can be read, and the report it used to produce
could not be: the glob that matched and the *first* file that hit it. "This branch
changed something under `engine/`" is the same sentence whether the branch touched one
file or thirty, so every hold looked alike and every hold was approved unread.

A hold therefore names **everything the zone matched**, one line per hit:

```
!! 91-zones HELD BY THE MERGE POLICY LAYER — it is rebased onto main and its verify came back GREEN;
   it is not merged because the merge policy layer matched what it changed:
     review  path:src/schema/  (matched: src/schema/order.rs)  — the data model two agents must not diverge on
     review  path:src/schema/  (matched: src/schema/user.rs)
     review  budget:lines      (matched: US-3: 612 line(s), 9 file(s))  — the per-story diff-size budget …
```

- **The reason rides the zone's first line only.** It belongs to the zone, not to each
  hit, and a sentence printed ten times is a sentence nobody reads.
- **A long list is cut, and the cut says so.** Past `ZONES_HIT_LIMIT` (10) the list ends
  with `… and 14 more changed file(s) (24 in total, set id 3279879893-116)`. Never a
  list that simply stops: a report that lies about the size of what it describes is the
  same defect one register up.
- **The same detail reaches all four places a hold is reported** — the worker log, the
  request file (`.chief/state/parallel/<name>.zone-request.json`), the run summary's
  awaiting-approval block, and `chief approve --list`. All four render the one list, so
  they cannot drift into three and one.

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
- **Cutting a long list for display does not shorten what the approval covers.** The
  truncation line carries a `set id` over the *whole* match, so two branches differing
  only past the cut get different checksums. Bind to what survived truncation instead
  and a later change that rewrote a different ten of the same thirty surfaces would
  silently reuse the old yes.

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

## The other rules in the same layer: the diff-size budget, and resolution deletions

The merge phase asks **one** policy question, and three rules answer it. The second is the
per-story [diff-size budget](diff-budget.md): chief measures every branch's diff against
the base, decomposed by story, and — under `CHIEF_DIFF_BUDGET=block` — an oversized story
holds the branch exactly as a `review` zone does.

They are unified at the gate rather than stacked as two checkpoints because they are the
same question — *this branch is green and still needs a person* — so a branch that trips
a declared zone **and** a size budget is asked about once, on one request file, with one
checksum-bound verdict and one `chief approve`. The request lists every reason; a budget
hold appears in it as `budget:lines` or `budget:files` next to any zones that matched.

The third rule is [resolution deletions](resolution-deletions.md): when a branch's
conflict resolution throws away lines that already merged, the branch is held and the
finding names each line, the commit that added it and the sibling tasklist whose work
it was, as `resolution:deleted` hold lines in the same request. It differs from the two
above in one way worth stating here — **it is always armed**. A `review` zone is opt-in
and `CHIEF_DIFF_BUDGET=block` is opt-in; that rule holds with no `zones.conf` at all,
because it does not report a preference about where review is warranted, it reports
that already-merged work would be undone.

## What this is not

- **Not a conflict predictor.** Chief evaluated binding one and declined
  ([`docs/decisions/conflict-predictor-adoption-decision.md`](../decisions/conflict-predictor-adoption-decision.md)):
  every one it assessed predicts *collision*, which the merge floor already determines
  by real rebase, and none detects design divergence, which is what this page is about.
- **Not a weakening of the floor.** Nothing here can let something merge that the floor
  would have stopped; the check runs strictly after it, and its only power is to withhold.
- **Not a judgement about whether a design is right.** `surface:` targets holds more
  precisely; it cannot tell a good contract change from a bad one. A branch a zone held
  has cleared the whole floor and is being shown to a person because the surface it
  changed is one this repo decided a person should look at. The reading is still the
  person's work — narrowing only buys back the attention to do it.
- **Not a scheduling change.** `touches` remains what it was: a hint the scheduler uses
  to avoid wasted rebase churn ([`../explanation/drivers-and-safety.md`](../explanation/drivers-and-safety.md)).
  A `serialize` zone changes nothing at all; a `review` zone changes only whether a
  green branch may merge unattended.
