# Console runs — planning and building with `claude -p` on API credits

> **Status:** Proposed · **Updated:** 2026-10-23 · **Owner:** chief

A **console run** is chief driving Claude Code in print mode (`claude -p`) through a fixed set of phases
over one or more repos, billed to a **Claude Console organization's API credits** rather than a
subscription. It exists for work that is worth doing as a *repeatable pipeline* — fanned-out mappers, a
planner, independent critics, and optionally builders — where every phase writes a file you can read,
correct and rerun. Built by `129-chief-console` (not yet run).

It follows chief's direction: chief is a **thin project-management layer** over Claude Code (and Codex,
OpenCode…). Chief owns the prompts, the budgets, the run record, the sequencing and the gates; **inside
a phase, Claude Code manages its own agents and worktrees**. Chief does not spin up per-story agents
itself for a console run.

## Why `claude -p` can carry real work, and what it cannot do

`claude -p` is the full Claude Code agent loop with the interactive shell removed: it reads, greps,
edits, writes, runs Bash and tests, spawns subagents, loads `CLAUDE.md`, settings, MCP servers, skills
and hooks, and can work in its own git worktree. So a console run can **plan and execute**. What print
mode lacks is a person mid-run: no permission prompts (anything not pre-authorised is denied), no
steering, one prompt and one result per call. The design supplies what that person would:

| A person would… | A console run instead… |
|---|---|
| approve each edit or command | pre-authorises per phase: read-only phases get `--allowedTools Read,Glob,Grep`; builders get `--permission-mode acceptEdits` plus a scoped `--allowedTools` (e.g. `Bash(git:*)`, `Bash(npm test:*)`), or `bypassPermissions` only inside a disposable worktree |
| stop a run that wanders | caps every call with `--max-budget-usd` (Claude Code 2.1.304 has no `--max-turns`; the dollar cap is the bound) and keeps phases short |
| read the result and decide | asks critics for a verdict in a fixed shape (`--json-schema`) and loops on it, with a round cap |
| keep the thread | writes every phase to a file; uses `--output-format json` + `--resume <session>` only where a phase needs its own earlier context |

Flags verified against Claude Code **2.1.304**: `--max-budget-usd`, `--allowedTools`/`--disallowedTools`,
`--permission-mode` (`acceptEdits`, `auto`, `bypassPermissions`, `manual`), `-w/--worktree`,
`--json-schema`, `--output-format`, `--resume`, `--agents`, `--settings`, `--add-dir`, `--model`,
`--fallback-model`, `--append-system-prompt`, `--mcp-config`, `--bare`. Re-check them when Claude Code
updates; `chief console --check` prints the installed version and refuses a flag it does not offer.

## Billing without leaking a key

API credits apply when Claude Code authenticates with the Console organization. **Never export
`ANTHROPIC_API_KEY` in a shell profile**: every process started from that shell inherits it — including
other loops' editors and their own `claude` children, which some loops forbid (the Insimul loops check
that no model key exists in an editor's process tree). A console run instead uses one of:

1. **A dedicated config directory** (preferred): `CLAUDE_CONFIG_DIR=~/.chief/claude-console`, signed in
   once with `claude /login` → *Anthropic Console account* → the organization holding the credits.
   Chief sets `CLAUDE_CONFIG_DIR` only on the `claude -p` processes it starts.
2. **`--settings` with an `apiKeyHelper`** that reads the key from the macOS Keychain at call time.

`--account console|subscription` selects which; `console` is the default for console runs. Chief records
the spend per phase from `--output-format json`'s cost field into the run record, and `chief usage`
reports it with the rest.

## Phases

```
brief ──► MAP (fan-out) ──► SYNTHESIZE ──► PLAN ──► GAUNTLET ⇄ REVISE ──► FINAL ──► [EXECUTE]
          sonnet, R/O        sonnet         opus      opus critics, R/O      opus       builder ⇄ critic
          one per subsystem  maps only      + checks  one per lens          + gen     per milestone
```

| Phase | Reads | Writes | Tools | Default model · budget |
|---|---|---|---|---|
| **map** | the code of one subsystem (from `--subsystems`, or a quick discovery call) | `map/<subsystem>.md` in the research-phase format (`docs/research-phase.md`): purpose, key types, data flow, extension points, coupling, fragile spots, cited paths | Read, Glob, Grep | sonnet · $3 each |
| **synthesize** | the maps only | `architecture.md`: seams, dependencies, constraints, open questions | Read | sonnet · $5 |
| **plan** | architecture + brief; may open specific files to check a claim | `plan.md` (components, data-model and API changes, sequencing, risks, acceptance criteria per milestone) and `roadmap.json` in `chief gen`'s input contract | Read, Glob, Grep | opus · $15 |
| **gauntlet** | plan + architecture + the code | `critic/<lens>-r<n>.json` (verdict schema below) | Read, Glob, Grep | opus · $4 per lens |
| **revise** | plan + every critic verdict of the round | the next `plan.md`, plus `decisions.md` entries: each change the critics forced and each finding disputed, with evidence | Read, Glob, Grep | opus · $10 |
| **final** | the last plan and verdicts | `final/plan.md`, `final/decisions.md`, `final/roadmap.json`; runs `chief gen -n` on it to prove it generates valid tasklists | Read, Bash(chief gen:*) | opus · $5 |
| **execute** *(opt-in)* | one generated tasklist | a branch in its own worktree; `build/<NN>/round-<n>/report.md` | builder: Read, Edit, Write, scoped Bash, worktree; critic: read-only + the repo's tests | builder opus · $10, critic opus · $5, per round |

**Lenses** (each a template under `templates/console/lenses/`, chosen per run with `--lenses`):
`architecture-fit`, `engine-constraints`, `scope-realism`, `what-breaks`, `licensing-and-data`,
`security`. A brief can add its own with `--lens-file <file>` (one or more).

**Critic verdict** (enforced with `--json-schema`):
`{lens, round, verdict: "pass"|"revise", findings: [{id, severity: "blocker"|"major"|"minor", claim, evidence, suggested_change}], checked: [what was verified against the code]}`.
The loop stops when every lens passes with no blocker or major, or at `--rounds` (default 3; critiques
tend to get pickier, not better, after that). Leftover minors go to `decisions.md`.

**Execute** reuses chief's existing machinery rather than inventing a second one: the final roadmap
becomes tasklists through `chief gen`; each tasklist is run as **builder ⇄ critic rounds** (zero blocker
and major, at most five rounds — the same bounded stop rule the Insimul loops use), the builder in its
own worktree (`claude -p --worktree`), the critic with fresh context. Nothing merges to a base branch;
merging stays with `chief run`'s serialized merge phase and the operator's go. Heavy commands (engine
builds, bakes) go through whatever machine lock the target repo declares (`--lock <cmd>`, e.g. the
Insimul loops' `ui/bin/heavy.sh`), so a console run never fights another loop for the machine.

## The run record

```
<repo>/.chief/console/<run-id>/
  brief.md  run.json            # inputs, flags, models, budgets, Claude Code version, start/end
  map/  architecture.md  plan.md  roadmap.json  critic/  decisions.md
  final/  build/                # execute only
  cost.json                     # per call: phase, model, session id, usd, tokens
```

Every phase is resumable: `chief console … --from gauntlet` reuses everything before it; `--rerun map:core`
redoes one mapper. `--dry-run` prints every prompt and flag and spawns nothing. A run stops before a
phase whose budget would push the total over `--budget`, and says so.

## Command

```
chief console <repo>... --brief <file> [--mode plan|execute|plan+execute]
              [--budget <usd>] [--phase-budget map=3,plan=15,critic=4,...]
              [--models map=sonnet,plan=opus,critic=opus,build=opus]
              [--subsystems a,b,c] [--lenses a,b] [--rounds 3]
              [--lens-file <file>...] [--account console|subscription] [--lock <cmd>]
              [--from <phase>] [--to <phase>] [--dry-run] [--check]
```

Several repos may be named (`--add-dir` gives the agents read access to the others); the run record lives
in the first.

## Costs, roughly

A planning run over a workspace the size of Insimul (10–12 subsystems): mappers ≈ $30–36, synthesis ≈ $5,
plan ≈ $15, three to four lenses over two to three rounds ≈ $25–45, final ≈ $5 — **about $60–100 with
the defaults**, less with fewer lenses or rounds. Run `map` alone first and check the Console's billing
page before the rest, to calibrate. Executing a large feature set costs far more than a planning run;
use execute mode for one milestone at a time.

## What a console run is not

- Not a replacement for `chief run`: tasklists, the story loop, verification and the merge phase stay
  where they are; a console run *produces* tasklists and can *build* one, and hands merging back.
- Not a way to steer an agent mid-run: if a phase goes wrong, correct its file and rerun from it.
- Not a key in your environment: the credential lives in a config directory or the Keychain.
