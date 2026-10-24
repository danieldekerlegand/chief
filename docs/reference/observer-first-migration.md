# Observer-first migration ledger

> **Status:** Implemented · **Updated:** 2026-10-21 · **Owner:** chief

This ledger maps the seven migration phases to reviewable repository evidence. The governing
boundary is the [observer-first decision](../decisions/native-harness-observer-first.md).

| Phase | Result | Evidence |
|---|---|---|
| 1. Reverse the execution-first assumption | Native harnesses own sessions, agents, worktrees, and loops; the Chief runner remains supported | Successor ADR and updated root README/roadmap |
| 2. Define telemetry contracts | Versioned schemas cover runs, lanes, stages, rounds, sessions, findings, decisions, evidence, and events | `packages/contracts/` and semantic validator |
| 3. Import the active Insimul work | The reported asset/UI lanes, stage counts, caps, dependency, runtime, and clothing decision are represented | `packages/contracts/fixtures/insimul-current-lanes.json` and private Rosetta loop-run manifest |
| 4. Build the observer | Read-only source adapters normalize supported facts; chiefd serves snapshots/SSE and records local SQLite history | `collectors/observers/` and `services/chiefd/` |
| 5. Replace the snapshot-only UI | The dashboard prioritizes active loops and decisions and refreshes when chiefd emits an update | `apps/portfolio/public/observatory.js` |
| 6. Package the desktop surface | Tauri packages the dashboard and chiefd sidecar with a menu-bar/tray menu, launch-at-login, and notifications | `apps/desktop/` |
| 7. Demote the old runner gracefully | Documentation presents observation first while preserving runner commands, tasklists, verification, and merge safety | Root README, roadmap, and successor ADR |

The service and adapters have no start, resume, stop, approval, or merge operations. Operator
decisions stay pending until the operator records an answer. Proposed compendium loops remain
reference data and are never scheduled by collection.

## Verification

```sh
npm run gauntlet:test
npm run observe:test
npm run portfolio:test
npm run chiefd:test
npm run desktop:check
node --check apps/portfolio/public/observatory.js
CHIEF_BASE_BRANCH=main .chief/verify.sh
```
