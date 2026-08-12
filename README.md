# chief

**chief** is an autonomous **tasklist runner** for AI coding agents (Claude Code,
Devin, and OpenCode). You write a tasklist — user stories with explicit **acceptance criteria** —
and `chief` drives an agent through them one story at a time: **implement → verify
→ commit → mark done**, looping fresh agent instances until the whole tasklist is
complete, then rebasing, re-verifying, and merging the branch.

Independent tasklists run **concurrently, each in an isolated git worktree**, gated
by a dependency + conflict-domain scheduler, with a **serialized rebase → verify →
merge floor** so parallel agents can never silently corrupt the base branch. A
host-wide **monitor** (`chief ps` / `chief monitor`) shows every active run across
all your repos — which repo, which tasklists, and how far along each one is.

Runs on stock **bash 3.2+ · git · jq** (`node` optional). No build step, no daemon,
no root. State lives on the filesystem, so an interrupted run just resumes.

> Named for Chief Wiggum — Ralph's dad. It's a parallel, self-installing evolution
> of the original [Ralph](https://github.com/snarktank/ralph) loop.

---

## Contents

- [Install & update](#install--update)
- [Quickstart](#quickstart)
- [Monitoring runs](#monitoring-runs)
- [Concepts](#concepts)
- [How it fits together](#how-it-fits-together)
- [Concurrency & the safety floor](#concurrency--the-safety-floor)
- [Resuming interrupted runs](#resuming-interrupted-runs)
- [Command reference](#command-reference)
- [Docs](#docs)
- [Development](#development)
- [Status](#status)

---

## Install & update

```sh
curl -fsSL https://raw.githubusercontent.com/danieldekerlegand/chief/main/install.sh | sh
# clones the engine to ~/.chief/src and links `chief` into ~/.local/bin
export PATH="$HOME/.local/bin:$PATH"   # if it isn't already on PATH
```

The installer is idempotent — re-run it any time to update. Or from an installed
copy:

```sh
chief update                       # fast-forwards the installed checkout in place
CHIEF_VERSION=v0.4.1 chief update  # pin a specific tag/branch
```

Installer environment overrides: `CHIEF_REPO`, `CHIEF_VERSION` (branch/tag),
`CHIEF_PREFIX` (default `~/.chief`), `CHIEF_BINDIR` (default `~/.local/bin`).

**Dependencies:** `git` and `jq` are required; `node` is used opportunistically
(there's a `jq` fallback for everything). `claude` (Claude Code), `devin`, or
`opencode` provides the actual agent.

## Quickstart

```sh
cd your-repo
chief init                     # scaffolds .chief/ + tasks/chief/ (+ gitignores runtime state)
# 1. edit .chief/config           — tool, base branch, path overrides
# 2. edit .chief/verify.sh        — your build/test/lint; exit 0 = allow the merge
# 3. edit .chief/agent-context.md — your project's quality checks + conventions
# 4. write tasklists in tasks/chief/*.json   (see docs/tasklist-schema.md)

chief list                     # tasklists + how many stories pass
chief run -n -p 3              # DRY RUN — print the schedule waves, spawn nothing
chief run                      # sequential (one tasklist at a time, still worktree-isolated)
chief run -p 3                 # up to 3 tasklists at once
chief run --devin --model opus  # use Devin with a model override
chief run --provider opencode --model opencode/glm-4.7-free
```

Claude Code remains the default provider. Use `--provider claude|devin|opencode`
(or the `--claude`, `--devin`, and `--opencode` shortcuts) and optionally
`--model MODEL`; the same settings can be persisted as `CHIEF_PROVIDER` and
`CHIEF_MODEL` in `.chief/config`. The older `CHIEF_TOOL`/`--tool` setting remains
accepted for compatibility with existing projects.

`chief init` is safe to re-run: it keeps any `.chief/` files you've already edited.

## Monitoring runs

Every real run registers in a host-wide registry (`~/.chief/runs/`), so you can
watch progress across **all** your repos from any terminal:

```sh
chief ps                 # one-shot table of active runs
chief monitor            # the same view, refreshing in place (Ctrl-C to exit)
chief monitor 5          # refresh every 5s (default 2s)
```

```text
CHIEF · 2 active run(s) · 2026-07-15 14:03:11

my-api  (pid 12345 · -p3 · claude · 12m · →main)
  /Users/me/dev/my-api
   ● auth                   running   2/4     chief/auth
       ↳ US-2 done: added refresh-token rotation
   ✓ billing                done      5/5     chief/billing
   ○ web                    pending   0/3     chief/web

web  (pid 12346 · -p2 · claude · 3m · →main)
  /Users/me/dev/web
   ● nav-redesign           running   1/3     chief/nav-redesign
```

Each tasklist shows its **state** (running / done / failed / blocked / pending),
**stories passing/total**, and **branch**; running ones also show the latest note
the agent logged. Run files are cleaned up when a driver exits and pruned on sight
if its process died. See [`docs/monitoring.md`](docs/monitoring.md).

**Monitoring here is the CLI — chief ships no desktop app.** `chief ps` /
`chief monitor` / `chief logs` are the monitoring surface, and the registry they
read is plain files anything else may read too. A desktop **GUI** (and any
cross-host, multi-machine view) is **chief-cloud**'s, the separate control plane,
whose Tauri app builds over that data — chief itself stays daemon-free and
GUI-free by design. The reasoning is written down in
[`docs/desktop-gui-decision.md`](docs/desktop-gui-decision.md).

## Concepts

- **Tasklist** — one JSON file in `tasks/chief/<name>.json`: an ordered list of
  `userStories`, each with `acceptanceCriteria` (the contract for "done"), plus
  optional scheduler fields. `<name>` is its id, used for the branch and deps. It's
  a coherent unit of work carried to completion by a chain of fresh agent turns.
- **Story loop** — for each story the agent does exactly one thing: implement it,
  verify it, commit it, flip `passes: true`. A fresh agent instance runs the next
  story, so each turn is self-contained and cheap to retry.
- **Worktree isolation** — every tasklist (even at `-p 1`) runs in its own git
  worktree with its own HEAD/index and its own gitignored `.chief/state/`. Agent
  loops never share a working tree, so they can't corrupt each other.
- **The merge floor** — a finished branch is rebased onto the latest base and
  re-verified before a **serialized**, one-at-a-time merge. Only clean, green
  branches land on the base branch.
- **verify.sh** — your project's quality gate. `chief` calls it to decide whether a
  rebased branch may merge (exit 0 = allow). This is where your real build/test/lint
  lives — see [`docs/verify-hook.md`](docs/verify-hook.md).

## How it fits together

- **Engine** (`~/.chief/src/engine/`, project-agnostic) — the driver/scheduler, the
  per-tasklist agent loop, worktree isolation, the safe merge floor, and the
  monitor. You don't edit this; `chief update` upgrades it.
- **Project config** (`<repo>/.chief/`) — the only project-specific pieces:
  - `config` — tool, base branch, path overrides (sourced as bash).
  - `verify.sh` — the hook the engine calls to verify a branch before merge.
  - `agent-context.md` — your project's checks + conventions, appended to the
    agent's generic loop instructions each turn.
- **Tasklists** (`tasks/chief/*.json`) — `userStories` + `acceptanceCriteria`, plus
  scheduler fields (`dependsOn`, `touches`, `warmup`, `parked`). Completed tasklists
  are recorded in `tasks/chief/completed/<name>.json` (all `passes:true` +
  `mergedToMain: <sha>`) and the source file is retired, so a re-run skips them.
- **Runtime state** (`<repo>/.chief/state/`, gitignored) — worktrees, per-tasklist
  status/logs, and snapshots. Safe to delete between runs.

## Concurrency & the safety floor

`-p N` sets max tasklists running at once. A pending tasklist launches only when
**all three** hold: fewer than `N` are running, every `dependsOn` entry is already
merged, and none of its `touches` conflict-domains overlaps a currently-running
tasklist.

- **dependsOn** = *ordering* — B needs A merged first.
- **touches** = *conflict domains* — A and B edit the same area, so don't co-run
  them (an optimization to avoid wasted rebase churn).

The real correctness guarantee isn't the tags — it's the **merge floor**. Before
merging, each branch is rebased onto the latest base and re-verified:

- file overlap two "disjoint" tasklists actually had → surfaces as a **rebase
  conflict** (caught; the branch is left for a human), and
- semantic staleness (B built on a base A later changed) → surfaces as a **verify
  failure** (caught).

Interference degrades to a caught failure and a wasted rebase — **never a silent
bad merge**. There's no AI auto-conflict-resolution: conflicts stop that tasklist.
Over-tagging `touches` only costs parallelism; under-tagging only costs a rebase.
Use `chief run -n` to preview the schedule waves before a real run. Full detail in
[`docs/drivers-and-safety.md`](docs/drivers-and-safety.md).

## Resuming interrupted runs

A run stopped partway — Ctrl-C, token/quota exhaustion, lost connectivity, a crash
— is safe to just re-run. On the next `chief run`:

- an existing `chief/<name>` branch is **reused**, not force-deleted: if every
  story already passes it goes straight to verify+merge; if partial, only the
  **remaining** stories run (state seeded from the branch, so finished work is
  never redone).
- the single-driver lock **auto-clears** when its owner pid is dead, and orphaned
  agent loops from the dead run are reaped.
- mid-run token/usage limits are handled inside the agent loop
  (`RATE_LIMIT_RETRY`, default on): it sleeps until the limit resets and resumes
  the same story rather than failing the tasklist.
- `RESET=1 chief run` forces a fresh branch from the base, discarding partial
  progress.

## Command reference

| Command | Purpose |
| --- | --- |
| `chief init` | Scaffold `.chief/` + `tasks/chief/` in the current repo. |
| `chief run [-p N] [names…]` | Run pending tasklists. `-p N` = concurrency (default 1). |
| `chief run --provider P --model M` | Select Claude (default), Devin, or OpenCode and optionally override its model. |
| `chief run --local` | Cost-avoidance preset: every agent turn on a LOCAL/self-hosted endpoint via OpenCode — zero API cost, materially lower coding quality, and an error rather than a paid fallback when unconfigured ([`docs/local-inference-preset.md`](docs/local-inference-preset.md)). |
| `chief run -n` | Dry run: print the schedule waves and exit (no git, no agents). |
| `chief run --no-merge` | Complete branches but don't merge into the base. |
| `chief run --headless` | Non-interactive embedding mode: no colour, a `chief: run-id=…` line, a JSON outcome summary and a documented exit-code table ([`docs/headless-invocation.md`](docs/headless-invocation.md)). |
| `chief list` | List tasklists with pass status. |
| `chief ps` | One-shot table of active runs across all repos. |
| `chief monitor [interval]` | Live-refreshing run view (default 2s; Ctrl-C to exit). |
| `chief logs [name] [-f]` | Tail a tasklist's per-iteration log from a live run (`-f` follows; `-n N` sets the tail size). |
| `chief events [id] [-f]` | Subscribe to a run's machine-readable NDJSON event stream — run/tasklist/story transitions as they happen, stdout is pure NDJSON (`-l` lists the logs on this host). The contract chief-cloud and embedding hosts read ([`docs/events.md`](docs/events.md)). |
| `chief models [provider]` | List the models you can pass to `--model` (live from devin/opencode; stable aliases for claude). |
| `chief reap [-n] [--grace N]` | Stop orphaned chief work — agent trees with no live, registered run behind them (`-n` reports only). |
| `chief pause [--all]` | Withhold agent turns — drain, never kill: in-flight iterations finish, the rest park as paused. |
| `chief resume [--all]` | Lift the pause and re-arm parked tasklists as pending for the next `chief run`. |
| `chief update` | Self-update the installed engine (`CHIEF_VERSION` pins a tag). |
| `chief version` · `chief help` | Version / usage. |

## Docs

- [`ROADMAP.md`](ROADMAP.md) — the roadmap: shipped capabilities vs. planned work.
- [`docs/tasklist-schema.md`](docs/tasklist-schema.md) — the tasklist JSON format.
- [`docs/roadmap-input.md`](docs/roadmap-input.md) — the roadmap-document contract
  `chief gen` consumes: `phases[] → items[]`, the field mapping and defaults, and a
  worked example. The programmatic way for an embedding host to author tasklists.
- [`docs/drivers-and-safety.md`](docs/drivers-and-safety.md) — sequential vs
  parallel, `dependsOn`/`touches`/`warmup`, and the safety model.
- [`docs/cross-repo-dependencies.md`](docs/cross-repo-dependencies.md) — waiting on
  a tasklist in another repo with `"<repo>:<tasklist>"`.
- [`docs/verify-hook.md`](docs/verify-hook.md) — writing `verify.sh`.
- [`docs/providers.md`](docs/providers.md) — the provider seam: the onboarding
  checklist for adding an agent CLI (one `_run_provider` case + one conformance
  fixture), the invariants a provider must satisfy, and how usage-limit detection
  depends on its output.
- [`docs/monitoring.md`](docs/monitoring.md) — `chief ps` / `chief monitor` and the
  run registry.
- [`docs/headless-invocation.md`](docs/headless-invocation.md) — embedding chief in
  a host app: `chief run --headless`, the run-id line, the exit-code table and the
  machine-readable summary.
- [`docs/containers.md`](docs/containers.md) — running chief inside a container or a
  Riju workspace: the env an embedding host sets (state prefix, worktree root, git
  `safe.directory`, committer identity), the guarantees, and what degrades.
- [`docs/events.md`](docs/events.md) — the machine-readable event stream: the NDJSON
  path, the versioned line schema, the event catalogue and `chief events`. The
  contract chief-cloud and embedding hosts subscribe to.
- [`docs/local-inference-preset.md`](docs/local-inference-preset.md) — the
  cost-avoidance mode: `chief run --local` routes every agent turn through a
  LOCAL/self-hosted endpoint at zero API cost, and what you give up for it.
- [`docs/desktop-gui-decision.md`](docs/desktop-gui-decision.md) — why monitoring is
  CLI-only here and a desktop GUI belongs to chief-cloud.
- [`examples/minimal/`](examples/minimal/) — a 3-tasklist demo you can `chief run -n`.

## Development

Offline, deterministic tests drive the real runtime with a scripted fake agent
(no network, no real AI). CI (`.github/workflows/ci.yml`) runs shellcheck +
`bash -n` + the suite on **Ubuntu and macOS** — macOS's default bash 3.2 is the
compatibility floor. The four core tests:

- `test/smoke.sh` — install → init → agent loop → verify → merge → retire.
- `test/ratelimit.sh` — token/usage-limit pause+resume survives the parallel driver.
- `test/monitor.sh` — the run registry + `chief ps` reflect a live run, then clean up.
- `test/noworkguard.sh` — a false-complete (COMPLETE + zero commits) is caught as
  `EMPTY-NO-WORK`, never merged or retired.

Beyond the core four, `test/` holds focused tests for pause/resume, liveliness,
reaping, providers, submodule handling, retry-on-failure, and more.

```sh
bash test/smoke.sh      # installs the COMMITTED state — commit engine changes first
bash test/monitor.sh
bash test/all.sh        # everything, one command: the whole bash suite
```

`test/all.sh` is the un-scoped counterpart to CI and `.chief/verify.sh` (both of
which run path-scoped subsets): a single command that proves both halves of the
tree at once.

## Status

**v0.8.0** (current version: [`VERSION`](VERSION)) — extracted from a production setup where it drives real multi-tasklist
programs, then generalized: self-installing/updating, a cross-repo run monitor,
hardened merge safety (no-work guard, verify-failure re-engagement, mid-merge
crash recovery), and offline end-to-end tests. Known limit: parallel drivers rely on the
merge floor rather than perfect conflict tags (by design — see above). The run monitor
is per host/user; runs on other machines don't appear — cross-host aggregation and a
desktop GUI are chief-cloud's, the separate control plane, not this repo's
([`docs/desktop-gui-decision.md`](docs/desktop-gui-decision.md)).

## License

Apache-2.0 — see [`LICENSE`](LICENSE).
