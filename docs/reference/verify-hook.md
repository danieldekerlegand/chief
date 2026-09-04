# The verify hook (`.chief/verify.sh`)

> **Status:** Current · **Updated:** 2026-09-04 · **Owner:** chief

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

## Running this gate yourself: `chief verify`

Chief runs this hook **twice** on the way to a merge: once at the end of the agent
turn that reports the tasklist complete, and once more in the merge phase after the
rebase. Both of those reads are served from a **verdict cache** keyed on
`tree · base · hook · subs` (the four inputs the gate reads — see
[what a verdict is keyed on](#what-a-verdict-is-keyed-on)), so when nothing moved
between them the gate is paid once and the second read is a skip:

```
>> verify SKIPPED: tree 52e9018… (GREEN verdict from …/verify-cache/…; same base and verify hook)
```

An agent that runs the gate **itself** inside its turn — `./.chief/verify.sh`,
`npm test`, `cargo test --workspace` — is issuing a plain shell command chief never
sees, so it writes no verdict and buys nothing. That is not hypothetical: measured on
2026-09-02, one tasklist paid a ~20-minute workspace suite inside the turn and another
~21 minutes at the agent boundary, for one merge, over a tree neither run had moved.

`chief verify` is the version that counts:

```bash
chief verify              # run the hook, record the verdict
chief verify --no-record  # run the hook, write nothing
```

It runs the same hook the same way (same cwd, same `CHIEF_BASE_BRANCH` /
`STRICT_VERIFY` / `NO_VERIFY` environment, a tasklist's own `"verify"` array
honoured), exits with the hook's own status, and then records that status where the
agent boundary and the merge phase will find it. Inside an agent turn it needs no
arguments — the driver has already exported the worktree, the run's state directory,
the tasklist and the work base, and those are preferred over `.chief/config`.

**It records only for HEAD's tree.** The cache key is the *committed* tree while the
hook tests the *working* one, so recording while those differ would let chief skip the
merge gate for a tree nothing ever checked — the one failure mode of this mechanism
that could merge a red tree. A dirty tree (tracked or untracked) is therefore checked
and reported but **never** recorded, and neither is a run that HEAD moved under:

```
chief verify: the working tree is not HEAD's — this verdict will NOT be recorded.
              COMMIT first and re-run `chief verify`, or the gate is paid again at merge.
```

So the order in an agent turn is **commit, then `chief verify`**, and `--amend` if it
comes back red. Refusing to record is never refusing to check: the hook still runs and
the exit status is still yours.

`chief verify` deliberately never *reads* the cache. Every component of the key is a
*committed* input, so it says nothing about uncommitted work, and the one caller whose
working tree is expected to be moving
is this one — answering "green" about an edit made since the record would be worse than
running the suite again.

Cheap, scoped checks — a typecheck, one test file, a linter over the two files you
touched — need none of this. This is for the full gate.

### What a verdict is keyed on

A record is one sentence: *this hook, run over this tree, on this base, with these
submodules checked out, exited N*. Every part of that sentence is in the key, and
nothing that is not in the key may be allowed to change a gate's answer.

| Component | Taken as | Why it is in the key |
| --- | --- | --- |
| **tree** | `git rev-parse HEAD^{tree}` | The gate tests source, so a different tree is a different question. It is the *committed* tree — which is why a dirty working tree is checked but never recorded (above): the one failure mode of this mechanism that could merge a red tree is a verdict recorded for a tree nothing ever ran. |
| **base** | `git rev-parse <base branch>` | A path-scoped hook decides *what to run* from `git diff <base>`, and every verdict chief acts on is a statement about a branch **against that base**. A base that moved under an unchanged tree is a different computation, and the merge it is about is a different merge. |
| **hook** | `git hash-object` of the hook file | The gate **is** the question. Identity by content and not by path, because a hook is edited — one more test, one stricter flag — far more often than it is replaced, and every verdict taken under the old one says nothing about the new one. |
| **subs** | `cksum` of `git submodule status --recursive`, or `nosub` where there are none | The input **chief itself moves** between the two reads. A project worktree never initializes its submodules, so the agent boundary runs the hook against an *empty* submodule directory while the merge phase runs `submodules_sync` first and runs the same hook over the same tree against a synced one: same tree sha, different filesystem, different answer. The general rule this component exists to state — **anything chief mutates between a record and its reuse belongs in the key**, and a tree sha is not a proxy for the filesystem the hook actually tests. |

Records live under the run's state directory, one per key, a red one beside an `.out`
holding the tail of the gate's own report:

```
<state>/verify-cache/<hash of repo root>/<tree>.<base>.<hook>.<subs>
<state>/verify-cache/<hash of repo root>/<tree>.<base>.<hook>.<subs>.out
```

The 32 most recent are kept; a record and its report are pruned together.

**A record is reused whatever its status.** Identical tree, base, hook and submodule
checkout is the same computation, so a **red** verdict short-circuits to the recorded
failure — with the retained report replayed, so the agent is told *which* test failed
and not merely that it may not finish — exactly as a green one short-circuits to
success. Nothing about the key becomes false when the answer is a failure; and if the
agent changes something in response, the key moves and the gate runs. The measurement
that settled this: `cuneiform:388` ran six hours and merged nothing, its log holding
**five full ~11.6-minute gate runs and six identical failures over a byte-identical
tree** — four of the five re-deriving a verdict already on disk
(`test/verify-cache.sh` PART G drives that shape and asserts the cost).

### Forcing a re-run: `CHIEF_VERIFY_CACHE=0`

Reusing a verdict of **any** status, as above, rests on the hook being a
deterministic function of the four inputs the key names — for an unmoved tree, base,
hook and submodule checkout a second run is not a second sample, it is the same
computation:

```
>> verify SKIPPED: tree 52e9018… (RED verdict, exit 1, from …/verify-cache/…; same base
   and verify hook) — the gate was NOT re-run; its recorded output follows
```

That is what stops an agent who cannot fix a gate paying the whole gate again every
iteration to be told the same thing. If your hook is **not** deterministic — a real
clock, a real network, a race, an order-dependent suite — chief cannot tell from the
outside; both runs are just a status. So you say so:

```bash
CHIEF_VERIFY_CACHE=0 chief run        # every lookup declines: the gate runs
CHIEF_VERIFY_CACHE=0 chief run 120-…  # …and its fresh verdict REPLACES the record
```

It reads like the engine's other opt-outs (`CHIEF_VERIFY_TESTS=0`, `CHIEF_SWEEP=0`,
`CHIEF_MERGE_BATCH_BISECT=0`), it is inherited by the agent boundary and the merge
phase alike so one variable clears both reads of a run, and the forced run says so
rather than looking like an ordinary miss:

```
>> verify cache DISABLED (CHIEF_VERIFY_CACHE=0): a matching verdict exists (…) and is
   being IGNORED — the gate runs, and its result replaces that record
```

Overwriting matters as much as bypassing: a hatch that only skipped the lookup would
leave the disbelieved verdict on disk for the next un-hatched run to serve. There is
no cache to disable in `chief verify` — it never reads one — so that command remains
the way to re-earn a single verdict without changing how a whole run behaves.

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

## A gate that did not run is not a gate that passed

The hook above draws a line locally that is easy to state and easy to lose: a check
that was **skipped** is not a check that **passed**. `CHIEF_VERIFY_TESTS=0` says so
out loud, and `scripts/check-engine-pin.sh` fails loudly rather than skip quietly.
This section is that same line, pointed outward at the gate a repository *declares*
but may not be running.

### The three states, and the two non-findings

Chief names a gate's state in exactly one vocabulary, wherever it reports one
(`engine/cigate.sh`, and `chief cigate` on top of it):

| State | Means |
|---|---|
| **RAN AND PASSED** | it executed, and it was green |
| **RAN AND FAILED** | it executed, and it went red |
| **DID NOT RUN** | no run recorded · a run that completed without executing a single step · a green run that never covered the commit in question · a workflow no event chief produces could start |
| `UNKNOWN` | it could not be **measured**. Not a pass, ever. |
| `NO GATE DECLARED` | the repo declares no CI. A legitimate state, and not a finding. |

`UNKNOWN` is the load-bearing one. An absent `gh`, no network, no remote, an API
that refuses — every one of those ends as `UNKNOWN` and is *printed* as unknown.
Rounding an unmeasured gate up to green is the exact mistake this whole surface
exists to end, so chief does not do it even when it would be convenient.

`DID NOT RUN` and `NO GATE DECLARED` are deliberately different findings. A repo
that never claimed to have CI is not failing at anything; a repo that declares a
workflow which has never executed is.

### Why this hid for so long: Actions is free for public repos and billed for private ones

Measured across this portfolio on 2026-08-25:

```
praxis      PUBLIC    success  2026-08-15
pinakes     PUBLIC    success  2026-08-25
talos       PRIVATE   failure  2026-08-24
cuneiform   PRIVATE   failure  2026-08-25
vita        PRIVATE   failure  2026-08-25
```

All three private failures were byte-identical, and none was a code problem:

> The job was not started because recent account payments have failed or your
> spending limit needs to be increased.

GitHub Actions minutes are **free for public repositories and billed for private
ones**. One account-level billing block therefore killed CI on *every* private repo
at once — while the public ones kept running, kept going green, and kept the whole
setup looking normal. That asymmetry is why nobody noticed: the surface that would
have raised the alarm was the surface that still worked.

Before reading a `DID NOT RUN` finding as a code problem, **check billing.**

### The second, independent version: the trigger mismatch

`vita`'s workflow declared `on: [pull_request, workflow_dispatch]`. Chief merges a
finished branch into the base **locally** and pushes the base branch — it never
opens a pull request, and nobody clicks *Run workflow* on its behalf. So no event
chief generates could ever have started that workflow. Its CI had not run once in
the repository's history, and tasklist `72` was unparked and merged as
`auto-verified` on the premise that it had.

Nothing about the file looks wrong, and no amount of asking GitHub finds it: *"no
runs"* is what a dead gate and a brand-new gate both look like, and only the trigger
says which. Chief therefore reads the `on:` mapping **textually and offline** — no
YAML dependency, no network call — and reports the mismatch in the operator's terms:
*what the workflow waits for*, and *what chief actually does*. A passing run does
**not** clear it: a green run on a `pull_request`-only workflow means someone opened
a pull request by hand, and chief's merge was still ungated.

If a workflow is genuinely meant to be a merge gate under chief, it needs a `push`
trigger that accepts the base branch.

### Reading a merge record afterwards

A completed record carrying `mergedToMain` is evidence of a **merge**, not of a
**check**. Since chief records gates, `finalize_merged` stamps each record with what
it knew at the time:

```json
"gates": {
  "local": { "state": "dead",
             "detail": "no verify hook is configured and this tasklist declares no \"verify\" commands — NOTHING checked this merge" },
  "ci":    [ { "workflow": "ci", "state": "dead",
               "detail": "trigger mismatch: it waits for someone opening a pull request …" } ]
}
```

The states are the tokens behind the table above, so one vocabulary renders old and
new records alike. The local half is the `amphora` check — three tasklists there
merged against a `.chief/verify.sh` that ran one unrelated check and then `exit 0`,
which is green for the same reason an empty test suite is green. No hook, no
per-tasklist `verify` commands, or `NO_VERIFY=1` are all recorded as **DID NOT RUN**,
not as a pass.

The CI half is the **offline trigger check only**. Nothing on the merge path may
make a network call or fail because a third-party service is down, so whether a run
then happened is written down as `UNKNOWN` — `chief cigate` is the command that asks
GitHub, and it is deliberately not on this path.

`chief cigate --records [paths…]` reads it all back, per repo:

```
⚑ 72-windows-linux-bundles [ci.yml] — DID NOT RUN: trigger mismatch: it waits for
  someone opening a pull request … (reconstructed from the file at 1d0e72a)
33 merged tasklist(s) in vita: 27 gate(s) DID NOT RUN across 27 of them · 0 UNKNOWN
```

Records written **before** the field existed are not lost: the trigger half is a
pure function of the workflow files, so it is reconstructed from them *as they stood
at the merge commit* (`git show <mergedToMain>:.github/workflows/…`) — offline, and
historically accurate. That is how the four merges this surface exists because of
became readable off the record instead of findable only by hand.

Like everything else here, it **reports**. It exits 0 on a finding, it is never on
the merge path, and it blocks nothing.
