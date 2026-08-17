# Roadmap input contract (`chief gen`)

> **Status:** Current · **Updated:** 2026-08-14 · **Owner:** chief

`chief gen <roadmap.json>` turns a **roadmap document** into one schema-valid tasklist
per roadmap item — `tasks/chief/NN-slug.json`, numbered in the next free band, with
`branchName`, `dependsOn` and `touches` already correct
([tasklist-schema.md](tasklist-schema.md)).

This is the operation an **embedding host** calls to author tasklists programmatically
instead of hand-writing JSON: Cuneiform's Chief-in-Riju operator loop, chief-cloud, a CI
job. **The input shape below is a published contract, not an internal detail** — it is
normative, and the generator rejects anything that does not match it (including fields it
does not recognise, so a mis-spelled key is never silently dropped).

```
  chief gen <roadmap.json> [--dry-run] [--force] [--allow-unknown]
                           [--out DIR] [--project NAME]
```

`-` reads the roadmap from stdin, so a host can pipe one straight out of its model.

## The document

The top level is a JSON **object** with exactly one field, `phases`: a non-empty array of
phase objects. A phase is `{"name": string, "items": [item, …]}`. Phases group items for
the human reading the roadmap; they do **not** affect numbering, ordering or dependencies
— items are numbered in document order across all phases.

```jsonc
{
  "phases": [
    { "name": "Phase name",                 // required, non-empty string
      "items": [                            // required array (a phase may be empty, but
        { "title":       "…",               //   the document must yield >= 1 item)
          "description": "…",
          "scope":       "…",
          "deps":        ["…"],
          "touches":     ["…"],
          "iters":       6,
          "crossRepo":   ["…"] }
      ] }
  ]
}
```

### Item fields

| Field | Required | Type | Maps to | Default when omitted |
|---|---|---|---|---|
| `title` | **yes** | non-empty string | the filename **slug** (`NN-<slug>.json`), `branchName`, and the seeded story's `title` | — |
| `description` | **yes** | non-empty string | tasklist `description`, plus the seeded story's `description` and first acceptance criterion | — |
| `scope` | no | string | appended to the tasklist `description` as `Scope: <scope>`, and added as a second acceptance criterion | nothing appended |
| `deps` | no | array of strings | `dependsOn` | `[]` (starts as soon as the scheduler reaches it) |
| `touches` | no | array of non-empty strings | `touches` | `[]` (no conflict domain — free to co-schedule with anything) |
| `iters` | no | positive integer | `iters` | `5` (the schema's default soft budget) |
| `crossRepo` | no | array of non-empty strings (repo names) | `crossRepo` | omitted — and then an acceptance criterion naming another repo (`argos:82`, `argos/tasks/…`) is **warned about** here and **fails the tasklist** at run time as `UNSATISFIABLE`, because a worktree cannot do work that lives elsewhere ([tasklist-schema.md](tasklist-schema.md)) |

`crossRepo` is emitted only when the item declares it — the hatch for criteria that name
another repo is meant to be a visible, deliberate line in the record, not a field every
tasklist carries empty.

Every other tasklist field is emitted with a fixed value: `parked: false`, `warmup: []`,
`project` (see `--project`), and `branchName`/`userStories` as described below.
`mergedToMain` is **never** emitted — an unmerged tasklist must not claim to be merged.
Fields the roadmap cannot set at all (`repo`, `baseBranch`, `verify`) are omitted, so the
tasklist inherits the project defaults; add them by hand afterwards if a tasklist needs
them.

### Slugs, numbering and `branchName`

- The **slug** is `title` lowercased, with every run of non-`[a-z0-9]` characters replaced
  by `-`, trimmed of leading/trailing `-`, and capped at 48 characters cut back to a word
  boundary. `"Widget read API"` → `widget-read-api`. A title with no letters or digits is
  an error (it would produce a nameless file and branch).
- The **number** is the next free band: the generator scans both `tasks/chief/*.json` and
  `tasks/chief/completed/*.json` and starts **above the maximum** already present, so a
  retired tasklist keeps its number and nothing ever collides. Items are then numbered
  consecutively in document order, zero-padded to two digits.
- `branchName` is always `chief/<NN-slug>` — the same stem as the filename. This is the
  invariant the tasklist gate checks, and the one hand-authoring gets wrong.

### `deps` → `dependsOn`

A dep is a **tasklist name — the filename minus `.json`** — never a branch name
(`chief/…` is rejected, with the correction in the error), and never a path. Qualify work
in another repo as `<repo>:<stem>`; the repo half may be a path
(`../pinakes:10-their-work`), the stem half may not. See
[cross-repo-dependencies.md](cross-repo-dependencies.md).

A host writing a roadmap cannot know which band its items will land in, so **a dep that
matches a sibling item's slug is rewritten to that sibling's generated stem**:
`"deps": ["widget-store-schema"]` becomes `"dependsOn": ["42-widget-store-schema"]`. If two
titles slug identically, the first item wins. A `<repo>:`-qualified dep is never
rewritten — it names work in another repo. A dep that matches no sibling is passed through
verbatim (that is how you point at an existing tasklist like `41-old-thing`).

### The seeded user story

Each generated tasklist carries **one** story, `US-1`, with `passes: false` and the item's
description (plus `Scope:` line, if any) as its acceptance criteria. That story is a
**starting point, not a plan**: acceptance criteria are the contract an agent implements
against, so review and split it before `chief run`. Everything else about the file is
already correct.

## Unknown fields are an error

An unrecognised field at the top level, on a phase, or on an item **fails the generation**
with the offending path and the allowed field list:

```
chief gen: the roadmap does not match the input contract (docs/reference/roadmap-input.md):
  - roadmap: unknown field "version" — the contract allows "phases"
  - phases[0].items[0]: unknown field "touched" — the contract allows "title", "description", "scope", "deps", "touches", "iters", "crossRepo"
  (pass --allow-unknown to ignore unknown fields instead of failing)
```

This keeps the contract honest as embedding hosts evolve — a host that writes `"touched"`
or `"dependsOn"` into an item is told, rather than watching the generator emit a tasklist
missing the very thing the roadmap asked for. `--allow-unknown` downgrades it to a warning
on stderr for a host that deliberately carries its own metadata alongside the contract
fields.

Every other contract violation is reported the same way — **all of them at once**, each
with its `phases[i].items[j]` address, so a host regenerating a roadmap gets one full list
instead of one error per round-trip.

## Output modes

| Mode | Behaviour |
|---|---|
| default | writes `tasks/chief/NN-slug.json` per item and prints each path |
| `--dry-run` / `-n` | writes **nothing**; emits one NDJSON line per item — `{"path":…,"name":…,"tasklist":{…}}` — for a host to review or post-process (`… \| jq .tasklist`) |
| `--force` / `-f` | overwrite existing files. Without it the generator refuses if **any** target exists and writes **none** of them — a partial batch never lands |
| `--out DIR` | write into `DIR` instead of the tasks dir (numbering still comes from the tasks dir, so a staged batch keeps its band) |
| `--project NAME` | the emitted `project` field; defaults to the repo directory name, resolved through the git common dir so a run inside a worktree still reports the repo |

Exit codes: `0` generated (or dry-run emitted), `2` the roadmap does not match the
contract (or the flags were wrong), `1` a refusal or failure (an existing file without
`--force`, a missing roadmap file, an unwritable output dir).

Before it writes anything, the generator **audits its own output** against the tasklist
gate — filename stem is `NN-slug`, `branchName == chief/<stem>`, no `mergedToMain`,
non-empty `project`/`description`/`userStories`, every story `passes:false` with non-empty
acceptance criteria — and re-checks each file on disk after writing. A failure there is a
bug in `chief gen`, not in your roadmap, and it says so.

## Worked example

`roadmap.json`, in a repo whose highest existing band is `41` (a retired
`tasks/chief/completed/41-old.json`):

```json
{
  "phases": [
    {
      "name": "Foundations",
      "items": [
        {
          "title": "Widget store schema",
          "description": "Create the widgets table and the migration that lands it.",
          "scope": "Schema + migration only; no HTTP surface."
        },
        {
          "title": "Widget read API",
          "description": "Serve GET /widgets and GET /widgets/:id from the new store.",
          "deps": ["widget-store-schema", "koine:12-widget-contract"],
          "touches": ["api", "db-schema"],
          "iters": 8
        }
      ]
    }
  ]
}
```

```console
$ chief gen roadmap.json --project acme
  gen  tasks/chief/42-widget-store-schema.json
  gen  tasks/chief/43-widget-read-api.json
✓ 2 tasklists generated, band 42..43. Review the seeded stories, then: chief run -n
```

`tasks/chief/42-widget-store-schema.json` — everything optional defaulted:

```json
{
  "project": "acme",
  "branchName": "chief/42-widget-store-schema",
  "description": "Create the widgets table and the migration that lands it. Scope: Schema + migration only; no HTTP surface.",
  "parked": false,
  "dependsOn": [],
  "touches": [],
  "iters": 5,
  "warmup": [],
  "userStories": [
    {
      "id": "US-1",
      "title": "Widget store schema",
      "description": "Create the widgets table and the migration that lands it.",
      "acceptanceCriteria": [
        "Create the widgets table and the migration that lands it.",
        "Scope: Schema + migration only; no HTTP surface."
      ],
      "passes": false,
      "notes": ""
    }
  ]
}
```

`tasks/chief/43-widget-read-api.json` — note the sibling dep resolved to `42-…` and the
cross-repo dep passed through untouched:

```json
{
  "project": "acme",
  "branchName": "chief/43-widget-read-api",
  "description": "Serve GET /widgets and GET /widgets/:id from the new store.",
  "parked": false,
  "dependsOn": [
    "42-widget-store-schema",
    "koine:12-widget-contract"
  ],
  "touches": [
    "api",
    "db-schema"
  ],
  "iters": 8,
  "warmup": [],
  "userStories": [
    {
      "id": "US-1",
      "title": "Widget read API",
      "description": "Serve GET /widgets and GET /widgets/:id from the new store.",
      "acceptanceCriteria": [
        "Serve GET /widgets and GET /widgets/:id from the new store."
      ],
      "passes": false,
      "notes": ""
    }
  ]
}
```

Then review the seeded stories, split them where a tasklist really carries several, and
run the schedule: `chief run -n`.

Pinned by `test/gen.sh`. Implementation: `engine/gen.sh`.
