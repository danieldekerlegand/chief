#!/usr/bin/env bash
# test/limitmonitor.sh — a usage-limit PAUSE must be legible in `chief ps`.
#
# US-4 of tasks/chief/70-usage-limit-selfheal: a run interrupted by a Claude
# usage/session limit self-heals (driver.sh waits out the window and re-dispatches),
# so while it waits the monitor must show "paused: usage limit — retry at <time>",
# NOT something that reads like a failure, a block, or a hang.
#
# This drives engine/monitor.sh directly against a synthetic run registry + the
# on-disk scheduler state the driver writes (<name>.state, <name>.retry-at,
# <name>.retries, .limit-pause-until). No driver, no agent, no git — so it is fast
# and has none of the timing sensitivity that keeps test/monitor.sh out of the
# merge gate's behavioral subset.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
holder=""
cleanup() {
  if [ -n "$holder" ]; then
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true    # reap it quietly: no "Terminated" job notice
  fi
  rm -rf "$WORK"
}
trap 'rc=$?; cleanup; exit "$rc"' EXIT   # keep the real verdict: `wait` on the killed holder returns 143
fail() { echo "LIMITMONITOR FAIL: $*" >&2; [ -n "${out:-}" ] && printf '%s\n' "--- chief ps ---" "$out" >&2; exit 1; }
has()  { case "$out" in *"$1"*) ;; *) fail "$2" ;; esac; }

STATE="$WORK/state"; PAR="$STATE/parallel"; RUNS="$WORK/runs"
mkdir -p "$PAR" "$RUNS" "$WORK/repo" "$WORK/tasks" "$WORK/wt"

# A live pid to own the run file — the monitor prunes run files whose pid is dead.
sleep 60 & holder=$!

NOW="$(date +%s)"
RESET=$(( NOW + 900 ))                    # 15 minutes out
ETA="$(date -r "$RESET" '+%H:%M' 2>/dev/null || date -d "@$RESET" '+%H:%M')"

# The five states the operator must be able to tell apart at a glance. Two paused
# tasklists: one with the reset epoch the worker parsed, one with no ETA at all.
echo rate-limited > "$PAR/pause-eta.state";  printf '%s' "$RESET" > "$PAR/pause-eta.retry-at"
printf '1' > "$PAR/pause-eta.retries"
echo rate-limited > "$PAR/pause-noeta.state"
echo running      > "$PAR/work-run.state"
echo failed       > "$PAR/dead-fail.state"
echo blocked      > "$PAR/dead-block.state"

cat > "$RUNS/$holder.run" <<EOF
pid=$holder
repo=$WORK/repo
base=main
parallel=2
tool=claude
automerge=1
limitmax=3
started=$NOW
state=$STATE
staterel=.chief/state
tasks=$WORK/tasks
wt=$WORK/wt
names=pause-eta pause-noeta work-run dead-fail dead-block
EOF

out="$(CHIEF_RUNS="$RUNS" bash "$ROOT/engine/monitor.sh" once)" || fail "monitor.sh exited non-zero"
echo "--- chief ps (synthetic paused run) ---"; printf '%s\n' "$out"

# 1) The paused tasklist reads as paused, with the ETA and the re-dispatch budget.
has 'pause-eta'                    "the paused tasklist is missing from the output"
has 'paused'                       "state 'rate-limited' didn't render as 'paused'"
has "retry at $ETA"                "no retry ETA for the paused tasklist (expected $ETA)"
has 'usage limit'                  "the pause doesn't say what it's waiting on"
has 're-dispatch 1/3'              "no re-dispatch count/cap (retries=1, limitmax=3)"
has '(15m)'                        "no relative countdown to the reset"

# 2) Unknown ETA still reads as a pause that will retry — never as a hang.
has 'retries when the window resets' "a paused tasklist with no ETA lost its explanation"

# 3) …and it is NOT confused with the terminal/active states.
has 'running'                      "the running tasklist stopped rendering"
has 'failed'                       "the failed tasklist stopped rendering"
has 'blocked'                      "the blocked tasklist stopped rendering"
for bad in 'pause-eta   *failed' 'pause-eta   *blocked'; do
  case "$out" in *"$bad"*) fail "the paused tasklist rendered as $bad" ;; esac
done
# The paused row must not borrow the failed/blocked glyphs.
line="$(printf '%s\n' "$out" | grep 'pause-eta ' || true)"
case "$line" in *'✗'*|*'⤬'*) fail "paused row uses a failure glyph: $line" ;; esac
case "$line" in *'⏸'*) ;; *) fail "paused row is missing the pause glyph: $line" ;; esac

echo "LIMITMONITOR PASS — a usage-limit pause renders as 'paused: usage limit — retry at $ETA · re-dispatch 1/3', distinct from running/failed/blocked"
