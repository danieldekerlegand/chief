# CLAUDE.md — chief (autonomous tasklist runner)

Chief is the **harness every sibling repo is built with**, not a product. A Bash engine
(`bin/chief` + `engine/*.sh`) drives an agent through **implement → verify → commit → merge**,
one user story at a time, with git-worktree-isolated parallelism. Chief is **self-hosting** — its own roadmap lives in `tasks/chief/*.json`
and is run with chief itself. The inter-repo picture is in `../CLAUDE.md`; the tasklist schema and
the parallel-safety model are in `docs/`.

## What belongs here

- The **engine** (`engine/driver.sh` scheduler+worker, `engine/agent.sh` one iteration,
  `engine/monitor.sh` run registry, `engine/lib.sh` shared helpers, `engine/live.sh` per-tasklist
  liveliness records, `engine/events.sh` the NDJSON event stream, `engine/reap.sh` orphan reaping,
  `engine/ledger.sh` the recorded descendant tree that reaping's fourth key reads)
  and the **CLI** (`bin/chief`), including the roadmap → tasklists generator
  (`engine/gen.sh`, `chief gen` — input contract in `docs/reference/roadmap-input.md`).
- The hermetic **test suite** (`test/*.sh`), the `chief init` **templates** (`templates/`), and the
  **docs** (`docs/`).

## What does NOT belong here

- Product or ecosystem logic. Chief runs other repos' tasklists; it doesn't implement their work.
- Contract definitions — those live in `../koine`. Chief only needs to read a tasklist's schema.

## Your task (per iteration)

1. Read the target **tasklist** JSON in `tasks/chief/` and the worktree's `progress.txt` / prior
   notes for established patterns.
2. Check out the tasklist's **`branchName`** (`chief/NN-slug`) from `$CHIEF_BASE_BRANCH` (usually
   `main`) — the engine does this for you inside the worktree.
3. Pick the **highest-priority `userStory` where `passes:false`**. Implement **exactly one**.
4. Run the **gate for the area you touched** (see the table) and make it green — locally, before
   committing. A red tree compounds across fresh-context iterations.
5. Commit `feat: [US-x] - <Story Title>`, body ending
   `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
6. Flip that story's **`passes:true`** and append a short note to `progress.txt` (what you did +
   any reusable pattern; update the nearest `CLAUDE.md` if the pattern is durable).
7. **Stop condition:** when every `userStory` has `passes:true`, emit `<promise>COMPLETE</promise>`.
   Never emit it with commit-free work — the engine's EMPTY-NO-WORK guard will reject it anyway.

## Quality gates

`.chief/verify.sh` runs the matching subset automatically at merge — it's path-scoped, so you only
pay for what you changed. A tasklist may override it with its own `"verify":[...]` array.

Run the FULL gate as **`chief verify`**, never as a bare `.chief/verify.sh`: chief runs the same
hook again at the end of the turn and again at merge, and only `chief verify` records the verdict
those two reads are served from. It records for HEAD's tree only, so commit first, then verify.

| Area | Gate |
|---|---|
| Shell engine (`bin/chief`, `engine/*.sh`, `install.sh`, `test/*.sh`) | `bash -n` clean + `shellcheck -S error` clean; behavioral core `test/{smoke,ratelimit,noworkguard}.sh` green |
| Engine version discipline | editing `bin/`/`engine/`/`install.sh` **must** bump `VERSION` (`test/version-bump.sh`) |
| Docs vs engine (`README.md`, `ROADMAP.md`, `VERSION`, `bin/chief`, `tasks/chief/completed/`) | README's **and** ROADMAP's bold `**vX.Y.Z**` == `VERSION`; README's command table covers every `bin/chief` subcommand; ROADMAP names every merged tasklist stem in `completed/` (`test/doc-sync.sh`). The roadmap half was added by `114` because `86` gated the README and stopped there — and the roadmap is the file that then rotted, to `v0.8.0` beside a `VERSION` of `0.8.94` with 21 merged bands invisible, while the gated README stayed correct to the patch. **Retiring a tasklist is now a roadmap edit**: a record in `completed/` that `ROADMAP.md` never names fails CI. |
| Tasklists (`tasks/chief/*.json`) | valid JSON (`jq -e .`); `branchName == chief/NN-slug`; `mergedToMain:false` until merged; no acceptance criterion naming another repo unless `crossRepo` declares it (`chief lint`) |

Notes: the behavioral tests install chief from **`git rev-parse HEAD`**, not from your working
tree — an uncommitted `engine/` edit is invisible to them. Commit first, then run the test, then
`--amend`; or source `engine/reap.sh` (etc.) straight from the worktree to smoke-test before
committing. `test/version-bump.sh` reads history the same way — it diffs the last commit touching
`VERSION` against HEAD, so an *uncommitted* bump still fails it, and any follow-up commit touching
`engine/`/`bin/`/`scripts/`/`install.sh` (a ratchet-clearing refactor counts) re-stales `VERSION`.
Bump `VERSION` and README's bold `**vX.Y.Z**` together — bumping one alone just trades a
version-bump block for a `doc-sync` one. `shellcheck` is enforced in CI (`.github/workflows/ci.yml`) and skipped locally if absent —
install it for parity. The behavioral subset is hermetic (a scripted fake `claude` on `PATH`, temp
prefixes — it never touches your real `~/.chief`); set `CHIEF_VERIFY_TESTS=0` to skip it while
iterating. `monitor.sh` is intentionally out of the auto-gate (timing-sensitive under parallel load)
but stays in CI and the full suite.

## Stack

Bash (engine + tests) · JSON tasklists. Tooling: `jq`, `shellcheck`.

## Layout

```
bin/chief            # CLI: init · gen <roadmap.json> · lint · run [-p N] [-n] [--no-merge] [--merge-batch[=N]] [--headless] [--parked] [names…] · list · status [--blocked] [--all] [--json] [--enforce-order] · ps · monitor · logs · events · usage · models · reap · quality · verify · cigate · retire · approve · decide · pause · resume · version · update
                     #   (2026-09-04: the seven arms this line had never grown — events · usage ·
                     #   quality · cigate · retire · approve · decide. test/doc-sync.sh gates the
                     #   README's command table against this dispatch and nothing gates THIS line,
                     #   which is exactly why it was the one that rotted)
engine/
  driver.sh          #   scheduler + per-tasklist worker: worktree → agent loop → rebase → verify → merge
  agent.sh           #   one agent iteration (implement a single story)
  monitor.sh         #   active-run registry view  (chief ps / chief monitor). `once` renders and
                     #   returns; `watch` LOOPS, and a looping viewer must not outlive the terminal
                     #   that asked for it — it checks its tty and its parent once per tick and exits
                     #   when either is gone. bin/chief EXECs into it, and the tick is bash's own
                     #   `read` timeout, so one view is ONE process instead of wrapper + watcher + a
                     #   forked `sleep` per second
  lib.sh             #   shared helpers: run_verify / verify_branch, locks, state I/O
  paths.sh           #   host-wide state paths (prefix · runs · repos · worktree root), resolved
                     #   in one place — container-safe when $HOME is unset/read-only
  gitenv.sh          #   the git a CONTAINER hands us: safe.directory for a repo owned by another
                     #   uid ($CHIEF_GIT_SAFE_DIRECTORY), a committer identity when git can't find one
  decision.sh        #   the DECISION tasklist and its verdict, both halves in one file because
                     #   106 shipped only one of them: `chief decide` WROTE `.verdict` and the
                     #   driver's halt parked unconditionally, so recording a verdict left the
                     #   tasklist exactly where it was plus a field nothing read. is_decision_tasklist ·
                     #   decision_verdict_file/json (where the durable record lives and what shape
                     #   it is) · decision_stories_id (the BINDING — a projection over
                     #   {id,title,acceptanceCriteria}, so a verdict recorded against one brief
                     #   cannot authorise its re-worded successor, exactly as review.sh binds a
                     #   plan approval) · decision_verdict_set (the reader) · decision_stop (the
                     #   halt, and the one thing that lifts it). The record is `.chief/state/
                     #   decisions/<name>.json` and NOT the tasklist JSON — see the durable-state
                     #   invariant below for the two ways that loses a verdict
  crossrepo.sh       #   resolving a "<repo>:<stem>" REFERENCE to another repo's tasklist — the
                     #   lookup every cross-repo dependsOn has always used, lifted out of the
                     #   driver so the AUTHORING-time gates run the same one. Chief reads exactly
                     #   one file across the boundary (the merged completed/<stem>.json) and never
                     #   schedules, branches or merges in another repo. Every helper a hot loop
                     #   calls comes as a SET-A-GLOBAL / PRINT-IT pair (dep_record_set /
                     #   dep_record): `$(f)` is a FORK, and a portfolio report resolving one edge
                     #   per tasklist pays it thousands of times. The completed/ INDEX — one jq
                     #   per directory behind is_recorded_done instead of one per edge — is
                     #   opt-in for the reason it is not the default: a one-shot READER may cache
                     #   the merge verdict, the SCHEDULER may not, because a run asks the same
                     #   question over hours during which records are appearing
  counterpart.sh     #   the MARKER LINK: a tasklist that is a placeholder for work owned and built
                     #   in ANOTHER repo declares the tasklist that will complete it —
                     #   "downstreamCounterpart": ["agora:75-..."], the forward half of the
                     #   hand-authored supersededBy. A FIELD, because prose is not checkable: a
                     #   counterpart named only in the description is invisible and the gate SAYS
                     #   so rather than reporting clean. `chief lint` resolves each declaration
                     #   through crossrepo.sh, so a pointer to nothing fails instead of reading as
                     #   checked. Then it FOLLOWS the link: a counterpart carrying mergedToMain
                     #   while its marker is still live is REPORTED — marker, counterpart, merge
                     #   sha — and nothing else is. In flight, filed-without-mergedToMain, and an
                     #   already-superseded marker are all silent; a repo not checked out here
                     #   degrades to one unresolvable line and the rest of the scan still runs.
                     #   It REPORTS — `chief lint` and `chief list` both exit 0 on a finding and a
                     #   run still schedules the marker — and it runs in `chief list` because that
                     #   is where the backlog is READ; a check only answering on demand caught
                     #   none of koine's five. The block names the retirement ORDERING in the same
                     #   breath (repoint dependents FIRST, then stamp supersededBy and file),
                     #   because a filed marker carries no mergedToMain and blocks its dependents
                     #   forever on a record that can never be stamped
  claims.sh          #   the DOCUMENT CLAIM: counterpart.sh one register up. A TASKLIST can name
                     #   the tasklist that completes it; nothing let a DOCUMENT name the
                     #   downstream tree it asserts something about, and the obligation runs
                     #   the wrong way to fix itself — agora has no reason to know koine wrote
                     #   a gate against agora's tree. Measured: koine's kcs-encoding-gate doc
                     #   said three tests had no encoding; agora encoded all three 49 MINUTES
                     #   later, and koine carried the claim into two authored tasklists a week
                     #   on. So `.chief/claims.json` declares {document, claim, repo, path} and
                     #   the repo half goes through crossrepo.sh's `resolve_repo` — the same
                     #   lookup dependsOn and downstreamCounterpart use, because a second
                     #   resolver drifting from the first IS the bug class. The vocabulary is
                     #   TWO predicates over a path (`present` · `absent`) and stays that small
                     #   on purpose: a claim that cannot be reduced to a predicate stays prose
                     #   and stays INVISIBLE, exactly as an undeclared counterpart does
  criteria.sh        #   the SCOPE rule on acceptance criteria: a criterion naming ANOTHER repo
                     #   (argos:82 · argos/tasks/… · ../pinakes/…) cannot be met from this
                     #   worktree — warns in `chief gen`, fails `chief lint`, and stops a run as
                     #   UNSATISFIABLE before the first agent turn unless "crossRepo" declares it
  deps.sh            #   DEPENDENCY RESOLUTION, extracted from driver.sh so there is exactly ONE
                     #   answer to "is this tasklist's dependsOn satisfied": deps_of · dep_record ·
                     #   is_recorded_done · the cross-repo <repo>:<stem> resolution. Functions over
                     #   four globals the CALLER owns ($REPO/$TASKS_REL/$SRC/$COMPLETED — deps_scope
                     #   sets them per repo); it establishes no environment of its own. driver.sh
                     #   sources it to decide what to LAUNCH, status.sh to decide what to REPORT
  status.sh          #   `chief status` — what is LEFT and what can START NOW. The scheduler's gate
                     #   run in REPORT mode: remaining (live/parked), runnable vs blocked, completed
                     #   counted separately as history. Runnable means what it means to the driver,
                     #   because it IS deps.sh — a private copy would drift and then name work as
                     #   startable that a run would refuse to start. Degrades on malformed input into
                     #   a `problems` section rather than aborting, and always exits 0.
                     #   SCOPE is resolved WITHOUT load_project (whose hard exit is right for `run`
                     #   and wrong for a report): inside a repo -> that repo; above several -> a
                     #   depth-limited WALK of the tree, unioned with the registry entries under it;
                     #   --all -> the registry. A repo is one whose ROOT the walk finds, so a nested
                     #   tasks/chief (examples/minimal) is never a second backlog; walk and registry
                     #   are reconciled by RESOLVED ABSOLUTE PATH so a symlink or trailing slash
                     #   cannot mint a phantom; worktrees, ignore-listed subtrees ($CHIEF_PREFIX/
                     #   ignore) and stale registry entries are REPORTED, never silently dropped —
                     #   a repo missing from a total reads exactly like a repo with no work.
                     #   CATEGORIES are REPORTED, never adopted: `category` is an OPAQUE
                     #   string chief holds no vocabulary for. A project declares its own
                     #   ordering (CHIEF_CATEGORIES in .chief/config, READ AS A LINE — a
                     #   portfolio report must not SOURCE N repos' bash); without one rows
                     #   order by count and no ordering is claimed. Plain status always
                     #   exits 0 — only the opt-in --enforce-order can fail, and only on
                     #   the project's OWN declared rule. TWO RENDERS, ONE SCAN: --json
                     #   emits the whole report as one document on stdout with every note
                     #   on stderr (`chief events`' discipline), serializing the same
                     #   accumulators rather than re-counting. --blocked also aggregates
                     #   by EDGE — holds / releases / cascade, three numbers kept apart,
                     #   ranked highest first — because "82 blocked" is a number and
                     #   "these merges release 82" is a plan. Reads one jq per DIRECTORY,
                     #   not per record: 1,040 records went 2,576 forks and 23s -> 32 and
                     #   2s (test/status-perf.sh asserts the FORK count as well as the
                     #   clock, and is out of the merge gate like monitor.sh because only
                     #   the clock half is load-sensitive). A PARK carries a REASON on the
                     #   same terms: "parked":true is what the SCHEDULER reads and is
                     #   untouched, "parkedReason" is the string a person needs, and it is
                     #   never mandatory. One reader serves both declarations
                     #   (config_list · reconcile_decls · breakdown_rows), so
                     #   CHIEF_PARK_REASONS behaves exactly as CHIEF_CATEGORIES does —
                     #   including that entries are TOKENS, so a multi-word reason is
                     #   reportable but not declarable. A reason with no flag is a park
                     #   that never happened: it is LIVE, and named in `problems`. And the
                     #   park is reported where it is MET — naming a parked tasklist in
                     #   `chief run` prints its reason and schedules nothing (`--parked`
                     #   runs it anyway; that override used to be the silent default), and
                     #   a bare run in an all-parked repo names the parks rather than
                     #   reporting that everything is complete
  measure.sh         #   the BAR rule on acceptance criteria: a story claiming a checkable bar
                     #   ("green" · "exit 0" · "the baseline to beat is 77 failed") must record the
                     #   value it OBSERVED in `notes`, or it ends `unverified` — not passing, not
                     #   silently ignored. Chief requires the measurement; it never judges it.
                     #   That stop OUTLIVES its run: `$SNAP/<name>.unverified.md` is the
                     #   verify-failed log's twin, and the resume reads it as a THIRD re-engage
                     #   arm — an all-pass branch carrying one is not finished, so the agent is
                     #   engaged with the demoted stories back at passes:false and the report in
                     #   its prompt. Cleared at both merge sites, or a finished tasklist would
                     #   buy a wasted agent turn on every future resume
  research.sh        #   the RESEARCH PHASE contract: the four required sections of the per-tasklist
                     #   research document, its validator, and the sub-agent structured-output prompt.
                     #   Runs ONCE per tasklist before the first story (opt-in: "research":true /
                     #   CHIEF_RESEARCH=1); the document is persisted, human-editable and reused, never
                     #   regenerated. agent.sh dispatches it; a failure is exit 6 -> RESEARCH-FAILED
  mergequeue.sh      #   the OPT-IN batch merge queue: stack N merge-ready branches on the base and
                     #   verify the batch TIP ONCE instead of paying the gate N times. OFF by default
                     #   (`chief run --merge-batch[=N]` / CHIEF_MERGE_BATCH) — the serialized
                     #   rebase -> re-verify -> --no-ff floor stays the correctness guarantee, and a
                     #   batch of one IS that floor. A red tip names no culprit, so it is BISECTED
                     #   (binary search over the stacked prefixes -> confirm the suspect ALONE on the
                     #   base -> blame it VERIFY-FAILED, merge the proven-green prefix, re-form a
                     #   batch from the survivors). A confirming run that DISAGREES with the bisect —
                     #   flaky gate, or a joint failure — abandons it: every branch is restored to
                     #   the sha its worker finished on and re-run serially. Bisect assumes the gate
                     #   is a deterministic function of the tree; CHIEF_MERGE_BATCH_BISECT=0 opts out
  concurrency.sh     #   the HOST-WIDE machine view: a READER over the same run registry `chief ps`
                     #   uses, owning no lock, daemon or second state store. A driver pid is the
                     #   authority for whether a record is live; the tasklist live records then say
                     #   whether that driver is spending an AGENT TURN or running a GATE — two
                     #   budgets, because they cost different things. Sets globals rather than
                     #   printing: every display line here is a `$( )`, and a global written inside
                     #   one is lost, so `render` and the driver's banner sample the load ONCE in
                     #   the parent before anything reads
  budget.sh          #   the DIFF-SIZE BUDGET: how large one STORY's change was allowed to get,
                     #   measured on the branch about to merge. The other half of zones.sh's
                     #   finding — change size is the lever an orchestrator actually controls.
                     #   WARNS by default and blocks only on request, because a rename sweep, a
                     #   codemod and a real refactor are all legitimately big and a gate that
                     #   stops them is a gate that gets turned off
  zones.sh           #   the OVERLAP ZONE REGISTRY, a policy layer ABOVE the merge floor. The floor
                     #   catches TEXTUAL interference (rebase conflict) and staleness (verify
                     #   failure); it says nothing about two branches whose DESIGNS disagree — both
                     #   rebase clean, both verify green, the result is still wrong. No automated
                     #   gate detects that, so a declared domain holds the branch for `chief approve`
  resolution.sh      #   WHAT A CONFLICT RESOLUTION DELETED — the third shape, and the one the
                     #   floor is blind to BY CONSTRUCTION. The floor catches textual
                     #   interference and staleness; it never compares what a rebase REMOVED
                     #   against what landed on the base while the branch was in flight. Measured
                     #   downstream: an 8-day-stale branch conflicted, the resolution kept the
                     #   BRANCH's copy of two whole files, and seven merged tasklists' work went
                     #   with them (registered commands 68 -> 44). Every gate was green because a
                     #   deleted test cannot fail and an undeclared module is not compiled. Chief
                     #   still never resolves a conflict itself — it HANDS OFF, in integrate_base's
                     #   conflict arm and in conflict_report's runbook, and the branch comes back
                     #   ALREADY rebased, so the floor's own rebase takes the "strictly ahead"
                     #   no-op arm and never sees it. Nothing chief kept could answer the question
                     #   afterwards (the base sha at `worktree add` is written nowhere;
                     #   `.integrated-base` is a THROTTLE key inside the worktree run_worker
                     #   deletes; `pre_mb` is read AFTER the agent rebased; the reflog is not
                     #   chief's to rely on), so the (fork, pre-rebase tip) pair is RECORDED at
                     #   each handoff — under $STATE, plus a PIN REF, because after the rebase
                     #   those commits are unreachable and gc's to take. A line is a deletion when
                     #   the post-rebase diff removes it, the pre-rebase diff did NOT, the base has
                     #   it, and the tip no longer does — the fourth clause settles the MOVE edge
                     #   for free. Removals are NET of re-adds: a file whose last line lacked a
                     #   trailing newline has that line rewritten by any append, and counting the
                     #   removal half alone flags it everywhere. The post-resolution-commit edge is
                     #   excluded PRECISELY — a rebase preserves author date/author/subject, so the
                     #   window ends at the newest REPLAYED commit and the story the agent went on
                     #   to implement is out of scope. Binary and renamed paths are UNCHECKED, never
                     #   silently clean. It sees deleted LINES, not broken meaning
  review.sh          #   the HUMAN half of the plan checkpoint (docs/plan-review.md): a person reads
                     #   the plan artifact and only an APPROVED plan reaches implementation. The
                     #   review SURFACE is adopted, not built (plannotator's one-shot approval gate),
                     #   and an approval is bound by checksum to the plan it approved
  terminal.sh        #   A STORY WHOSE CORRECT ANSWER IS `false`. Chief had one notion of done —
                     #   every story passes:true — so a story whose honest measured result is
                     #   NEGATIVE made its tasklist permanently uncompletable. `terminalFalse` is
                     #   the hand-authored declaration that a negative finding IS the deliverable
  repeat.sh          #   the SAFETY NET for terminal.sh's declaration, because the tasklist that
                     #   needs it is exactly the one nobody thought to write it on: a story
                     #   recording the SAME outcome at REPEAT_LIMIT consecutive iteration
                     #   boundaries stops as CANNOT-COMPLETE. Invisible to the stall counter,
                     #   which is the whole reason it is its own module — commits landed on every
                     #   one of those iterations
  retire.sh          #   RETIRING A TASKLIST WHOSE ANSWER WAS NO (`chief retire --negative`), the
                     #   command the 59-iteration incident had nowhere to land: delivered stories
                     #   passed, the remaining one terminated false and carries its measurement.
                     #   REFUSES a tasklist that is merely unfinished, and one live tasklists still
                     #   depend on — a record with no mergedToMain satisfies no dependency edge
  quality.sh         #   DETERMINISTIC code-quality metrics and the RATCHET over them (`chief
                     #   quality`), the merge gate's second axis: verify.sh answers only "did the
                     #   gates exit 0", and the maintainability damage shows up in weeks. Every
                     #   number is awk over text — NO model judgment, and no hidden zeroes
  cigate.sh          #   A GATE THAT DID NOT RUN IS NOT A GATE THAT PASSED (`chief cigate`).
                     #   Measured across this portfolio 2026-08-25: every private repo's CI was
                     #   dead and all three failures were byte-identical billing refusals, not code.
                     #   Three states — RAN AND PASSED · RAN AND FAILED · DID NOT RUN — and the
                     #   third is the one a green-or-red vocabulary cannot say
  preset.sh          #   named run PRESETS: one switch resolving to a full provider · model ·
                     #   endpoint bundle over the EXISTING provider seam, so the dry-run line, ps,
                     #   monitor and the events keep reporting the plain resolved provider·model.
                     #   A preset is NOT a provider, which is why endpoint/credential wiring lives
                     #   here and never in a new dispatch case
  gen.sh             #   ROADMAP → TASKLISTS (`chief gen`): one schema-valid tasks/chief/NN-slug.json
                     #   per roadmap item. The operation an EMBEDDING HOST calls to author tasklists
                     #   programmatically, so its INPUT SHAPE IS A PUBLISHED CONTRACT
                     #   (docs/reference/roadmap-input.md), not an internal detail
  instructions.md    #   the generic agent loop injected into every story turn; plan-instructions.md
                     #   is the same for a PLAN turn. Prose, not code — but templates/agent-context.md
                     #   QUOTES these headings verbatim while explaining them, so a behavioural test
                     #   must never assert on a heading that appears in both
  live.sh            #   per-tasklist liveliness record (iteration · story · phase · last activity), read by ps/monitor
  events.sh          #   append-only NDJSON event stream ($CHIEF_RUNS/<run-id>.events.jsonl) — a projection
                     #   of the transitions above, for chief-cloud + embedding hosts to subscribe to
  sweep.sh           #   the DISK half of reaping: what chief CAUSED TO BE BUILT inside a worktree
                     #   goes with the worktree. A TABLE of toolchain artifact dirs (target/ ·
                     #   node_modules/ · .venv/ · build/) — adding a toolchain is a row. Runs
                     #   immediately before every worktree removal, because removal is best-effort
                     #   at every site and a removal that loses is how a finished run strands
                     #   gigabytes. `chief_sweep_candidate ROOT WT PATH` is a PURE function of
                     #   three paths and the whole safety argument: a shared CARGO_TARGET_DIR, a
                     #   symlink, a sibling worktree, a `..` escape are all REFUSED with a stated
                     #   reason, never followed. Bytes reclaimed are reported per worktree and
                     #   totalled in the run summary. `chief_sweep_disk` is the same thing for
                     #   the DEBT already on the fleet — every worktree with no live run behind
                     #   it — and takes the liveness predicate as a FUNCTION NAME, because that
                     #   rule is reap.sh's (registry + process table) while the rm is this
                     #   module's. Liveness AND an idle-age floor, so a run between iterations
                     #   is safe; an unanswerable mtime reads as "leave it alone", never as old.
                     #   CHIEF_SWEEP=0 opts out
  reap.sh            #   find + reap ORPHANED chief processes, in TWO KINDS reported separately
                     #   because they cost different things to end: agent WORK (a process tree with
                     #   no live, registered run behind it) and an abandoned VIEW (a `chief monitor`
                     #   watcher that outlived its terminal). A view matches NONE of the work keys
                     #   — no run marker, no inherited id, a cwd wherever the operator stood — so
                     #   the sweep reported "no orphaned chief processes" with nine of them running.
                     #   It gets its OWN key (chief's `monitor.sh watch` argv, re-parented to PID 1),
                     #   is never narrowed by --scope (it belongs to no run) and never consults the
                     #   registry; a watcher whose parent is still alive is not touched by EITHER
                     #   half, which is also new — the cwd key used to claim one started inside a
                     #   worktree. PID 1 that is not a system init DECLINES rather than guesses.
                     #   Also the PID-NAMESPACE token every pid-keyed record carries, so a shared prefix
                     #   across containers is never read as "that pid is dead". `chief reap` runs the
                     #   DISK pass too (--no-disk / --disk-only / --disk-age), under the same
                     #   foreign-registry refusal — misreading a live run there deletes a build
  ledger.sh          #   KEY 4: the DESCENDANT LEDGER, and the only key that is a RECORD rather
                     #   than a SEARCH. Keys 1-3 ask the process table (cwd · argv · inherited
                     #   $CHIEF_RUN_ID), and the shape key 3 exists for — chdir'd OUT of the
                     #   worktree AND wearing a boring argv — is unanswerable on macOS, where
                     #   SIP accepts `ps -E` and prints no environment. So key 3 is INERT here
                     #   and that shape had no key at all: found in the field 2026-09-11,
                     #   `UnrealEditor-Cmd -unattended` from a downstream tasklist's run, PPID 1, 78
                     #   minutes old, 199% CPU, ignoring SIGTERM. A PPID walk cannot reach it
                     #   either — re-parented to launchd, there is no edge back to chief — so
                     #   the tree is recorded WHILE IT IS STILL CONNECTED: the driver writes
                     #   $CHIEF_RUNS/<pid>.ledger (pid · start time · command per descendant)
                     #   once per scheduler poll, and a still-live pid in a DEAD run's ledger is
                     #   a candidate whatever its cwd, argv and environment now say. PID REUSE
                     #   is the failure to refuse, so an entry whose pid is alive with a
                     #   DIFFERENT start time is reported LEFT ALONE and never signalled — and
                     #   both sides of that comparison go through ONE function
                     #   (chief_ledger_starttime), because a second reader spelling the token
                     #   differently does not degrade, it INVERTS. The bound is the cadence:
                     #   what is spawned, orphaned AND abandoned inside one poll was never
                     #   recorded. EARNED, not inherited — it holds what the driver's own tree
                     #   held, so it needs none of key 3's three gates. The snapshot must not
                     #   record ITSELF: `$(ps …)` is captured to a variable and a `kill -0`
                     #   builtin drops the two processes that took it, or every ledger would
                     #   name them and none could be read as what the run was doing
templates/           # scaffolded into a repo by `chief init` (config · verify.sh · agent-context.md · tasklist.example.json · quality.conf · zones.conf)
tasks/chief/         # THIS repo's own tasklists (self-hosting), ordered by numeric band
  completed/         #   merged tasklists (each stamped mergedToMain)
test/*.sh            # hermetic behavioral suite (fake claude on PATH; needs git + jq)
                     #   bystander.sh — runs the behavioural block with a decoy run from ANOTHER
                     #   install alive, and fails the test that signals it (hermetic in STATE is
                     #   not hermetic in PROCESSES); it IS verify.sh's behavioural block
                     #   monitor-orphan.sh — the abandoned VIEW, both halves against a real
                     #   watcher: it self-exits when its terminal dies, and while it is still
                     #   alive `chief reap` reports it under [view] and never as agent work.
                     #   REPRODUCES first — it neuters watch_should_stop in a copy of the
                     #   engine (not `git show HEAD~N`: CI clones shallow) and asserts THAT
                     #   watcher survives, so the file cannot pass by restating behaviour that
                     #   always worked. In all.sh + CI but NOT the merge gate, like monitor.sh:
                     #   it asserts on refresh intervals and verify runs under parallel load
                     #   verify-cache.sh — the AGENT BOUNDARY's half of the verdict cache
                     #   (_agent_verify_final's verify_cache_try), driving engine/agent.sh
                     #   DIRECTLY against a scratch repo — no driver, one second, and the
                     #   assertion is the number of times the HOOK ITSELF executed, never a
                     #   log line. Its hook lives OUTSIDE the repo (via $CHIEF_VERIFY_HOOK)
                     #   so the `tree.base.hook.subs` key's components can be moved one at a
                     #   time. REPRODUCES first, like monitor-orphan.sh
                     #   doc-claims.sh — engine/claims.sh against the incident it exists
                     #   for: koine's document claiming an agora path is ABSENT, an agora
                     #   tree where it EXISTS, and the assertion that the report names the
                     #   DOCUMENT and the PATH. Half the file is NEGATIVE CONTROL, because
                     #   this checker runs against repos that legitimately drift — a claim
                     #   that still holds prints nothing AND the count sentence proves it
                     #   was read, an unresolvable repo stays a `?`, and "no registry costs
                     #   nothing" is measured as jq INVOCATIONS under a shimmed jq (the
                     #   with-registry probe runs first, or the counter could be dead)
                     #   merge-checkout.sh — the BASE CHECKOUT half of the merge, both
                     #   claims, deterministically: a `git` shim holds a real
                     #   .git/index.lock across `checkout <base>`. Held for ONE attempt,
                     #   work_checkout retries and the tasklist merges (the flake);
                     #   held for every attempt, the tasklist ends CHECKOUT-FAILED with
                     #   no merge commit, no completed/ record and NO retire commit
                     #   stranded on the branch. MUTATION-CHECKED both ways — on the
                     #   unfixed engine both parts report `MERGED @<branch tip>`
                     #   reap-escaped.sh — the FIELD shape, built: a descendant that leaves
                     #   the worktree, execs a boring argv, ignores TERM and is re-parented
                     #   to PID 1 when its driver is SIGKILLed with the run file still
                     #   reading `running`. It asks the FOUR keys one at a time and PRINTS
                     #   each answer, so the log records which key saw it on which platform
                     #   instead of inferring either — and it is SKIPPED NOWHERE, a skip
                     #   being how the hole stayed invisible for as long as it did. It
                     #   records its tree by calling the engine's own
                     #   chief_ledger_snapshot, not by hand-writing a file, so it cannot
                     #   pass against a format only the test knows how to produce; a
                     #   sibling that STAYS in the worktree is the positive control, so "the
                     #   escapee was not named" can never read as "the sweep never ran".
                     #   PART B plants the entry the start-time check exists for — alive pid,
                     #   wrong start time — and pins that it is REPORTED and LEFT ALONE
docs/                # Diataxis, per the ecosystem documentation standard, and docs/README.md is
                     # the map: A DOCUMENT NOT LINKED THERE DOES NOT EXIST. guides/ (containers ·
                     # headless-invocation · local-inference-preset · monitoring · providers) ·
                     # reference/ (tasklist-schema · roadmap-input · status · verify-hook · events ·
                     # concurrency · cross-repo-dependencies · decision-tasklists · diff-budget ·
                     # overlap-zones · provider-unavailability · account-credentials · usage) ·
                     # explanation/ (drivers-and-safety = the parallel-safety model · dead-code-audit) ·
                     # decisions/ (immutable; superseded by a successor, never edited in place).
                     # research-phase.md and plan-review.md (the two opt-in review checkpoints) sit at
                     # the docs/ ROOT as a declared exception — they are cited by bare path from ~30
                     # places in bin/ and engine/, so moving them is an engine change that would owe a
                     # VERSION bump no engine consumer could act on. The reasoning is written down in
                     # docs/README.md rather than left for a reader to wonder about
.chief/              # created by `chief init`: config · verify.sh · agent-context.md · quality.conf · state/ (gitignored)
VERSION              # engine version — bump on any engine/bin/install change
```

## Conventions & invariants

- **Tasklists:** `tasks/chief/NN-slug.json`, ordered by numeric band. `branchName` is `chief/NN-slug`;
  `dependsOn` names the numbered stem (cross-repo: `repo:stem`); `touches` lists conflict domains the
  parallel scheduler serializes on. A finished tasklist moves to `tasks/chief/completed/` with a
  `mergedToMain` field. **A `completed/` record means it merged — verify the actual code/submodule
  changes, not just the `passes` flags** (a doc-only merge that flipped every flag built nothing).
- **One story per iteration; keep `main` green.** The engine merges with `--no-ff` only after a clean
  rebase + a green `verify.sh`; a non-zero verify leaves the branch as `VERIFY-FAILED` for re-engagement.
- **Durable per-tasklist state lives OUTSIDE the worktree.** `run_worker` does `rm -rf "$wt"` at the
  top of every run, so anything written only under `$wt/.chief/state/` is rebuilt by each resumed run.
  The working shape: the driver owns an absolute path under `$STATE_ROOT`, hands it down as an env var
  (`CHIEF_PAUSE_FILE`, `CHIEF_RESEARCH_FILE`, `CHIEF_PRD_SNAPSHOT`), and `agent.sh` seeds FROM it and
  promotes back TO it the moment the artifact is valid — not at the end of the loop, or a mid-run death
  loses it. **For a `repo:<sub>` tasklist that snapshot IS the per-story record** — its tasklist is in the
  parent and its work branch in the submodule, so neither side commits "2 of 3" and only
  `.chief/state/snapshots/<name>.json` can answer it on a resume (`prd_state_source` in `driver.sh`).
  **Operator-authored state may not live in the tasklist JSON at all**, in either form: uncommitted, the
  reconcile step's `git checkout -- "$TASKS_REL/$name.json"` (the ISOLATION GUARD, which exists to undo an
  agent that reached out of its worktree) silently discards it before any arm reads it; committed on the
  base, it collides at rebase with the branch's own edit to that same file — the pass-flags — and ends the
  tasklist in REBASE-CONFLICT. Gitignored state under `$STATE_ROOT` is invisible to both (`engine/decision.sh`).
  Relatedly, a
  new `agent.sh` exit code needs its `run_worker` arm placed **above** the EMPTY-NO-WORK guard whenever
  that stop can legitimately leave zero commits (as 2, 3, 4, 5 and 6 all can). Exit codes are a
  **contended namespace** across parallel tasklists — grep `AGENT_RC_` in `driver.sh` *and* agent.sh's
  exit-code header before claiming one, and expect to renumber after a rebase.
- **A `docs/…​.md` path in a shell comment is a link the merge gate checks.**
  `scripts/check-doc-links.mjs` scans every *tracked* file (its `BARE_DOC` regex, not just `.md`) and
  `.chief/verify.sh` runs it as a ratchet, so pointing at a doc a later story will write is a new dead
  link that blocks the merge. Reference the module, not the doc that doesn't exist yet.
- **A new `test/*.sh` is a gate only when it is in THREE lists**: `.chief/verify.sh`'s
  `CHIEF_BYSTANDER_TESTS` (the merge gate), `test/all.sh`'s `BASH_SUITE`, and
  `.github/workflows/ci.yml`. Nothing derives one from another. Relatedly, a behavioural
  test must not assert on prompt text that a **doc quotes** — `templates/agent-context.md`
  quotes the engine's injected headings verbatim while explaining them, so grepping a
  prompt for one matches even when nothing was injected. Assert on a string only the
  engine emits, plus a marker your own fixture planted.
- **"The gate ran N times" is a RACY assertion, and the verify CACHE is why.**
  `verify_cache_try` (`engine/lib.sh`) serves a merge-phase verify from the verdict the
  AGENT boundary already recorded whenever tree + base + hook are unchanged — which for
  the first branch to reach the merge lock is the normal case, since its rebase is a
  no-op ("strictly ahead of main"). So a parallel test counting gate invocations gets a
  different number depending on who won the lock. The gate was still PAID; it ran in the
  WORKTREE (`_agent_verify_final` → `run_verify "$CHIEF_PROJECT"`) rather than at the
  repo root, so a fixture hook keyed off `$PWD` files it somewhere the assertion never
  reads, and "did not run" is indistinguishable from "ran out of view". Pin the count to
  the reading the branch's own log reports (`verify SKIPPED …` vs a fresh hook run) —
  never widen it to a range, which also passes when the floor was never reached at all
  (`test/merge-batch.sh` PART C; PART A is the same trap, caught earlier).
- **The verdict cache key names every input the GATE READS — four of them.**
  `verify_cache_try`/`verify_cache_record` (`engine/lib.sh`) key on
  `tree.base.hook.subs`, and a record is reused for **any** status: identical tree,
  base, hook and submodule checkout is the same computation, so a RED verdict is
  short-circuited exactly as a green one is (with the gate's own output replayed from
  `<key>.out`). The fourth component exists because chief itself moves it — a project
  worktree never initializes its submodules, so the AGENT BOUNDARY runs the hook with
  a submodule directory that is EMPTY while the MERGE PHASE runs `submodules_sync`
  first and runs the same hook over the same tree against a synced one. Same tree sha,
  different filesystem, different answer (`test/submodule-gitlink.sh`). Generally:
  **anything chief mutates between a record and its reuse belongs in the key**, and
  the tree sha is not a proxy for the filesystem the hook actually tests. The reuse
  rests on the hook being a DETERMINISTIC function of those four inputs, which chief
  cannot check from the outside — both runs are just a status — so
  **`CHIEF_VERIFY_CACHE=0`** is the operator's word for "this gate is flaky": every
  lookup declines, the gate runs, and its fresh verdict REPLACES the record
  (`docs/reference/verify-hook.md`). `chief verify` never reads the cache at all, so
  it remains the way to re-earn ONE verdict without changing a whole run.
- **The driver RE-SEEDS `.chief/state/progress.txt` at run start** — fresh header, plus a
  `⚠️ PRIOR VERIFICATION FAILED` block when the last merge attempt came back red. That
  file and `.chief/state/prd.json` are the two TRACKED exceptions to the gitignored
  `.chief/state/`, so committing the re-seeded copy as found DELETES every earlier note
  from the tree. Restore `git show HEAD:.chief/state/progress.txt` first, then append —
  the log is append-only by contract and the re-seed does not know that.
- **A backtick in an unquoted heredoc RUNS.** Every usage/help block in the engine is a
  `cat <<EOF` (it interpolates `$VERSION`, `${CHIEF_REAP_GRACE:-5}`, `$CHIEF_WT_ROOT_ALL`), and
  chief's prose is full of `` `chief monitor` ``-style backticks. Unescaped, that is command
  substitution: writing `` `chief monitor` `` into `chief_reap_usage` made `chief reap --help`
  start a watcher and hang forever. `bash -n` is clean on it, no test renders `--help`, and the
  hang looks like a slow scan — escape them `\`` (as `bin/chief`'s own usage already does), and
  check with `awk '/^name\(\)/,/^EOF$/' file | grep -n '[^\\]`'`.
- **`IFS=$'\t' read` COLLAPSES a run of tabs.** Tab is IFS *whitespace*, so consecutive tabs are
  one delimiter and leading ones are stripped — any **empty middle field** (a tasklist with no
  category, one with no dependencies) silently shifts every field after it left. The engine's TSV
  accumulators get away with tabs only because none of their fields is ever empty; a reader whose
  fields can be empty uses **US (`printf '\037'`)**, which is not whitespace, and `read` keeps the
  empties (`engine/status.sh`'s `read_records`). Relatedly, `read -r -d '' V <<EOF` strips leading
  whitespace and *keeps* the final newline: `IFS= read -r -d ''` plus `V="${V%$'\n'}"` before
  comparing against a `$( )` capture.
- **The quality RATCHET is a merge gate, and it reads the WORKING TREE.**
  `bash engine/quality.sh ratchet` answers in seconds what the full `.chief/verify.sh`
  takes ~10 minutes to tell you, and it needs no commit — run it the moment a change
  grows a function or adds a helper. `function_length_max` counts **raw line span**,
  comments and blanks included, so in a codebase commented like this one a well-argued
  addition to a long function is what trips it; the fix is to move the block somewhere
  it belongs (`unmeasured_stop` lives in `engine/measure.sh`, not in the driver arm that
  calls it), never to strip the comments. `single_use_functions` counts helpers with
  exactly one call site, so extracting *and* deduplicating in one pass is the move that
  satisfies both metrics at once.
- **`live_set` DROPS keys it does not know, silently** (`engine/live.sh`, `# ignore
  unknown keys`). Adding a field to the liveliness record is **three** edits, not one:
  `LIVE_FIELDS`, `LIVE_NUMERIC` if it is a number, and the hand-written `local _lv_*`
  list inside `live_set` (explicit so per-field scratch vars stay out of the caller's
  globals — driver.sh and agent.sh both source the file). Miss one and the write looks
  perfectly healthy and lands nothing. Relatedly, `stories()` and `live_prog` in
  `engine/monitor.sh` render the SAME progress number from two different sources; a
  change to one is a change to both, or which reader a caller happens to reach decides
  what the operator sees.
- **A failed `git checkout <base>` is a merge that SUCCEEDS.** The merge phase ends
  `work_checkout <base>` then `git merge --no-ff <branch>`. If the checkout fails, HEAD
  is still on the BRANCH, and merging a branch into itself prints `Already up to date.`
  and exits **zero** — so an unguarded call site records `MERGED @<branch tip>` and
  `finalize_merged` writes the completed record and the retire commit onto the FEATURE
  BRANCH, while the base never moves and `completed/` stays empty. The branch checkout
  was guarded from the start and the base one was not; that asymmetry is the bug, and
  `work_checkout_or_stop` (driver.sh) is now both. The cause of the failure is the
  SHARED project index: sibling workers mutate it from the reconcile step's isolation
  guard and from `finalize_merged` (both take `idx_lock`), and a checkout that loses
  that race dies `Unable to create '.git/index.lock'` and rc 128 — transiently, which
  is why `work_checkout` now retries (`CHIEF_CHECKOUT_RETRIES`, default 3). An
  `idx_lock` around it would not be enough on its own: git processes chief does not own
  contend for the same file, and holding chief's lock across a rebase and a ten-minute
  verify is not an option. Generally: **any git command whose no-op case exits 0 needs
  its precondition checked, not its own exit status** (`test/merge-checkout.sh`).
- **A backtick cannot START a YAML plain scalar, and `.github/workflows/ci.yml` is
  full of prose.** `` ` `` is a RESERVED indicator in YAML, so `- name: ` followed by
  `` `chief status` agrees with the scheduler `` makes the whole workflow unparseable
  — and GitHub does not report that as a failing job. It reports a run of THE FILE
  (name `.github/workflows/ci.yml` rather than the workflow `ci`) with **zero jobs**,
  which reads exactly like an ordinary red CI. It stood that way from 2026-08-25 to
  2026-09-03 (run `33047688561`, `jobs = []`). Quote any step name that begins with a
  backtick, and check the file after ANY edit with
  `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"` —
  ci.yml is the third of the three gate lists and is the only one that **nothing
  local checks**. `bash -n` sees nothing here, exactly as it sees nothing in the
  heredoc case below.
- **A jq comment is `#`, never `//`.** `//` is jq's ALTERNATIVE operator, so a line of prose
  after one inside a `jq -n '…'` program parses as an expression and silently replaces the
  field it follows — valid jq, wrong document, and `bash -n` sees nothing. The JSONC in
  `docs/` uses `//` because it is documentation; the programs in `engine/` may not.
- **`LC_ALL=C` any `awk`/`grep` that parses agent-authored prose.** BSD `awk` (macOS) aborts with
  "illegal byte sequence" as soon as `tolower()`/`substr()` meets a multi-byte character in a UTF-8
  locale — and everything the agent writes here is full of em-dashes. Byte semantics cost nothing when
  the tokens being matched are ASCII.
- **Verify is the quality bar** (`docs/reference/verify-hook.md`): exit 0 allows the merge, non-zero blocks it,
  cwd is the repo root with the finished branch checked out, and the hook **must stay executable**.
  `NO_VERIFY=1` skips it (don't); `STRICT_VERIFY=1` blocks on pre-existing issues too.
- **Self-run:** after `chief init`, drive chief on chief from the repo root — `bin/chief run -n` prints
  the schedule (dry run), `bin/chief run` executes sequentially, `-p N` runs N tasklists in parallel
  (worktree-isolated), `--no-merge` completes without merging. `chief ps` / `chief monitor` watch live
  runs across every repo on the host.
