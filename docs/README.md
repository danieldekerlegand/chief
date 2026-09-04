# chief documentation

> **Status:** Current · **Updated:** 2026-09-04 · **Owner:** chief

**chief** is the autonomous tasklist runner every repo in this ecosystem is built with: you write `tasks/chief/*.json` and it drives an agent implement → verify → commit → merge, one story at a time, with worktree isolation.

The map. Structured per the ecosystem documentation standard —
`rosetta/docs/reference/documentation-standard.md`, cited by path because it lives in
a sibling repository and no relative link to it resolves from a chief worktree —
**a document not linked here does not exist**.

## Guides

*task-oriented — how to do one thing*

- [Running chief in a container / Riju workspace](guides/containers.md)
- [Embedding chief — headless / programmatic invocation](guides/headless-invocation.md)
- [The local-inference preset — cost avoidance as a supported mode](guides/local-inference-preset.md)
- [Monitoring active runs](guides/monitoring.md)
- [Providers — the onboarding recipe](guides/providers.md)

## Reference

*information-oriented — what it is*

- [Account credentials — running under a designated provider account](reference/account-credentials.md)
- [Host-wide concurrency](reference/concurrency.md)
- [Cross-repo dependencies](reference/cross-repo-dependencies.md)
- [Decision tasklists](reference/decision-tasklists.md)
- [The per-story diff-size budget](reference/diff-budget.md)
- [The event stream — chief's machine-readable status contract](reference/events.md)
- [Overlap zones — where a green gate is not enough authority to merge](reference/overlap-zones.md)
- [Provider unavailability — an iteration that never reached the model](reference/provider-unavailability.md)
- [Roadmap input contract (`chief gen`)](reference/roadmap-input.md)
- [`chief status` — what is left, and what can start now](reference/status.md)
- [Tasklist schema](reference/tasklist-schema.md)
- [The verify hook (`.chief/verify.sh`)](reference/verify-hook.md)
- [`chief usage` — cost and rate-limit reporting from the event logs](reference/usage.md)

## Explanation

*understanding-oriented — why it is this way*

- [Drivers, scheduling, and the safety model](explanation/drivers-and-safety.md)
- [Dead-code audit — the inventory, and the searches behind it](explanation/dead-code-audit.md)
- [The research phase — buying the map once](research-phase.md)
- [Plan review — the checkpoint between criteria and code](plan-review.md)

## Decisions

*immutable; superseded by a successor, never edited in place*

- [Decision: chief stays CLI-only — the desktop GUI is chief-cloud's](decisions/desktop-gui-decision.md)
- [Decision: chief builds the overlap-zone registry; it does not bind a conflict predictor](decisions/conflict-predictor-adoption-decision.md)

## Archive

*dated and superseded; kept for the reasoning, never linked as current*

- [The hand-maintained `CHANGELOG.md`, as it stood on 2026-08-21](archive/changelog-2026-08-21.md) — replaced by `ROADMAP.md`'s completed bands and `tasks/chief/completed/`, archived 2026-09-04

## Structure — what is here, and the one declared exception

`docs/` uses five of the standard's seven directories — `guides/`, `reference/`,
`explanation/`, `decisions/` and, since 2026-09-04, `archive/`. `tutorials/` and
`runbooks/` are absent because they are empty, not because they are disallowed; the
standard names the vocabulary, and an empty directory is not a document. There is no
directory here outside that vocabulary.

**The exception, declared:** `research-phase.md` and `plan-review.md` sit at the
`docs/` root rather than under `reference/`. They are cited by **bare path** from
roughly thirty places in `bin/chief`, `engine/*.sh`, `test/*.sh` and
`templates/agent-context.md`, and `scripts/check-doc-links.mjs` gates every one of
those citations — so relocating the two files is an edit to `bin/` and `engine/`,
which `test/version-bump.sh` then requires be paid for with an engine `VERSION`
bump. Bumping the engine version to move a doc puts a change in the version signal
that no consumer of the engine can act on. The two files are linked above and
banner-stamped like every other document; the deviation is their path, and it is
recorded here rather than left for a reader to find and wonder about. Anyone
retiring this exception should do it in the same commit as a real engine change.

## Corrections of record — 2026-09-04

Tasklist `901-docs-tell-the-truth` read this documentation set against the tree
rather than against itself. Each correction to a `docs/` file is also stated **in
the document it corrects**, under its banner, in the house `> **Corrected <date>**`
form — this list is the index, not a second home for the reasoning. The two root
files carry no banner, so their corrections are recorded only here.

| Document | What was wrong |
|---|---|
| [`reference/events.md`](reference/events.md) | The catalogue was **eight events behind the engine** (41 emitted, 33 documented) and claimed one log per run when two operator commands now write fixed logs of their own. This file calls itself the contract, so an omission here is a transition a conforming consumer may ignore. |
| [`reference/tasklist-schema.md`](reference/tasklist-schema.md) | `category` — carried by 46 of this repo's 47 tasklists (the exception predates the check), rendered by `chief list`, aggregated by `chief status`, and a **merge blocker** here via `scripts/check-tasklist-categories.mjs` — was named zero times. The DECISION/research note was also stated twice, in two wordings that had begun to disagree. |
| [`guides/providers.md`](guides/providers.md) | Counted **four** providers; `codex` was promoted 2026-08-19 and the roster table was updated then while the prose around it was not — the doc whose job is to stop roster drift had drifted against its own table. Its `README.md` link also pointed at this file rather than the repo README. |
| [`../README.md`](../README.md) · [`../CLAUDE.md`](../CLAUDE.md) | Both restated the verdict-cache key as **three** components; it has been four (`tree · base · hook · subs`) since the submodule component was added. `reference/verify-hook.md` is now cited as the single home for that table. `CLAUDE.md`'s layout map was also missing **13 of 33** `engine/` files and **7 of 23** `bin/chief` subcommands. |

**`Updated:` stamps.** Six banners named a date older than the last change to what
the document says, by up to three weeks — `explanation/drivers-and-safety.md`,
`guides/headless-invocation.md`, `reference/roadmap-input.md`,
`reference/status.md`, `reference/cross-repo-dependencies.md` and
`reference/verify-hook.md`. Restamped from git. The rule, stated so the next sweep
applies the same one: **`Updated:` is the last change to what the document *says*.**
A path-only link repair is not that, which is why `guides/containers.md`,
`guides/local-inference-preset.md`, `reference/account-credentials.md` and
`decisions/desktop-gui-decision.md` still read 2026-08-14 although git touched them
on 2026-08-15 — that commit only repointed relative links broken by the Diataxis
restructure.

**Known-wrong text this sweep did not touch, and why.** The three-component cache
key is also written into `engine/instructions.md` (injected into every agent
prompt), `bin/chief`'s `chief verify` hint, and `engine/lib.sh`'s two
`verify SKIPPED` lines. All four are correct about *behaviour* and understate the
*key*. They were left because `test/version-bump.sh` scopes on `engine/`, `bin/`,
`scripts/` and `install.sh` by path — so correcting a comment there obliges an
engine `VERSION` bump, which is the same argument this file already makes for the
declared exception above: a version signal no engine consumer can act on. Retire
this alongside a real engine change.

## Archived, not deleted — 2026-09-04

One document was superseded and one was archived; nothing was deleted.

**`CHANGELOG.md` → [`archive/changelog-2026-08-21.md`](archive/changelog-2026-08-21.md).**
It was created on 2026-08-20 by `chief:107-list-and-ps-show-what-is-live`, given three
entries under a single `## Unreleased` heading, and never written to again. Measured on
this tree: **0** commits have touched it since 2026-08-21 and **15 of 15** tasklists
merged in that span added no line, while `ROADMAP.md` — which `test/doc-sync.sh` fails
CI over — stayed correct across the same fifteen. That is the difference between a
gated record and an ungated copy of it, not a lapse a reminder fixes. The three entries
were never wrong, only mis-filed: all three shipped in **v0.8.82** (merge `522ee4c`,
2026-08-21) and all three flags still exist in `bin/chief`. The archived file carries
the content verbatim, the measurement, what replaced it, and what reinstating a
hand-maintained changelog would cost.

The root `CHANGELOG.md` still exists and is now a pointer. The standard names it a Tier
1 root file where a repo ships, and chief ships (`install.sh`, `chief update`); a
missing changelog reads as an oversight, while one that files shipped work under
`Unreleased` reads as current. It names where the record lives and links the archive.

## Left alone, and why

A document that looks stale and is actually history is not a finding. Recorded so the
next sweep does not re-open them:

| Left alone | Why |
|---|---|
| [`explanation/dead-code-audit.md`](explanation/dead-code-audit.md) | Its §§2–5 inventory was **acted on** by `900-dead-code-paydown`, so the candidate lists read as past tense — but the document is both the record of an approved measurement (§7 verification, §8 disposition) and *live* guidance: §3 Class B is "deliberately unexercised, do not remove", §5 is what the search proved absent "so the next sweep skips them", §§9–10 are what the method cannot decide. Rewriting the findings to today's tree would destroy the only reason to keep it. |
| [`decisions/`](decisions/desktop-gui-decision.md) (both ADRs) | Immutable by construction. The conflict-predictor ADR records a **decline "for now"**, which is exactly the reasoning the next proposal needs to read. Only the work-state **field label** was changed (`Status:` → `Phase:`), for the collision the standard names; both bodies are untouched, and each says so in place. |
| `tasks/chief/completed/*.json` | The work record. Its references were valid when it ran; `scripts/check-doc-links.mjs` skips it as a citer for that reason, and rewriting it would falsify history. |
| `ROADMAP.md` and the roadmap plans | Out of scope by this tasklist's brief — reconciled portfolio-wide on 2026-09-02/03 against their own evidence standard. Its one dead cross-repo reference (`../AGENTIC-ENGINEERING-ADVISORY.md`) was left for the same reason, and is invisible to the link gate anyway (paths normalizing outside the repo are skipped). |
| The four `engine/`/`bin/` copies of the three-component cache key | Recorded above: correct about behaviour, understating the key, and correcting a comment there obliges an engine `VERSION` bump no consumer can act on. |

## What this sweep did NOT verify

Stated because the alternative — silence — reads as a claim that the documentation is
now true, which is stronger than the method supports. What the method supports is:
**every claim in `docs/` that resolves to a symbol was resolved against the tree, and
the ones that failed are in the table above.** The rest was read, not proved.

- **No procedure in any document was executed.** `guides/containers.md`,
  `guides/local-inference-preset.md`, `guides/headless-invocation.md` and
  `guides/providers.md` are step sequences; none was run end to end. Their commands,
  flags and paths were checked to **exist**. A flag that exists is not a flag that
  behaves as the sentence around it says.
- **Prose with no symbol in it was checked only by reading.** ~6,900 lines under
  `docs/`. The mechanical passes cover paths, function names, `chief` subcommands,
  `CHIEF_*` identifiers, `event_emit` literals and counts. A claim like "the
  serialized merge floor is the correctness guarantee" resolves to nothing a script
  can query and was taken on a read of the code, not on a test.
- **Dated measurements were not re-measured.** Where a document reports a number
  observed on a date — the dead-code audit's inventory (2026-09-03, `VERSION`
  0.9.13), timing and threshold figures elsewhere — the number was left as the
  observation it is. Only the counts named in the corrections table above were
  re-run on this tree.
- **External links were not checked.** `docs/` carries nine URL occurrences, six
  distinct — four GitHub projects and two local inference endpoints. `scripts/check-doc-links.mjs` is
  local-only by design: a gate that fails for network reasons is a gate that gets
  switched off.
- **Prose outside `docs/` was not audited against the code**, and in this repo that
  is where much of the explanation lives: `engine/instructions.md`,
  `engine/plan-instructions.md`, `templates/agent-context.md`,
  `.chief/agent-context.md`, `examples/minimal/`, `.github/workflows/ci.yml`
  comments, and the long header comments in `bin/chief` and `engine/*.sh`. One known
  understatement there is recorded above; the rest was not read line by line.
  `CLAUDE.md` and `README.md` were corrected where the corrections table says and
  not otherwise.
- **Cross-repo claims were not checked**, because none are declared: this repo has no
  `.chief/claims.json`, so `engine/claims.sh` has nothing to resolve. Documents here
  that cite `rosetta/docs/reference/documentation-standard.md` do so as prose by
  path, which degrades honestly from a checkout that does not have it — but nothing
  gates that the sibling still says what this repo believes it says.
