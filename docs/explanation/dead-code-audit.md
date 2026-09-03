# Dead-code audit — the inventory, and the searches behind it

> **Status:** Current · **Audited:** 2026-09-03 against `VERSION` 0.9.13 ·
> **Disposition:** §8, 2026-09-03 against `VERSION` 0.9.14 ·
> **Undecidable + limits:** §§9–10, same day · **Owner:** chief

This is the artifact a human approves **before** anything is deleted. Every candidate
below names the search that found it, and the scope that search ran over, so the
finding can be re-run rather than believed. A candidate list without its method is
unreviewable.

The reason this document exists in this form: this portfolio has repeatedly found
things that *looked* dead and were not — a Prolog corpus reached by a path nobody
found, a `content_qa` declared callerless when it had a caller, a `docs/studioos`
tree cited by 93 files. Deletion is irreversible in effect even when git remembers,
because nobody re-reads a deleted file.

**The classes are not the same finding.** Class A is dead. Class B is *deliberately*
unexercised and says so in the source — deleting it removes a stated contract, and it
is listed here so the next sweep does not re-litigate it. Class C is duplication.
Class D is code that runs nowhere. Class E is what the search proved absent, which is
worth recording because it is the expensive half of the work.

---

## 1. Method

All searches ran from the repo root over **tracked files only** (`git grep`, so
`.git/`, worktrees and gitignored state are out of scope by construction), on
2026-09-03.

### 1.1 Unreferenced shell functions

Definitions were extracted from the production tree — `bin/chief`, `engine/*.sh`,
`install.sh` — and each name was then searched for across **every tracked file in the
repo** (engine, CLI, tests, docs, templates, examples, CI, tasklists), with the
defining line itself excluded:

```sh
# 1. extract definitions  ->  file<TAB>line<TAB>name
for f in bin/chief engine/*.sh install.sh; do
  grep -nE '^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*\(\)[[:space:]]*\{' "$f" \
    | sed -E "s|^([0-9]+):[[:space:]]*(function[[:space:]]+)?([A-Za-z_][A-Za-z0-9_:.-]*)[[:space:]]*\(\).*|$f\t\1\t\3|"
done > /tmp/prodfns.tsv

# 2. count references anywhere in the tree, minus the definition line
while IFS=$'\t' read -r file line fn; do
  n=$(git grep -nE "(^|[^A-Za-z0-9_])${fn}([^A-Za-z0-9_]|$)" -- . \
      | grep -vE "^${file}:${line}:" | wc -l)
  printf '%d\t%s\t%s\t%s\n' "$n" "$fn" "$file" "$line"
done < /tmp/prodfns.tsv | sort -n
```

Word-boundary matching, not substring — a substring search inflates the count of any
short name (`status`, `render`, `field`) until nothing looks dead.

**Result: 560 production functions scanned. Exactly one has zero references.**
98 have exactly one reference (a single call site). Those 98 are **not** findings
here: a single-call-site helper is `chief quality ratchet`'s `single_use_functions`
metric, a decomposition question, not a liveness one, and this repo's helpers are
frequently one-call-site *by design* (the SET-A-GLOBAL / PRINT-IT pairs in
`engine/crossrepo.sh`, the per-render row builders in `engine/status.sh`).

### 1.2 Duplicate definitions of one name

```sh
awk -F'\t' '{print $3"\t"$1":"$2}' /tmp/prodfns.tsv | sort \
  | awk -F'\t' '{a[$1]=a[$1]" "$2; c[$1]++} END{for(k in a) if(c[k]>1) print c[k]"\t"k"\t"a[k]}'
```

**Result: 12 names defined in more than one production file.** All 12 resolved to
Class B (§3) on reading — see there.

### 1.3 Variables written and never read

Every assignment target in the production tree, checked for a dereference in its own
file (`${V}`, `$V`, `[ -n "$V" ]`, `(( V ))`) and anywhere else in the tree:

```sh
grep -oE '(^|[[:space:]]|;)(local |export |declare -[a-zA-Z]+ )?[A-Za-z_][A-Za-z0-9_]*=' "$f" \
  | sed -E 's/.*[[:space:];]//; s/^(local|export|declare)//; s/=$//' | sort -u
# then, per name: an in-file read scan + a tree-wide git grep
```

Separately, the 142 distinct `CHIEF_*` identifiers in the production tree were split
into reads (`${CHIEF_X`), writes (`CHIEF_X=`) and mentions (docs + tests):

```sh
git grep -ohE 'CHIEF_[A-Z0-9_]+' -- bin engine install.sh templates .chief scripts | sort -u
```

**Result: 3 write-only names** (§2.2). The rest of the raw hits were false positives
and are named in §5 so the next sweep does not re-open them.

### 1.4 Scripts and tests nothing runs

Per `CLAUDE.md`, a `test/*.sh` is a gate only when it appears in **three** lists:
`.chief/verify.sh`'s `CHIEF_BYSTANDER_TESTS`, `test/all.sh`'s `BASH_SUITE`, and
`.github/workflows/ci.yml`. Nothing derives one from another, so a file can exist in
zero of them and look like coverage.

```sh
SUITE=$(sed -n '/^BASH_SUITE=(/,/^)/p' test/all.sh | grep -v '^BASH_SUITE\|^)' | tr ' ' '\n' | sed '/^$/d' | sort -u)
for t in test/*.sh; do s=$(basename "$t" .sh); [ "$s" = all ] && continue
  echo "$SUITE" | grep -qx "$s" || echo "not in BASH_SUITE: $s"; done
git grep -n '<script name>' -- .chief .github bin engine test   # per scripts/*.mjs
```

**Result: 3 test files in zero lists, 1 script invoked by nothing** (§4).

### 1.5 Unreferenced files

```sh
for d in $(git ls-files docs templates examples scripts test/fixtures); do
  n=$(git grep -l "$(basename "$d")" -- . | grep -v "^$d$" | wc -l)
  [ "$n" -eq 0 ] && echo "UNREF $d"
done
```

**Result: 0 unreferenced docs, 0 unreferenced templates, 0 unreferenced fixtures.**
The three `examples/minimal/tasks/chief/*.json` match only by directory, not by
filename — they are the `README.md:316` demo and the `test/status-scope.sh` nesting
fixture, and they are live (§5).

### 1.6 Commented-out code

```sh
git grep -nE '^[[:space:]]*#[[:space:]]*(if |for |while |case |local |echo |return |export |[a-z_]+=[^ ]|[a-z_]+\(\) *\{|fi$|done$|esac$)' \
  -- bin engine install.sh scripts templates
```

**Result: 0 commented-out blocks.** Every hit was word-wrapped English prose whose
continuation line happens to begin with `for`, `while` or `local`. The single hit that
*is* shell (`engine/reap.sh:14`) is an illustrative anti-pattern inside a header
comment, deliberately quoted.

---

## 2. Class A — candidates for removal  ·  **both removed, 2026-09-03**

### 2.1 `crossrepo_completed()` — engine/crossrepo.sh:33

The only zero-reference function in 560. It is the PRINT-IT half of a SET/PRINT pair
whose SET half (`crossrepo_completed_set`, line 31) has a caller at line 72; the
printing form has none.

```
$ git grep -n "crossrepo_completed" -- .
engine/crossrepo.sh:31:crossrepo_completed_set() { … }
engine/crossrepo.sh:33:crossrepo_completed()     { crossrepo_completed_set; printf '%s' "$CROSSREPO_COMPLETED"; }
engine/crossrepo.sh:72:    *)   crossrepo_completed_set; DEP_RECORD="…"; return 0 ;;
```

**Counter-argument, which must be answered before deletion.** The file's own header
states the pair as a rule: *"Every helper here that a hot loop calls comes in two
forms."* Its sibling `crossrepo_root()` (line 32) **is** called, from `resolve_repo`.
So this is either a genuinely dead half, or a stated API contract with no consumer
yet. Deciding that is US-2's job, not this document's — but note it is 1 line.

### 2.2 Write-only variables — engine/sweep.sh

| Name | Written | Read | Says it is an output? |
|---|---|---|---|
| `CHIEF_SWEEP_REFUSED` | `sweep.sh:191`, `sweep.sh:208` | nowhere | **yes** — `sweep.sh:187` names it as one of three accumulators "for a caller that wants to total across a run" |
| `CHIEF_SWEEP_STARTUP_BYTES` | `sweep.sh:437` | nowhere | no |
| `CHIEF_SWEEP_STARTUP_COUNT` | `sweep.sh:437` | nowhere | no |

The distinction is the whole point of separating the classes. `CHIEF_SWEEP_REFUSED`'s
two siblings in the same sentence *are* read — `CHIEF_SWEEP_BYTES` at
`driver.sh:653` and `sweep.sh:352`, `CHIEF_SWEEP_COUNT` at `sweep.sh:216` and
`sweep.sh:349` — so the comment is a live contract that one member happens not to
have a consumer for. It belongs in Class B unless the contract itself is withdrawn.

`CHIEF_SWEEP_STARTUP_BYTES`/`_COUNT` carry no such statement: `chief_sweep_startup`
already `echo`s its summary on the line above, and the two assignments are the last
statement before `return 0`. Those are Class A.

Search:

```
$ git grep -n "CHIEF_SWEEP_STARTUP_BYTES\|CHIEF_SWEEP_STARTUP_COUNT" -- .
engine/sweep.sh:437:  CHIEF_SWEEP_STARTUP_BYTES="$bytes"; CHIEF_SWEEP_STARTUP_COUNT="$n"
```

One hit each, tree-wide, and it is the write.

---

## 3. Class B — deliberately unexercised. Do not remove.

**All 12 duplicate function definitions are degradation stubs**, and every one is
guarded by an `if [ -f "$DIR/<module>.sh" ]` whose `else` arm defines the stub. They
exist so an engine tree *predating* a module keeps working: `bin/chief` can point at
an older `engine/`, and a run mid-upgrade must not take a view down. The source says
so at each site.

| Name | Real definition | Stub | The stated reason |
|---|---|---|---|
| `live_get`, `live_set` | `engine/live.sh:107,134` | `engine/agent.sh:933,934` | missing `live.sh` must be a no-op, not a crash |
| `live_get`, `live_age` | `engine/live.sh:107,115` | `engine/monitor.sh:188,189` | *"the stubs keep every row rendering exactly as it did before"* |
| `event_emit` | `engine/events.sh:84` | `engine/agent.sh:943` | *"an empty one (a standalone run) is a no-op, and a missing file must cost us nothing"* |
| `measure_gate` | `engine/measure.sh:89` | `engine/agent.sh:954` | *"the SAME function `engine/driver.sh` runs at the merge phase … one rule with two moments, instead of two implementations that can drift"* |
| `research_enabled` | `engine/research.sh:127` | `engine/agent.sh:1800` | *"An install that predates this module"* — and the stub **warns** rather than silently skipping |
| `chief_find_unregistered_drivers`, `chief_run_file_ns`, `chief_ns_foreign` | `engine/reap.sh:1152,188,181` | `engine/monitor.sh:211,214,215` | *"against an older engine tree the stub keeps every row rendering as it did before"* |
| `chief_machine_activity`, `chief_machine_activity_line` | `engine/concurrency.sh:131,168` | `engine/monitor.sh:225,226` | same guard, same reason |
| `usage` | `bin/chief:53` | `engine/gen.sh:50` | not a duplicate at all — two independent programs, each with its own help text |

This is the finding that most needed writing down. A sweep that greps for "two
definitions of one name" and deletes the second removes chief's entire
forward/backward-compatibility story, and every test would stay green, because the
stubs are unreachable **in a correct install** by design.

Also Class B: **`CHIEF_SWEEP_REFUSED`** (see §2.2) and **`crossrepo_completed`**
(§2.1) if the pair rule is kept.

---

## 4. Class D — code that runs nowhere  ·  **all four registered, 2026-09-03**

### 4.1 Three test files in zero gate lists

`CLAUDE.md` requires three registrations. These have none:

| File | `BASH_SUITE` | `CHIEF_BYSTANDER_TESTS` | `ci.yml` |
|---|---|---|---|
| `test/parked-decisions.sh` | ✗ | ✗ | ✗ |
| `test/ps-all.sh` | ✗ | ✗ | ✗ |
| `test/update-reroot.sh` | ✗ | ✗ | ✗ |

```
$ git grep -n "ps-all\|update-reroot" -- .        # nothing outside the files themselves
$ git grep -n "parked-decisions" -- .             # only three completed/ tasklist notes
```

`test/parked-decisions.sh` is *cited as having been run* in three of `106`'s story
notes, so it was live coverage when it was written and lost its registration since.
**This is almost certainly a fix, not a deletion** — the right resolution is to add
all three to the three lists (or to state why each is excluded, as
`test/monitor-orphan.sh:53` and `test/status-perf.sh` explicitly do for the merge
gate). It is listed under dead code because "a script nothing runs" is exactly the
tasklist's definition, and because a test that no gate runs is *worse* than no test:
it reads as coverage.

### 4.2 `scripts/check-tasklist-categories.mjs` — 109 lines, invoked by nothing

```
$ git grep -n "check-tasklist-categories" -- .
docs/reference/status.md:320:  … 16 vendor a `check-tasklist-categories.mjs` …
docs/reference/status.md:325:  **If you vendored a per-repo category guard** …
scripts/check-tasklist-categories.mjs:39: * Usage: node scripts/check-tasklist-categories.mjs …
tasks/chief/completed/97-tasklist-state-report.json:5: … enforced by a `check-tasklist-categories.mjs` vendored into 16 of them …
```

Not in `.chief/verify.sh` (which *does* run `scripts/check-doc-links.mjs`, line 42),
not in `.github/workflows/ci.yml`, not in `test/all.sh`. Its only same-repo mentions
are prose describing the *class* of script, not invocations of this one. Its single
commit is `3714f28 tasks: categorize every active tasklist`.

It is operator-invocable and self-documenting, so it is not obviously waste — but as
shipped it is a guard that guards nothing. Resolution (wire it into the gate, or
remove it) is US-2's.

---

## 5. Searched, and found live — recorded so the next sweep skips them

These all appeared in a raw scan and are **not** findings. Re-deriving that costs
more than reading it.

| Looked dead | Why it is live |
|---|---|
| 98 single-call-site functions | one call site is a decomposition metric (`chief quality ratchet`), not a liveness one; several are one-call-site by stated design |
| `examples/minimal/tasks/chief/{feature-a,feature-b,foundation}.json` | matched no filename reference because they are consumed **by directory** — `README.md:316` demo, and `test/status-scope.sh:71`'s nested-backlog trap fixture |
| `engine/quality.sh`: `OFS`, `dolint`, `dupfile`, `haveSC`, `lintfile`, `shellfile` | `awk -v` bindings — read inside the awk program, invisible to a shell-variable scan |
| `engine/live.sh`: `_lv_heartbeat` (and every `_lv_*`) | read through `eval "val=\"\${_lv_$key:-}\""` — indirect expansion over `$LIVE_FIELDS`. No static search over shell text can see this |
| `engine/concurrency.sh`: `cores` | `awk -v cores="$CHIEF_MACHINE_CORES"` |
| `engine/driver.sh`: `machine_budget`, `machine_budget_disabled` | not variables — literal text inside the `detail=` headless-summary string at `driver.sh:2243` |
| `engine/cigate.sh`: `VERBOSE` | a documented *parameter name* in two function-header comments; no assignment exists |
| `engine/reap.sh`: `etime` | `ps -o etime=` — a `ps` format spec, not an assignment |
| `bin/chief`: `CLICOLOR`, `GIT_PAGER`, `NO_COLOR` | exported **for child processes** (git); a same-tree read would not exist even if they were live, which they are |
| `AGENT_RC_UNAVAILABLE` (=8) | agent.sh emits it as `… || exit 8` at lines 1886 and 2135, not as a line-initial `exit 8`. All of `AGENT_RC_{LIMIT,PAUSED,PLAN,REVIEW,RESEARCH,UNVERIFIED,UNAVAILABLE,REPEAT}` are both emitted and armed |
| every `cmd_*` in `bin/chief` | each has exactly one reference — its own `case "$cmd"` dispatch arm. That is what a subcommand looks like |
| all 24 files under `docs/` | every one is linked from `docs/README.md`, whose stated rule is *"a document not linked here does not exist"* |

---

## 6. Limits of this method

The outline, written while the inventory was being taken. **§10 states these
in full** — including the ones this outline did not know about — and **§9** is
the list of candidates they leave undecidable.

- **`shellcheck` is not installed on the audit host**, so `SC2034` (assigned but
  unused) and `SC2317` (unreachable command) contributed nothing. CI runs shellcheck
  at `-S error`, which reports neither. The §1.3 scan is a hand-rolled substitute and
  is strictly weaker.
- **Indirect expansion (`eval "_lv_$key=…"`) and `awk -v` bindings are invisible** to
  any grep over shell source. `engine/live.sh` is the worked example.
- **Cross-repo consumers cannot be seen from this tree at all.** `bin/chief` is
  installed onto a host and sourced by 24 sibling repos; `engine/*.sh` modules are
  sourced by `${BASH_SOURCE[0]}`-relative path from installs that may be older or
  newer than this checkout. This is the exact failure mode the portfolio has already
  been bitten by.
- Scope is **tracked files**. Gitignored state, worktrees and `$CHIEF_PREFIX` are out.

---

## 7. Verification of this document

`chief verify` (the repo's full gate) was green when this inventory was committed;
the observation is recorded in `tasks/chief/900-dead-code-paydown.json`'s US-1 note.
No code changed in the commit that added this file.

The removals in §8 were verified the same way, on the tree that carries them:
`chief verify` **exit 0**, ~20 minutes — quality ratchet OK, `bash -n` clean,
`test/version-bump.sh` PASS at `0.9.14`, the behavioural block **57 tests** (55
before this branch; the two added are the new merge-gate registrations) run under
`test/bystander.sh` with the decoy run alive and a genuine orphan still reaped,
`test/doc-sync.sh` PASS over 42 merged tasklists, tasklist JSON and category
coverage OK. Verdict recorded for tree `fb83c89c`.

---

## 8. Disposition — what US-2 did with each finding, and why

Written the day the removals landed. §§2–5 above are the inventory **as measured**
and are left as they were, so the searches can still be re-run against the state
that produced them; this section is the *decision* taken on each one. Where the two
disagree, this section is later.

**The rule this sweep applied**, stated once so the next one does not re-derive it:

> **Unreferenced code is deleted. Working code that no gate invokes is registered.**

Both are "dead" under this tasklist's definition — but they fail differently.
Nothing calls `crossrepo_completed`, so nothing can notice it going. A test in zero
gate lists is *worse than absent*, because it reads as coverage; deleting it would
destroy working coverage to make a count go down. Four of the six findings were the
second kind.

### 8.1 Removed

| Finding | Where | Commit | The search, re-run immediately before the deletion |
|---|---|---|---|
| `crossrepo_completed()` | `engine/crossrepo.sh` | step 1/3 | `git grep -n "crossrepo_completed" -- .` → 3 hits, all inside `crossrepo.sh` itself (the `_set`, the removed printing form, and the `_set`'s one caller) |
| `CHIEF_SWEEP_STARTUP_BYTES`, `CHIEF_SWEEP_STARTUP_COUNT` | `engine/sweep.sh` | step 1/3 | `git grep -n "CHIEF_SWEEP_STARTUP_BYTES\|CHIEF_SWEEP_STARTUP_COUNT" -- .` → 1 hit, and it is the write |

§2.1 could not resolve `crossrepo_completed` on its own, because the module header
stated the SET/PRINT pair as a *rule* and deleting one half would have made the
header false. That is now answered rather than dodged: the header says what the pair
is **for** — a caller that reads the answer inline — instead of implying that
symmetry is the point, and it names this removal so the half is not re-added out of
tidiness. Cost of being wrong: one line, in a function whose `_set` half is intact.

### 8.2 Registered rather than removed

| Finding | Resolution | Why not deletion |
|---|---|---|
| `test/parked-decisions.sh` | all three lists | Passes today (0.36s, hermetic), and `106`'s story notes cite it as *run* — it lost a registration it once had |
| `test/update-reroot.sh` | all three lists | Passes today (5.6s, hermetic), and pins a production failure: an install frozen on a force-pushed re-root |
| `test/ps-all.sh` | `BASH_SUITE` + CI, deliberately **not** the merge gate | The one that was RED. Its second half starts a real watcher and read it after a fixed `sleep 0.2`, which no longer holds (~400ms to first render on a loaded host; 3/3 failures). It now waits for the render, bounded at 10s — same output, same assertion, 3/3 green. Excluded from the merge gate for `monitor.sh`'s reason, stated in its own header |
| `scripts/check-tasklist-categories.mjs` | `.chief/verify.sh` + CI | It enforces category **coverage**, which chief structurally cannot: `category` is an opaque string to the engine, and `chief status --enforce-order` — what [`docs/reference/status.md`](../reference/status.md) says replaces a vendored guard — replaces the ordering half only and never fails on an uncategorized tasklist. Observed: `OK — 4 tasklists categorized` |

**A registration is a claim about a gate, so the gate had to be readable.** It was
not: `.github/workflows/ci.yml` **had not parsed since 2026-08-25**. Five step names
added that day begin with a backtick, a reserved indicator in YAML, so
`- name: ` + `` `chief status` … `` is not a legal plain scalar. GitHub reports this
as a run of *the file* — name `.github/workflows/ci.yml` rather than the workflow
`ci` — with **zero jobs**: run `33047688561`, 2026-08-27, head `55b94f0`,
conclusion `failure`, `jobs = []`. The five names are now quoted and the file parses
(72 steps). This is not a claim that CI is green — every run in the last 20 is a
failure, which is `115`'s subject, not this tasklist's.

### 8.3 Not removed, and this is the durable half of the record

Nothing below is a deferral. Each was examined and **kept**, and the reason is
recorded here so the next sweep does not spend its budget re-litigating the same
files.

| Kept | Why it survived |
|---|---|
| All **12** duplicate function definitions (§3) | Every one is a degradation stub inside an `if [ -f "$DIR/<module>.sh" ] … else` guard, with the reason written at the site. They are unreachable *in a correct install by design*, so deleting them leaves every test green and removes chief's whole older-engine-tree compatibility story. This is the single most expensive mistake this sweep could have made |
| `CHIEF_SWEEP_REFUSED` (§2.2) | Written twice, read nowhere — but `engine/sweep.sh:187` names it as one of three accumulators *"for a caller that wants to total across a run"*, and its two named siblings **are** read. The comment is a live contract with one member that has no consumer yet. Withdrawing the contract is a decision about the API, not a cleanup |
| The **98** single-call-site functions | One call site is `chief quality ratchet`'s `single_use_functions` metric — a decomposition question, not a liveness one. Several are one-call-site by stated design (the SET/PRINT pairs, `engine/status.sh`'s per-render row builders) |
| Every row of §5 | `awk -v` bindings, `eval`-indirect `_lv_*` expansion, `ps` format specs, exported-for-children env vars, `cmd_*` dispatch arms, the `examples/minimal` fixtures consumed by directory. All were raw-scan artefacts; none is a finding |
| `engine/reap.sh:14`'s commented shell | The one commented-out-looking line in the tree, and it is an illustrative anti-pattern quoted inside a header comment |

### 8.4 Found while removing, fixed, and not dead code

Recorded because both are the same *shape* as the findings above — a check that
exists and does not run — and because a reader of this document will otherwise
wonder why they are in the diff.

- **`ROADMAP.md` did not name `118-a-document-can-claim-something-downstream`.** Its
  retire commit (`b381350`) filed the `completed/` record without the roadmap row
  `test/doc-sync.sh` requires, so `main` was red on that gate before this branch
  existed. This branch touches `VERSION`/`README`/`ROADMAP` and therefore pays the
  gate, which is how it surfaced. Fixed in its own commit, deliberately separate
  from the removals.
- The **CI parse failure** in §8.2, which was found by asking whether a CI
  registration means anything.


---

## 9. Undecidable — what the sweep could not resolve, and left in place

Written 2026-09-03 against `VERSION` 0.9.14, after the removals in §8.

§§2–4 are the findings the searches **resolved**. This section is the other
result, and it is a legitimate one: candidates a static search over this tree
**cannot decide**, because the thing that would decide them is not in the tree.
Every row below was examined and **left exactly where it is**. None of it is
scheduled for a later sweep — an item here is not "deferred", it is *reported as
undecidable*, which is the honest terminal state until something outside a grep
(a trace, a subscriber inventory, a sibling-repo scan) is brought to it.

The classes are ordered by how far the missing evidence lives from this file.

### 9.1 Names that do not exist until runtime — `eval` and indirect expansion

**Ten** executable `eval` sites and **one** `${!VAR}` in the production tree:

```sh
git grep -nE '(^|[^A-Za-z0-9_])eval[[:space:]]' -- bin engine install.sh scripts templates
git grep -nE '\$\{![A-Za-z_]' -- bin engine install.sh scripts templates
```

They split into two kinds, and only the second is undecidable *within* this repo.

| Site | What it constructs | Decidable here? |
|---|---|---|
| `engine/live.sh:148,154,167` | `_lv_<key>` for each key in `$LIVE_FIELDS` | **No** by grep — but `LIVE_FIELDS` (live.sh:101) is a literal list of 16 names, so the family is closed and enumerable *by reading that line*. This is why `CLAUDE.md` states `live_set`'s three-edit rule: the compiler cannot see it either |
| `engine/gitenv.sh:64,65` | `GIT_CONFIG_KEY_$n` / `GIT_CONFIG_VALUE_$n` | **No** — and doubly so: the consumer is **git itself**, not chief. Nothing in this repo will ever reference those names |
| `engine/quality.sh:766` (`qq_tol`) | `CHIEF_QUALITY_TOL_<metric>`, metric from data | Closed **today**: `QUALITY_METRICS_KNOWN` names 11 metrics and `qq_default_tolerances` gives exactly 11 defaults. A twelfth metric would read a name that appears nowhere in this tree, and no search would notice |
| `engine/quality.sh:799,801` (`eval "$line"`) | any `CHIEF_QUALITY_*` name found in `.chief/quality.conf` or `.chief/config` | **No, and unboundedly so** — the names come from a config file in whatever repo the ratchet is run against |
| `engine/agent.sh:2283`, `engine/driver.sh:2613`, `engine/lib.sh:188` | nothing — they evaluate **operator-supplied shell**: `CHIEF_ITER_HOOK`, the warm-up commands, the per-tasklist `verify` array | **No.** These are the boundary at which chief executes text this repository does not contain. A hook may call any chief function; a scan here sees an empty string |

Nothing was removed on account of any of these. The `awk -v` bindings in §5 are
the same phenomenon one language down.

### 9.2 Called through a variable that holds a function name

`engine/sweep.sh:327` and `:425` call `"$livefn" "$wt"` — the liveness predicate
is **injected by name**, deliberately (`sweep.sh:288–296`: the rule belongs to
`engine/reap.sh`, the deletion belongs to `sweep.sh`, and a test can then pin both
halves against a fixture).

It is decidable **today only by luck**: both callers pass the literal token
`chief_reap_wt_live` (`engine/driver.sh:2264`, `engine/reap.sh:1245`), so a
word-boundary grep finds it. The moment any caller composes the name — a
`chief_reap_${kind}_live` — the callee becomes invisible and reads as a
zero-reference function, which is precisely the shape §2.1 deleted on. Recorded
so a future sweep checks the *call site*, not just the count.

### 9.3 Call sites guarded by a runtime capability probe

`command -v <function> >/dev/null 2>&1 && <function> …` is how the engine
degrades when a module is absent (§3's twelve stubs are the other half of the
same mechanism). **13** production functions are probed this way:

```sh
# per function name: references, minus the definition line, split on the probe form
git grep -nE "command -v[[:space:]]+${fn}([^A-Za-z0-9_]|$)" -- bin engine
```

| Probed function | probe refs | other refs |
|---|---|---|
| `live_set` | 2 | 102 |
| `event_emit` | 1 | 48 |
| `live_get` | 1 | 46 |
| `measure_gate` · `chief_prefix` · `chief_pid_alive` · `chief_scan_descendants` · `repeat_bump` · `chief_ns_foreign` · `research_validate` · `decision_verdict_file` · `chief_sweep_candidate` · `review_ask` | 1 each | 18 · 17 · 13 · 12 · 12 · 11 · 9 · 8 · 6 · 3 |

**Measured result: none is probe-only.** Every one has real call sites, by an
order of magnitude. So this generated no finding today — but the probe string
*is* a textual reference, and it survives the deletion of the last genuine call
site. A function whose last caller went away would still count as referenced,
once, forever. This is the audit's clearest false-**negative** generator, and the
only defence is the one used here: read the hits, do not count them.

### 9.4 Reachable only from outside this repository

Chief is installed onto a host and driven by hand and by sibling repos. Four
dispatch arms are invoked by **nothing** in this tree, named in **no** README
row, **no** document, and **no** usage block:

| Alias | Primary |
|---|---|
| `generate` | `gen` |
| `watch` | `monitor` |
| `tail` | `logs` |
| `subscribe` | `events` |

```sh
sed -n '/^case "\$cmd"/,/^esac/p' bin/chief        # the dispatch table
git grep -nE "chief (generate|watch|tail|subscribe)([^a-z-]|$)" -- . 
```

They are undecidable in the ordinary way (someone's muscle memory or someone's
script may type `chief watch`) and they are **structurally invisible to the gate
that would otherwise catch them**: `test/doc-sync.sh:95` reduces each arm to
`primary="${arm%%|*}"` before checking README coverage, so an alias can never
fail doc-sync. That is a defensible choice for a gate about *documentation
drift*; it means the four names have no reader in this repo at all. Left in
place — deleting a synonym breaks a habit that leaves no trace here, and it is
`901`'s call whether to document them instead.

### 9.5 Operator input: read by the engine, assigned by nobody

**13** `CHIEF_*` names are dereferenced in the production tree and assigned
nowhere in it — they exist to be set by an operator, a container environment, or
a sibling repo's `.chief/config`:

```sh
git grep -ohE 'CHIEF_[A-Z0-9_]+' -- bin engine install.sh templates .chief scripts | sort -u
# per name: writes anywhere  vs  reads in bin/engine/install.sh
git grep -nE "(^|[^A-Za-z0-9_])${v}=" -- .
git grep -nE "\\\$\{?${v}[^A-Za-z0-9_]" -- bin engine install.sh
```

Whether any of them is ever set is **not decidable from this tree** — an
environment variable has no declaration site. What *is* decidable is whether a
reader of this repository could ever learn the name exists, and on that four of
the thirteen fail: their **only** occurrence in any tracked file is the read
itself.

| Undiscoverable | Only occurrence | Effect if never set |
|---|---|---|
| `CHIEF_QUALITY_CONFIG` | `engine/quality.sh:790` | ratchet config path stays `.chief/quality.conf` |
| `CHIEF_SWEEP_DEPTH` | `engine/sweep.sh:167` | artifact scan stays `-maxdepth 6` |
| `CHIEF_SWEEP_MAX` | `engine/driver.sh:2264`, `engine/sweep.sh:390` (both reads) | startup sweep stays capped at 100 worktrees |
| `CHIEF_SWEEP_STARTUP_DRY_RUN` | `engine/driver.sh:2262` | startup sweep deletes rather than reports |

The other nine are reachable knowledge: `CHIEF_REAP_GRACE`, `CHIEF_CHECKOUT_RETRIES`
(`CLAUDE.md`), `CHIEF_SWEEP_MIN_AGE` (`chief reap --help`, `engine/reap.sh:1291`),
`CHIEF_EVENTS_KEEP_DAYS`, `CHIEF_IGNORE`, `CHIEF_STATUS_DEPTH`, `CHIEF_CLAIMS_FILE`,
`CHIEF_ZONES`, `CHIEF_TEARDOWN_CRITICAL_GRACE` (all documented, and `CHIEF_ZONES`
has three tests).

None is a removal candidate — every one is a live default with a live read.
The four are a **documentation** finding, which is `901`'s subject, not this
tasklist's; recorded here so it inherits them measured.

### 9.6 The event stream — a published surface with its consumer elsewhere

`engine/events.sh` exists to be subscribed to by chief-cloud and embedding hosts
(`docs/reference/events.md`). So "does anything read this event?" is a question
about *other systems*.

```sh
git grep -ohE 'event_emit[[:space:]]+"?[a-z][a-z._-]+' -- bin engine \
  | sed -E 's/event_emit[[:space:]]+"?//' | grep '\.' | sort -u
# per type: named in test/ ?  named in docs/ or README ?
```

**33 distinct event types. 21 are asserted by no test. Four have no in-tree
consumer of any kind** — no test, no document:

| Emitted, and nothing here reads it |
|---|
| `story.unverified` |
| `tasklist.queued` |
| `tasklist.terminal-negative` |
| `tasklist.unsatisfiable` |

All four are emitted on real transitions the engine takes, so none is dead code
by any reading. The undecidable half is on the **subscriber** side, and a
subscriber outside this repository cannot subscribe to an event no document
names — so these four are, again, discoverable-only-by-reading-the-source.
Left in place; the same `901` note applies.

### 9.7 Scaffolded into other repositories

`templates/` is copied into a target repo by `chief init`; its contents then run
**there**. `templates/tasklist.example.json` is referenced by no test:

```sh
for f in $(git ls-files templates); do
  printf '%-40s tests=%s\n' "$f" "$(git grep -lF "$(basename "$f")" -- test | grep -c .)"; done
```

`verify.sh` (53), `config` (21), `agent-context.md` (3), `quality.conf` (2) and
`zones.conf` (2) are all exercised; `tasklist.example.json` is the one whose only
reader is a human in a repo `chief init` has run in. §1.5 correctly reported it
as *referenced* — `bin/chief`'s `cmd_init` copies it by name — which is exactly
the distinction this section exists to draw: **copied is not read.**

### 9.8 Text whose consumer is a language model

`engine/agent.sh` composes the prompt. Its headings, its ordering, and the
`templates/agent-context.md` block appended to it are consumed by a model's
attention, and no static or dynamic analysis of this repository decides whether a
sentence in a prompt is load-bearing. `CLAUDE.md` already records the one
mechanical trap here (a behavioural test must not grep a prompt for a string that
`templates/agent-context.md` also quotes, or it matches when nothing was
injected). Prompt text was therefore **excluded from this audit's scope
entirely** rather than sampled — an audit that deleted a heading because no code
read it would be measuring the wrong thing.

---

## 10. Limits of the method, in full

§6 is the outline written while the inventory was being taken. This is the
complete statement, including the limits §6 did not know about yet.

**What the search is.** `git grep`, word-boundary, over tracked files, from the
repo root, at a point in time. That is the whole instrument. Everything below
follows from it.

1. **No `shellcheck`.** It is not installed on the audit host; CI runs it at
   `-S error`, which reports neither `SC2034` (assigned and unused) nor `SC2317`
   (unreachable command) — the two checks that would matter most here. The §1.3
   variable scan is a hand-rolled substitute and is **strictly weaker** than
   either. No claim in this document should be read as "shellcheck agrees".
2. **Runtime reachability was never measured.** No `set -x` trace, no coverage
   run, no instrumented `chief run`. Every statement is about *text*, not about
   *execution*. A function called on a path no test takes and a function called
   on every iteration are indistinguishable to this method.
3. **Constructed names are invisible** — §9.1. `eval`, `${!n}`, `awk -v`, and
   config-file-driven variable creation each defeat grep completely.
4. **A textual mention counts as a reference**, and three kinds of mention are
   not calls: prose in `docs/` and `CLAUDE.md`, a `command -v <fn>` probe
   (§9.3, 13 names), and a name inside a usage heredoc. *Measured:* re-running
   the §1.1 scan restricted to executable paths
   (`-- bin engine install.sh test scripts .chief .github templates`) leaves
   **zero** functions with no reference — so prose kept nothing alive in this
   tree today. The inflation is real and it produced no false negative here.
5. **Deletion changes the question.** Reference counts were taken against one
   tree. Removing a call site can turn a live function into a dead one, and the
   audit does not re-run itself. §8's rule — re-run the search immediately
   before each deletion and paste it into the commit — exists for exactly this.
6. **Scope is tracked files, and the worktree is the boundary.** Gitignored
   state, `$CHIEF_PREFIX`, and every sibling repository are outside it. This
   audit ran **inside a git worktree**, where reaching up to the project checkout
   or across to a sibling repo is forbidden by chief's own agent contract — so no
   cross-repo consumer was checked, and none *could* have been. `bin/chief` is
   installed onto a host and invoked by other repos' hooks; `engine/*.sh` is
   sourced by `${BASH_SOURCE[0]}`-relative path from installs that may be older
   or newer than this checkout. **This is the exact failure mode the portfolio
   has already been bitten by** (the `content_qa` caller, the `docs/studioos`
   tree cited by 93 files), and it is unmitigated here.
7. **Version skew is a consumer this tree cannot enumerate.** An older install
   sourcing a newer `engine/` module — and the reverse — is what §3's twelve
   degradation stubs are for. Whether any host is actually running such a
   combination is not knowable from here, which is why "every test stays green
   without them" is not an argument for deleting one.
8. **A published API has no local caller by design** — §9.6's event types,
   §9.4's aliases, the `.chief/verify.sh` hook contract, `chief`'s exit codes.
   For these, "no reference in this repo" is the *expected* reading and carries
   no information about liveness.
9. **Time.** §§1–5 were measured 2026-09-03 against `VERSION` 0.9.13; §§8–10 the
   same day against 0.9.14, after the removals. Any later divergence is real —
   re-run the searches rather than trusting the counts.

**What would make the undecidable decidable**, in the order the cost is worth
paying: install `shellcheck` (limit 1, minutes); a subscriber inventory for the
event stream, owned wherever chief-cloud is (limits 8 and §9.6); a portfolio-wide
`git grep` for `chief <subcommand>` run from *above* the repos rather than inside
a worktree (limits 6 and §9.4); a traced `chief run` (limit 2). None of them is
this tasklist's, and none of them is a reason to have deleted anything without
them.
