# The verify hook (`.chief/verify.sh`)

> **Status:** Current · **Updated:** 2026-08-18 · **Owner:** chief

Chief calls this to decide whether a completed, rebased branch may merge. It's the
one place your project's real quality bar lives.

**Contract:**
- Runs with **cwd = repo root**, the finished branch **checked out**, after a rebase
  onto the base.
- `$CHIEF_BASE_BRANCH` is exported (the base branch name).
- **Exit 0 = allow the merge. Non-zero = block it** (the branch is left for review,
  marked `VERIFY-FAILED`).
- If `CHIEF_VERIFY` is unset/empty in `.chief/config`, verification is skipped.

**Keep it fast and focused** — gate only on what the branch changed:

```bash
#!/usr/bin/env bash
set -uo pipefail
changed="$(git diff --name-only "$CHIEF_BASE_BRANCH"...HEAD)"
[ -z "$changed" ] && exit 0

if echo "$changed" | grep -q '^web/';    then (cd web && npm test)         || exit 1; fi
if echo "$changed" | grep -q '^api/';    then (cd api && uv run pytest -q) || exit 1; fi
if echo "$changed" | grep -q '\.go$';    then go build ./... && go test ./... || exit 1; fi
exit 0
```

## Baselining against the base (optional but recommended)

If your repo has failures that pre-exist on the base (flaky tests, drifted
generated files), a strict pass/fail will wrongly block good branches. Baseline
instead: run the check on the branch; if it fails, run the *same* check on
`$CHIEF_BASE_BRANCH` and fail only on the **new** failures. Pattern:

```bash
new_failures() { comm -23 <(printf '%s\n' "$1"|sort -u) <(printf '%s\n' "$2"|sort -u); }
# branch_failures=... ; git stash; git checkout "$CHIEF_BASE_BRANCH"; base_failures=... ; git checkout -
# [ -z "$(new_failures "$branch_failures" "$base_failures")" ] || exit 1
```

(The extraction this tool came from ships a full baselined verify — copy that
approach if your suite is noisy.)

## Determinism: what the opt-in merge queue assumes of this hook

The serialized floor asks nothing of this hook beyond exit 0 / non-zero: it runs it
once per branch, on that branch's own tree, and a flaky answer costs one branch one
re-run. The **opt-in merge queue**
([drivers-and-safety](../explanation/drivers-and-safety.md#a-red-tip-bisect-confirm-then-blame))
asks for one more thing, and only while it is switched on: that this hook be a
**deterministic function of the tree** it is run against.

The reason is the bisect. A batch tip's red verdict is amortized across N branches, and
isolating which one is bad is a binary search over trees. A hook whose answer varies
run-to-run — a test with a real clock or a real network in it, a race, an
order-dependent suite — turns that search into a search over coin flips, and a coin
flip cannot be bisected. Chief will not pretend otherwise: every bisect verdict is put
to a **confirming run of the isolated branch alone**, and if the two observations
disagree the bisect is abandoned and the whole batch is re-run through the serialized
floor. That is a correct answer, not a cheaper one, so a flaky hook does not corrupt
anything — it just spends the batch's savings and then some.

If you know your gate is not deterministic, say so rather than paying for the search:
`CHIEF_MERGE_BATCH_BISECT=0` makes a red tip dissolve to the floor immediately, and
`CHIEF_MERGE_BATCH=1` (the default) opts out of batching altogether.

## Who checks what: chief, this hook, and you

**Chief's own comment says it plainly — `verify.sh` is the real merge bar, not the
`passes` flags.** That is a deliberate design choice and it holds: an agent that
genuinely finished should not be blocked by a stale flag, and the flags are a
self-report while this hook is a measurement. But it means a tasklist author has to
know which of their acceptance criteria anything will actually check. This is that
division.

| Layer | What it checks | What it can never check |
| --- | --- | --- |
| **Chief (the engine)** | That the branch produced real commits (`EMPTY-NO-WORK`); that a story chief passed on the agent's behalf says HOW in its `notes` (`UNVERIFIED`); that a story claiming a **measurable bar** records the value it observed (`UNVERIFIED`); that no criterion names a path outside the worktree (`UNSATISFIABLE`, before the first agent turn) | Whether the work is *correct*, or whether an observed value actually **meets** the bar. Chief cannot run your suite and does not know what GREEN means in your repo |
| **`.chief/verify.sh`** (this file) | Everything mechanical and repo-specific: build, tests, lint, the quality ratchet. **Exit 0 allows the merge; non-zero blocks it.** This is where a bar like "the suite is green" is genuinely *enforced* | Anything it was not written to run. A criterion about a subsystem the hook does not gate is unchecked, however well it is worded |
| **A human** | That the criterion was the right thing to ask for, that the recorded observation is honest and relevant, and every judgement no script can make ("reads clearly", "the seam is in the right place") | — |

### Writing criteria the engine can help with

- **State a bar and it gets held to one.** A criterion containing a checkable bar —
  `exit 0`, `green`, `0 failures`, `at least 3`, `95%`, `byte-identical`, a baseline
  with a number — makes the story owe an **observed value** in its `notes`. Without
  one the story is marked **`unverified`** rather than `passes`, and the branch stops
  instead of merging.
- **`unverified` is an honest third state, not a failure verdict.** It is the same
  rule the quality ratchet uses for a metric no analyzer could measure: it goes in
  `unmeasured[]` and is *skipped*, because an absent number must never be read as a
  good one. A story chief cannot check is recorded as unchecked.
- **The observation is not judged, only required.** Chief does not compare `25 failed`
  against `GREEN`; it requires that `25 failed` be written down where you can. The
  gate is lenient on purpose — any number or result word in the `notes` satisfies it —
  because a gate that failed honest work would be switched off, and a switched-off
  gate checks nothing.
- **If you want a bar *enforced*, put it in this hook.** A criterion is a claim; a
  line in `verify.sh` is a check. Anything you are unwilling to write as a check is,
  by construction, left to a human — which is fine, as long as the tasklist knows it.

### What the engine layer costs, and what it was proven against

These gates run on **every story of every tasklist**, so the cost is part of the
contract — a slow check gets switched off, and a switched-off gate checks nothing.

| | Cost | When |
| --- | --- | --- |
| Scope gate (`criteria_scope_report`) | ~31 ms per tasklist (one `jq` pass + one `ls`) | Once per run, **before** the first agent turn |
| Bar gate (`measure_gate`) | ~24 ms per tasklist (one `jq` report + one `jq` rewrite) | At every **iteration boundary** (never inside a turn), and again on every path to a merge |
| Evidence gate (`evidence_gate`) | one `jq` pass, same order | Once per run, only where an agent ran |

Measured over this repo's largest tasklist (12 KB, 4 stories, 13 criteria), 5 passes
each. **Nothing runs inside a turn** — the whole engine layer is ~55 ms per tasklist
per run, plus one bar-gate pass per iteration, against runs measured in minutes.

The bar gate runs twice over for a reason. At the **merge** it is the floor: it catches
everything, including a story the last turn marked — and it catches it at the one
moment nothing can be done about it, because the agent is gone. At the **iteration
boundary** it is the same predicate said early: the story is back at `passes:false`
before the next turn begins, while the agent still has the command output in its
context and can record the value in one edit. It only ever *demotes*, which is what
makes running it in both places safe.

`test/five-cases.sh` is the proving run. It replays, as fixtures, the recorded shape
of the five stories that reported green against criteria they had not met
(2026-08-16/17) and asserts each now fails — two of them before an agent turn is
spent — and, in the same run, replays three tasklists that were genuinely green and
asserts they still merge. One of the three is the honest cost: a tasklist whose
criteria say *"reports zero errors"* and whose filed record says nothing at all is
stopped, because from the record it is indistinguishable from the one that claimed
GREEN and delivered 25 failures. The remedy is one line of `notes`, and the fixture
proves it.

## The code-quality ratchet (`chief quality`)

Everything above is a **test oracle**: it answers *did the gates exit 0*. That is a
reward shape with a documented blind spot — tests come back in seconds, while the
maintainability damage (duplication, ballooning functions, deep nesting, "helper"
churn nobody reuses) shows up in weeks. `chief quality` is the **second, measured
axis**: it turns a file set into a metric record, compares two revisions of the same
repo, and blocks a merge that made the numbers worse **even with every test green**.

**It is deterministic and contains no model judgment.** Every number comes from awk
over text. No LLM, no network, no host-specific value, no timestamp — identical
inputs produce byte-identical JSON. A model scoring a model's work would reintroduce
exactly the blind spot this closes, so nothing in the gate consults one.

### What is measured

| Family | Metrics |
| --- | --- |
| size | `files` · `source_lines` · `added_lines` / `removed_lines` (diff mode) |
| complexity | `functions` · `function_length_mean` · `function_length_max` · `max_nesting_depth` |
| duplication | `duplicate_blocks` · `duplicate_line_pct` (N consecutive *normalized* source lines) |
| decomposition | `single_use_functions` — a function with exactly one call site |
| violations | `lint_violations` — only where a linter is actually installed |

**Language-aware, degrading honestly.** The core — source lines, duplication by
normalized-line hashing, nesting by a brace/indent heuristic — is language-agnostic
and always runs. Richer per-language analyzers (function extraction, lint) run only
where one exists *and* the toolchain is present. Everything else lands in the
record's `unmeasured[]` with a reason, and **the ratchet skips a metric listed
there** rather than reading its absence as "nothing got worse". A metric that
vanishes is worse than one that is openly absent.

All of it is heuristic by construction — text, not parse trees. That is deliberate:
a heuristic applied *identically to both sides* of a comparison still ranks them
correctly, and it costs no toolchain, no network, and no dependency beyond the `jq`
the engine already requires.

### Ratchet semantics: deltas, never absolute thresholds

`chief quality ratchet` evaluates two axes and blocks if either regresses:

- **Scope axis (always on).** The files this branch changed, measured on `HEAD` and
  again at `$CHIEF_BASE_BRANCH`, compared as **deltas**. A repo with pre-existing
  high complexity is never blocked for its history — only for what this branch adds.
  This mirrors the path-scoped, diff-driven design of `verify.sh` itself. Files the
  branch *created* have no base version, so they are excluded, counted, and
  announced in the gate's header; the baseline axis is what covers them.
- **Baseline axis (on once a baseline exists).** The whole tracked tree measured
  against a committed `.chief/quality-baseline.json`. Inactive until that file
  exists, so a fresh `chief init` is never blocked on day one.

A branch **allows** when every tracked metric holds or improves, and **blocks** when
one regresses past its tolerance. Blocking output names the metric, its base value,
its branch value, the tolerance, and the files that contributed most — an operator
can act on the message without rerunning anything:

```
quality: scope — the 3 changed source file(s), HEAD vs main
quality:   ok     duplicate_blocks              2 -> 2        (delta 0      tol 0)
quality:   BLOCK  max_nesting_depth      base 3 -> branch 7 (delta 4, tolerance 1)
quality:            top contributors by max_nesting_depth (base -> branch):
quality:              engine/driver.sh                     3 -> 7 (+4)
quality:   skip   single_use_functions   not measured — no function analyzer for this language
```

Records are also comparable only against like records: a baseline computed with a
different duplication window, or on a host where the linter was absent, is
**refused** rather than silently compared.

### The baseline file and re-baselining

```bash
chief quality ratchet --write-baseline     # writes .chief/quality-baseline.json
git add .chief/quality-baseline.json && git commit -m 'chore: quality baseline'
```

`--write-baseline` is the **explicit, reviewable escape hatch**. There is no
automatic re-baseline: the floor moves only when a human commits a new one, and that
move shows up in a diff. Adopt the baseline axis once your tree is in a shape you
would defend — a floor you cannot hold is worse than no floor.

### Per-repo configuration

`chief init` scaffolds `.chief/quality.conf` (a sourced bash file). Precedence:
**environment > `.chief/quality.conf` > `.chief/config` > built-in defaults.**

```bash
CHIEF_QUALITY_METRICS="duplicate_blocks duplicate_line_pct max_nesting_depth \
                       function_length_max function_length_mean single_use_functions lint_violations"
CHIEF_QUALITY_TOL_duplicate_blocks=0        # a copied block is never accidental
CHIEF_QUALITY_TOL_duplicate_line_pct=1      # percentage points
CHIEF_QUALITY_TOL_max_nesting_depth=1
CHIEF_QUALITY_TOL_function_length_max=15    # lines
CHIEF_QUALITY_TOL_function_length_mean=5
CHIEF_QUALITY_TOL_single_use_functions=2
CHIEF_QUALITY_TOL_lint_violations=0
CHIEF_QUALITY_DUP_WINDOW=6                  # normalized lines per duplicate block
CHIEF_QUALITY_BASELINE=.chief/quality-baseline.json
```

Tolerance is *how much worse the branch may be than the base*, in the metric's own
units — zero where any regression is a real defect, non-zero where honest new work
legitimately moves the number. A repo may drop a metric from
`CHIEF_QUALITY_METRICS` to stop gating on it, **but the disabling is visible in the
config diff**; there is deliberately no implicit, invisible way to switch one off.

### Skipping

- `CHIEF_VERIFY_QUALITY=0` skips just this gate — exactly like `CHIEF_VERIFY_TESTS=0`
  skips a behavioral suite. Iterating locally should not be punished.
- `NO_VERIFY=1` continues to bypass the whole hook, this gate included.

### Wiring it in

`templates/verify.sh` ships the gate **commented out**, with the bootstrap steps
inline — turning a gate on for a brownfield repo the moment `chief init` runs is how
a gate gets permanently disabled instead of adopted. One line enables it:

```bash
chief quality ratchet --base "$CHIEF_BASE_BRANCH" || exit 1
```

Chief's own `.chief/verify.sh` runs it as the first (cheapest) gate, on the delta
axis only. Chief deliberately ships **no** committed baseline: freezing this repo's
current `duplicate_blocks` as a zero-tolerance floor would make the next tasklist
that adds a `test/*.sh` unmergeable through no fault of its own. That is the tradeoff
the two axes exist to let each repo make for itself.
