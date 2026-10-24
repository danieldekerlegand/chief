# Console runs — an Agent SDK runner that Chief observes

> **Status:** Draft · **Updated:** 2026-10-23 · **Owner:** chief

A **console run** is a planning (and optionally building) pipeline that a **native runner** on the
**Claude Agent SDK** drives through fixed phases over one or more repos, billed to a **Claude Console
organization's API credits**. Map, synthesize, plan, gauntlet ⇄ revise and final each produce a file
that a person can read, correct and rerun. The first runner of this kind is
`~/insimul-loops/briefs/console_plan_run.py`, which planned the next Insimul feature set on 2026-10-23.

**Chief observes a console run; it does not schedule one.** This follows
[Chief observes native coding harnesses first](../decisions/native-harness-observer-first.md): the
native harness owns sessions, agents, context and its own loop, and Chief discovers and correlates
that work read-only through the [observation contracts](../../packages/contracts/README.md). The runner
owns its phases, budgets and prompts. Chief supplies the prompt templates (`templates/console/`) and the
contract the runner emits (below). A `chief console` command that starts the runner is a **compatibility
path**, like `chief run`: a convenience for starting the run from Chief. It does not move the loop into
Chief. Built by `129-chief-console` (not yet run).

> **Naming.** *Console* here means the Claude Console, the organization that holds the API credits. It
> is unrelated to the **portfolio console** (`apps/portfolio`, Chief's read-only observatory UI). This
> document says *console run* throughout. Renaming the command or the runner is the operator's call.

## Why the Agent SDK, and what it cannot do

The operator's promotional API credit applies to the Agent SDK, the API, Batch, the Playground and Managed
Agents, **but not to Claude Code itself** (checked 2026-10-23). The Agent SDK runs the same agent loop as
Claude Code (read, grep, tools, subagents, `CLAUDE.md`, settings), so a console run uses the SDK.

There is no person in the loop mid-run: anything not pre-authorised is denied, nobody steers, and each call
takes one prompt and returns one result. The runner supplies what that person would do:

| A person would… | A console run instead… |
|---|---|
| approve each edit or command | pre-authorises per phase through the SDK options: read-only phases get `allowed_tools=["Read","Glob","Grep", read-only git]` with `permission_mode="default"` (everything else is denied); a builder gets `permission_mode="acceptEdits"` plus a scoped `allowed_tools` (e.g. `Bash(git:*)`, `Bash(npm test:*)`), and only inside a disposable worktree |
| stop a run that wanders | bounds every call with `max_turns`, and applies **the runner's own dollar cap**: before each call it checks that the money spent so far plus that phase's cap stays under the run budget, and refuses the call if not; spend comes from each result's `total_cost_usd` |
| read the result and decide | asks critics for a verdict in a fixed JSON shape, parses it, and loops on it, with a round cap |
| keep the thread | writes every phase to a file; a later phase reads the files, not a session's memory |

| SDK option (`ClaudeAgentOptions`) | Use in a console run |
|---|---|
| `allowed_tools` | the phase's tool list: read-only phases `Read`, `Glob`, `Grep` and read-only git (`git show`, `log`, `ls-tree`, `grep`, `diff`); builders add scoped edit and test tools |
| `permission_mode` | `default` for read-only phases (tools outside the list are denied); `acceptEdits` for a builder in its own worktree |
| `max_turns` | per phase (the first runner: map 60, synthesize 30, plan 80, critic 50, revise 60, final 20) |
| `cwd` | the subsystem being mapped, the run directory, or the builder's worktree |
| `add_dirs` | the other repos the agents may read |
| `model` | per phase: sonnet for map and synthesize, opus for plan, critics, revise and final |

Re-check these against the installed `claude-agent-sdk` when it updates (the first runner used 0.2.173).

**Agents return documents; the runner writes the files.** Read-only phases have no write tool. Each
prompt ends with an instruction to put the file's complete content in the final answer, split by
markers (`=== PLAN ===`, `=== ROADMAP ===`, `=== DECISIONS ===`), and the runner writes them under the run
directory. A template's "return X" means exactly that.

## Billing without leaking a key

**Never export `ANTHROPIC_API_KEY` in a shell profile.** Every process started from that shell inherits it,
including other loops' editors and their own `claude` children, which some loops forbid (the Insimul
loops check that no model key exists in an editor's process tree). A console run uses one of:

1. **A dedicated config directory** (preferred): `CLAUDE_CONFIG_DIR=~/.chief/claude-console`, signed in
   once (`claude /login` → *Anthropic Console account* → the organization holding the credits). The
   variable is set only on the runner's command line (`CLAUDE_CONFIG_DIR=… uv run --with claude-agent-sdk
   python <runner>`), so the SDK process and its children see it and the shell does not.
2. **A key from the macOS Keychain**, read at start and passed only to the SDK process (in the `env`
   the runner hands the SDK). It is never written to a file, a log or the manifest, and never printed.

## Phases

```text
brief ──► MAP (fan-out) ──► SYNTHESIZE ──► PLAN ──► GAUNTLET ⇄ REVISE ──► FINAL ──► [EXECUTE]
          sonnet, R/O        sonnet         opus      opus critics, R/O      opus       builder ⇄ critic
          one per subsystem  maps only      + checks  one per lens          + gen     per milestone
```

| Phase | Reads | Returns (the runner writes) | Tools | Default model · cap |
|---|---|---|---|---|
| **map** | the code of one subsystem | `map/<subsystem>.md` in the research-phase format (`docs/research-phase.md`) | Read, Glob, Grep, read-only git | sonnet · $3–6 each |
| **synthesize** | the maps only | `architecture.md`: seams, dependencies, constraints, open questions | Read | sonnet · $5–8 |
| **plan** | architecture + brief; may open files to check a claim | `plan.md` and `roadmap.json` in `chief gen`'s input contract | Read, Glob, Grep | opus · $15–20 |
| **gauntlet** | plan + architecture + the code | one verdict per lens: `critic/<lens>-r<n>.json` | Read, Glob, Grep | opus · $4–8 per lens |
| **revise** | plan + every verdict of the round | the next `plan.md` and `roadmap.json`, plus `decisions.md` entries | Read, Glob, Grep | opus · $10–15 |
| **final** | the last plan and verdicts | `final/plan.md`, `final/decisions.md`, `final/roadmap.json`; the **runner** then runs `chief gen -n` on the roadmap and writes `final/chief-gen-check.txt` | Read | opus · $5–8 |
| **execute** *(opt-in)* | one generated tasklist | a branch in its own worktree; `build/<NN>/round-<n>/report.md` | builder: Read, Edit, Write, scoped Bash; critic: read-only + the repo's tests | builder opus · $10, critic opus · $5, per round |

**Lenses** (`templates/console/lenses/`): `architecture-fit`, `engine-constraints`, `scope-realism`,
`what-breaks`, `licensing-and-data`, `security`; a brief can add its own lens files.

**Critic verdict** (parsed by the runner; an unparseable answer becomes one `major` finding):
`{lens, round, verdict: "pass"|"revise", findings: [{id, severity: "blocker"|"major"|"minor", claim, evidence, suggested_change}], checked: [...]}`.
The loop stops when every lens passes with no blocker or major, or at the round cap. Leftover minors go to
`decisions.md`.

**Execute** builds one tasklist that the final roadmap generated (`chief gen`), as **builder ⇄ critic rounds**
(stop at zero blocker and zero major, or after five rounds — the Insimul loops' rule). The builder runs
through the SDK in its own worktree; the critic runs read-only with fresh context. **Nothing merges to a
base branch**: the branch is left for the operator, or for `chief run`'s serialized merge phase on the
compatibility path. Heavy commands go through the machine lock the target repo declares (e.g. the Insimul
loops' `ui/bin/heavy.sh`).

## The run record

```text
<run-dir>/                      # e.g. ~/insimul-loops/briefs/runs/2026-10-23-1639
  brief.md  run.json  log.txt   # inputs, budget, rounds, lenses, subsystems, start; the runner's log
  map/  architecture.md  plan.md  roadmap.json  critic/  decisions.md
  final/  build/                # build/ in execute mode only
  cost.jsonl                    # one line per SDK call: label, model, session_id, usd, tokens, secs
  loop-run.json                 # the chief.loop-run/v1 observation (below)
```

Every phase can be resumed: a phase whose file exists is reused, so deleting a file reruns that phase. When
the budget would be exceeded, the runner stops before the next call and says so. When a call fails, for
example because the credit runs out, the runner stops and keeps everything written so far.

## Emitting the observation contract

So Chief can observe the run without understanding the runner, the runner writes **one
`chief.loop-run/v1` manifest per run** (`loop-run.json` in the run directory) and rewrites it whenever the
run stops, finishes or pauses. The records:

| Record | One per | Notes |
|---|---|---|
| `chief.loop-run/v1` | run | `id` like `console:<project>:<run-dir-name>`; `status` from the run's state; `runtime` from the log's start and stop times (the gaps between invocations are pauses) |
| `chief.lane/v1` | run | one lane, stages `map`, `synthesize`, `plan`, `gauntlet`, `revise`, `final` (and `execute` in execute mode); `progress` derived from the stage states |
| `chief.round/v1` | lens round | each critic verdict is a round of the `gauntlet` stage (`number` = gauntlet round, `phase` = the lens), carrying its finding, session and evidence ids and the verdict's counts in `measurements`; the revisions are rounds of the `revise` stage |
| `chief.finding/v1` | critic finding | severity `blocker` → `critical` (kind `blocker`), `major` → `major`, `minor` → `minor`; findings of a round that a revision answered are `superseded`, the latest round's are `open` |
| `chief.native-session/v1` | SDK call | `provider: "claude"`, `attribution: "provider-api"`, `externalId` = the result's `session_id`; cost, session id, tokens, model, turns and seconds under `extensions["anthropic.agent-sdk"]`; linked to its lane, stage and round |
| `chief.evidence/v1` | phase file | every map, plan, roadmap, verdict, decision log and final file, with its `sha256` |

**Running out of credit is a pause, not a failure.** When a call fails because the credit balance is
exhausted, the run, its lane and the stage that was running are `paused`. The reason (e.g.
`API credit exhausted 2026-10-24 00:00 UTC`) goes in `runtime.pauseReasons`. The failed call is a
`failed` session and a `void` round. Topping up the credit and rerunning resumes the run from that phase.

The runner validates the manifest with Chief's dependency-free validator
(`collectors/gauntlet/validate_observation.py`: schema plus links and derived counts) **before writing
it**, and writes nothing if the manifest is invalid. Chief then reads it like any other loop-run manifest.
The portfolio collector reads the manifests its `loopRuns` setting names (by default Rosetta's private
data, `portfolio/loop-runs/*.json`), so a run directory outside that path is collected once the
manifest is copied or linked there, or once the setting also names it. Chief never writes to the run
directory. Live run data wins over the compendium for execution state
([observer-first decision](../decisions/native-harness-observer-first.md)).

## Costs, roughly

Measured on the first run (Insimul, 11 subsystems, 7 lenses, 4 gauntlet rounds, 45 calls): mappers
$5.80, synthesis $0.53, plan $1.49, critics $12–16 per round, revisions $1.8–2.9 each, final $2.73. The
total was **$71.75** before the credit ran out at revise round 4. Run `map` alone first and check the
Console's billing page, to calibrate. Executing a feature set costs far more than planning one; execute
one milestone at a time.

## What a console run is not

- Not a scheduler inside Chief: the runner owns its loop; Chief observes the manifest it emits.
- Not a replacement for `chief run`: a console run *produces* tasklists and can *build* one on a branch,
  and leaves merging to the operator (or to `chief run`'s merge phase).
- Not a way to steer an agent mid-run: if a phase goes wrong, correct its file and rerun from it.
- Not a key in your environment: the credential lives in a config directory or the Keychain.
