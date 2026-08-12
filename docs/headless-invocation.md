# Embedding chief — headless / programmatic invocation

`chief run` is built for a human terminal: a schedule you read, a summary you skim.
A **host app** embedding chief — a Cuneiform Riju agent, chief-cloud, a CI job — needs
the opposite: start a run without an interactive step, and correlate its output with
the run's records. That is what **headless mode** is.

It is the *same engine*. Headless changes no scheduling, no merge policy, no agent
loop. It only guarantees a non-interactive shape and **adds** machine-readable lines.

> Scope note: this document currently covers the **entry point, the configuration
> surface and the run-id line**. The exit-code table and the end-of-run JSON summary
> are added by the following stories in this tasklist.

## The entry point

```sh
chief run --headless [-p N] [--no-merge] [--provider P] [--model M] [names…]
```

Equivalently, set `CHIEF_HEADLESS=1` in the environment or in the project's
`.chief/config`. `--headless` and the env var mean exactly the same thing; the flag
wins when both are present.

There is **no second command and no separate code path** — `--headless` is a flag on
the run you already know, and every flag and environment variable a normal run
accepts works unchanged next to it:

| in | via |
|---|---|
| concurrency | `-p N` / `--parallel N` |
| don't merge into the base | `--no-merge` (or `AUTO_MERGE_MAIN=0`) |
| provider / model | `--provider`, `--model`, or `CHIEF_PROVIDER` / `CHIEF_MODEL` |
| which repo | `CHIEF_PROJECT` (or cwd inside the project) |
| which tasklists | trailing `names…` (default: everything runnable) |
| schedule only, run nothing | `-n` / `--dry-run` |

## What "headless" guarantees

- **No interactive behavior.** Nothing is read from stdin by chief, nothing waits on
  a human, no pager. (The provider is already invoked in its non-interactive `--print`
  mode by `engine/agent.sh`, headless or not.)
- **No ANSI colour.** The engine emits none of its own, and headless exports the
  standard `NO_COLOR=1` / `CLICOLOR=0` / `GIT_PAGER=cat` to every child, so a tool
  that would colourize on its own doesn't put escape sequences in your captured
  stream.
- **Line-oriented output.** Every machine-readable record is a single line of the
  form `chief: <key>=<value>`, one key per line, printed to **stdout**. Grep for the
  prefix; ignore anything else on the stream.
- **Human output is a superset, not a replacement.** The schedule, the per-tasklist
  progress lines and the final summary all still print, so a host may tee the same
  stream to a person.

### It is never inferred from a TTY

Headless is switched on **explicitly**. Chief deliberately does *not* test
`[ -t 1 ]`, because a contract that changes shape depending on how stdout happens to
be attached is not one you can code against — piping an ordinary `chief run` through
`tee` or into a file must produce exactly what a terminal shows.

## The run-id line

Before the scheduler loop begins — and after the run's registry file exists, so the
id resolves immediately — a headless run announces itself:

```
chief: run-id=myrepo-1234567890-1765000000-54321
chief: run-file=/Users/me/.chief/runs/54321.run
chief: state=/Users/me/myrepo/.chief/state
```

- **`run-id`** is `CHIEF_RUN_ID`, the marker `engine/driver.sh` mints for the run:
  `<repo>-<cksum>-<epoch>-<pid>`. It is the same string that is stamped on argv of
  every process in the run's tree and recorded as `runid=` in the run file, so it is
  how you tie stdout, the process tree and the registry together.
- **`run-file`** is the run's entry in the host-wide registry (`$CHIEF_RUNS/<pid>.run`),
  the same file `chief ps` / `chief monitor` read. Key=value, one per line.
- **`state`** is the run's state directory; per-tasklist logs live in
  `<state>/parallel/<name>.log` and live records in `<state>/parallel/<name>.live.json`.

A **dry run** (`--headless -n`) spawns nothing and writes no registry file, so it
announces `chief: run-id=…` followed by `chief: dry-run=1` and no `run-file`.

Parsing, defensively:

```sh
run_id="$(chief run --headless "$@" | sed -n 's/^chief: run-id=//p' | head -1)"
```

## Related

- `docs/monitoring.md` — the run registry and live records these lines point at.
- `docs/drivers-and-safety.md` — what the scheduler does with the run once it starts.
- `docs/verify-hook.md` — the gate that decides whether a branch merges.
