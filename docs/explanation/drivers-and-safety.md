# Drivers, scheduling, and the safety model

> **Status:** Current · **Updated:** 2026-08-18 · **Owner:** chief

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
        scheduler stops co-scheduling them — docs/explanation/drivers-and-safety.md.
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

Four more guards back this up:

- **No-work guard (`EMPTY-NO-WORK`).** Pass-flags in JSON can lie: an agent might
  emit `<promise>COMPLETE</promise>` and mark every story `passes:true` while
  committing nothing (a stale/wrong tasklist misfire). Before merging, the driver
  checks the branch actually diverges from base (`git diff BASE...branch`). An empty
  branch is **never** merged (a `--no-ff` merge would otherwise forge an empty merge
  commit) or retired — it's marked `EMPTY-NO-WORK` and its dependents stay blocked.
- **Evidence gate (`UNVERIFIED`).** A `COMPLETE` from an agent that committed real
  work promotes the stories it left `passes:false` — verify, not the pass-flags, is
  the merge bar. That promotion is what lets a story report green against a
  criterion nothing ever read, so it is **conditional**: chief promotes a
  stale-false story only if it carries evidence in `notes`. One that says nothing
  about how it was done is left false and the branch is marked `UNVERIFIED` — not
  merged, not retired — with the story and the criteria it claimed quoted in the
  run log. Stories the agent marked passing **itself** are never subject to this:
  the gate stops silent promotion, it does not tax honest self-reporting.
- **Scope gate (`UNSATISFIABLE`).** A story runs in ONE worktree, so a criterion
  naming another repo — `argos:82`, `argos/tasks/…`, `../pinakes/…` — cannot be met
  from where the run executes, and the agent's only honest move is to report it
  undone. Chief reads the acceptance criteria BEFORE the first agent turn and stops
  the tasklist as `UNSATISFIABLE`, naming the story, quoting the criterion and the
  reference it found. No turns are spent, because no number of them would help. A
  tasklist that genuinely coordinates across repos says so — `"crossRepo": ["argos"]`
  names the repos its criteria may reference, and that declaration is a reviewable
  line in the record. The same rule warns at `chief gen` time and fails `chief lint`
  ([engine/criteria.sh](../../engine/criteria.sh)).
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
  `failure-recovery-runbook.md` §2.

- **Refusal is not conflict (`REBASE-REFUSED`).** A non-zero `git rebase` is only a
  *content* collision when git leaves **≥1 unmerged path** behind. Git also refuses
  outright — a work repo with uncommitted tracked changes (no longer reachable here:
  they are parked for the critical section, see below), a leftover
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

- **The operator's own checkout is not part of the floor.** The merge phase does its
  rebase → re-verify → `--no-ff` merge *in the work repo*, so it used to require that
  checkout to be clean — and one uncommitted line in a file no branch touched was
  enough to fail a tasklist that had finished every story. It no longer is: for the
  length of that critical section chief **parks** the work repo's uncommitted tracked
  changes in git's own stash and gives them back on the way out, so the gate measures
  the branch and nothing else. **Editing the repo while a run is in flight is safe for
  the merge.** The work is only ever in git's object store, it is applied back *by
  sha* (never `stash@{0}`, which an operator's own `git stash` would displace) and
  with `--index`, and there are three restore paths — the merge subshell's `EXIT`
  trap, teardown on a signal, and a sweep of stale `.critical` markers on the next
  run, for the SIGKILL where neither ran. A replay that cannot apply cleanly **drops
  nothing**: the entry stays and the run summary names the `git stash apply <sha>`
  that recovers it.

- **The startup gate protects the AGENT, not the merge.** `chief run` still refuses to
  start on a dirty tree, or off the base branch, and `FORCE=1` still skips that. What
  it buys is the *fork point*: every worktree is created from the base branch's tip,
  so anything uncommitted in the operator's checkout is invisible to every tasklist in
  the run — the agent plans and builds against a base its operator has already moved
  past, and can duplicate or contradict the change sitting in the editor. It never
  protected the merge (it is checked *once*, at launch, and nothing re-checks it — an
  operator who typed a line five minutes in walked straight past it), and since the
  parking above there is nothing left there to protect. So it stays a block on the
  narrower ground: a run forked from the wrong tree cannot be repaired afterwards.
  `FORCE=1` is the right call when the uncommitted work is somewhere no tasklist in
  the run will look.

Terminal per-tasklist statuses: `MERGED @<sha>`, `COMPLETE-UNMERGED`, `INCOMPLETE`,
`EMPTY-NO-WORK`, `UNVERIFIED`, `UNSATISFIABLE`, `WORKTREE-FAILED`, `CHECKOUT-FAILED`, `REBASE-CONFLICT`,
`REBASE-REFUSED`, `VERIFY-FAILED`, `MERGE-CONFLICT`.

## The policy layer above the floor (overlap zones · the diff-size budget)

Everything above this line is unchanged, and the sentences it is built on still
hold exactly as written: **the merge floor is the correctness guarantee**, and
**`touches` is a scheduling hint** — coarse, cheap, advisory, costing at worst a
wasted rebase. Nothing on this page can let something merge that the floor would
have stopped. Its only power is to *withhold*.

It exists because the floor is blind to one specific thing. Rebase catches textual
interference; verify catches staleness. Neither says anything about two parallel
branches whose code does not collide and whose **designs disagree** — one adds a
queue, the other a second queue for the same events; one widens a schema column,
the other adds a parallel table. Both rebase clean. Both verify green. The result
is still wrong, and it is wrong at the level of *intent*, which is where a person
has standing and a test does not. No automated gate chief could add detects it, so
chief does not pretend to: it asks a human, in the places a repo says to ask.

**Overlap zones.** A repo declares its high-impact domains in `.chief/zones.conf`
(scaffolded fully commented by `chief init`; full contract in
[`../reference/overlap-zones.md`](../reference/overlap-zones.md)):

```
review     path:src/schema/     the data model two agents must not diverge on
serialize  path:docs/           documented, scheduled apart, merged as usual
```

- `serialize` is **today's behaviour, unchanged** — the scheduler already refuses to
  co-run tasklists sharing a `touches` domain, and declaring the zone only records
  the domain in a reviewable file. The merge phase does not change.
- `review` means a green gate is *not sufficient authority* to merge. The branch is
  rebased and verified **first**, and only then held in `awaiting-approval` until
  `chief approve <name>` releases it — so a person is asked about a branch that has
  already cleared every automated bar, never instead of the bar.

Matching keys on the branch's **real changed files** (`git diff --name-only
<base>...HEAD`), not on `touches`, because `touches` entries are often conceptual
tags — a real tasklist declared `cuneiform-engine` and `render-goldens`, neither of
which is a path — so a registry keyed on tags alone would be invisible in exactly
the case it exists for. `touches:<domain>` is offered as a secondary matcher.

**The diff-size budget.** The same layer's second rule, from the same research: in
the AgenticFlict dataset larger diffs correlate with higher conflict probability, so
change size is the lever an orchestrator actually controls. Chief measures each
branch's diff against the base *decomposed by story* and reports it; the default
enforcement is `warn` (reported in the worker log, in `ps`/`monitor` and in the
story's permanent record, and merged anyway), because a hard block would stop
legitimate rename sweeps and codemods and a gate people switch off reports nothing.
`CHIEF_DIFF_BUDGET=block` turns it into the same hold a `review` zone uses. Details
and the vertical-slice guidance it is meant to encourage:
[`../reference/diff-budget.md`](../reference/diff-budget.md).

**One gate, one approval.** The two rules are asked as a single question at the end
of the merge phase — one request file, one checksum-bound verdict, one
`chief approve` — so a branch that trips a declared zone *and* an oversized story is
asked about once. The verdict is a file in the driver's state dir, bound by checksum
to the changed-file list plus the zones matched, so it survives process death and a
rebuilt worktree, is never re-asked, and never carries over to a later change.

`awaiting-approval` is **non-terminal and not a failure**: dependents stay `pending`
instead of cascading to `blocked`, siblings keep running, and the run summary reports
it apart from the failures. `chief ps` shows it as `zone-hold`.

**Which checkpoint asks when.** Chief's other human gate, the opt-in
[plan review](../plan-review.md) (`"review": "plan"`), is a different decision at a
different time: *before* any code exists it asks "is this the right plan?" and parks
in `awaiting-review`; this one asks, *after* the floor has run on a finished branch,
"does this green change agree with what else landed?" and parks in
`awaiting-approval`. With both enabled you are asked twice over a tasklist's
lifetime and never twice about the same thing.

The whole layer is pinned by [`test/overlap-zones.sh`](../../test/overlap-zones.sh):
a `serialize` zone merges exactly as before, a `review` zone and an over-budget story
each hold a rebased, verified-green branch, an approval survives a restart in a
separate process, and `warn` reports without blocking.

## The merge queue: batching verification (opt-in, off by default)

Everything above describes the **floor**: for N finished tasklists, chief pays the
verify gate N times — rebase, re-verify, `--no-ff`, one at a time. That is the
correctness guarantee and it does not change. At portfolio scale it is also the
dominant cost of the merge phase, and the merge queue
([`engine/mergequeue.sh`](../../engine/mergequeue.sh)) is the opt-in way to amortize
it, in the shape Bors and Gastown's "Refinery" have run for years: **stack** several
merge-ready branches (rebase each onto the running batch tip) and **verify that tip
once**.

It is off unless someone asks for it:

```
chief run -p 4 --merge-batch      # up to 4 branches per batch (bare flag = 4)
chief run -p 4 --merge-batch=6    # up to 6
chief run -p 4                    # the serialized floor — unchanged
```

Per repo, in `.chief/config`: `CHIEF_MERGE_BATCH=4` (default `1` = off) and
`CHIEF_MERGE_BATCH_WAIT=120` (seconds a batch leader waits for peers to finish before
it closes the batch; `0` batches only what has already arrived). With the option
absent the merge phase runs the same code it ran before this feature existed —
there is exactly one `if` in `driver.sh` guarding the fork, and it is closed.

What batching does **not** change:

- **Merges are still `--no-ff`, one commit per tasklist, still serialized against the
  base.** A batch is a verification-amortization device; it never makes concurrent
  writes to the integration branch.
- **A batch is only formed from branches that are already merge-ready under the rules
  above** — the agent loop reached COMPLETE, the no-work guard passed, and the branch
  rebases cleanly onto the tip. A branch that hits a rebase conflict is **ejected**
  with the same `REBASE-CONFLICT` label and the same forensics file it gets today, and
  the batch re-forms without it. One bad rebase never fails the whole batch.
- **Ordering is deterministic**, so a batch is reproducible: completion order (the
  order workers reached the merge phase), ties broken by tasklist name.
- **A batch of one is the serialized path.** There is no special case for it — one
  member means "rebase onto the base, verify that tree, merge `--no-ff`", which is
  the floor, reached through the same loop.

Two kinds of branch are **never** batch members, and take the floor instead:

- one carrying its own per-tasklist `"verify": [...]` array — that gate was written
  about *that* tree, and a tip shared with other branches is not it;
- one that changes a domain declared a `review` [overlap zone](#the-policy-layer-above-the-floor-overlap-zones--the-diff-size-budget).
  A batch-tip verify is not a human's yes, so such a branch is never smuggled into the
  base as a batch member — see [below](#overlap-zones-and-the-diff-budget-under-batching)
  for that rule and for how the diff-size budget stays per branch.

### A red tip: bisect, confirm, then blame

A red batch tip says *one of these N is bad* and names none of them. Discarding the
whole batch for that would be correct, and would also throw away the reason to batch,
so chief does what Bors and Gastown's Refinery do — it **bisects**.

The search space is already built. Member *k*'s branch was rebased onto member *k-1*,
so member *k*'s branch **is** the tip of the first *k* branches: probing a prefix costs
one checkout and one gate run, and nothing is re-stacked. Chief binary-searches for the
**smallest red prefix**; the branch at that boundary is the one whose arrival broke the
stack. Two facts bound the search and both are *observed*, never assumed — prefix *N*
is red (that is why we are here) and prefix `lo-1` is green (`lo` only advances past a
prefix a gate just passed). Prefix 0 is the base branch, taken as green because the
floor put it there green.

Then, before anything is labelled, the verdict is **confirmed**. The suspected branch
is restored to the sha its worker finished on, rebased onto the base *alone*, and
verified — exactly the position the serialized floor would have put it in.

- **Red again** → confirmed. The branch is left in the floor's own `VERIFY-FAILED`
  state, with the same status string, the same event and the same
  `snapshots/<name>.verify-failed.log` the floor persists, so it is eligible for the
  existing bounded re-arm on the next run with no new plumbing. Its predecessors —
  the prefix the search *proved* green — are merged on that observation. The
  survivors *after* it have never been verified without it, so they are **re-formed
  into a fresh batch** and go round again rather than being merged on the strength of
  a tip that contained the culprit.
- **Green** → the two observations disagree, and chief does not pick one. Either the
  gate is flaky, or the failure is **joint** (this branch is fine by itself and only
  breaks in combination with a peer it was stacked on). Neither licenses blaming it,
  so the bisect is **abandoned**: every branch is restored to the sha its worker
  finished on and the whole batch is re-run through the serialized floor. A joint
  failure then resolves itself correctly there — the first branch merges, the second
  meets it *on the base* and fails there, attributably.

**Multiple culprits terminate.** Each round either ends the batch or removes at least
one member, so the loop is finite on its own. `CHIEF_MERGE_BATCH_BISECT` (default `2`)
is the tighter bound: after that many isolations a still-red batch **dissolves to the
serialized floor** rather than bisecting again, because past a couple of bad members
the floor is simply cheaper. `0` disables bisect entirely — a red tip dissolves
immediately, which is what this feature did before bisect existed and is the honest
setting for a gate you know to be flaky.

**Determinism is the assumption, and the bisect is where it bites.** Amortizing a gate
across N branches is sound only when the gate is a deterministic function of the tree;
a flaky gate turns the tip's verdict into a coin flip about a *set* rather than a fact
about a *tree*, and a bisect over coin flips blames an innocent branch with total
confidence. Chief cannot make a gate deterministic — see
[the verify hook contract](../reference/verify-hook.md). What it can do is never blame
a branch on the strength of one observation, which is what the confirming run above is
for, and fall back to the floor the moment two observations disagree.

**What bisect costs.** `ceil(log2 N)` probes plus one confirming run, on top of the
tip. For N=8 that is 1+3+1 = 5 gate runs against the floor's 8, and the survivors'
batch makes it 6 — a win. For N=3 it is 5 against 3 — a loss. Bisect pays off as
batches grow, and it is not free.

**Whatever the path, the invariant holds:** nothing reaches `$CHIEF_BASE_BRANCH` that
has not had a green gate run on a tree containing it. A green tip merges its members;
a proven-green prefix merges on the probe that proved it; survivors are re-verified;
an abandoned bisect re-verifies everything one branch at a time.

The amortization is **counted, not claimed**. The run summary reports the ratio it
actually achieved, and — on its own line, only when it was spent — what the bisect
cost, so the search can never quietly absorb its own bill into the ratio:

```
   merge queue: 2 batch-tip verification(s) covering 5 branch(es) (max batch 4)
   merge queue: 3 extra verification(s) spent bisecting — 1 branch(es) isolated, 0 batch(es) dissolved to the serialized floor
```

### A quality-ratchet regression on a batch tip: attributed, never bisected

The merge gate has two axes and they fail in different **shapes**. The test axis is a
boolean function of the tree, and that is exactly what makes a bisect over stacked
prefixes sound. The [code-quality ratchet](../../engine/quality.sh) is not a boolean:
it is a **metric delta**, measured against the base over the changed-file scope, and
it is path-dependent in two ways a test suite is not.

- It is **cross-branch by construction.** Duplication and decomposition are relations
  *between* files. Two branches can each sit comfortably inside tolerance and still,
  together, put two copies of the same block in the tree. Neither one of them did it.
- **The scope moves with the prefix.** Probing "the first *k* branches" re-measures a
  different file set against the base, so the answers a binary search would compare
  are not answers to the same question. Bisecting them is not merely expensive — it
  is meaningless.

So a red tip carrying a ratchet block is **never bisected**. Chief attributes it
mechanically instead: every member is restored to the sha its worker finished on and
**re-measured alone** against the base over *its own* changed files — exactly what the
serialized floor would have measured for it — and a branch is blamed only when **its
individual delta exceeds the tolerance**. What is left over is not guessed at:

- **One or more members are out of tolerance on their own** → each is left in the
  floor's own `VERIFY-FAILED` state, with the ratchet's own output persisted to
  `snapshots/<name>.verify-failed.log` where the next run's re-engagement reads it.
  The survivors have never been verified without them, so they **re-form as a fresh
  batch** and go round again rather than merging on the strength of a tip that
  contained a blamed branch.
- **Nobody is out of tolerance on their own** → `RATCHET-NOT-ATTRIBUTABLE`, a
  first-class, named outcome. Every member is individually green and the *combination*
  is not, so no single branch can be blamed for it and **none is**. The batch is
  dissolved, its members are restored to their workers' shas and re-run through the
  serialized floor, each measured against a base that already contains the ones merged
  before it.

Whether the floor then catches the joint regression is the ratchet's business rather
than the queue's, and it is worth being exact about, because the two axes answer
differently:

- the **whole-tree baseline axis** does see it. Duplication between two branches' files
  is a whole-tree fact, so the first branch merges and the second — now measured
  against a tree containing the first — is blocked *there*, attributably. That is the
  outcome the fallback is built for, and it needs a committed
  `.chief/quality-baseline.json` (`chief quality ratchet --write-baseline`);
- the **changed-file scope axis** does not. It measures only what the branch itself
  changed, so a regression living in the *relation* between two branches' files is
  invisible to it and both branches merge.

A batch tip can therefore see a class of regression a per-branch gate cannot — the tip's
scope contains both branches' files. That is a reason to commit a baseline if you batch;
it is not a reason for the queue to invent a culprit. What the queue guarantees is
narrower, and it is the part that matters: **it never blames a branch it cannot see the
regression in, and it never merges anything the floor would have blocked.**

Both halves of that are the rule: **a metric delta is never guessed at, and a
regression is never allowed through because no single branch could be blamed.** The
outcome is reported on its own summary line, for the same reason the bisect's cost is:

```
   merge queue: 3 per-branch quality-ratchet re-measurement(s) — 1 branch(es) attributed, 0 batch(es) RATCHET-NOT-ATTRIBUTABLE (dissolved to the serialized floor)
```

`CHIEF_MERGE_BATCH_BISECT` bounds this the same way it bounds the bisect — it is the
number of *isolation rounds* one batch is worth, whichever mechanism spends them — so
`0` means a red tip of any shape dissolves straight to the floor.

### Overlap zones and the diff budget under batching

Batching must not weaken the [policy layer](#the-policy-layer-above-the-floor-overlap-zones--the-diff-size-budget),
and it is kept out of its way by two separate rules:

- **A branch that changed a `review` zone is excluded from batching entirely.** That
  is the choice, and it is the strict one: it is not "batched, then held" and not
  "batched once approved" — `mq_batchable` refuses it before a batch is ever formed,
  so it takes the floor and a human is asked about it exactly as today, on a branch
  rebased onto the base and verified by itself. A batch-tip verify is never a human's
  yes, and no `review`-zone branch is ever merged as a batch member on the strength of
  one. (`test/merge-batch.sh` PART C asserts it: the zoned branch is held
  `AWAITING-APPROVAL` and never appears in a batch, while its peers batch without it.)
- **The diff-size budget is evaluated per branch, not per batch tip.** A stacked
  member's `base...HEAD` is the *whole batch*, so the queue passes the tip the member
  was stacked on as the scope base instead. The budget then measures that branch's own
  stories — a batch can neither dilute an oversized diff into an aggregate that clears
  the budget, nor charge a member for a peer's diff or a peer's zone.

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
chief reap -n     # report what would be reaped: repo, tasklist, run id, pid, command
chief reap        # stop it: TERM, then KILL after --grace N seconds (default 5)
chief reap -s chief-2915283-      # only that repo's runs
```

**`chief reap` is HOST-WIDE unless you scope it.** It is not "reap this repo": process
discovery is `pgrep -u <you> -f -- --chief-run=`, every chief process *this user owns*
on the whole box, whichever repo you were standing in when you typed it. That is the
useful behaviour — an orphan in a repo you have not opened in a week is exactly the one
spending quota unwatched — but it is a surprising thing to discover by losing work in a
sibling repo. `--scope <repo>-<cksum>-` narrows it to one repo's runs; that is the form
the driver's own startup sweep uses. A host-wide sweep out of a `$CHIEF_RUNS` that is
not this host's own is refused outright (below).

**Both paths name every process before signalling it.** A silent `kill -9` sweep is
indistinguishable from a crash to whoever is watching, so each pid is printed with the
key that matched it, the run and repo it is attributed to, and the evidence that the
run is dead — and only then is it reaped:

```
chief reap: 2 orphaned process(es) — chief work with no live, registered run. About to reap each of these:
       keys: [cwd] cwd inside a chief worktree · [argv] --chief-run= marker · [env] inherited $CHIEF_RUN_ID · [tree] descendant of a match
       · pid 40987   [argv] chief engine process · run chief-2915283-1753996812-40321
         ↳ repo /Users/you/Development/chief · run chief-2915283-1753996812-40321
         ↳ ORPHAN — a run file in /Users/you/.chief/runs claims this run, and its driver (pid 40321) is gone
         bash /Users/you/.chief/src/engine/agent.sh --chief-run=chief-2915283-1753996812-40321
       · pid 41002   [tree] child of pid 40987
         ↳ repo /Users/you/Development/chief · run chief-2915283-1753996812-40321
         ↳ ORPHAN — a run file in /Users/you/.chief/runs claims this run, and its driver (pid 40321) is gone
         claude --dangerously-skip-permissions --print
```

A child is reported under its **parent's** run and repo, not as a bare "child of pid N":
it is being reaped for the parent's reasons, and a line nobody can place is a line
nobody can object to in time.

**"Left alone" is a separate block, and reading it matters.** A process wearing a
well-formed `--chief-run=` marker whose run *this install cannot account for* — no run
file in this `$CHIEF_RUNS`, no repo in this `$CHIEF_REPOS`, no worktree under this
prefix — is reported and **not** touched:

```
  ↷ left alone — chief processes whose run this install cannot resolve. …
       · pid 55110   unresolvable · LEFT ALONE · run vita-4471902-1755449051-55110
         ↳ no run file in /tmp/tmp.XYZ/runs, no repo in /tmp/tmp.XYZ/repos, no worktree under /tmp/tmp.XYZ/worktrees —
           this install cannot account for that run, which is not the same as it being dead
```

An empty orphan list means a clean host. A *populated* left-alone list means a **blind
sweep** — the registry being consulted is not the one those runs registered into, so
their absence from it says nothing at all (see below). Telling those two apart from the
output is the whole point of printing it.

### An unreadable registry is not evidence of orphanhood

The two halves of a sweep have different reach, and that asymmetry is a live hazard.
Discovery is host-wide by construction. The registry those processes are *judged*
against is whatever `$CHIEF_RUNS` the caller is pointed at. Point the second somewhere
private — a hermetic test's temp prefix, a container's, a second install's — and the
first still sees everything, so the sweep ends up ruling on runs its registry was never
going to know about. On 2026-08-17 that shape killed live runs in three sibling repos.

Two rules close it:

- **Absence is only evidence when you are looking in the right place.** A run-marked
  process may be reaped only when this install can *account for* the run its marker
  names — a run file in this `$CHIEF_RUNS` claims the id, **or** the id's cksum names a
  repo in this `$CHIEF_REPOS`, **or** it names a worktree dir under this prefix. None of
  the three: reported as `LEFT ALONE`, never signalled. Reaping is irreversible and
  leaving an orphan is not, so the asymmetry decides it — the next sweep, run from the
  right prefix, gets it. This applies to the argv key *and* the inherited-`$CHIEF_RUN_ID`
  key, which is what makes macOS and Linux agree: under SIP the environment key is inert,
  so argv is the fallback there, and a fallback must never be more aggressive than the
  primary it stands in for.
- **A host-wide sweep out of a foreign registry is refused before it scans anything.**
  An empty run-id prefix read against a `$CHIEF_RUNS` that is not this host's own exits
  non-zero with a diagnosis. Scope it (`--scope <repo>-<cksum>-`), or point `$CHIEF_RUNS`
  at the registry those runs actually wrote to. A *scoped* sweep is always allowed from
  any registry: `--chief-run=<repo>-<cksum>-` cannot match a run the caller did not mint,
  so the reach of the two halves agrees again.

`test/reapscope.sh` and `test/reapenv.sh` pin both rules; `test/bystander.sh` stands up a
run belonging to another install — its own driver argv, its own `$CHIEF_RUNS`, its own
worktree root — and runs the whole behavioural block over it, asserting after every test
that the bystander is still alive.

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
