#!/usr/bin/env bash
# Two registered runs share one machine-wide agent-turn slot; the second waits
# until the first driver's live record disappears.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RUNS="$WORK/runs"; mkdir -p "$RUNS" "$WORK/one/parallel" "$WORK/two/parallel"
sleep 60 & first_pid=$!
cat > "$RUNS/one.run" <<EOF
pid=$first_pid
state=$WORK/one
names=first
EOF
cat > "$RUNS/two.run" <<EOF
pid=$$
state=$WORK/two
names=second
EOF
printf '{"phase":"agent-turn"}\n' > "$WORK/one/parallel/first.live.json"
printf '{"phase":"pending"}\n' > "$WORK/two/parallel/second.live.json"
# BEFORE the source, not after. concurrency.sh captures the operator's request into
# CHIEF_MACHINE_BUDGET_REQUESTED at file level (a later assignment to
# CHIEF_MACHINE_BUDGET is just the value `chief_machine_budget_init` overwrites), so
# setting it afterwards left the budget at the CORE COUNT and this file asserted
# nothing on any host with more than one core.
export CHIEF_MACHINE_BUDGET=1
. "$ROOT/engine/reap.sh"
. "$ROOT/engine/concurrency.sh"
chief_machine_budget_init
chief_machine_activity "$RUNS"
[ "$CHIEF_MACHINE_AGENT_TURNS" = 1 ] || { echo "expected one live agent turn" >&2; exit 1; }
if chief_machine_budget_allows; then
  echo "second run did not hold at budget one" >&2; exit 1
fi
kill "$first_pid" 2>/dev/null || true; wait "$first_pid" 2>/dev/null || true
chief_machine_activity "$RUNS"
chief_machine_budget_allows
echo "MACHINE BUDGET PASS — second run held at 1/1, then proceeded after first finished"
