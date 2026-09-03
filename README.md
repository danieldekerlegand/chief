# chief

**chief** is an autonomous **tasklist runner** for AI coding agents (Claude Code,
Devin, OpenCode, and Amp). You write a tasklist — user stories with explicit **acceptance criteria** —
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
- [Working in the repo while a run is in flight](#working-in-the-repo-while-a-run-is-in-flight)
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
(there's a `jq` fallback for everything). `claude` (Claude Code), `devin`,
`opencode`, `amp`, or `codex` provides the actual agent.

## Quickstart

```sh
cd your-repo
chief init                     # scaffolds .chief/ + tasks/chief/ (+ gitignores runtime state)
# 1. edit .chief/config           — tool, base branch, path overrides
# 2. edit .chief/verify.sh        — your build/test/lint; exit 0 = allow the merge
# 3. edit .chief/agent-context.md — your project's quality checks + conventions
# 4. write tasklists in tasks/chief/*.json   (see docs/reference/tasklist-schema.md)

chief list                     # live tasklists + how many stories pass (use --all for completed)
chief run -n -p 3              # DRY RUN — print the schedule waves, spawn nothing
chief run                      # sequential (one tasklist at a time, still worktree-isolated)
chief run -p 3                 # up to 3 tasklists at once
chief run --devin --model opus  # use Devin with a model override
chief run --provider opencode --model opencode/glm-4.7-free
```

Claude Code remains the default provider. Use `--provider claude|devin|opencode|amp|codex`
(or the `--claude`, `--devin`, `--opencode`, `--amp`, and `--codex` shortcuts) and optionally
`--model MODEL`; the same settings can be persisted as `CHIEF_PROVIDER` and
`CHIEF_MODEL` in `.chief/config`. Amp has no model selector — it picks its own
model — so `--model` is refused for it rather than silently ignored
([`docs/guides/providers.md`](docs/guides/providers.md#model-overrides)). The older `CHIEF_TOOL`/`--tool` setting remains
accepted for compatibility with existing projects.

`chief init` is safe to re-run: it keeps any `.chief/` files you've already edited.

## Monitoring runs

Every real run registers in a host-wide registry (`~/.chief/runs/`), so you can
watch progress across **all** your repos from any terminal:

```sh
chief ps                 # one-shot table of active runs
chief ps --all           # active runs plus every non-done tasklist here
chief monitor            # the same view, refreshing in place (Ctrl-C to exit)
chief monitor --all      # refreshing view with every non-done tasklist here
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
if its process died. See [`docs/guides/monitoring.md`](docs/guides/monitoring.md).

**Monitoring here is the CLI — chief ships no desktop app.** `chief ps` /
`chief monitor` / `chief logs` are the monitoring surface, and the registry they
read is plain files anything else may read too. A desktop **GUI** (and any
cross-host, multi-machine view) is **chief-cloud**'s, the separate control plane,
whose Tauri app builds over that data — chief itself stays daemon-free and
GUI-free by design. The reasoning is written down in
[`docs/decisions/desktop-gui-decision.md`](docs/decisions/desktop-gui-decision.md).

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
  lives — see [`docs/reference/verify-hook.md`](docs/reference/verify-hook.md).

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

`-p N` sets max tasklists running at once within this run. A pending tasklist launches only when
**all three** hold: fewer than `N` are running, every `dependsOn` entry is already
merged, and none of its `touches` conflict-domains overlaps a currently-running
tasklist. It is additionally clamped by the host-wide machine budget, which defaults
to the detected physical core count and is shared by all registered runs. A run says
`machine budget hold` while waiting for a turn from another repo. Set
`CHIEF_MACHINE_BUDGET=0` to opt out; that choice is recorded in the run registry and
`machine-budget.log`.

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
[`docs/explanation/drivers-and-safety.md`](docs/explanation/drivers-and-safety.md).

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

## Working in the repo while a run is in flight

**Editing the repo during a run is safe for the merge.** The merge phase rebases,
re-verifies and merges in your own checkout, so before it enters that critical
section it **parks** your uncommitted tracked changes in git's own stash and gives
them back on the way out — including after a crash or a `kill -9`, which the next
`chief run` picks up and restores. `verify.sh` therefore measures the branch and
nothing else, and a replay that can't apply cleanly **drops nothing**: the stash
entry stays and the run output names the `git stash apply <sha>` that recovers it.

**Submodules are handled, not ignored.** Git leaves a submodule's working tree where
it was when a ref moves, so a branch that bumps a **gitlink** makes the checkout read
as modified — which used to refuse the merge of the very branch whose job was the
bump. Chief now syncs the stale submodules (`git submodule update`) after each
checkout in the merge path, and at startup. Uncommitted work *inside* a submodule is
untouched and still blocks, since only you can commit or stash it.

What `chief run` still checks at **startup** — a clean tree, on the base branch — is
about the *agent*, not the merge: every worktree forks from the base branch's tip, so
work you haven't committed is invisible to every tasklist in the run, and the agent
will build against a base you've already moved past. `FORCE=1 chief run` skips that
check, which is the right call when the uncommitted work is somewhere no tasklist in
the run will look.

## Command reference

| Command | Purpose |
| --- | --- |
| `chief init` | Scaffold `.chief/` + `tasks/chief/` in the current repo. |
| `chief usage [--days N] [--repo PATH|--scope PATH] [--json]` | Project usage and rate-limit history from existing event logs: per-run and total turns, available token/cost measurements, limit incidents, wait time, and reset ETA. JSON is documented in [docs/reference/usage.md](docs/reference/usage.md). |
| `chief gen <roadmap.json>` | Generate one schema-valid `tasks/chief/NN-slug.json` per roadmap item — the programmatic way to author tasklists (`-n` emits NDJSON and writes nothing; input contract: [`docs/reference/roadmap-input.md`](docs/reference/roadmap-input.md)). |
| `chief run [-p N] [names…]` | Run pending tasklists. `-p N` = within-run concurrency (default 1), additionally clamped by the host-wide machine budget (`CHIEF_MACHINE_BUDGET`, default physical-core count). |
| `chief run --provider P --model M` | Select Claude (default), Devin, OpenCode, Amp, or Codex (shortcuts: `--claude`, `--devin`, `--opencode`, `--amp`, `--codex`) and optionally override its model. Amp has no model selector, so `--model` is refused for it. |
| `chief run --local` | Cost-avoidance preset: every agent turn on a LOCAL/self-hosted endpoint via OpenCode — zero API cost, materially lower coding quality, and an error rather than a paid fallback when unconfigured ([`docs/guides/local-inference-preset.md`](docs/guides/local-inference-preset.md)). |
| `chief run -n` | Dry run: print the schedule waves and exit (no git, no agents). |
| `chief run --no-merge` | Complete branches but don't merge into the base. |
| `chief run --parked [names…]` | Run a **parked** tasklist you named. Without it, naming one prints the reason it carries (`"parkedReason"` — an opaque string chief reports and never ranks) and schedules nothing, and a bare run in an all-parked repo names the parks instead of reporting that everything is complete. Both exit 0 (`no-work` under `--headless`). Also `CHIEF_RUN_PARKED=1`. |
| `chief run --merge-batch[=N]` | **Opt-in merge queue, off by default.** Batch up to N merge-ready branches (bare flag = 4), stack them on the base and verify the batch TIP **once** instead of paying the verify gate once per branch. Merges stay `--no-ff`, one commit per tasklist, serialized against the base — only the verification is amortized. Without the flag the merge phase is the unchanged serialized floor. Also `CHIEF_MERGE_BATCH` in `.chief/config` ([`docs/explanation/drivers-and-safety.md`](docs/explanation/drivers-and-safety.md)). |
| `chief run --headless` | Non-interactive embedding mode: no colour, a `chief: run-id=…` line, a JSON outcome summary and a documented exit-code table ([`docs/guides/headless-invocation.md`](docs/guides/headless-invocation.md)). |
| `chief run --account-env FILE` | Run this run's AGENT TURNS under a designated provider account: a `KEY=VALUE` credential env file applied at the provider boundary only (`--account-label NAME` names it in `ps`/`monitor`/events; also `CHIEF_ACCOUNT_ENV_FILE`). Values never reach logs, the registry or `argv` ([`docs/reference/account-credentials.md`](docs/reference/account-credentials.md)). |
| `chief list [-a|--all]` | List live tasklists with pass status; `--all` includes completed records and flags any marker whose declared `downstreamCounterpart` has already merged. |
| `chief status [--blocked] [--all] [--json] [--enforce-order]` | What is **left** and what can **start now**: remaining tasklists (live/parked split), how many are RUNNABLE versus BLOCKED on an unmerged dependency, completed records counted separately as history, and a `problems` section for input that cannot be resolved. The runnable verdict is the **scheduler's own** (`engine/deps.sh`, the module `chief run` launches on), so the report cannot drift from the run. `--blocked` names the edge holding each one, calls out a dependency on a retired record that never carried `mergedToMain` as a **permanent** stall, and aggregates the other way round — for each unmerged edge, how many tasklists it `holds`, how many it `releases` the moment it lands, and how many with the `cascade` — so "82 blocked" becomes a ranked list of merges to make. `--json` emits the whole report as **one JSON document on stdout** with every note on stderr, so it pipes to `jq` cleanly; the scan behind both reads one `jq` per *directory* rather than one per record (1,040 records: 2,576 forks and 23s before, 32 and 2s after). Run **inside** a repo it reports that repo; run **above** several (`~/Development`) it walks the tree and prints a per-repo table plus portfolio totals; `--all` reports every repo in the known-repos registry regardless of cwd — and the header always states which scope produced the numbers. Repos it deliberately skipped (worktrees, ignore-listed subtrees, stale registry entries) are reported rather than dropped. Excluding a subtree: `$CHIEF_PREFIX/ignore` (`CHIEF_IGNORE`). Totals are also broken down by each tasklist's `category`, live and parked separately — an **opaque string** chief reports and never ranks: any set of values renders, an absent one reads as `(uncategorized)`, and no chief source file names a vocabulary. A project declares its own ordering with `CHIEF_CATEGORIES` in `.chief/config`; the report then renders in it and states how much live work precedes the last category. The **parked** total is broken down the same way, by each park's `parkedReason` — additive and never mandatory (`"parked": true` alone still parks and reads as a park that does not say why), equally opaque, and equally declarable with `CHIEF_PARK_REASONS`. Always exits 0 — only the opt-in `--enforce-order`, for a CI job that wants the project's ordering enforced, can exit non-zero. See [docs/reference/status.md](docs/reference/status.md). |
| `chief lint [names…]` | Check tasklists before a run spends turns on them: valid JSON, `branchName` == `chief/<stem>`, no `mergedToMain` on unmerged work, and no acceptance criterion naming work in **another repo** — which the tasklist's worktree cannot reach. Declare real coordination with `"crossRepo":["<repo>"]`. Non-zero on any finding. |
| `chief ps [-a|--all]` | One-shot table of active runs across all repos; `--all` also shows every non-done tasklist in the current repo. |
| `chief monitor [-a|--all] [interval]` | Live-refreshing run view; `--all` adds every non-done tasklist in the current repo (default 2s; Ctrl-C to exit). |
| `chief logs [name] [-f]` | Tail a tasklist's per-iteration log from a live run (`-f` follows; `-n N` sets the tail size). |
| `chief events [id] [-f]` | Subscribe to a run's machine-readable NDJSON event stream — run/tasklist/story transitions as they happen, stdout is pure NDJSON (`-l` lists the logs on this host). The contract chief-cloud and embedding hosts read ([`docs/reference/events.md`](docs/reference/events.md)). |
| `chief models [provider]` | List the models you can pass to `--model` (live from devin/opencode; stable aliases for claude; no listing for amp/codex). |
| `chief quality ratchet` | The merge gate's second, MEASURED axis: deterministic code-quality metrics (duplication, function length, nesting depth, single-use helpers, lint counts) compared branch-vs-base, exiting non-zero when one regressed past its tolerance — so `verify.sh` can BLOCK a merge that made the codebase worse with every test still green. No model judgment anywhere; `measure` emits the raw record, `--write-baseline` is the reviewable re-baseline hatch ([`docs/reference/verify-hook.md`](docs/reference/verify-hook.md)). |
| `chief verify [--no-record]` | **Run this repo's verify hook and RECORD the verdict** — the agent-invocable half of chief's verdict cache. Chief runs the same gate at the end of an agent turn and again in the merge phase, and skips those runs when a GREEN verdict for the identical `tree · base · hook` is already on record; only this command writes that record, so an agent that runs `.chief/verify.sh` directly buys nothing and the suite is paid twice for one merge (measured 2026-09-02: ~20 minutes, then ~21 more, over a tree neither run had moved). It **records only for HEAD's tree** — the key is the committed tree while the hook tests the working one, so a dirty tree, or a HEAD that moved while the gate ran, is checked and reported but never recorded. Commit first, then verify. Exits with the hook's own status; `--no-record` runs the gate and writes nothing ([`docs/reference/verify-hook.md`](docs/reference/verify-hook.md)). |
| `chief cigate [-a] [-v] [--head] [--records] [paths…]` | **Did the declared CI gate actually run?** Per repo, the state of the most recent run of every `.github/workflows/*.yml` it declares: **RAN AND PASSED**, **RAN AND FAILED**, or **DID NOT RUN** — no run ever recorded, a run that completed without executing a single step (the shape a billing block produces), or a green run that never covered the commit asked about (`--head` / `--sha`). A repo with no workflows at all declares no gate and is **not** flagged; those are different situations. Measured 2026-08-25, every *private* repo in this portfolio had dead CI for an unknown period and nothing said so — Actions minutes are free for public repositories and billed for private ones, so one account-level block killed them all while the public ones kept working and kept looking normal. It also detects the **trigger mismatch** — a workflow waiting for an event chief never produces (`on: pull_request` only, a manual dispatch, a branch or tag it does not push). That is measured from the file, textually and offline, because `gh` cannot answer it: "no runs" is what a dead gate and a brand-new one both look like, and only the trigger says which. `vita`'s CI had never run once in the repository's history and a tasklist merged as `auto-verified` on the premise that it had. **Offline-safe and never on the merge path**: an absent `gh`, no remote or no network is `UNKNOWN`, stated as unknown and never rounded up to a pass. `--records` asks the question BACKWARDS and entirely offline — for every tasklist already in `completed/`, which gates actually executed for *that* merge. A record carrying `mergedToMain` is evidence of a merge, not of a check: `finalize_merged` now stamps a `gates` object (the local verify hook, and the offline trigger verdict for each declared workflow), and a record written before that field existed is **reconstructed** from the workflow files as they stood at the merge commit. That names vita's `72` — merged as `auto-verified` against a workflow nothing chief does could start — off the file instead of by hand. `-a` scans every repo in the known-repos registry, `-v` also shows the healthy ones. Always exits 0 — this reports, it never blocks. |
| `chief reap [-n] [--grace N] [--scope P]` | Stop orphaned chief processes of **both kinds**, reported separately: agent trees with no live, registered run behind them, and abandoned `chief monitor` views that outlived their terminal (`-n` reports only). **Host-wide**: every repo on the box, not just the current one; `--scope <repo>-<cksum>-` narrows it to one repo's runs — a view belongs to no run, so it is never narrowed. A watcher whose terminal is still open is never touched. |
| `chief approve [names…]` | Release a branch **held at an overlap zone** — a domain this repo declared in `.chief/zones.conf` as one where a green gate is not sufficient authority to merge. The branch is already rebased and verified GREEN; the approval is durable, bound by checksum to the change it approved, and never re-asked after a restart (no name = report what is waiting) ([`docs/reference/overlap-zones.md`](docs/reference/overlap-zones.md)). |
| `chief retire --negative NAME [-n]` | Retire a tasklist whose delivered stories **passed** and whose remaining story **terminated false** — declared `"terminalFalse"` and carrying the measurement behind the answer. The `completed/` record keeps the negative as `false` with its finding *and* lifts it into a `retiredOnNegative` block a successor tasklist can cite, and the tasklist stops being scheduled. It **refuses** a tasklist whose stories are merely unfinished, one whose declaration recorded no measurement, and — when the work never reached the base branch — one that live tasklists still depend on (a record with no `mergedToMain` satisfies no dependency edge). `-n` reports the verdict and writes nothing ([docs/reference/tasklist-schema.md](docs/reference/tasklist-schema.md)). |
| `chief decide NAME VERDICT` | Record a human verdict for a `DECISION` tasklist, with a prose `--note`, then either retire it with `--retire ID` or release it with `--unpark`. The agent can prepare the brief but cannot approve its own choice ([`docs/reference/decision-tasklists.md`](docs/reference/decision-tasklists.md)). |
| `chief pause [--all]` | Withhold agent turns — drain, never kill: in-flight iterations finish, the rest park as paused. |
| `chief resume [--all]` | Lift the pause and re-arm parked tasklists as pending for the next `chief run`. |
| `chief update` | Self-update the installed engine (`CHIEF_VERSION` pins a tag). |
| `chief version` · `chief help` | Version / usage. |

## Docs

- [`ROADMAP.md`](ROADMAP.md) — the roadmap: shipped capabilities vs. planned work.
- [`docs/reference/tasklist-schema.md`](docs/reference/tasklist-schema.md) — the tasklist JSON format.
- [`docs/reference/concurrency.md`](docs/reference/concurrency.md) — the host-wide agent-turn budget and hold behavior.
- [`docs/reference/roadmap-input.md`](docs/reference/roadmap-input.md) — the roadmap-document contract
  `chief gen` consumes: `phases[] → items[]`, the field mapping and defaults, and a
  worked example. The programmatic way for an embedding host to author tasklists.
- [`docs/explanation/drivers-and-safety.md`](docs/explanation/drivers-and-safety.md) — sequential vs
  parallel, `dependsOn`/`touches`/`warmup`, and the safety model.
- [`docs/reference/cross-repo-dependencies.md`](docs/reference/cross-repo-dependencies.md) — waiting on
  a tasklist in another repo with `"<repo>:<tasklist>"`.
- [`docs/reference/verify-hook.md`](docs/reference/verify-hook.md) — writing `verify.sh`.
- [`docs/reference/overlap-zones.md`](docs/reference/overlap-zones.md) — the per-repo
  registry of domains where a green gate is not sufficient authority to merge: a branch
  that changed one is held for a human AFTER it rebases and verifies (`chief approve`).
  The policy layer above the merge floor, for the one risk no automated gate sees —
  parallel branches whose code does not collide and whose designs disagree.
- [`docs/guides/providers.md`](docs/guides/providers.md) — the provider seam: the onboarding
  checklist for adding an agent CLI (one `_run_provider` case + one conformance
  fixture), the invariants a provider must satisfy, and how usage-limit detection
  depends on its output.
- [`docs/guides/monitoring.md`](docs/guides/monitoring.md) — `chief ps` / `chief monitor` and the
  run registry.
- [`docs/guides/headless-invocation.md`](docs/guides/headless-invocation.md) — embedding chief in
  a host app: `chief run --headless`, the run-id line, the exit-code table and the
  machine-readable summary.
- [`docs/guides/containers.md`](docs/guides/containers.md) — running chief inside a container or a
  Riju workspace: the env an embedding host sets (state prefix, worktree root, git
  `safe.directory`, committer identity), the guarantees, and what degrades.
- [`docs/reference/events.md`](docs/reference/events.md) — the machine-readable event stream: the NDJSON
  path, the versioned line schema, the event catalogue and `chief events`. The
  contract chief-cloud and embedding hosts subscribe to.
- [`docs/reference/account-credentials.md`](docs/reference/account-credentials.md) — running under a
  DESIGNATED provider account: `chief run --account-env <file>`, the file format, the
  provider-boundary-only application, the loud-failure rule and the non-leakage
  guarantee. The runner-side seam a multi-account pooler (chief-cloud) drives.
- [`docs/guides/local-inference-preset.md`](docs/guides/local-inference-preset.md) — the
  cost-avoidance mode: `chief run --local` routes every agent turn through a
  LOCAL/self-hosted endpoint at zero API cost, and what you give up for it.
- [`docs/decisions/desktop-gui-decision.md`](docs/decisions/desktop-gui-decision.md) — why monitoring is
  CLI-only here and a desktop GUI belongs to chief-cloud.
- [`examples/minimal/`](examples/minimal/) — a 3-tasklist demo you can `chief run -n`.

## Development

Offline, deterministic tests drive the real runtime with a scripted fake agent
(no network, no real AI). CI (`.github/workflows/ci.yml`) runs shellcheck +
`bash -n` + the suite on **Ubuntu and macOS** — macOS's default bash 3.2 is the
compatibility floor. The core tests:

- `test/smoke.sh` — install → init → agent loop → verify → merge → retire.
- `test/ratelimit.sh` — token/usage-limit pause+resume survives the parallel driver.
- `test/monitor.sh` — the run registry + `chief ps` reflect a live run, then clean up.
- `test/noworkguard.sh` — a false-complete (COMPLETE + zero commits) is caught as
  `EMPTY-NO-WORK`, never merged or retired.
- `test/evidence-gate.sh` — a story chief force-passes with an empty `notes` is
  caught as `UNVERIFIED`; honest and self-reported work still merges.
- `test/criteria-scope.sh` — a criterion naming another repo is caught as
  `UNSATISFIABLE` before any agent turn; declared (`crossRepo`) and local work merges.

Beyond the core set, `test/` holds focused tests for pause/resume, liveliness,
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

**v0.9.11** (current version: [`VERSION`](VERSION)) — extracted from a production setup where it drives real multi-tasklist
programs, then generalized: self-installing/updating, a cross-repo run monitor,
hardened merge safety (no-work guard, verify-failure re-engagement, mid-merge
crash recovery), and offline end-to-end tests. Known limit: parallel drivers rely on the
merge floor rather than perfect conflict tags (by design — see above). The run monitor
is per host/user; runs on other machines don't appear — cross-host aggregation and a
desktop GUI are chief-cloud's, the separate control plane, not this repo's
([`docs/decisions/desktop-gui-decision.md`](docs/decisions/desktop-gui-decision.md)).

## License

Apache-2.0 — see [`LICENSE`](LICENSE).
