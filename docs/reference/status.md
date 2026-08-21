# `chief status` — what is left, and what can start now

> **Status:** Current · **Updated:** 2026-08-20 · **Owner:** chief

`chief list` prints a column-aligned table per live tasklist with its state, story progress,
category and any park/block reason, and summarizes completed tasklists. Use `chief list --all`
to include those completed records. Use `chief list --plain` for stable tab-delimited rows
when a script consumes the output. It answers *how far along is each one*. `chief status`
answers the other question — **what is the state of the backlog**:
how much remains, how it splits into live and parked, how much of it could start right now,
and what is holding the rest.

```
chief status                  this repo (or the one above cwd)
chief status --blocked        only what is waiting, naming the edge that holds it,
                              and ranking the merges that would release the most
chief status --all            every repo in the known-repos registry, regardless of cwd
chief status --json           the whole report as ONE JSON document on stdout
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
  gets no runnable/blocked verdict, because the scheduler never considers it. It may say
  **why** in `parkedReason`, and the parked total is broken down by it — see
  [Parks](#parks--why-the-work-is-held-on-the-same-terms).
- **Malformed input degrades, it never aborts.** An unparseable tasklist, a missing
  `dependsOn`, a dependency naming a repo that does not exist: each is counted, named in a
  `problems` section, and the rest of the report still renders.

## `--blocked` — from a number to a plan

"82 blocked" is a number. It tells an operator that something is wrong and nothing about
what to do, because the thing to do is a **merge**, and the report is keyed by the
tasklist that is waiting. So `--blocked` also aggregates the other way round — by the
**edge** — and ranks the edges by what merging each one would start:

```
  blocked  4 of 6 live
      11-a           needs 10-root — no merged record yet (…/completed/10-root.json)
      12-b           needs 10-root — no merged record yet (…/completed/10-root.json)
      13-c           needs 10-root — no merged record yet (…/completed/10-root.json)
      14-trap        needs 06-unstamped — PERMANENTLY BLOCKED: its record … has no "mergedToMain"

  release   — merge these first; each row is what merging it starts
      edge                         releases   cascade  holds  state
      10-root                             2         3      3  unmerged
      06-unstamped                        1         1      1  retired
      2 merge(s) would release 3 of the 4 blocked tasklist(s) the moment they land
```

Three columns, because they are three different numbers and conflating them overstates
every row:

| column | means |
|---|---|
| `holds` | how many blocked tasklists name this edge **at all**. The widest number, and on its own misleading: a tasklist with two unmet edges is not started by merging either one. |
| `releases` | how many become runnable **the moment this merges** — those for which it is the only unmet edge. The honest direct answer. |
| `cascade` | ...and how many in total if each tasklist so released is then worked and merged in its turn. The chain an operator is planning — stated separately because it assumes work that has not happened. |

The join key is the **record path** on both sides: the `completed/<stem>.json` a tasklist
would have once merged is exactly what its dependents' edges resolve to, so a chain that
crosses a repo boundary is followed like one inside a repo.

The table shows the top `CHIEF_STATUS_CASCADE_CAP` edges (default 25) and **says how many
it did not show** — the cascade closure is quadratic in the blocked set, and a truncated
table in a report about totals would otherwise read as the whole of it. `--json` carries
every edge, with `releases_with_cascade: null` on the ones past the cap.

## `--json` — the machine feed

`chief status --json` emits **one JSON document on stdout and nothing else**; every
human-facing note — the scope notes, the problems section, the `--enforce-order` verdict
— goes to **stderr**. That is the same stdout-is-data discipline `chief events` keeps, and
it means `chief status --json | jq …` needs no filter to strip a header first. The exit
status is unchanged: 0, unless `--enforce-order` was asked for and the project's own
ordering is violated.

It is the same scan rendered a second way. Nothing in the JSON path re-counts or
re-decides anything, so the two renders cannot disagree — `test/status-json.sh` asserts
the totals match field by field.

```jsonc
{
  "chief": "0.8.74",
  "report": "chief status",
  "scope":  { "mode": "walk|repo|registry", "description": "…as printed in the header",
              "base": "/abs/path", "depth": 4, "multi_repo": true, "repos": 16 },
  "totals": { "repos": 16, "remaining": 312, "live": 219, "parked": 93,
              "runnable": 137, "blocked": 82, "unreadable": 0, "completed": 703 },
  "repos":  [ { "label": "koine", "path": "/abs/path", "source": "walk|registry|both|cwd",
                "remaining": 12, "live": 9, "parked": 3,
                "runnable": 4, "blocked": 5, "completed": 41 } ],
  "runnable":   [ "koine/31-x" ],          // qualified with the repo label when multi-repo
  "parked":     [ "koine/44-y" ],
  "unreadable": [ "koine/17-broken" ],     // counted as remaining; no verdict is possible

  // one entry per blocked tasklist — the FIRST unmet edge, as the text render shows it
  "blocked": [ { "tasklist": "koine/13-c", "blocked_by": "10-root",
                 "class": "unmerged|retired|norepo", "detail": "…" } ],
  // ...and EVERY unmet edge, which is what the aggregation below is computed from
  "edges":   [ { "tasklist": "koine/13-c", "record": "/abs/…/completed/13-c.json",
                 "dep": "10-root", "dep_record": "/abs/…/completed/10-root.json",
                 "class": "unmerged", "detail": "…" } ],
  "blockers": [ { "dep": "10-root", "dep_record": "/abs/…/completed/10-root.json",
                  "class": "unmerged", "holds": 3, "releases": 2,
                  "releases_with_cascade": 3 } ],   // null past CHIEF_STATUS_CASCADE_CAP

  "categories": { "tasklists_with_category": 9,
                  "vocabulary": [ "fix", "unblock", "replace", "feature" ],
                  "vocabulary_source": ".chief/config (CHIEF_CATEGORIES)",  // null if none
                  "vocabulary_conflict": 0,   // >0 = that many different vocabularies in scope
                  "breakdown": [ { "category": "feature", "live": 3, "parked": 1 } ],
                  "ordering": { "declared": true, "last": "feature",
                                "live_preceding": 4, "live_in_last": 3 } },

  "parks": { "parked": 93, "with_reason": 71,
             "vocabulary": [ "owned-elsewhere", "awaiting-evidence" ],
             "vocabulary_source": ".chief/config (CHIEF_PARK_REASONS)",  // null if none
             "vocabulary_conflict": 0,   // >0 = that many different vocabularies in scope
             "breakdown": [ { "reason": "owned-elsewhere", "parked": 41 } ],
             "tasklists": [ { "tasklist": "koine/44-y", "reason": null } ] },  // null = no reason given

  "problems": [ { "tasklist": "koine/17-broken", "message": "…" } ],
  "excluded": [ "/abs/path" ], "stale": [ "/abs/path" ], "worktrees_skipped": [ "/abs/path" ],
  "order_check": { "enforced": false,
                   "result": "not-enforced|no-vocabulary|conflict|pass|fail" }
}
```

Stable points a consumer can rely on: every count is a number, never a string; every list
is present even when empty; `(uncategorized)` and `(unreadable)` are chief's labels for an
absent and an unparseable category and are the only category values chief itself produces.

`chief list` remains a different tool — per-tasklist story progress, not aggregate state —
and completed tasklists are opt-in with `--all`; `test/status-json.sh` pins the status JSON,
not this human listing.

## Cost, and why it is a fixed number of forks

A portfolio is ~1,000 records. `chief list` runs `jq` once per tasklist, which is fine for
one repo's listing and does not survive that scale; a report nobody runs casually is a
report nobody runs. So `chief status` reads each **directory** in one `jq` — the live
tasklists in one pass, and each `completed/` directory as a single merged-record index
behind `is_recorded_done` — and resolves edges without a subshell apiece.

Measured on this host, 1,040 records across 16 repos: **2,576 jq invocations and 23s**
before, **32 invocations and 2s** after. `test/status-perf.sh` guards it and asserts the
**fork count** as well as the clock, because the fork count is what regresses and it does
not depend on how loaded the machine is.

The one thing the index changes is who may cache: a one-shot reader may, and the
**scheduler may not**. A run asks "is this dep merged?" repeatedly over hours during which
records are appearing, so `engine/crossrepo.sh` keeps the index opt-in and `chief status`
is the only caller that turns it on. The driver's behaviour is byte-for-byte what it was.

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

## Parks — why the work is held, on the same terms

`"parked": true` tells the scheduler not to schedule a tasklist. It has never said
**why**, so the reason lived in prose nobody reads at the moment it matters. A tasklist
may now carry one in a field:

```jsonc
{ "parked": true, "parkedReason": "owned-elsewhere" }
```

`chief status` breaks the **parked total** down by it:

```
  park reasons    7    of 9 parked tasklist(s) say why; the value is theirs, and chief holds no vocabulary of its own
      reason                    parked
      owned-elsewhere                4
      awaiting-evidence              2
      awaiting-decision              0
      (no reason given)              2
      wedged                         1   *
      * outside the declared vocabulary — reported, never dropped
      declared  owned-elsewhere · awaiting-evidence · awaiting-decision   — in .chief/config (CHIEF_PARK_REASONS)
```

"93 parked" is a number. "41 waiting on another repo, 30 waiting on evidence, 22 waiting
on a decision" is three different conversations, and only the last two are the
operator's to have.

The field is **additive, never mandatory**:

- `"parked": true` alone keeps working exactly as it did, and reads as a park that does
  not say why. A repo that adopts nothing sees today's behaviour, unchanged.
- The flag is what the **scheduler** reads. A `parkedReason` with no `"parked": true` is
  a park that never happened: the tasklist is live and will be scheduled, and the report
  names it in `problems` rather than quietly treating it as parked.
- The value is an **opaque string**, on exactly the terms `category` is (above). Any set
  of values renders, an absent one reads as `(no reason given)`, and no chief source
  file names a park vocabulary — `test/park-reasons.sh` asserts the source discipline
  alongside the behaviour, and pins no vocabulary of its own.

### Declaring a park vocabulary

The same declaration, read by the same code path as `CHIEF_CATEGORIES`:

```sh
CHIEF_PARK_REASONS="owned-elsewhere awaiting-evidence awaiting-decision"
```

Then the rows render in that order — every declared reason shown, even at zero — and a
reason outside the vocabulary is marked `*` and kept. Without a declaration, rows are
ordered by count then name and no ordering is claimed. The same two details apply: it is
**read as a literal line, not sourced**, and across a portfolio one repo's declaration
is not the portfolio's (agreement wins; disagreement means none is in force and the
report says so). `CHIEF_PARK_REASONS` in the environment overrides every declaration.

One consequence of the shared reader: entries are whitespace- or comma-separated
**tokens**, so a multi-word reason can be *reported* but not *declared* — it renders
below the declared rows, marked `*`, and is counted like any other.

### Meeting a park in `chief run`

The most common way to meet a park is to try to run one, and that is where chief used to
say nothing:

```
$ chief run 44-encode-scenarios
Nothing was scheduled — 1 of the tasklist(s) you named is parked:
   ⏸ 44-encode-scenarios — parked: owned-elsewhere
   A park is a decision, not a failure. Drop "parked" in tasks/chief/<name>.json to work it for good,
   or run it once without unparking it:  chief run --parked 44-encode-scenarios
```

Naming a parked tasklist **prints its reason and schedules nothing**. `--parked` runs it
anyway — the capability that used to be the silent default, now explicit. A bare
`chief run` in a repo where everything is parked names the parks and their reasons
instead of reporting that everything is complete. Neither is a failure: both exit 0
interactively, and `no-work` (3) under `--headless`.

The **counterpart** case — a park that names work owned and built in another repo — is
`engine/counterpart.sh`'s, and is not reimplemented here. This reports the reason; the
merged-counterpart detection stays where it is, because a second implementation of a
marker link would drift, and drift in a marker is the failure that check exists to close.

## Environment

| Variable | Default | Effect |
|---|---|---|
| `CHIEF_STATUS_DEPTH` | `4` | how deep beneath the walk base a repo root may sit |
| `CHIEF_IGNORE` | `$CHIEF_PREFIX/ignore` | the ignore list described above |
| `CHIEF_REPOS` | `$CHIEF_PREFIX/repos` | the known-repos registry (`--all`'s scope) |
| `CHIEF_WORKTREE_ROOT` | `$CHIEF_PREFIX/worktrees` | the tree the worktree guard excludes |
| `CHIEF_CATEGORIES` | *(unset)* | the ordered category vocabulary for one report, overriding what the repos in scope declare |
| `CHIEF_PARK_REASONS` | *(unset)* | the same, for the park reasons broken down under `park reasons` |
| `CHIEF_RUN_PARKED` | *(unset)* | `1` = `chief run` schedules a parked tasklist you named instead of printing its reason and stopping (`chief run --parked`) |
| `CHIEF_STATUS_CASCADE_CAP` | `25` | how many blocked edges get the release cascade computed, and how many rows `--blocked` prints |

## Related

- [Tasklist schema](tasklist-schema.md) — `dependsOn`, `parked`, `parkedReason`, `completed/` records
- [Cross-repo dependencies](cross-repo-dependencies.md) — the `<repo>:<stem>` edge status resolves
- [Drivers, scheduling, and the safety model](../explanation/drivers-and-safety.md) — the gate status reports on
