# `chief status` — what is left, and what can start now

> **Status:** Current · **Updated:** 2026-08-19 · **Owner:** chief

`chief list` prints one line per tasklist with a story count. It answers *how far along is
each one*. `chief status` answers the other question — **what is the state of the backlog**:
how much remains, how it splits into live and parked, how much of it could start right now,
and what is holding the rest.

```
chief status                  this repo (or the one above cwd)
chief status --blocked        only what is waiting, naming the edge that holds it
chief status --all            every repo in the known-repos registry, regardless of cwd
chief status --enforce-order  exit non-zero if the project's OWN declared category
                              ordering is violated — for a CI job that asked for it
```

It **always exits 0** — unless `--enforce-order` was asked for and the project's own
declared ordering is violated. This reports state; it does not grade it.

## Runnable means what it means to the scheduler

A tasklist is **runnable** when every `dependsOn` edge resolves to a `completed/` record
carrying `mergedToMain` — including the cross-repo `<repo>:<stem>` form. That verdict is
not re-derived here. `engine/status.sh` sources `engine/deps.sh`, which is the same module
`engine/driver.sh` sources to decide what to **launch**, so the report cannot name work as
startable that a run would then refuse to start. `test/status-deps.sh` asserts the agreement
directly, against the driver's own dry-run schedule.

Three consequences worth knowing:

- **A dependency on a retired-but-unstamped record is a permanent stall.** A `completed/`
  record with no `mergedToMain` can never satisfy an edge, so `--blocked` calls it
  `PERMANENTLY BLOCKED` rather than letting it read as ordinary waiting.
- **Parked is a split, not a verdict.** A `"parked": true` tasklist counts as remaining and
  gets no runnable/blocked verdict, because the scheduler never considers it.
- **Malformed input degrades, it never aborts.** An unparseable tasklist, a missing
  `dependsOn`, a dependency naming a repo that does not exist: each is counted, named in a
  `problems` section, and the rest of the report still renders.

## Scope — and why the header always states it

A portfolio total is a number nobody can check by eye, so every render says what it covers.

| cwd | scope | header says |
|---|---|---|
| at or below a chief-initialized repo | that repo alone | `scope: this repo` |
| anywhere else | the tree **beneath** cwd, reconciled with the registry | `scope: the tree beneath <dir> (depth N), reconciled with the registry` |
| anywhere, with `--all` | every repo in the known-repos registry | `scope: the known-repos registry (<path>), regardless of cwd` |

In the two multi-repo scopes the output is a per-repo table — remaining, live, parked,
runnable, blocked, completed — followed by the portfolio totals it sums to, and a `source`
column saying how each repo entered scope:

| source | meaning |
|---|---|
| `walk` | found on disk beneath the base |
| `registry` | a known repo the walk did not reach (pruned, or deeper than the depth limit) |
| `both` | found both ways, and counted **once** |

### What the walk deliberately does not count

A repo is one whose **root** the walk finds. Everything below an already-matched root
belongs to that repo. Four rules keep the arithmetic honest, and each one **reports** what
it removed — a repo that silently vanishes from a total reads exactly like a repo with no
work in it:

- **Nesting.** A `tasks/chief` below a matched root is a fixture, an example or a vendored
  sample — `chief`'s own `examples/minimal/tasks/chief` is one — never a second backlog.
- **Worktrees.** A worktree is a full copy of a repo, `.chief/config` and all. They normally
  live outside the scanned tree, but relocating `CHIEF_WORKTREE_ROOT` beneath it would
  otherwise count every in-flight tasklist twice, so anything under that root is skipped and
  listed.
- **Identity.** The walk and the registry are reconciled by **resolved absolute path**
  (`cd -P`), so a symlink, a trailing slash or a `..` cannot mint a phantom second repo.
- **Noise.** Dot-directories, `node_modules`, `vendor`, `target`, `dist` and `build` are not
  descended into, and the walk is depth-limited.

A registry entry whose repo no longer exists on disk is reported as **stale**, never dropped.

### Excluding a subtree

Set an ignore list rather than editing the walk. Default location `$CHIEF_PREFIX/ignore`
(so `~/.chief/ignore` on a normal host); override with `CHIEF_IGNORE`.

```
# ~/.chief/ignore — one entry per line; # starts a comment
/Users/me/Development/AutomatedRetailAssociates
~/scratch
/Users/me/Development/*-archive
```

An entry excludes that path **and everything beneath it**. Absolute paths and `~/` paths are
recommended; a relative entry resolves against cwd. An entry containing `*`, `?` or `[` is
matched as a glob against the repo's absolute path. Excluded repos are reported in an
`excluded` section with the file that excluded them — never silently dropped.

## Categories — reported, never adopted

A tasklist may carry a `category`. `chief status` breaks its totals down by it, **live
and parked separately**:

```
  categories     9    tasklist(s) carry one; the value is theirs, and chief holds no vocabulary of its own
      category                   live  parked
      fix                           1       0
      unblock                       1       0
      replace                       2       0
      feature                       3       1
      chore                         1       0   *
      (uncategorized)               1       0   *
      * outside the declared vocabulary — reported, never dropped
      ordering  fix › unblock › replace › feature   — declared in .chief/config (CHIEF_CATEGORIES)
                4 live tasklist(s) precede "feature", the last category
                2 live tasklist(s) carry a category the ordering does not name — unranked, not dropped
```

**`category` is not chief's concept.** It is a convention of the repos a given host
builds, and chief holds no vocabulary of its own. The value is an **opaque string**:

- Any set of values renders. `banana`, `réview needed`, `P0` — chief neither validates
  a category nor knows what one means.
- A tasklist with no category is reported as `(uncategorized)`, which is a description,
  not an error. One chief cannot parse at all is `(unreadable)`; it is still counted.
- No chief source file names a category. `test/status-categories.sh` asserts both the
  behaviour (given the four words this host happens to use and no declared vocabulary,
  the rows come out in **count** order, not that one) and the source discipline.
- The live and parked columns **sum to** the live and parked totals of the report they
  break down. A category is never dropped, so the arithmetic always closes.
- The breakdown is over the **backlog**. `completed/` records are counted separately, as
  history, and are never pooled into it — the same active/completed split the totals
  above keep. History is deliberately exempt: backfilling a category onto work that has
  already merged buys nothing, and the ordering question is only ever asked about work
  that has not run yet. Measured on this host 2026-08-20 across 24 repos, 0 of 225
  active tasklists are uncategorized against 512 completed records that are — a report
  that pooled the two would show an uncategorized column larger than every real category
  combined and read like a broken tree.

### Declaring an ordering

A project that works its backlog in an order says so itself, in its own `.chief/config`:

```sh
CHIEF_CATEGORIES="fix unblock replace feature"   # earliest first
```

Then the rows render in that order — every declared category shown, even at zero — and
the report states **how much live work precedes the last category**: the project's
ordering rule, made visible. A category outside the vocabulary is marked `*` and kept.
Without a declaration, rows are ordered by count then name and **no ordering is
claimed**.

Two details worth knowing:

- The declaration is **read as a line, not sourced.** This command reports a portfolio
  of repos it discovered rather than chose, and sourcing each one's `.chief/config`
  would execute arbitrary shell from every repo on the host inside the reporting
  process. Only a **literal** value is honoured — no `$VAR`, no command substitution.
  Entries are separated by spaces or commas.
- Across a **portfolio**, one repo's declaration is not the portfolio's. If every
  declaring repo in scope agrees, that ordering is used; if they disagree, none is in
  force and the report says so rather than picking a winner. `CHIEF_CATEGORIES` in the
  **environment** overrides every repo's declaration for one report.

### `--enforce-order`, and why it is separate

`chief status` **always exits 0** over a category, whatever the backlog looks like. A
category is a statement *about* a tasklist, and the decision to run one out of order is
the operator's — chief reports it and stops there.

A CI job that wants the rule enforced opts in:

```sh
chief status --enforce-order    # exit 1 iff live work in the LAST declared category
                                # while live work in earlier categories remains
```

It enforces the **project's** declared ordering and nothing else. With no vocabulary in
scope — or with repos that declare conflicting ones — there is nothing to enforce: it
says so on stderr and exits 0. Uncategorized and out-of-vocabulary work is never a
violation, because chief has no opinion about where it belongs.

**Chief does not enforce a category, and nothing here implies it does.** `chief lint`
validates JSON, `branchName`, `mergedToMain` and the cross-repo criteria rule; it knows
nothing about `category` and never has. A repo whose uncategorized count is zero got
there by convention, or by its own vendored guard — not by a guarantee chief makes. Of
the 24 repos on this host, 16 vendor a `check-tasklist-categories.mjs` and the rest do
not, and `chief lint` calls both kinds clean. So an explanation of an uncategorized
column that appeals to lint would be citing a guarantee that does not exist; the honest
account of a zero is the convention, or the guard, that produced it.

**If you vendored a per-repo category guard** (a `check-tasklist-categories.mjs` or
similar), this is what replaces it and what does not. Chief computes the distribution
and the ordering statement for every repo, from one implementation. Chief does **not**
decide which vocabulary is right, does not fail a build on its own, and does not rank
a category it was not given an ordering for. A repo consolidating onto this keeps its
vocabulary — in `.chief/config`, where it is now declared once and read by the report —
and keeps its build failure, as `chief status --enforce-order` in the same CI step.

## Environment

| Variable | Default | Effect |
|---|---|---|
| `CHIEF_STATUS_DEPTH` | `4` | how deep beneath the walk base a repo root may sit |
| `CHIEF_IGNORE` | `$CHIEF_PREFIX/ignore` | the ignore list described above |
| `CHIEF_REPOS` | `$CHIEF_PREFIX/repos` | the known-repos registry (`--all`'s scope) |
| `CHIEF_WORKTREE_ROOT` | `$CHIEF_PREFIX/worktrees` | the tree the worktree guard excludes |
| `CHIEF_CATEGORIES` | *(unset)* | the ordered category vocabulary for one report, overriding what the repos in scope declare |

## Related

- [Tasklist schema](tasklist-schema.md) — `dependsOn`, `parked`, `completed/` records
- [Cross-repo dependencies](cross-repo-dependencies.md) — the `<repo>:<stem>` edge status resolves
- [Drivers, scheduling, and the safety model](../explanation/drivers-and-safety.md) — the gate status reports on
