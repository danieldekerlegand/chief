# Resolution deletions — the hold that stops a merge from erasing merged work

> **Status:** Current · **Updated:** 2026-09-12 · **Owner:** chief

When a branch's conflict resolution throws away lines that **already merged**, chief
holds the merge and names every line, the commit that added it, and the sibling
tasklist whose work it was. The hold is released by the same `chief approve` an
[overlap zone](overlap-zones.md) and an over-budget story use.

This is the merge policy layer's **third** rule, and the only one that is **always
armed**.

## The shape the merge floor cannot see

The floor — rebase onto the latest base, re-verify, merge `--no-ff` — catches exactly
two risks. **Textual interference** surfaces as a rebase conflict; **staleness**
surfaces as a red gate. It never compares what a rebase *removed* against what landed
on the base while the branch was in flight, so a resolution that throws the base side
away clears both.

Measured, in a downstream repository: a branch eight days stale conflicted at the
floor, and the agent resolving it kept the **branch's** copy of two whole files. That
erased what seven already-merged tasklists had put in them — a module declaration,
about two dozen command registrations, a validation check, a UI warning and several
tests. Registered commands went **68 → 44**. The agent then fixed what the compiler
flagged, the gate came back green, and chief merged.

Every layer was blind *by construction*: a deleted test cannot fail, an undeclared
module is not compiled so its errors vanish with it, and commands registered by string
name are checked by no compiler. **The gate was green because the evidence had been
deleted along with the work.**

Chief still never resolves a conflict itself. It hands resolution off — in
`integrate_base`'s conflict arm and in `conflict_report`'s runbook — and the branch
comes back *already rebased*, so the floor's own rebase takes the "strictly ahead of
`<base>` — rebase is a no-op" arm and never sees the conflict it exists to catch.

## What is compared

The branch's **intent** is its pre-rebase diff (`fork..preTip`). Its **result** is its
post-rebase diff (`newFork..tip`). A line is a resolution deletion when all four hold:

1. the post-rebase diff removes it,
2. the pre-rebase diff did **not** remove it,
3. it is present in the new base, and
4. it no longer appears in that file at the tip.

Clause 4 settles the *moved within the file* edge for free — a relocation is not a
loss. Removals are counted **net of re-adds**: a file whose last line lacked a trailing
newline has that line rewritten by any append, and counting the removal half alone
would flag it everywhere.

`(fork, preTip)` is not recoverable after the fact — the base sha at `worktree add` is
written nowhere, `.integrated-base` is a throttle key inside a worktree chief deletes
every run, the merge phase's `pre_mb` is read *after* the agent rebased, and reflogs
are not chief's to rely on. So the pair is **recorded at each handoff**, under the
driver's state directory (`<state>/parallel/<name>.resolution.json`), plus a pin ref
(`refs/chief/resolution/<name>`) — after the rebase those commits are unreachable, and
an unreachable object is gc's to take. The record is cleared when the tasklist merges.

**Commits made after the resolution are excluded precisely.** A rebase preserves author
date, author and subject, so a post-rebase commit is a *replay* when some pre-rebase
commit shares that key; the measured window ends at the newest replayed commit, and the
story the agent went on to implement in the same iteration is out of scope. A commit
interleaved *after* a replay stays inside the window and can only over-report — a
mistake in the permissive direction repeats the incident, a mistake in the strict
direction costs one `chief approve`.

**Binary and renamed paths are reported `UNCHECKED`, never silently skipped** — "I did
not check this" and "I checked this and it is clean" are different answers. An
`UNCHECKED` record alone does not hold a merge; it is printed in the worker log.

## What the resolver is told, before it resolves

A rule discovered only as a merge block is a rule nobody was told. Both places where
chief hands a conflict to someone else — `integrate_base`'s `INTEGRATE-BASE.md` note
and `conflict_report`'s runbook (`REBASE-CONFLICT` and `MERGE-CONFLICT`) — carry the
same three things, written by `resolution_keep_base_requirement` and
`resolution_base_side_diff` in `engine/resolution.sh`:

1. **What the base changed under each conflicted file**, as
   `git diff <fork>..<base> -- <file>`, one section per file. An over-limit diff is cut
   to its first `CHIEF_RESOLUTION_DIFF_LINES` (default 80) lines and followed by its
   real size and the exact command that shows the rest; over
   `CHIEF_RESOLUTION_DIFF_FILES` (default 12) files, the remainder is named with a
   count. A file the base never touched says so, because "there was nothing to keep"
   and "the conflict is inside this branch's own replay" are different answers.
2. **That those hunks are already-merged work and must still be present afterwards**,
   and that chief compares the result and holds the merge when they are not.
3. **The trap, by its mechanism.** Taking one side of a whole file — `git checkout
   --ours <file>`, `git checkout --theirs <file>`, or pasting one version over the
   other — discards *every* base-side change in that file, not only the conflicted
   hunks, and the changes that did not conflict are exactly the ones never on screen.
   That is the incident, in one sentence. The note also states that **in a rebase
   `--ours` is the base and `--theirs` is the commit being replayed**, the reverse of a
   merge, because a resolver reaching for the familiar meaning takes the wrong side of
   every file.

The diff is scoped to the *conflicted* paths and to `<fork>..<base>`, so it shows the
work at risk rather than the whole base history.

## What the hold looks like

The finding joins `zones_merge_gate` as zone-shaped hold lines, so it uses the
machinery that already exists: one request file, one checksum-bound verdict, one
`chief approve`. A branch that trips a declared zone, a size budget **and** this rule
is asked about once.

```
!! 84-thing: this branch's CONFLICT RESOLUTION would ERASE 3 line(s) of already-merged work —
   they are on main, this branch's own pre-rebase diff never removed them, and they are gone at its tip:
     src/commands.rs  a1b2c3d  (tasklist 77-register-commands)      register("audit.run", audit_run);
     ...
!! 84-thing HELD BY THE MERGE POLICY LAYER — it is rebased onto main and its verify came back GREEN;
   it is not merged because the merge policy layer matched what it changed:
     review  resolution:deleted  (matched: 3 line(s) of already-merged work would be erased)  — …(id 2412…-93)
```

The same lines appear in the approval request file, in the run summary's
awaiting-approval block, and in `chief approve --list`. A long list is **truncated with
a count**, never silently.

The tasklist ends `AWAITING-APPROVAL` with its branch kept, rebased and green. There is
no new park state and no new approval command. Both merge paths are covered — the
serialized floor and the opt-in [merge queue](../guides/monitoring.md) both call the
same gate; in the queue the comparison is made against the tip the member was *stacked
on*, so a member is never charged with what a peer earlier in the batch removed.

## The override

```
chief approve <name> -m "we deliberately dropped the old registry"
chief run <name>
```

The approval is bound by checksum to **exactly the flagged lines** — the hold's summary
line carries an id over the whole finding, so a re-resolution that erases something
different asks again, even if it erases the same number of lines in the same files.

`zones_clear_record` deletes the verdict file the moment the branch merges, so the file
alone is no record. The approval — who, when, the note, and the lines it covered — is
folded into `tasks/<project>/completed/<name>.json` as `.approval`, the same place a
[decision tasklist](decision-tasklists.md)'s verdict lands.

## Always armed

A `review` zone is opt-in (a repo declares it) and the [diff budget](diff-budget.md)'s
teeth are opt-in (`CHIEF_DIFF_BUDGET=block`). This rule is neither. It holds

- with no `.chief/zones.conf` at all,
- with every declared zone set to `serialize`,
- under `CHIEF_DIFF_BUDGET=warn` and `=off`.

It does not report a preference about where review is warranted; it reports that work
which already passed this repo's gates and merged would be **undone**. There is no repo
for which that is the default-acceptable outcome, and the incident it was built from
happened in a repo with no `zones.conf` at all.

## The cost, and why it runs on every merge

A branch that never had a conflict handed to it costs **one file-existence test** — no
git process at all (measured: ~0.8 ms, 0 git invocations). A branch that did costs one
comparison: on a 12-file, 683-line branch, **~1.0 s and 61 git invocations**, against a
merge phase that has just run the full verify gate. There is no conditional path,
because a conditional path is one more place the check can fail to run.

## The limit of the rule

**It sees deleted lines, not broken meaning.** A resolution that keeps every base line
and changes what they do is still the verify gate's business. Nothing here weakens the
floor: the question is asked strictly *after* the rebase and the green gate, and its
only power is to withhold.
