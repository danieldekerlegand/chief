# Cross-repo dependencies

A tasklist can wait on work that lands in a **different repo** by qualifying the
dep as `<repo>:<tasklist>`:

```json
"dependsOn": ["local-tasklist", "pinakes:10-koine-align"]
```

A bare name is resolved against the current repo, as it always was. Only the
qualified form crosses a repo boundary.

## What chief does and does not do across the boundary

Chief reads **one file** in the other repo: the merged record
`<repo>/tasks/chief/completed/<tasklist>.json`. The dep is satisfied when that
file exists and carries a `mergedToMain` stamp — the same test used for local
deps.

Chief never schedules, branches, runs an agent, or merges in another repo. There
is no distributed scheduler and no cross-repo locking: the upstream work has to
be run there, by its own `chief run`. A qualified dep is a *barrier*, not a
trigger.

That also means the two runs are independent. If a `chief run` is active in the
upstream repo, the downstream one sees the record appear the moment that
tasklist merges — but only on its next scheduling pass, and it will not wait
around for it. An upstream tasklist that hasn't merged yet simply blocks the
downstream one for that run.

## How `<repo>` is resolved

In order:

| Form | Example | Resolves to |
|---|---|---|
| Absolute path | `/Users/me/dev/pinakes:work` | itself |
| Home-relative | `~/dev/pinakes:work` | `$HOME/dev/pinakes` |
| Relative path | `../pinakes:work` | relative to the **current repo root** |
| Plain name | `pinakes:work` | the uniquely-named repo in `$CHIEF_REPOS` |

A path form must contain a `/`; anything else is treated as a registry name.
Every candidate must contain a `.chief/` directory or it is rejected.

`$CHIEF_REPOS` (default `~/.chief/repos`) is the known-repos registry — one
absolute path per line, appended by `chief init` and `chief run`. So a repo
becomes referable by name after chief has been run in it once. If two registered
repos share a basename the name is **ambiguous and stays unresolved**; use a path
instead.

Prefer a plain name when both repos live under one working tree you control, and
a relative path when the pair is checked out together (it survives the registry
being rebuilt on a new machine).

## When a dep can't be satisfied

The run reports it up front, blocks the tasklist rather than leaving it at
`pending`, and exits non-zero if that means nothing ran at all:

```
  ⤬ down-work BLOCKED
       needs "pinakes:10-koine-align", which cannot complete in this run:
       not merged in /Users/me/dev/pinakes yet — …/completed/10-koine-align.json
       does not exist. Chief reads that record across repos but never runs
       another repo: complete it there ('cd /Users/me/dev/pinakes && chief run')
```

The distinct cases, each with its own message:

- **repo can't be resolved** — not a path, and no uniquely-named match in the
  registry. Run chief in that repo once, or qualify with a path.
- **no such tasklist there** — neither `tasks/chief/<name>.json` nor a completed
  record exists in the resolved repo. Usually a misspelling.
- **not merged yet** — the tasklist exists upstream but hasn't landed.
- **record has no `mergedToMain`** — the merge didn't finish.
- **bare name that lives elsewhere** — suggests the `<repo>:<name>` form.
- **parked / not selected this run** — for local deps.

**A blocked tasklist is not a bug.** If the ordering is real, the recurring block
is an accurate statement that the work cannot start yet. Don't delete a
`dependsOn` edge to clear the message.

## `dependsOn` takes tasklist names, not branch names

```json
"dependsOn": ["chief/some-tasklist"]     // WRONG — looks for completed/chief/some-tasklist.json
"dependsOn": ["some-tasklist"]           // right — the filename minus .json
```

When renaming a tasklist, remap every `dependsOn` that referenced the old
filename.

## The marker-record escape hatch

If the upstream work isn't a chief tasklist at all — a manual migration, a
release cut by hand — assert it in the dependent repo:

```json
// <dependent repo>/tasks/chief/completed/<name>.json
{ "mergedToMain": true }
```

That is exactly what the satisfaction test reads. Write it only when the
prerequisite genuinely holds, never to silence a block. Prefer a real
`<repo>:<tasklist>` dep whenever the upstream work *is* a chief tasklist — the
marker duplicates state that then has to be kept honest by hand.
