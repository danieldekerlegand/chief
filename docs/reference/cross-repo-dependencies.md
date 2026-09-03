# Cross-repo dependencies

> **Status:** Current · **Updated:** 2026-08-14 · **Owner:** chief

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

## Document claims — what a *document* asserts about another repo

`dependsOn` and `downstreamCounterpart` connect one **tasklist** to another. Neither
connects a **document** to the tree it makes a claim about, and that gap runs the
wrong way to close itself: the repo that changes has no reason to know that a
document somewhere else asserted something about its tree.

Measured: koine's `docs/reference/kcs-encoding-gate-verification.md` recorded that
three KCS pressure tests had no encoding. agora encoded all three **49 minutes
later**. koine did not learn for a week, its promotability ladder repeated the claim,
and two tasklists were authored from it before anybody read the tree.

So a repo declares its checkable claims in `.chief/claims.json`:

```json
{
  "claims": [
    {
      "document": "docs/reference/<the-doc-making-the-claim>.md",
      "claim":    "absent",
      "repo":     "agora",
      "path":     "console/src/kcs/scenarios/resume-checkpoint.ts"
    }
  ]
}
```

(`document` takes a real repo-relative path — koine's is
`docs/reference/kcs-encoding-gate-verification.md`; it is written as a placeholder
above only because a literal one would read as a dead link to chief's own doc-link
gate, which resolves `docs/…` against *this* repo.)

A bare top-level array works too. All four fields are required. `repo` is resolved by
the **same** lookup the table above describes — path, `~/…`, `../…`, or a registry
name — because a second resolver would drift from the first.

| Field | Meaning |
|---|---|
| `document` | path, relative to this repo's root, of the document making the claim |
| `claim` | `present` or `absent` — the whole vocabulary |
| `repo` | the other repo, in the `<repo>` notation above |
| `path` | path, relative to *that* repo's root, the claim is about |

**The vocabulary is deliberately small, and every member is a predicate over a path.**
`present` means that path exists in the other repo's tree; `absent` means it does not.
A claim that cannot be reduced to a predicate does not belong here — it stays prose,
and stays invisible, exactly as a counterpart named only in a `description` does.
Growing the vocabulary means adding a checkable predicate, never a checkable-*sounding*
one.

**Prose is not the mechanism.** A document that names a downstream fact only in its
text is invisible to this check, and is meant to be: the alternative is grepping
English for assertions. `chief lint` reports how many declarations it saw, so
"0 checked" reads as *nobody declared one*, never as *nothing is stale*.

**A repo with no `.chief/claims.json` pays one `[ -f ]`** — no jq, no scan, no output.

Chief reads no file across the boundary for this. It asks the filesystem whether a
path exists, and nothing else. `$CHIEF_CLAIMS_FILE` relocates the registry.
