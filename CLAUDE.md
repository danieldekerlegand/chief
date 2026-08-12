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
  (`engine/gen.sh`, `chief gen` — input contract in `docs/roadmap-input.md`).
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
| Tasklists (`tasks/chief/*.json`) | valid JSON (`jq -e .`); `branchName == chief/NN-slug`; `mergedToMain:false` until merged |

Notes: `shellcheck` is enforced in CI (`.github/workflows/ci.yml`) and skipped locally if absent —
install it for parity. The behavioral subset is hermetic (a scripted fake `claude` on `PATH`, temp
prefixes — it never touches your real `~/.chief`); set `CHIEF_VERIFY_TESTS=0` to skip it while
iterating. `monitor.sh` is intentionally out of the auto-gate (timing-sensitive under parallel load)
but stays in CI and the full suite.

## Stack

Bash (engine + tests) · JSON tasklists. Tooling: `jq`, `shellcheck`.

## Layout

```
bin/chief            # CLI: init · gen <roadmap.json> · run [-p N] [-n] [--no-merge] [names…] · list · ps · monitor · logs · models · reap · pause · resume · version · update
engine/
  driver.sh          #   scheduler + per-tasklist worker: worktree → agent loop → rebase → verify → merge
  agent.sh           #   one agent iteration (implement a single story)
  monitor.sh         #   active-run registry view  (chief ps / chief monitor)
  lib.sh             #   shared helpers: run_verify / verify_branch, locks, state I/O
  live.sh            #   per-tasklist liveliness record (iteration · story · phase · last activity), read by ps/monitor
  events.sh          #   append-only NDJSON event stream ($CHIEF_RUNS/<run-id>.events.jsonl) — a projection
                     #   of the transitions above, for chief-cloud + embedding hosts to subscribe to
  reap.sh            #   find + reap ORPHANED chief process trees (agent work with no live, registered run behind it)
templates/           # scaffolded into a repo by `chief init` (config · verify.sh · agent-context.md · tasklist.example.json)
tasks/chief/         # THIS repo's own tasklists (self-hosting), ordered by numeric band
  completed/         #   merged tasklists (each stamped mergedToMain)
test/*.sh            # hermetic behavioral suite (fake claude on PATH; needs git + jq)
docs/                # tasklist schema · roadmap-input contract (chief gen) · verify-hook contract · parallel-safety model
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
- **Verify is the quality bar** (`docs/verify-hook.md`): exit 0 allows the merge, non-zero blocks it,
  cwd is the repo root with the finished branch checked out, and the hook **must stay executable**.
  `NO_VERIFY=1` skips it (don't); `STRICT_VERIFY=1` blocks on pre-existing issues too.
- **Self-run:** after `chief init`, drive chief on chief from the repo root — `bin/chief run -n` prints
  the schedule (dry run), `bin/chief run` executes sequentially, `-p N` runs N tasklists in parallel
  (worktree-isolated), `--no-merge` completes without merging. `chief ps` / `chief monitor` watch live
  runs across every repo on the host.
