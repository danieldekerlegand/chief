# Native observation adapters

> **Status:** Current · **Updated:** 2026-10-21 · **Owner:** chief

Chief observes native coding tools without owning their execution loop. The adapters in
`collectors/observers/` only run documented read commands or read local state files. They do not
launch, resume, stop, queue, merge or edit an agent session.

Every adapter implements `collect(now) -> ObservationBatch`. Its records use the in-process
`chief.observation/1` projection. This projection is an ingestion boundary for chiefd, not a
replacement for the versioned public contracts in `packages/contracts/`.

| Adapter | Authority it reads | What it can claim |
|---|---|---|
| Claude Code | `claude agents --json --all` | Native session inventory and the status Claude reports at collection time |
| Codex | `$CODEX_HOME/session_index.jsonl` | Session identity, title and last indexed time |
| Chief legacy | `$CHIEF_RUNS/*.run` and `*.events.jsonl` | Registry process liveness plus Chief's native event history |
| Tracker files | `state.json`, `ledger.json`, `RUNNING.md` under configured roots | Declared JSON state and file freshness |
| Git | `git log`, `status` and `worktree list --porcelain` | Repository/worktree topology, branch and dirty-file facts |

The Codex CLI installed when this adapter was written has an interactive `codex agents` browser,
but no documented non-interactive JSON inventory. Chief therefore does not invoke it or scrape its
terminal UI. The machine-readable session index is useful for discovery, but it does not prove a
session is executing. Every Codex record has `status: unknown`; even a matching writer lock is
reported only as `writerLockObserved`, with liveness left unknown. A future supported app-server
inventory can strengthen this adapter without changing the normalized output.

## Status and freshness are separate

`status` answers what the source asserts about work: `active`, `waiting`, `paused`, `blocked`,
`complete`, `failed`, `gone`, or `unknown`. Unrecognized native words map to `unknown` rather than
the nearest-looking Chief state.

`freshness.state` answers how old the evidence is: `fresh`, `stale`, or `unknown`. Each record also
carries the source update time, age, threshold and reason. A stale active tracker remains `active`
with stale evidence; it is never silently changed to paused or failed. An old completed session can
be fresh when it came from a live inventory command. Git's last commit and a Markdown file's mtime
never establish process liveness.

An adapter batch is:

- `ok` when its authority was read and every record was understood;
- `degraded` when useful records exist but a capability is absent, rows were malformed, or history
  was truncated to the configured bound;
- `unavailable` when its command or source root cannot be read.

An empty successful native inventory is different from an unavailable adapter. Consumers must
show the adapter issue instead of interpreting unavailable as zero active work.

## Collection

Call the module with only the sources the installation has configured:

```sh
python3 -m collectors.observers.collect \
  --claude \
  --codex-home ~/.codex \
  --chief-runs ~/.chief/runs \
  --tracker-root ~/insimul-loops/trackers \
  --tracker-root ~/vibe-trackers \
  --git-root ~/Development \
  --pretty
```

The result contains each adapter batch plus a flattened `observations` array for ingestion.
`nativeSessions` and `events` are portable projections using `chief.native-session/v1` and
`chief.normalized-event/v1`. A newly discovered session has an empty `links` array until a tracker
or operator manifest correlates it; the adapter never invents a lane or stage. Paths, thresholds
and sources are explicit inputs so tests and private installations do not depend on the developer
account running Chief.

The adapters intentionally avoid provider SQLite databases, undocumented terminal scraping and
process-name heuristics. Tracker Markdown is indexed as a document with unknown status; prose is
not treated as a state machine. Chief event details remain human text and are never parsed to infer
new transitions.
