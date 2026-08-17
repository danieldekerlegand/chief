# Embedding chief — headless / programmatic invocation

> **Status:** Current · **Updated:** 2026-08-14 · **Owner:** chief

`chief run` is built for a human terminal: a schedule you read, a summary you skim.
A **host app** embedding chief — a Cuneiform Riju agent, chief-cloud, a CI job — needs
the opposite: start a run without an interactive step, and correlate its output with
the run's records. That is what **headless mode** is.

It is the *same engine*. Headless changes no scheduling, no merge policy, no agent
loop. It only guarantees a non-interactive shape and **adds** machine-readable lines.

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
chief: events=/Users/me/.chief/runs/myrepo-1234567890-1765000000-54321.events.jsonl
chief: state=/Users/me/myrepo/.chief/state
```

- **`run-id`** is `CHIEF_RUN_ID`, the marker `engine/driver.sh` mints for the run:
  `<repo>-<cksum>-<epoch>-<pid>`. It is the same string that is stamped on argv of
  every process in the run's tree and recorded as `runid=` in the run file, so it is
  how you tie stdout, the process tree and the registry together.
- **`run-file`** is the run's entry in the host-wide registry (`$CHIEF_RUNS/<pid>.run`),
  the same file `chief ps` / `chief monitor` read. Key=value, one per line.
- **`events`** is this run's append-only NDJSON **event stream** — every
  run/tasklist/story transition as it happens, the live counterpart to the one-shot
  summary below. Follow it with `chief events <run-id> -f`, or read the file
  directly; the schema is the contract in [`events.md`](../reference/events.md).
- **`state`** is the run's state directory; per-tasklist logs live in
  `<state>/parallel/<name>.log` and live records in `<state>/parallel/<name>.live.json`.

A **dry run** (`--headless -n`) spawns nothing and writes no registry file, so it
announces `chief: run-id=…` followed by `chief: dry-run=1` and no `run-file`.

Parsing, defensively:

```sh
run_id="$(chief run --headless "$@" | sed -n 's/^chief: run-id=//p' | head -1)"
```

## The exit code

A headless run **exits with a code that names the outcome**, so a host can branch on
the result without reading anything. The codes are derived from the same
per-tasklist terminal states the human summary prints — there is no second state
machine.

| code | outcome | meaning |
|---|---|---|
| `0` | `merged` | every requested tasklist reached a merged/complete terminal state (`MERGED`, or `COMPLETE-UNMERGED` under `--no-merge`) |
| `2` | — | **invocation / configuration error — the run never started**: `jq` missing, another driver already active on the repo, the repo not on its base branch, uncommitted tracked changes on the base |
| `3` | `no-work` | **nothing ran**: no runnable tasklist (all complete or parked), or every scheduled tasklist was blocked on a dependency |
| `4` | `verify-failed` | ≥1 tasklist ended `VERIFY-FAILED` — its branch is kept for re-engagement |
| `5` | `conflict` | ≥1 tasklist ended `REBASE-CONFLICT` or `MERGE-CONFLICT` — a human owns it (chief never auto-resolves) |
| `6` | `failed` | ≥1 tasklist failed for another reason: `INCOMPLETE`, `EMPTY-NO-WORK` (the false-complete guard), `UNVERIFIED` (the evidence gate), `UNSATISFIABLE` (the criteria scope gate), `REBASE-REFUSED`, `BAD-REPO`, `WORKTREE-FAILED` |
| `7` | `paused` | work was **withheld, not broken**: an operator pause (`chief pause`), a Claude usage-limit window, and/or a tasklist parked `AWAITING-REVIEW` (a plan nobody has approved — [plan-review.md](plan-review.md)). Branches and worktrees are kept; re-run to resume |
| `129` `130` `143` | — | the run was signalled (`SIGHUP` / `SIGINT` / `SIGTERM`); unchanged from an interactive run |

**Precedence**, when a run ends in more than one of these: `5` → `4` → `6` → `7` →
`3` → `0`. The state a human has to act on first wins, and "nothing happened" only
wins when nothing else did. The mapping is total and deterministic: the same set of
terminal states always produces the same code.

> **These codes apply to headless runs only.** An interactive `chief run` keeps the
> exits it has always had — `0` on success or on "nothing ran, operator pause armed",
> `1` when everything was blocked on a dependency — because existing scripts depend
> on them. Opting into the contract is what opts you into the table.

## The end-of-run summary

After the human summary block, a headless run prints one final line — the whole
outcome as a single JSON object, on the same `chief: <key>=<value>` convention:

```
chief: outcome=verify-failed
chief: exit=4
chief: summary={"runId":"myrepo-1234567890-1765000000-54321","repo":"/Users/me/myrepo","base":"main","state":"/Users/me/myrepo/.chief/state","outcome":"verify-failed","exit":4,"ok":false,"tasklists":[{"name":"auth","state":"done","status":"MERGED @a1b2c3d","outcome":"merged","attempts":1,"log":"/Users/me/myrepo/.chief/state/parallel/auth.log"},{"name":"billing","state":"failed","status":"VERIFY-FAILED","outcome":"verify-failed","attempts":1,"log":"/Users/me/myrepo/.chief/state/parallel/billing.log"}]}
```

Top level:

| field | |
|---|---|
| `runId` | the same id as the `chief: run-id=` line |
| `repo` · `base` · `state` | the repo driven, its base branch, and the run's state dir |
| `outcome` | the run outcome from the table above |
| `exit` | the exit code this run will exit with |
| `ok` | `exit == 0`, for hosts that only want the boolean |
| `tasklists[]` | every **requested** tasklist, in schedule order (empty on the `no-work` path) |

Per tasklist:

| field | |
|---|---|
| `name` | the tasklist stem (`tasks/<project>/<name>.json`) |
| `outcome` | `merged` · `complete-unmerged` · `verify-failed` · `conflict` · `rebase-refused` · `rate-limited` · `paused` · `awaiting-review` · `no-work` · `plan-invalid` · `bad-repo` · `blocked` · `not-launched` · `failed` |
| `state` | the raw scheduler state (`done` · `failed` · `blocked` · `rate-limited` · `paused` · `awaiting-review` · `pending`) |
| `status` | the driver's own status line, verbatim (`MERGED @<sha>`, `INCOMPLETE 2/5`, `REBASE-CONFLICT see …`) — the detail behind `outcome` |
| `attempts` | attempts spent this run (`RETRY_MAX` governs the budget); `0` when it was never retried |
| `log` | that tasklist's log file — what to show a user who asks "why?" |

Reading it:

```sh
out="$(chief run --headless)"; rc=$?
summary="$(printf '%s\n' "$out" | sed -n 's/^chief: summary=//p' | tail -1)"
case "$rc" in
  0) echo "merged: $(jq -r '.tasklists[]|select(.outcome=="merged").name' <<<"$summary")" ;;
  4) echo "verify failed: $(jq -r '.tasklists[]|select(.outcome=="verify-failed").log' <<<"$summary")" ;;
  7) echo "held — re-run to resume" ;;
esac
```

`outcome` and `exit` are printed as their own lines too, so a host that would rather
not depend on `jq` can grep those and still get the contract's core.

## Testing it

`test/headless.sh` is the executable copy of this document: it drives real runs with
a scripted fake `claude` on `PATH` and temp `CHIEF_*` prefixes, and asserts the
run-id line, the exit codes, the JSON summary's fields, and that a **non-headless**
run still emits none of it.

It is part of the **behavioral subset**, not an optional extra — it runs in
`.chief/verify.sh` (so no engine change merges without it), in
`.github/workflows/ci.yml` on both Ubuntu and macOS, and in `test/all.sh`. Changing
anything in this document therefore means changing that test in the same commit.

## Related

- `docs/guides/monitoring.md` — the run registry and live records these lines point at.
- `docs/explanation/drivers-and-safety.md` — what the scheduler does with the run once it starts.
- `docs/reference/verify-hook.md` — the gate that decides whether a branch merges.
- `docs/guides/containers.md` — the other half of an embedded run: what a container needs set
  (state prefix, worktree root, git ownership and identity) for this contract to hold.
