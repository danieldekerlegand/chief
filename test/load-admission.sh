#!/usr/bin/env bash
# LOAD AVERAGE IS AN INPUT, not decoration.
#
# `CHIEF_MACHINE_LOAD_AVERAGE` used to be written and read inside one function and
# spent entirely on printing the word OVERSUBSCRIBED. It is the only signal chief has
# that sees work chief did not start, and both budgets are blind to it — which is how
# a 14-core host sat at load 14.32 with nine slots nominally free. This asserts that
# admission consults it, that ONE function owns the reading, that the operator can
# switch it off, and — the part that matters most — that foreign load cannot stall
# the portfolio.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RUNS="$WORK/runs"; ST="$WORK/st"
mkdir -p "$RUNS" "$ST/parallel"

# THIS shell is the live driver: a registry record is only as live as its pid.
cat > "$RUNS/one.run" <<REC
pid=$$
state=$ST
names=gate
REC
GATE_LIVE="$ST/parallel/gate.live.json"
printf '{"phase":"verifying"}\n' > "$GATE_LIVE"

# Both knobs are captured at SOURCE time (test/machine-budget.sh silently asserted
# nothing for months by setting one afterwards), so they go before the `.`.
# The load ceiling is 4 and the simulated one-minute average is 62 — the reading
# from the incident host, 4.4x oversubscribed on 14 cores.
export CHIEF_RUNS="$RUNS" CHIEF_LOAD_AVERAGE=62 CHIEF_MACHINE_LOAD_LIMIT=4 \
       CHIEF_MACHINE_GATE_BUDGET=8
# shellcheck source=engine/reap.sh
. "$ROOT/engine/reap.sh"
# shellcheck source=engine/concurrency.sh
. "$ROOT/engine/concurrency.sh"

fail() { echo "$*" >&2; exit 1; }

# ── A. ONE function owns the reading ──────────────────────────────────────────
# The admission predicate and the `chief ps` line must quote the same number; a
# second sampling path is how a display and a decision drift apart.
CHIEF_MACHINE_LOAD_AVERAGE=""
chief_machine_budget_ensure
CHIEF_MACHINE_CORES=14   # pin the DISPLAY's comparison; the ceiling under test is 4
chief_machine_load_sample
[ "$CHIEF_MACHINE_LOAD_AVERAGE" = 62 ] || fail "A: the sampler did not set the global ($CHIEF_MACHINE_LOAD_AVERAGE)"
case "$(chief_machine_load_line)" in
  # The CEILING, not the core count: the display and the decision now have to quote
  # the same line, and here they differ (ceiling 4, cores 14) precisely so a line
  # that fell back to the cores figure cannot pass this.
  *"load average: 62 "*"ceiling 4"*) ;;
  *) fail "A: the display line does not report the sampled reading: $(chief_machine_load_line)" ;;
esac
# …and NOT the alarm word, with no gate of chief's in flight. The bound is admitting
# work onto this host, so `OVERSUBSCRIBED` here would be an alarm about a decision
# that was never taken (test/concurrency-monitor.sh asserts the display side).
case "$(chief_machine_load_line)" in
  *OVERSUBSCRIBED*) fail "A: alarmed while admitting: $(chief_machine_load_line)" ;;
esac

# ── B. a loaded host does not admit more work ─────────────────────────────────
# The gate budget is 8 and one gate is live, so the gate budget ALONE would admit.
# Only the load line can refuse here, and it must — the load is over the ceiling
# whether chief caused it or an operator's own build did.
chief_machine_activity "$RUNS"
[ "$CHIEF_MACHINE_GATES" = 1 ] || fail "B: expected 1 live gate, got $CHIEF_MACHINE_GATES"
chief_machine_gate_budget_allows || fail "B: the gate budget of 8 held at 1 gate — wrong control refused"
if chief_machine_load_allows; then fail "B: load 62 admitted against a ceiling of 4"; fi
if chief_machine_admits gate;  then fail "B: a gate was admitted onto a host at load 62/4"; fi
case "$CHIEF_MACHINE_HOLD_REASON" in
  *"load average 62"*) ;;
  *) fail "B: the hold did not name the load: '$CHIEF_MACHINE_HOLD_REASON'" ;;
esac
if chief_machine_admits launch; then fail "B: a RUN was launched onto a host at load 62/4"; fi

# ── C. IT CANNOT STALL ON FOREIGN LOAD ────────────────────────────────────────
# Load average counts work chief did not start, cannot finish and cannot see. With
# nothing of chief's live there is nothing to wait FOR, so waiting would be an
# unbounded stall on somebody else's compute. Same simulated load of 62, zero live
# runs: admitted, immediately.
mv "$RUNS/one.run" "$WORK/one.run.parked"
chief_machine_activity "$RUNS"
[ "$CHIEF_MACHINE_RUNS" = 0 ]  || fail "C: expected zero live runs, got $CHIEF_MACHINE_RUNS"
[ "$CHIEF_MACHINE_GATES" = 0 ] || fail "C: expected zero live gates, got $CHIEF_MACHINE_GATES"
chief_machine_load_allows      || fail "C: load 62 blocked work on a host where chief has nothing running"
chief_machine_admits gate      || fail "C: gate admission stalled on foreign load with chief idle"
chief_machine_admits launch    || fail "C: run launch stalled on foreign load with chief idle"
start=$(date +%s)
chief_machine_gate_admit idle-host "" "$WORK/c.log" >/dev/null
[ $(( $(date +%s) - start )) -le 2 ] || fail "C: admission waited on foreign load with chief idle"
[ "$CHIEF_MACHINE_GATE_WAITED" = 0 ] || fail "C: waited ${CHIEF_MACHINE_GATE_WAITED}s with nothing of chief's running"
mv "$WORK/one.run.parked" "$RUNS/one.run"

# ── D. the hold RELEASES when the load falls ──────────────────────────────────
# Re-sampled every pass, or a hold taken at a spike outlives the spike.
CHIEF_LOAD_AVERAGE=62
( sleep 2; echo 1 > "$WORK/dropped" ) &
dropping=$!
# The sampler reads CHIEF_LOAD_AVERAGE on every poll; flip it from the fixture by
# pointing the reading at a file the background job rewrites.
chief_machine_load_average() { if [ -f "$WORK/dropped" ]; then printf 0.5; else printf 62; fi; }
CHIEF_MACHINE_GATE_POLL=1 CHIEF_MACHINE_GATE_HOLD_MAX=60 \
  chief_machine_gate_admit spike "" "$WORK/d.log" >/dev/null
wait "$dropping" 2>/dev/null || true
[ "${CHIEF_MACHINE_GATE_WAITED:-0}" -ge 1 ] || fail "D: never held for the load"
grep -q 'HOLD spike machine load: load average 62' "$WORK/d.log" || fail "D: the load hold was never logged: $(cat "$WORK/d.log")"
grep -q 'RESUME spike admitted' "$WORK/d.log" || fail "D: no resume line after the load fell"
if grep -q 'RELEASE spike' "$WORK/d.log"; then fail "D: released on the bound, not on the load falling"; fi
unset -f chief_machine_load_average
# shellcheck source=engine/concurrency.sh
. "$ROOT/engine/concurrency.sh"

# ── E. the wait is BOUNDED even when the load never falls ─────────────────────
# The second, independent floor: foreign load that stays high releases the hold
# rather than holding it forever.
CHIEF_MACHINE_GATE_POLL=1 CHIEF_MACHINE_GATE_HOLD_MAX=1 \
  chief_machine_gate_admit stuck-load "" "$WORK/e.log" >/dev/null
grep -q 'RELEASE stuck-load' "$WORK/e.log" || fail "E: a permanently loaded host never released the hold"

# ── F. THREE knobs, not one ───────────────────────────────────────────────────
# Load-based admission has its own off switch, and turning off the GATE budget must
# not turn it off — nor the reverse. An operator who knows the load is foreign says
# so with CHIEF_MACHINE_LOAD_LIMIT; that is a different sentence from "do not budget
# gates", and collapsing them is the defect this whole tasklist exists to undo.
CHIEF_MACHINE_BUDGET_READY=0
CHIEF_MACHINE_GATE_BUDGET_REQUESTED=off
chief_machine_budget_init
chief_machine_activity "$RUNS"; chief_machine_load_sample
[ "$CHIEF_MACHINE_LOAD_DISABLED" = 0 ] || fail "F: disabling the gate budget also disabled the load rule"
if chief_machine_admits gate; then fail "F: gate budget off admitted a gate onto a host at load 62/4"; fi
# And the ADMISSION WRAPPER honours the split, not just the predicate: the early
# return that used to sit at the top of chief_machine_gate_admit returned on the gate
# budget alone, so switching that off would have silently switched off the load rule
# with it.
CHIEF_MACHINE_GATE_POLL=1 CHIEF_MACHINE_GATE_HOLD_MAX=1 \
  chief_machine_gate_admit gate-off "" "$WORK/f-load.log" >/dev/null
grep -q 'HOLD gate-off machine load' "$WORK/f-load.log" \
  || fail "F: gate budget off short-circuited the load rule inside chief_machine_gate_admit"
CHIEF_MACHINE_BUDGET_READY=0
CHIEF_MACHINE_LOAD_LIMIT_REQUESTED=off
chief_machine_budget_init
[ "$CHIEF_MACHINE_LOAD_DISABLED" = 1 ] || fail "F: CHIEF_MACHINE_LOAD_LIMIT=off did not disable it"
chief_machine_activity "$RUNS"; chief_machine_load_sample
chief_machine_admits gate || fail "F: load rule still held while disabled"
start=$(date +%s)
chief_machine_gate_admit both-off "" "$WORK/f.log" >/dev/null
[ $(( $(date +%s) - start )) -le 2 ] || fail "F: both controls off and admission still waited"
# ...and with only the LOAD rule off, the agent-turn budget is untouched.
CHIEF_MACHINE_BUDGET_READY=0
CHIEF_MACHINE_BUDGET_REQUESTED=0
chief_machine_budget_init
[ "$CHIEF_MACHINE_BUDGET_DISABLED" = 1 ] || fail "F: the agent-turn budget's own escape hatch stopped working"

echo "LOAD ADMISSION PASS — one sampler feeds display and decision; load 62/4 refuses a gate and a launch; foreign load with chief idle admits immediately; the hold releases when load falls and is bounded when it does not; three independent knobs"
