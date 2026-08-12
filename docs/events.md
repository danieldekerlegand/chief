# The event stream — chief's machine-readable status contract

`chief ps` / `chief monitor` / `chief logs` are the **human** views of a run
([`monitoring.md`](monitoring.md)); `--headless` gives a host a run-id and a final
summary ([`headless-invocation.md`](headless-invocation.md)). Both are **snapshots**.
A control plane that wants to know *the moment* a tasklist merged, went
VERIFY-FAILED, or hit a usage limit had only one option: poll `<name>.live.json` and
diff it — which loses every transition that happens between two polls and
re-implements the driver's state machine in the consumer.

The **event stream** is the missing third view: an append-only **NDJSON** log of the
transitions themselves, one JSON object per line, written as they happen.

**This document is the contract.** chief-cloud's `chiefd` daemon and embedding hosts
(Cuneiform, CI jobs, a dashboard) code against what is written here. Chief's side of
the bargain is that the fields below keep their meaning within a schema version — see
[Versioning](#versioning-what-may-change).

It is a **projection, not a state machine.** Every event is emitted next to a write
the engine already performs (a `live_set` phase change, a `set_state`, a
`<name>.status` line). Nothing in the stream decides or schedules anything, and
deleting every emit would leave a run byte-identical. If an event and the live record
ever disagree, **the event is the bug**. `ps`, `monitor`, `logs` and the `.live.json`
records are unchanged by this feature — it is purely additive.

## Where it lives

```
$CHIEF_RUNS/<run-id>.events.jsonl        # default: ~/.chief/runs/<run-id>.events.jsonl
```

One file per **run** — not per pid, not per tasklist. A `-p 4` run with four workers
writes all four workers' events to the same log; `name` tells them apart.

Three ways to learn the path, in order of convenience:

| You have | Get the path |
|---|---|
| a headless run's stdout | the `chief: events=<path>` line, printed before the loop starts (next to `chief: run-id=<id>`) |
| the run registry | the `events=` field in `$CHIEF_RUNS/<pid>.run` (`runid=` is the same id) |
| nothing but the id | `$CHIEF_RUNS/<run-id>.events.jsonl` |

**Lifetime.** Unlike `<pid>.run`, which is deleted when the run exits, the event log
**outlives its run** — that is the point: a host can read it after the fact. It is
pruned by age at the start of the next run, `CHIEF_EVENTS_KEEP_DAYS` days back
(default **14**). Copy anything you need to keep.

**When there is no log.** Emitting is best-effort and silent: with no `jq` on `PATH`,
or on an older engine, a run simply produces no events and behaves exactly as before.
A consumer must treat "no log" as "no information", never as "nothing happened".

## Consuming it: `chief events`

```sh
chief events                     # the live run's stream (else the most recent log)
chief events -f                  # …and keep streaming as events land (Ctrl-C to stop)
chief events <run-id> [-f]       # a specific run, live or finished
chief events -l                  # list the logs on this host:  <run-id>  live|ended  N events  path
chief events -n 50 -f            # start 50 events back, then follow
```

**stdout is pure NDJSON.** Banners, warnings and hints go to **stderr**, so a
consumer can pipe stdout straight into a parser with nothing in the way:

```sh
chief events -f | jq -c 'select(.event == "tasklist.merged") | {name, detail}'
```

With no argument it resolves the **sole live run** from the registry; with none live
it falls back to the most recent log (and says so on stderr); with several live it
lists their ids and asks you to name one. With `-f`, a log that does not exist *yet*
is waited on for a few seconds — a host that launches a run and subscribes
immediately can beat the driver to the first event.

Nothing about this is privileged: the file is plain NDJSON, so `tail -f` (or any
language's file watcher) is an equally valid subscriber. `chief events` never writes
to the registry and never touches a run.

## The line schema

Every line is an independently valid JSON object:

```json
{"v":1,"schema":"chief.event/1","ts":1786000123,"runId":"my_api-284719-1786000000-4821",
 "repo":"/Users/me/dev/my-api","event":"tasklist.merged","name":"auth","story":null,
 "state":"done","detail":"chief/auth --no-ff into main @1a2b3c4"}
```

| Field | Type | Meaning |
|---|---|---|
| `v` | int | schema major version — **1** today |
| `schema` | string | `"chief.event/<v>"`, the same version as a string you can match on |
| `ts` | int | Unix epoch seconds when the event was emitted |
| `runId` | string | the run this belongs to — the same id as `chief: run-id=` and `runid=` in the run file |
| `repo` | string | absolute path of the repo the run is driving |
| `event` | string | the transition, from the catalogue below |
| `name` | string \| null | the tasklist it is about; `null` on `run.*` events |
| `story` | string \| null | the user-story id; non-null only on `story.passed` |
| `state` | string \| null | the coarse state it lands in — the same vocabulary `chief ps` shows |
| `detail` | string \| null | **free text for a human.** Not part of the machine contract — never parse it |

`detail` is bounded to a single line of 300 characters, and every value is
jq-encoded, so a git error or a story title can never break the framing.

## The event catalogue

### Run scope (`name` is null)

| `event` | `state` | Emitted when |
|---|---|---|
| `run.started` | `running` | the registry entry exists and the scheduler loop is about to begin — the first line of every log |
| `run.finished` | `merged` · `conflict` · `verify-failed` · `failed` · `paused` · `no-work` · `interrupted` | the run computes its outcome (the same word the headless summary and exit code carry); `interrupted` is the signal path |

A consumer that saw `run.started` gets `run.finished` on every normal exit path,
including Ctrl-C. A `kill -9` simply stops the log — which is why `ts` is on every
event, and why a stream with no terminal line means "died", not "still running".
Cross-check liveness against `chief ps` / the run file's pid.

### Tasklist scope (`name` is the tasklist)

| `event` | `state` | Emitted when |
|---|---|---|
| `tasklist.launched` | `running` | a worker takes the tasklist (deps + conflict domains satisfied) |
| `tasklist.blocked` | `blocked` | it cannot run — an unmet dependency |
| `tasklist.bad-repo` | `failed` | a `repo:<sub>` tasklist names something that is not a git repo |
| `tasklist.merged` | `done` | the branch merged `--no-ff` into the base (`detail` carries the sha) |
| `tasklist.complete-unmerged` | `done` | stories finished with auto-merge off (`--no-merge`) |
| `tasklist.verify-failed` | `failed` | the verify hook exited non-zero post-rebase; the branch is kept for re-engagement |
| `tasklist.rebase-conflict` | `failed` | rebase onto the base conflicted (`detail` points at the forensics report) |
| `tasklist.rebase-refused` | `failed` | the rebase was refused by a safety check |
| `tasklist.merge-conflict` | `failed` | the merge itself conflicted |
| `tasklist.checkout-failed` | `failed` | the branch could not be checked out for the merge phase |
| `tasklist.no-work` | `failed` | the false-complete guard fired: COMPLETE with no commits |
| `tasklist.incomplete` | `failed` | the iteration budget ran out with stories still unpassed |
| `tasklist.rate-limited` | `rate-limited` | a provider usage limit paused it; branch kept, `detail` carries the reset ETA when known |
| `tasklist.paused` | `paused` | an operator pause (`chief pause`) drained it; branch + worktree kept |
| `tasklist.re-dispatch` | `pending` | the usage-limit window elapsed and it is queued again |

### Story scope (`name` + `story`)

| `event` | `state` | Emitted when |
|---|---|---|
| `story.passed` | `running` | the agent loop observes a story flip to `passes: true` (emitted the moment the provider turn returns, so the last story of a tasklist is never missed) |

`story.passed` fires once per story per run; a RESUME does not re-announce stories
that passed in an earlier run. That makes **complete-vs-incomplete work** live: count
`story.passed` for a `name` against the tasklist's story total.

## Ordering and concurrency

- Sibling workers append to the **same file** from different processes. Each event is
  one short (<4 KiB) `O_APPEND` write, which POSIX keeps atomic: lines interleave but
  never tear.
- **Order across tasklists is not promised.** Order events on `ts`, then on
  `(name, event)`. Within a single tasklist the sequence is causal:
  `tasklist.launched` → `story.passed`… → one terminal tasklist event.
- The log is **append-only and never rewritten**, so re-reading from byte 0 replays
  the whole run and `tail -f` misses nothing.

## Versioning: what may change

- Fields are only ever **added** within a major version. A consumer **must ignore
  keys it does not know** and **must ignore event names it does not know** — new
  events are additive too.
- `v` / `schema` bump **only** on a breaking change: a removed field, or one whose
  meaning changed. Pin `v == 1` if you want to be strict; prefer ignoring the unknown.
- Optional fields are **nullable, never absent-with-meaning**: treat `null` and
  missing as the same "not available here".
- `detail` is explicitly outside the contract and may be reworded at any time.

## A minimal subscriber

```sh
#!/usr/bin/env bash
# Print a line whenever a tasklist reaches a terminal state, and exit with the run.
chief events -f | while IFS= read -r line; do
  ev="$(printf '%s' "$line" | jq -r '.event')"
  case "$ev" in
    tasklist.merged|tasklist.verify-failed|tasklist.rebase-conflict|tasklist.merge-conflict)
      printf '%s\n' "$(printf '%s' "$line" | jq -r '"\(.name): \(.state) — \(.detail)"')" ;;
    run.finished)
      printf 'run %s\n' "$(printf '%s' "$line" | jq -r '.state')"; break ;;
  esac
done
```

Launch-and-subscribe, the shape a host app uses:

```sh
chief run --headless -p 3 > run.out 2>&1 &
until id="$(sed -n 's/^chief: run-id=//p' run.out | head -1)"; [ -n "$id" ]; do sleep 0.2; done
chief events "$id" -f | your-consumer
```

## See also

- [`monitoring.md`](monitoring.md) — the human views (`ps` / `monitor` / `logs`) and
  the `.live.json` liveliness records this stream projects.
- [`headless-invocation.md`](headless-invocation.md) — the run-id, the `chief:` lines
  and the exit-code table a host starts from.
- [`desktop-gui-decision.md`](desktop-gui-decision.md) — why the GUI lives in
  chief-cloud and chief ships the stable data seam instead.
- `engine/events.sh` — the emitter, and the engine-side half of this contract.
- `test/events.sh` — the hermetic test that pins this document: it drives a real run
  (fake provider, temp `CHIEF_*` prefixes) and asserts the merged and verify-failed
  sequences from the catalogue above, line by line. **A schema or catalogue change
  that test does not reflect is a contract break, not a passing change.**
