# Portable gauntlet observations across native harnesses

> **Status:** Draft · **Updated:** 2026-10-24 · **Owner:** chief

This design describes how a native loop can expose portable, read-only observations to Chief
without changing its tracker, harness, or execution model. It follows
[Chief observes native coding harnesses first](../decisions/native-harness-observer-first.md):
the harness owns agents and runs; Chief discovers, normalizes, correlates, and presents facts the
source can support.

## Record model

The portable boundary is the versioned contracts in `packages/contracts`. The terms in a source
tracker must remain distinct: a **programme** contains **lanes**; a lane advances through
**components/stages**; a **round** is one builder/critic attempt; a **run** is one invocation of
the workflow. A lane may therefore contain several runs, and a run may contain several rounds.

| Contract | Portable meaning | Source facts needed |
|---|---|---|
| `chief.loop-run/v1` | One actual workflow invocation, with stable identity, project, lifecycle, observation/start precision, runtime accounting, and lane/stage topology. | An invocation ID and source-supported status/times. Runtime is not reconstructed from prose or file modification time. |
| `chief.round/v1` | One builder/critic attempt in a phase, with its lifecycle, linked sessions, findings, evidence, measurements, and summary where known. | A round ID/number and explicit phase and verdict/lifecycle. A numeric score history or component counter alone is not a round. |
| `chief.finding/v1` | One typed defect, gap, blocker, risk, or observation linked to its source and, when known, lane/stage/round. | Explicit kind, severity, status, title/summary, observation time, and source. A text-only note is not enough to infer severity. |
| `chief.native-session/v1` | One provider-owned session correlated to observed work, with provider, source ID, observed status/time, attribution, and proven links. | The provider or harness must expose the session ID/status or a reliable attribution source. Do not derive a session from a branch name. |
| `chief.evidence/v1` | A reference to a report, test, log, image, build, commit, or other proof, optionally content-addressed. | A usable URI, title, capture time, source, and a hash only when the bytes are stable and the hash is known. |

One run manifest should contain the run and its observed records, with stable cross-record IDs and
links. Provider identity is data, not a separate format: Claude Code, Codex, Devin, OpenCode, and
other supported harnesses emit the same contract versions; provider-specific details live under
namespaced `extensions`. The existing validator remains the gate for schema and cross-record
consistency.

## What existing trackers can and cannot say

Current tracker sources commonly provide a **latest lane row** with lane, stage, current round,
status, update time, title, and summary. Others provide a surface or wave summary with pieces,
verdict notes, numeric histories, findings, build results, and evidence links. These are valuable
for a portfolio snapshot, but they do not automatically identify one workflow invocation or
provide its complete round/session/evidence history.

The mapping rules are:

- A lane-status row is a source observation about a lane; it is not a `chief.loop-run/v1` merely
  because its field is named `runs`.
- A component's numeric history, wave number, or short verdict does not establish a
  `chief.round/v1` lifecycle. Project it as a round only when its producer makes the semantics and
  links explicit.
- A finding with only text and open/fixed state cannot supply the required kind, severity, source,
  observation time, and round linkage. Do not classify it from wording.
- A session is separate from a run and a round. Preserve an uncorrelated session as unlinked when
  the source exposes the session but not its relationship; do not invent a link.
- Preserve unknown facts as unknown. Do not manufacture start times, active duration, pause
  duration, provider IDs, severity, capture time, or hashes to satisfy a schema.

There is a contract-level limit to resolve before projecting sparse tracker rows: `loop-run/v1`
requires a numeric `runtime.activeSeconds`, while many trackers do not record active duration.
Until a source can support that value or the contract explicitly defines an approved approximation,
an adapter should retain the generic source observation rather than emit a misleading run
manifest. Similarly, a source without explicit finding severity cannot be losslessly converted to
`finding/v1`.

## Current Chief boundary

The existing generic tracker observer is opt-in: its roots are supplied explicitly, and it scans
known tracker filenames/fields without writing the source. It normalizes a basic status and update
time (falling back to file modification time) into a generic observation. Its current capability
declaration does not promise session inventory, liveness, or lifecycle events. The observer CLI
wires Claude, Codex, Chief-run, Git, and tracker adapters; although the native-session contract
includes Devin and OpenCode, the observer CLI does not currently wire native-session adapters for
those providers. This is not a complete conversion of a tracker tree into linked loop, round,
finding, session, and evidence contracts.

The portfolio collector separately reads configured loop-run manifests and validates them before
including them in a snapshot. The portfolio app is a read-only view of that projection. The
collector does not rewrite the portfolio workspace or the observed source. Existing
`ROADMAP.md` “Observatory follow-ups” describe known collector and validator gaps; this proposal
does not close those rows or change their code.

## Adoption and transport

1. A loop opts in by writing a `chief.loop-run/v1` sidecar beside its existing run artifacts. The
   sidecar represents one real workflow invocation and contains the source-supported rounds,
   findings, sessions, and evidence. Existing files and formats remain in place.
2. The loop's coordinating session is the single writer for that run's manifest. It updates the
   record at the loop's existing checkpoints; independent lanes use unique run IDs and paths
   rather than a shared programme-wide mutable file.
3. The loop commits the sidecar through its normal, path-scoped Git workflow. Git transports the
   record between machines; the owning loop and its current workflow decide when and how to
   synchronize. Chief does not fetch, pull, push, resolve conflicts, start agents, or modify the
   source tree.
4. An operator explicitly configures a narrow collector root or manifest pattern. The adapter
   validates before projection, reports an invalid or missing source as an issue, and retains
   provenance, source time, and freshness. It must not traverse `.git`, `wt/`, `state/run/`, lock
   directories, or environment files, and it never scans unrelated directories by default.
5. Tests use small committed fixture copies. They never open a live workspace, harness home,
   worktree, lock, port, or secret-bearing file.

The manifest is an additive sidecar, not a replacement tracker. A loop that has not adopted it
remains visible through the facts its current source supports. Where a tracker cannot express a
contract field, the adapter must not rewrite the tracker to make the schema appear complete.

## Portfolio view

After approval, the portfolio can present programme → lane → component/stage → round → run as
separate levels, alongside provider sessions and linked evidence. Each displayed fact should show
its source and observation time; stale or partial data should be visible as such. The view remains
read-only and links to native harnesses and source records rather than adding controls to start,
resume, stop, approve, or merge work.

## Questions and scope

Questions for the operator:

1. Is one `chief.loop-run/v1` sidecar per actual workflow invocation, with linked
   `chief.round/v1` records, the intended shared format for all providers?
2. How should the required `runtime.activeSeconds` be handled for sources that do not measure
   active time: retain those as generic tracker observations, or separately approve a contract
   change/approximation rule?

This is a Phase 1 design only. It adds no adapter, UI, runtime behavior, contract change, session
provider, or synchronization service. It does not change existing loop files or execute a
workflow. Phase 2 is gated on approval; migration remains separately gated on explicit approval
at a quiet point.
