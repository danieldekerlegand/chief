# `chief status` — what is left, and what can start now

> **Status:** Current · **Updated:** 2026-08-19 · **Owner:** chief

`chief list` prints one line per tasklist with a story count. It answers *how far along is
each one*. `chief status` answers the other question — **what is the state of the backlog**:
how much remains, how it splits into live and parked, how much of it could start right now,
and what is holding the rest.

```
chief status              this repo (or the one above cwd)
chief status --blocked    only what is waiting, naming the edge that holds it
chief status --all        every repo in the known-repos registry, regardless of cwd
```

It **always exits 0**. This reports state; it does not grade it.

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

## Environment

| Variable | Default | Effect |
|---|---|---|
| `CHIEF_STATUS_DEPTH` | `4` | how deep beneath the walk base a repo root may sit |
| `CHIEF_IGNORE` | `$CHIEF_PREFIX/ignore` | the ignore list described above |
| `CHIEF_REPOS` | `$CHIEF_PREFIX/repos` | the known-repos registry (`--all`'s scope) |
| `CHIEF_WORKTREE_ROOT` | `$CHIEF_PREFIX/worktrees` | the tree the worktree guard excludes |

## Related

- [Tasklist schema](tasklist-schema.md) — `dependsOn`, `parked`, `completed/` records
- [Cross-repo dependencies](cross-repo-dependencies.md) — the `<repo>:<stem>` edge status resolves
- [Drivers, scheduling, and the safety model](../explanation/drivers-and-safety.md) — the gate status reports on
