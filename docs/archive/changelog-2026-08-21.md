# Archived — the hand-maintained `CHANGELOG.md`, as it stood on 2026-08-21

> **Status:** Archived · **Updated:** 2026-09-04 · **Owner:** chief
>
> **Replaced by:** `ROADMAP.md`'s completed-band table and the merged records in
> `tasks/chief/completed/*.json`, which `test/doc-sync.sh` gates. **Archived:**
> 2026-09-04 by tasklist `chief:901-docs-tell-the-truth`. Nothing here was deleted;
> the file's entire content is reproduced verbatim below.

Archived documents are not linked as current and are **exempt from the link gate as
citers** — `scripts/check-doc-links.mjs` skips `docs/archive/` because an archived
document's links described the tree *as it was*. Links *into* this file from a live
document are still checked.

## Why this was archived

`CHANGELOG.md` was created on 2026-08-20 by tasklist
`chief:107-list-and-ps-show-what-is-live`, which wrote three entries under a single
`## Unreleased` heading across three commits (`1b4dfb6`, `5a42754`, `205acaa`). It was
never written to again.

The measurement, taken on 2026-09-04 on this tree:

| | |
|---|---|
| Commits touching `CHANGELOG.md` since 2026-08-21 | **0** |
| Tasklists merged since then that wrote no entry | **15 of 15** |
| `VERSION` when it was last written | **0.8.82** |
| `VERSION` on 2026-09-04 | **0.9.22** |
| Gates that read it | **none** |

Fifteen tasklists merged (`108-concurrency-is-machine-wide` through
`900-dead-code-paydown`) and not one of them added a line. That is not neglect that a
reminder fixes — it is a second record of a fact this repo already keeps somewhere
gated. `ROADMAP.md` names **every** merged tasklist stem in `tasks/chief/completed/`,
and `test/doc-sync.sh` **fails CI** when it does not; that gate is exactly why the
roadmap stayed current over the same fifteen merges. Two records of one fact is the
same defect as two implementations of one behaviour, and the ungated copy is the one
that drifts.

The three entries themselves were never *wrong* — they were **mis-filed**. All three
behaviours shipped in **v0.8.82**, merged 2026-08-21 as `522ee4c`, and all three still
exist in `bin/chief` today (`chief list --all`, `chief list --plain`, `chief ps --all`).
They sat under `## Unreleased` for forty patch versions.

**What it would cost to bring it back.** A hand-maintained changelog is a legitimate
choice; it is not one that survives without a gate here. Reinstating it means a check
that fails a merge whose tasklist wrote no entry — the shape `test/doc-sync.sh` already
has for the roadmap. Without that, the next fifteen merges do what the last fifteen did.
Do it as a deliberate piece of work, not by re-adding the heading.

---

## The archived content, verbatim

```markdown
# Changelog

## Unreleased

- Changed `chief list` to show live and parked tasklists by default. Completed
  tasklists are summarized as an omitted count and can be restored with
  `chief list --all`.
- Formatted `chief list` as a state table with progress, category and operator-facing
  reasons; added `--plain` for stable tab-delimited script output.
- Added `chief ps --all` and `chief monitor --all` to show every non-done tasklist in
  the current repo, including scheduler-backed blocked and parked reasons.
```

## Where those three entries are recorded now

- `ROADMAP.md` — the completed band naming `107-list-and-ps-show-what-is-live`.
- `tasks/chief/completed/107-list-and-ps-show-what-is-live.json` — the merged record,
  with each story's acceptance criteria and the `mergedToMain` stamp.
- `README.md`'s command table — the surface a reader actually needs, gated by
  `test/doc-sync.sh` against `bin/chief`'s dispatch.
