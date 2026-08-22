#!/usr/bin/env bash
# Prove chief ps exposes host contention and distinguishes a machine-budget hold.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CHIEF_RUNS="$WORK/runs" CHIEF_LOAD_AVERAGE=62
mkdir -p "$CHIEF_RUNS" "$WORK/state/parallel" "$WORK/tasks"
cat > "$WORK/tasks/hold.json" <<'JSON'
{"branchName":"chief/hold","userStories":[{"passes":false}]}
JSON
printf 'pid=%s\nrepo=%s\nstate=%s\ntasks=%s\nnames=hold\nparallel=1\nstarted=1\n' \
  "$$" "$WORK" "$WORK/state" "$WORK/tasks" > "$CHIEF_RUNS/hold.run"
cat > "$WORK/state/parallel/hold.live.json" <<'JSON'
{
  "name": "hold",
  "state": "pending",
  "phase": "machine-budget-waiting",
  "passing": 0,
  "total": 1
}
JSON

# Source the monitor in lib mode so its rendering helpers can be driven without
# starting a watch loop. Override the detected core count for a deterministic fixture.
output="$(bash -c '. "$1/engine/monitor.sh" lib; chief_find_unregistered_drivers() { CHIEF_UNREG=""; CHIEF_UNREG_INFO=""; }; CHIEF_MACHINE_CORES=14; CHIEF_MACHINE_LOAD_AVERAGE=62; render' _ "$ROOT")"
case "$output" in
  *"load average: 62 / 14 physical core(s) · OVERSUBSCRIBED"*) ;;
  *) echo "missing oversubscription line: $output" >&2; exit 1;;
esac
case "$output" in
  *"budget-hold"*"waiting: machine budget is full"*) ;;
  *) echo "missing budget hold row: $output" >&2; exit 1;;
esac

# The phase is intentionally quiet-by-design: waiting for a slot must not become a
# false stalled warning while the scheduler is doing exactly what it should.
threshold="$(bash -c '. "$1/engine/monitor.sh" lib; stale_threshold_for_phase machine-budget-waiting' _ "$ROOT")"
[ "$threshold" = 23400 ] || { echo "unexpected budget wait threshold: $threshold" >&2; exit 1; }
echo "CONCURRENCY MONITOR PASS — load/core contention and budget holds are visible"
