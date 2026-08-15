# Decision: chief stays CLI-only — the desktop GUI is chief-cloud's

> **Status:** Current · **Updated:** 2026-08-14 · **Owner:** chief

**Status:** decided · **Scope:** product boundary (no engine change) · **Supersedes:** the
referenced-but-absent `app/` desktop monitor

## The question

chief's README once pointed at a desktop monitoring app at `app/` that has never existed
in-tree. The dangling path was removed in a docs fix, but the underlying question was left
implicit: **does chief ship its own desktop monitor over the run registry, or is the
desktop/GUI surface deliberately somebody else's?**

## The decision

**chief is the open, CLI-only tasklist runner. It does not ship a desktop app, and the
`app/` idea is retired rather than deferred.** A monitoring GUI lives in **chief-cloud**,
the private control plane, whose Tauri desktop app already builds over its `chiefd`
daemon.

## The boundary

| | chief (this repo, open) | chief-cloud (private control plane) |
|---|---|---|
| Surface | CLI only — `chief run`, `chief ps`, `chief monitor`, `chief logs` | Tauri **desktop app** + control plane over `chiefd` |
| Scope | one host, one user, the terminal you're in | fleet-wide: many hosts, many repos, aggregated |
| State | files on disk (`~/.chief/runs/`, `.chief/state/`) that anything may read | a daemon that watches those files and its own store |
| Process model | **no daemon, no root, no build step** — a run is a shell process tree | a long-lived daemon is the point |
| Data it emits | the on-disk registry + state, and the machine-readable status stream from `chief/81-machine-readable-status-stream` | consumes both; renders, persists, and adds cost/ledger views |

Read as a sentence: **chief provides the CLI and the data a GUI consumes; chief-cloud
provides the GUI that consumes it.** There is no third place a monitoring GUI belongs.

## Why

- **Daemon-free is a stated property of chief**, not an accident — "no build step, no
  daemon, no root" is in the README's first screen, and the filesystem-as-state design
  falls out of it. A desktop app that watches runs usefully wants a supervising process;
  that pulls a daemon into the open runner and costs the property outright.
- **The dependency cost is disproportionate.** chief runs on stock bash 3.2 + git + jq,
  with `node` optional. A Tauri (or Electron) app adds a Rust/Node toolchain, a release
  pipeline, and per-OS signing to a repo whose entire test suite is hermetic shell.
- **It would be the second implementation.** chief-cloud's app already exists and already
  aggregates across hosts. A chief-native monitor would either duplicate it or diverge
  from it, and cross-host aggregation is already recorded in [`ROADMAP.md`](../ROADMAP.md)
  as *by design, never a chief feature*. This decision is that row's single-host twin.
- **The seam is better than the app.** What a GUI actually needs from chief is stable,
  readable run data — the registry (see [`monitoring.md`](monitoring.md)) today, the JSON
  event stream once `81` lands. Investing there serves chief-cloud, an embedding host like
  Cuneiform, and anyone's own dashboard equally; investing in one bundled app serves only
  that app.
- **CLI monitoring is already the answer for the single-host case.** `chief ps` /
  `chief monitor` render state, liveliness, stall detection, and pause reasons, and they're
  plain text when piped so `chief ps | grep stalled` scripts cleanly.

## Consequences

- No `app/` directory, and no reference to one, is expected in this repo. Monitoring docs
  point at the CLI, and any mention of a monitoring **GUI** points at chief-cloud.
- Keeping the run registry and the `81` status stream stable and documented is chief's side
  of the contract. Breaking either breaks a GUI that is out of this repo's tree.
- Chief's dependency floor stays bash + git + jq. A GUI toolchain is out of scope here.

## If this is ever reversed

Re-opening means deciding to build a chief-native app — which reverses the daemon-free and
dependency-floor properties above, so it is a product decision, not a task. If that call is
made, this record must be amended to say so, `79-desktop-monitor-app-decision` is re-opened
with a build scope (not the S-sized decision scope it holds now), and the ROADMAP row moves
out of decided. **Until then, the resolution is CLI-only.**
