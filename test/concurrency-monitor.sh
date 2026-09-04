#!/usr/bin/env bash
# `chief ps` stops overstating headroom, and names both machine holds apart.
#
# The incident line was
#
#   Machine activity: 5 live run(s) · 5 agent turn(s) · 0 gate(s) ·
#                     load average: 14.32 / 14 physical core(s) · OVERSUBSCRIBED
#
# — every number in it true, and read together they said nine free slots on a box
# already past its core count. This asserts the three things that fixes: the counts
# carry their budgets, a HEADROOM line says what admission would actually do, and
# `OVERSUBSCRIBED` is spent only where the ceiling changed a decision.
#
# It also asserts the second machine hold. A worker stopped at the gate boundary is
# neither pending nor dependency-blocked, and used to render as an ordinary running
# row with nothing said about it — indistinguishable from a slow verify.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CHIEF_RUNS="$WORK/runs" CHIEF_LOAD_AVERAGE=62
mkdir -p "$CHIEF_RUNS" "$WORK/state/parallel" "$WORK/tasks"

fail() { echo "$*" >&2; exit 1; }

for n in hold gate work; do
  printf '{"branchName":"chief/%s","userStories":[{"passes":false}]}\n' "$n" > "$WORK/tasks/$n.json"
done
printf 'pid=%s\nrepo=%s\nstate=%s\ntasks=%s\nnames=hold gate work\nparallel=1\nstarted=1\n' \
  "$$" "$WORK" "$WORK/state" "$WORK/tasks" > "$CHIEF_RUNS/hold.run"

# One key per line: `live_get` anchors its sed at the start of a line, so a record
# written as a single JSON object resolves every field to empty and the whole
# fixture renders as `unknown` with nothing counted.
live() { # $1 name  $2 state  $3 phase
  printf '{\n  "name": "%s",\n  "state": "%s",\n  "phase": "%s",\n  "passing": 0,\n  "total": 1\n}\n' \
    "$1" "$2" "$3" > "$WORK/state/parallel/$1.live.json"
}

# Render the whole view against a PINNED machine model. Without the pin,
# `chief_machine_budget_ensure` resolves cores from whatever box this runs on and
# every number below becomes host-dependent — which is how the old version of this
# file passed only on the 14-core machine it was written on.
mon() {
  bash -c '
    . "$1/engine/monitor.sh" lib
    chief_find_unregistered_drivers() { CHIEF_UNREG=""; CHIEF_UNREG_INFO=""; }
    CHIEF_MACHINE_CORES=14
    CHIEF_MACHINE_BUDGET=14;     CHIEF_MACHINE_BUDGET_DISABLED=0
    CHIEF_MACHINE_GATE_BUDGET=2; CHIEF_MACHINE_GATE_BUDGET_DISABLED=0
    CHIEF_MACHINE_LOAD_LIMIT=14; CHIEF_MACHINE_LOAD_DISABLED=0
    CHIEF_MACHINE_BUDGET_READY=1
    render' _ "$ROOT"
}

# ── A. the incident shape: nothing of chief's gating, and a saturated host ─────
# Load 62 on a 14-core ceiling with ZERO chief gates. Admission ADMITS here (the
# bound: chief defers to the load line only while it is contributing to it), so
# the alarm word must not appear — but the line still has to say the machine is
# over the ceiling, or `0 gate(s)` beside it reads as an idle box, which is the
# whole of the reported defect.
live hold pending machine-budget-waiting
live gate pending machine-budget-waiting
live work pending machine-budget-waiting
out="$(mon)"
case "$out" in
  *"OVERSUBSCRIBED"*) fail "A: alarmed on a host it was admitting work onto: $out" ;;
esac
case "$out" in
  *"over ceiling — admitting, no chief gate in flight"*) ;;
  *) fail "A: a saturated host read as idle: $out" ;;
esac
# The counts carry their budgets, and the headroom line is the admission answer.
case "$out" in
  *"0/14 agent turn(s) · 0/2 gate(s)"*) ;;
  *) fail "A: the counts do not name the budgets they are spending: $out" ;;
esac
case "$out" in
  *"headroom: 14 agent turn(s) · 2 gate(s)"*) ;;
  *) fail "A: headroom missing or wrong on an admitting host: $out" ;;
esac

# ── B. OVERSUBSCRIBED is spent only where it changed a decision ────────────────
# One live gate of chief's own, same load. Now the ceiling IS refusing, so the
# word appears — and headroom must read 0 for BOTH budgets even though the gate
# budget has an unspent slot and the agent budget has fourteen. Unspent budget
# behind a control that is refusing is not headroom; reporting it as headroom is
# the arithmetic that made nine free slots out of a saturated machine.
live work running verifying
out="$(mon)"
case "$out" in
  *"OVERSUBSCRIBED — new gates held"*) ;;
  *) fail "B: the ceiling refused a gate and the display did not say so: $out" ;;
esac
case "$out" in
  *"1/2 gate(s)"*) ;;
  *) fail "B: the live gate is not counted against the gate budget: $out" ;;
esac
case "$out" in
  *"headroom: 0 agent turn(s) · 0 gate(s) · holding on machine load: load average 62 over 14 core(s)"*) ;;
  *) fail "B: headroom reported unspent budget behind a refusing control: $out" ;;
esac

# ── C. the two machine holds are different findings ────────────────────────────
# `budget-hold` is work that has not STARTED; `gate-hold` is a live worker stopped
# at the gate boundary. Both are ⏸, and the note has to name the resource that
# actually refused — the row for a load hold may not claim the agent-turn budget
# is full, which is what the old fixed string said whatever had said no.
live gate running gate-budget-waiting
out="$(mon)"
case "$out" in
  *"budget-hold"*) ;;
  *) fail "C: the launch hold lost its row: $out" ;;
esac
case "$out" in
  *"gate-hold"*) ;;
  *) fail "C: a worker held at the gate boundary is indistinguishable from a slow verify: $out" ;;
esac
case "$out" in
  *"↳ waiting: machine load: load average 62 over 14 core(s)"*) ;;
  *) fail "C: a hold row named a resource other than the one that refused: $out" ;;
esac

# ── D. a hold is quiet BY DESIGN ──────────────────────────────────────────────
# Waiting for a slot must not become a false stalled warning while the scheduler is
# doing exactly what it should. Both phases, since both are now rendered.
for phase in machine-budget-waiting gate-budget-waiting; do
  threshold="$(bash -c '. "$1/engine/monitor.sh" lib; stale_threshold_for_phase "$2"' _ "$ROOT" "$phase")"
  [ "$threshold" = 23400 ] || fail "D: $phase is not quiet-by-design (threshold $threshold)"
done

echo "CONCURRENCY MONITOR PASS — budgets, headroom, and both machine holds are visible"
