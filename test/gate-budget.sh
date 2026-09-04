#!/usr/bin/env bash
# The GATE is budgeted as its own resource, and the budget can never refuse EVERY gate.
#
# Chief's original machine budget counted AGENT TURNS against the physical core count.
# An agent turn is provider latency; a gate is the compute. So a 14-core host reached
# load average 14.32 with five turns live and nine slots nominally free. This asserts
# the second budget: what it counts, that it holds, that it releases, and — the part
# that matters most — that it cannot wedge the portfolio.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RUNS="$WORK/runs"; ST="$WORK/st"
mkdir -p "$RUNS" "$ST/parallel"

# THIS shell is the live driver: a registry record is only as live as its pid, and a
# backgrounded `sleep` killed at exit prints a Terminated line that reads like a
# failure in CI output.
cat > "$RUNS/one.run" <<EOF
pid=$$
state=$ST
names=gate turn
EOF
GATE_LIVE="$ST/parallel/gate.live.json"
printf '{"phase":"verifying"}\n'  > "$GATE_LIVE"
printf '{"phase":"agent-turn"}\n' > "$ST/parallel/turn.live.json"

# The OPERATOR path: both budgets are read from the environment at SOURCE time, so
# they have to be set before the file is read. (test/machine-budget.sh sets them
# after and has been silently passing nothing on any host with >1 core.)
export CHIEF_RUNS="$RUNS" CHIEF_MACHINE_BUDGET=1 CHIEF_MACHINE_GATE_BUDGET=1
# shellcheck source=engine/reap.sh
. "$ROOT/engine/reap.sh"
# shellcheck source=engine/concurrency.sh
. "$ROOT/engine/concurrency.sh"

fail() { echo "$*" >&2; exit 1; }

# ── A. two counters, two budgets ──────────────────────────────────────────────
chief_machine_activity "$RUNS"
[ "$CHIEF_MACHINE_GATES" = 1 ]       || fail "A: expected 1 gate, got $CHIEF_MACHINE_GATES"
[ "$CHIEF_MACHINE_AGENT_TURNS" = 1 ] || fail "A: expected 1 agent turn, got $CHIEF_MACHINE_AGENT_TURNS"
if chief_machine_gate_budget_allows; then fail "A: a second gate was admitted at 1/1"; fi
# The agent-turn budget keeps working exactly as it did, with its own override.
if chief_machine_budget_allows; then fail "A: agent-turn budget stopped holding at 1/1"; fi

# ── B. a lock wait is not compute ─────────────────────────────────────────────
# `merge-wait` is a worker asleep on its run's merge lock. Counting it would let one
# run's merge queue read as N gates and starve every other repo on the host.
printf '{"phase":"merge-wait"}\n' > "$GATE_LIVE"
chief_machine_activity "$RUNS"
[ "$CHIEF_MACHINE_GATES" = 0 ] || fail "B: merge-wait counted as a gate ($CHIEF_MACHINE_GATES)"
chief_machine_gate_budget_allows || fail "B: held a gate behind a worker that was only waiting for a lock"

# ── C. ZERO HEADROOM STILL ADMITS ONE ─────────────────────────────────────────
# Nothing of chief's is gating, so a gate starts however small the budget is. A
# scheduler that can refuse every gate stops the portfolio permanently, which is a
# worse failure than the contention this exists to fix.
CHIEF_MACHINE_GATE_BUDGET=0; CHIEF_MACHINE_GATE_BUDGET_DISABLED=0
chief_machine_gate_budget_allows || fail "C: a budget of 0 refused the only gate on an idle host"
start=$(date +%s)
chief_machine_gate_admit zero-headroom "" "$WORK/c.log" >/dev/null
[ $(( $(date +%s) - start )) -le 2 ] || fail "C: admission waited on an idle host"
[ "$CHIEF_MACHINE_GATE_WAITED" = 0 ] || fail "C: waited ${CHIEF_MACHINE_GATE_WAITED}s with no gate live"

# ── D. the wait is BOUNDED ────────────────────────────────────────────────────
# The second, independent no-deadlock floor: a gate that never finishes (or a live
# record chief cannot clear) releases the hold rather than holding it forever.
printf '{"phase":"verifying"}\n' > "$GATE_LIVE"
CHIEF_MACHINE_BUDGET_READY=0
CHIEF_MACHINE_GATE_BUDGET_REQUESTED=1
chief_machine_budget_init
CHIEF_MACHINE_GATE_POLL=1 CHIEF_MACHINE_GATE_HOLD_MAX=1 \
  chief_machine_gate_admit stuck "" "$WORK/d.log" >/dev/null
grep -q 'HOLD stuck gate budget: 1/1' "$WORK/d.log" || fail "D: the hold was never logged"
grep -q 'RELEASE stuck' "$WORK/d.log" || fail "D: the bounded wait never released"

# ── E. it holds, then proceeds when the gate finishes ─────────────────────────
( sleep 2; printf '{"phase":"integrating"}\n' > "$GATE_LIVE" ) &
freeing=$!
CHIEF_MACHINE_GATE_POLL=1 CHIEF_MACHINE_GATE_HOLD_MAX=60 \
  chief_machine_gate_admit second "" "$WORK/e.log" >/dev/null
wait "$freeing" 2>/dev/null || true
[ "${CHIEF_MACHINE_GATE_WAITED:-0}" -ge 1 ] || fail "E: never waited for the live gate"
grep -q 'HOLD second gate budget: 1/1' "$WORK/e.log" || fail "E: the hold was never logged"
grep -q 'RESUME second admitted' "$WORK/e.log" || fail "E: no resume line after the gate finished"
if grep -q 'RELEASE second' "$WORK/e.log"; then fail "E: released on the bound, not on the freed slot"; fi

# ── F. the two knobs are SEPARATE ─────────────────────────────────────────────
# Disabling the gate budget must not disable the agent-turn budget, or this story
# has collapsed the two resources it exists to tell apart.
printf '{"phase":"verifying"}\n' > "$GATE_LIVE"
CHIEF_MACHINE_BUDGET_READY=0
CHIEF_MACHINE_GATE_BUDGET_REQUESTED=off
chief_machine_budget_init
[ "$CHIEF_MACHINE_GATE_BUDGET_DISABLED" = 1 ] || fail "F: CHIEF_MACHINE_GATE_BUDGET=off did not disable it"
chief_machine_activity "$RUNS"
chief_machine_gate_budget_allows || fail "F: gate budget still held while disabled"
if chief_machine_budget_allows; then fail "F: disabling the GATE budget also disabled the agent-turn budget"; fi

echo "GATE BUDGET PASS — gate counted apart from turns; merge-wait is not a gate; zero headroom and a stuck gate both still admit; the two knobs are independent"
