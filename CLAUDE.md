# CLAUDE.md — chief (autonomous tasklist runner)

Chief is the **harness every sibling repo is built with**, not a product. A Bash engine
(`bin/chief` + `engine/*.sh`) drives an agent through **implement → verify → commit → merge**,
one user story at a time, with git-worktree-isolated parallelism. Chief is **self-hosting** — its own roadmap lives in `tasks/chief/*.json`
and is run with chief itself. The inter-repo picture is in `../CLAUDE.md`; the tasklist schema and
the parallel-safety model are in `docs/`.

## What belongs here

- The **engine** (`engine/driver.sh` scheduler+worker, `engine/agent.sh` one iteration,
  `engine/monitor.sh` run registry, `engine/lib.sh` shared helpers, `engine/live.sh` per-tasklist
  liveliness records, `engine/events.sh` the NDJSON event stream, `engine/reap.sh` orphan reaping)
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

| Area | Gate |
|---|---|
| Shell engine (`bin/chief`, `engine/*.sh`, `install.sh`, `test/*.sh`) | `bash -n` clean + `shellcheck -S error` clean; behavioral core `test/{smoke,ratelimit,noworkguard}.sh` green |
| Engine version discipline | editing `bin/`/`engine/`/`install.sh` **must** bump `VERSION` (`test/version-bump.sh`) |
| Docs vs engine (`README.md`, `VERSION`, `bin/chief`) | README's bold `**vX.Y.Z**` == `VERSION` and its command table covers every `bin/chief` subcommand (`test/doc-sync.sh`) |
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
bin/chief            # CLI: init · gen <roadmap.json> · lint · run [-p N] [-n] [--no-merge] [names…] · list · ps · monitor · logs · models · reap · pause · resume · version · update
engine/
  driver.sh          #   scheduler + per-tasklist worker: worktree → agent loop → rebase → verify → merge
  agent.sh           #   one agent iteration (implement a single story)
  monitor.sh         #   active-run registry view  (chief ps / chief monitor)
  lib.sh             #   shared helpers: run_verify / verify_branch, locks, state I/O
  paths.sh           #   host-wide state paths (prefix · runs · repos · worktree root), resolved
                     #   in one place — container-safe when $HOME is unset/read-only
  gitenv.sh          #   the git a CONTAINER hands us: safe.directory for a repo owned by another
                     #   uid ($CHIEF_GIT_SAFE_DIRECTORY), a committer identity when git can't find one
  criteria.sh        #   the SCOPE rule on acceptance criteria: a criterion naming ANOTHER repo
                     #   (argos:82 · argos/tasks/… · ../pinakes/…) cannot be met from this
                     #   worktree — warns in `chief gen`, fails `chief lint`, and stops a run as
                     #   UNSATISFIABLE before the first agent turn unless "crossRepo" declares it
  measure.sh         #   the BAR rule on acceptance criteria: a story claiming a checkable bar
                     #   ("green" · "exit 0" · "the baseline to beat is 77 failed") must record the
                     #   value it OBSERVED in `notes`, or it ends `unverified` — not passing, not
                     #   silently ignored. Chief requires the measurement; it never judges it
  research.sh        #   the RESEARCH PHASE contract: the four required sections of the per-tasklist
                     #   research document, its validator, and the sub-agent structured-output prompt.
                     #   Runs ONCE per tasklist before the first story (opt-in: "research":true /
                     #   CHIEF_RESEARCH=1); the document is persisted, human-editable and reused, never
                     #   regenerated. agent.sh dispatches it; a failure is exit 6 -> RESEARCH-FAILED
  live.sh            #   per-tasklist liveliness record (iteration · story · phase · last activity), read by ps/monitor
  events.sh          #   append-only NDJSON event stream ($CHIEF_RUNS/<run-id>.events.jsonl) — a projection
                     #   of the transitions above, for chief-cloud + embedding hosts to subscribe to
  reap.sh            #   find + reap ORPHANED chief process trees (agent work with no live, registered run behind it);
                     #   also the PID-NAMESPACE token every pid-keyed record carries, so a shared prefix
                     #   across containers is never read as "that pid is dead"
templates/           # scaffolded into a repo by `chief init` (config · verify.sh · agent-context.md · tasklist.example.json)
tasks/chief/         # THIS repo's own tasklists (self-hosting), ordered by numeric band
  completed/         #   merged tasklists (each stamped mergedToMain)
test/*.sh            # hermetic behavioral suite (fake claude on PATH; needs git + jq)
                     #   bystander.sh — runs the behavioural block with a decoy run from ANOTHER
                     #   install alive, and fails the test that signals it (hermetic in STATE is
                     #   not hermetic in PROCESSES); it IS verify.sh's behavioural block
docs/                # tasklist schema · roadmap-input contract (chief gen) · verify-hook contract · parallel-safety
                     # model · containers.md (running chief in a container/Riju workspace) ·
                     # research-phase.md + plan-review.md (the two opt-in review checkpoints)
.chief/              # created by `chief init`: config · verify.sh · agent-context.md · state/ (gitignored)
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
  (`CHIEF_PAUSE_FILE`, `CHIEF_RESEARCH_FILE`), and `agent.sh` seeds FROM it and promotes back TO it the
  moment the artifact is valid — not at the end of the loop, or a mid-run death loses it. Relatedly, a
  new `agent.sh` exit code needs its `run_worker` arm placed **above** the EMPTY-NO-WORK guard whenever
  that stop can legitimately leave zero commits (as 2, 3, 4, 5 and 6 all can). Exit codes are a
  **contended namespace** across parallel tasklists — grep `AGENT_RC_` in `driver.sh` *and* agent.sh's
  exit-code header before claiming one, and expect to renumber after a rebase.
- **A `docs/…​.md` path in a shell comment is a link the merge gate checks.**
  `scripts/check-doc-links.mjs` scans every *tracked* file (its `BARE_DOC` regex, not just `.md`) and
  `.chief/verify.sh` runs it as a ratchet, so pointing at a doc a later story will write is a new dead
  link that blocks the merge. Reference the module, not the doc that doesn't exist yet.
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
