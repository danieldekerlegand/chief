#!/usr/bin/env bash
# The registry scan counts live agent/gate records and ignores a stale driver.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RUNS="$WORK/runs"; mkdir -p "$RUNS" "$WORK/live/parallel" "$WORK/gate/parallel"
sleep 60 & live_pid=$!
cat > "$RUNS/live.run" <<EOF
pid=$live_pid
state=$WORK/live
names=turn gate
EOF
cat > "$RUNS/stale.run" <<EOF
pid=999999
state=$WORK/live
names=stale
EOF
cat > "$WORK/live/parallel/turn.live.json" <<'EOF'
{"phase":"agent-turn"}
EOF
cat > "$WORK/live/parallel/gate.live.json" <<'EOF'
{"phase":"verifying"}
EOF

# shellcheck source=engine/reap.sh
. "$ROOT/engine/reap.sh"
# shellcheck source=engine/concurrency.sh
. "$ROOT/engine/concurrency.sh"
chief_machine_activity "$RUNS"
[ "$CHIEF_MACHINE_RUNS" = 1 ] || { echo "expected 1 live run, got $CHIEF_MACHINE_RUNS" >&2; exit 1; }
[ "$CHIEF_MACHINE_AGENT_TURNS" = 1 ] || { echo "expected 1 agent turn, got $CHIEF_MACHINE_AGENT_TURNS" >&2; exit 1; }
[ "$CHIEF_MACHINE_GATES" = 1 ] || { echo "expected 1 gate, got $CHIEF_MACHINE_GATES" >&2; exit 1; }
[ "$CHIEF_MACHINE_STALE" = 1 ] || { echo "expected 1 stale record, got $CHIEF_MACHINE_STALE" >&2; exit 1; }
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true
echo "CONCURRENCY PASS — 1 live run, 1 agent turn, 1 gate; 1 stale record ignored"
