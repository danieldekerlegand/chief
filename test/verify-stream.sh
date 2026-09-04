#!/usr/bin/env bash
# test/verify-stream.sh — the FINAL verify's output reaches the log WHILE the gate is
# still running, and the gate's own exit status still decides the completion.
#
# THE INCIDENT. `_agent_verify_final` (engine/agent.sh) used to run the project's gate
# inside a command substitution:
#
#     output="$(run_verify "$CHIEF_PROJECT" "$CHIEF_TASKLIST" 2>&1)" || rc=$?
#     printf '%s\n' "$output"
#
# Nothing reached the log until the hook RETURNED. talos:83-slice-lane-execution ran
# 7h41m and read `⚠ stalled in agent-turn — no activity for 1h06m` over a branch that
# was healthy in every measurable way — 7 commits, 4/4 stories passing, `stall: 0` —
# whose log ENDED at the completion token, 192 of 192 lines. It did not hang working;
# it hung finishing, invisibly. Its gate launches a real Godot process three times and
# drives a UnityEditor: minutes at best. The verify was probably doing its job.
#
# WHY THE ASSERTION IS A TIMING ONE, AND HAS TO BE. Asserting on the FINAL contents of
# the log cannot tell streaming from buffering — both end with every byte present, in
# the same order. The only observable difference is WHEN.
#
# SO IT IS A HANDSHAKE, NOT A SLEEP. The obvious shape — hook prints, sleeps N seconds,
# prints again — makes the verdict a race between the poll loop and a fixed window, and
# this file runs in the merge gate under `-p N` parallel load, where "the poll was
# descheduled for N seconds" is the one thing that can happen. Instead the hook prints
# its first marker and then BLOCKS until the probe tells it to continue; the probe
# releases it the moment it reads that marker out of the log. Streaming therefore costs
# no wall clock at all and cannot be starved — the hook waits as long as the machine
# needs. Buffering cannot be rescued by the same generosity: the marker is physically
# unable to reach the log before the hook exits, so the wait simply times out (PART C
# shortens that timeout, since it is the only case that ever pays it). The done-file the
# hook touches as its last act is what makes "before it exited" a fact and not an
# inference.
#
#   PART A  the first line is observable while the hook is STILL RUNNING (streaming)
#   PART B  the status is still the HOOK's — a red gate refuses the completion, and
#           the verdict is recorded either way (streaming changed WHEN, not WHAT)
#   PART C  REPRODUCTION — the same probe against an engine whose call is restored to
#           the command-substitution form must NOT see the line live, or PART A is
#           asserting something that was already true.
#   PART D  the PHASE half of the same incident: mid-gate the record reads `verifying`,
#           the gate's own output keeps bumping it, and `chief ps` renders it at 40m
#           quiet with no stall flag (40m is past an agent turn's 900s and inside the
#           3060s this phase has earned since it was measured).
#   PART E  REPRODUCTION for D — drop ONLY the phase publish and the same working gate
#           reads `stalled in agent-turn` again, which is the line talos:83 printed.
#   PART F  the NEGATIVE CONTROL, and the reason D is a fix rather than a trade: a gate
#           that produces nothing and never returns is STILL reported stale once
#           `verifying`'s own 3060s passes. One silent hook, one record, read twice —
#           at 70m quiet it flags, and after a single line of output, at the same age
#           in the same phase, it does not.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=vs GIT_AUTHOR_EMAIL=vs@test GIT_COMMITTER_NAME=vs GIT_COMMITTER_EMAIL=vs@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos" CHIEF_WORKTREE_ROOT="$WORK/wt" CHIEF_PREFIX="$WORK/ch"

note() { printf 'verify-stream: %s\n' "$*"; }
fail() { echo "VERIFY-STREAM FAIL: $*" >&2; [ -f "${LAST_OUT:-}" ] && tail -25 "$LAST_OUT" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

MARK_FIRST='CHIEF-STREAM-FIRST-LINE'
MARK_SECOND='CHIEF-STREAM-SECOND-LINE'
DONE="$WORK/hook.exited"
GO="$WORK/hook.go"
COUNT="$WORK/hook.count"; : > "$COUNT"
hook_runs() { wc -l < "$COUNT" | tr -d ' '; }
# How long the hook will hold the line waiting to be released, in 0.2s ticks. Generous
# for the streaming probes (they never pay it) and short for the buffered control (it
# always pays it, and no amount of waiting could make a captured line appear early).
TICKS_STREAM="${CHIEF_STREAM_TICKS:-300}"
TICKS_BUFFERED="${CHIEF_STREAM_TICKS_BUFFERED:-15}"

# ── the verify hook: print, sleep, print, then announce its own exit ─────────
# The done-file is written LAST, so "the marker is in the log and the done-file is not
# there yet" means exactly "output arrived before the hook exited".
write_hook() { # write_hook green|red
  local rc=0
  [ "$1" = red ] && rc=1
  cat > "$WORK/hook.sh" <<EOF
#!/usr/bin/env bash
printf 'ran\n' >> "$COUNT"
echo "$MARK_FIRST"
# Hold here until the probe has READ that line out of the log, or the wait runs out.
# Only the first invocation of a probe holds: a RED gate does not end the agent loop —
# that is what a red gate is for — so further iterations follow, and the probe deletes
# the done-file before it starts precisely so "not there yet" means "this is the
# invocation being timed".
if [ ! -f "$DONE" ]; then
  _w=0
  while [ ! -f "$GO" ] && [ "\$_w" -lt "\${CHIEF_STREAM_WAIT_TICKS:-$TICKS_BUFFERED}" ]; do
    sleep 0.2; _w=\$(( _w + 1 ))
  done
fi
echo "$MARK_SECOND"
: > "$DONE"
exit $rc
EOF
  chmod +x "$WORK/hook.sh"
}

# ── the fake provider: land a commit, pass the story, emit the token ────────
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat > /dev/null
jq '(.userStories[0].passes)=true' .chief/state/prd.json > .chief/state/prd.tmp
mv .chief/state/prd.tmp .chief/state/prd.json
if [ "${FAKE_COMMIT:-0}" = 1 ]; then
  printf '%s\n' "$FAKE_COMMIT_TOKEN" >> product.txt
  git add -A product.txt
  git commit -q -m "fixture: move the tree ($FAKE_COMMIT_TOKEN)"
fi
printf '%s\n' '{"type":"result","result":"<promise>COMPLETE</promise>","total_cost_usd":0.01,"usage":{"input_tokens":3,"output_tokens":2}}'
FAKE
chmod +x "$WORK/fakebin/claude"

scratch_repo() {
  local repo="$1"
  mkdir -p "$repo/.chief/state" "$repo/tasks/chief"
  git -C "$repo" init -q -b main 2>/dev/null || git -C "$repo" init -q
  cat > "$repo/.chief/state/prd.json" <<'JSON'
{"branchName":"chief/vs","userStories":[{"id":"US-1","title":"t","passes":false,"acceptanceCriteria":["do the thing"],"notes":null}]}
JSON
  cat > "$repo/tasks/chief/vs.json" <<'JSON'
{"branchName":"chief/vs","userStories":[{"id":"US-1","title":"t","passes":false}]}
JSON
  printf '%s\n' '# Chief Progress Log' > "$repo/.chief/state/progress.txt"
  printf '%s\n' 'seed' > "$repo/product.txt"
  git -C "$repo" add -A && git -C "$repo" commit -q -m scaffold
}

# ── the probe: run ONE agent iteration and watch the log while it runs ───────
# `env -u` every CHIEF_* the engine reads and this harness does not set — the suite is
# routinely run from inside a chief worktree whose driver exports CHIEF_VERIFY_HOOK and
# friends, and inheriting one would point this at the real repository's 10-minute gate.
# Sets $FIRST_SEEN_LIVE (1 = the marker was in the log before the hook exited) and
# $AGENT_RC.
probe() { # probe LABEL REPO ENGINE_DIR STATE_DIR COMMIT WAIT_TICKS
  local label="$1" repo="$2" engine="$3" state="$4" commit="$5" ticks="$6" apid deadline
  LAST_OUT="$WORK/$label.out"; : > "$LAST_OUT"
  rm -f "$DONE" "$GO"
  ( cd "$repo" && env \
      -u CHIEF_PRESET -u CHIEF_TOOL -u CHIEF_VERBOSE -u CHIEF_MODEL -u CHIEF_AGENT_CONTEXT \
      -u CHIEF_PAUSE_FILE -u CHIEF_LIVE_FILE -u CHIEF_EVENTS_FILE -u CHIEF_ITER_HOOK \
      -u CHIEF_PRD_SNAPSHOT -u CHIEF_UNVERIFIED_FILE -u CHIEF_RESEARCH -u CHIEF_RESEARCH_FILE \
      -u CHIEF_REVIEW -u CHIEF_TASKS_DIR -u NO_VERIFY -u STRICT_VERIFY \
      FAKE_COMMIT="$commit" FAKE_COMMIT_TOKEN="$label" CHIEF_STREAM_WAIT_TICKS="$ticks" \
      CHIEF_PROVIDER=claude CHIEF_PROJECT="$repo" CHIEF_HOME="$engine" \
      CHIEF_STATE_DIR=.chief/state CHIEF_TASKLIST=vs \
      CHIEF_VERIFY_CACHE_STATE="$state" CHIEF_VERIFY_HOOK="$WORK/hook.sh" \
      CHIEF_VERIFY_TASKS_DIR="$repo/tasks/chief" CHIEF_VERIFY_BASE=main \
      CHIEF_VERIFY_REPO="$repo" STALL_LIMIT=1 \
      PATH="$WORK/fakebin:$PATH" bash "$engine/agent.sh" 1 ) >"$LAST_OUT" 2>&1 &
  apid=$!
  FIRST_SEEN_LIVE=0
  deadline=$(( $(date +%s) + 180 ))
  while kill -0 "$apid" 2>/dev/null; do
    # The done-file is checked FIRST, so a hook that has already exited can never be
    # credited with a live read — the conservative direction.
    [ -f "$DONE" ] && break
    if grep -q "$MARK_FIRST" "$LAST_OUT" 2>/dev/null; then FIRST_SEEN_LIVE=1; break; fi
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 0.2
  done
  : > "$GO"   # release unconditionally: later iterations of a red loop must not block
  AGENT_RC=0; wait "$apid" || AGENT_RC=$?
  return 0
}

# ═══ PART A — the first line is observable while the hook still runs ═════════
write_hook green
REPO="$WORK/repo"; scratch_repo "$REPO"
probe a1 "$REPO" "$ROOT/engine" "$WORK/state" 1 "$TICKS_STREAM"
[ "$AGENT_RC" = 0 ] || fail "PART A: the iteration exited $AGENT_RC (a green hook + a committed COMPLETE must end the loop at 0)"
[ "$(hook_runs)" = 1 ] || fail "PART A: the boundary verify ran $(hook_runs)x, expected 1"
[ "$FIRST_SEEN_LIVE" = 1 ] \
  || fail "PART A: THE GATE IS STILL BUFFERED — '$MARK_FIRST' did not reach the log until the hook had exited. A long verify is indistinguishable from a hang, which is the whole incident."
grep -q "$MARK_SECOND" "$LAST_OUT" || fail "PART A: streaming lost output — the post-sleep line never landed in the log"
grep -q "$MARK_FIRST" "$LAST_OUT" || fail "PART A: streaming lost output — the pre-sleep line is absent from the finished log"
note "PART A ok — the gate's first line was in the log while the gate was still running, and nothing was dropped"

# ═══ PART B — the status is still the hook's, and the verdict still recorded ═
ls "$WORK/state/verify-cache/"*/* >/dev/null 2>&1 \
  || fail "PART B: the GREEN verdict was not recorded — streaming must change WHEN bytes appear, not what the gate decides"

write_hook red
REPO2="$WORK/repo-red"; scratch_repo "$REPO2"
probe b1 "$REPO2" "$ROOT/engine" "$WORK/state-red" 0 "$TICKS_STREAM"
[ "$AGENT_RC" != 0 ] \
  || fail "PART B: a RED gate was accepted as a completion — a streamed run must not lose the hook's exit status (this is what \${PIPESTATUS[0]} is for; a bare \$? would be the ticker's)"
grep -q 'agent verification failed' "$LAST_OUT" || fail "PART B: the failure was not reported to the log"
grep -lq '^status=1' "$WORK/state-red/verify-cache/"*/* 2>/dev/null \
  || fail "PART B: the RED verdict was not recorded"
[ "$FIRST_SEEN_LIVE" = 1 ] || fail "PART B: a red gate's output was buffered as well — streaming is not conditional on the verdict"
note "PART B ok — red still refuses the completion, both verdicts still recorded, and a red gate streams too"

# ═══ PART C — REPRODUCTION ══════════════════════════════════════════════════
# Restore the command-substitution form in a COPY of the engine (not `git show HEAD~N`:
# CI clones shallow) and run PART A's probe again. If the marker is STILL seen live,
# this file is not testing the call it claims to test.
cp -R "$ROOT/engine" "$WORK/engine-old"
sed -i.bak \
  -e 's#^  run_verify "$CHIEF_PROJECT" "$CHIEF_TASKLIST" 2>&1 | tee "$vlog" | _verify_tick#  _o="$(run_verify "$CHIEF_PROJECT" "$CHIEF_TASKLIST" 2>\&1)" || rc=$?; printf "%s\\n" "$_o" > "$vlog"; printf "%s\\n" "$_o"#' \
  -e 's#^  rc=\${PIPESTATUS\[0\]}#  :#' \
  "$WORK/engine-old/agent.sh" && rm -f "$WORK/engine-old/agent.sh.bak"
grep -q '_o="\$(run_verify ' "$WORK/engine-old/agent.sh" \
  || fail "PART C: could not restore the command-substitution form — its anchor moved. Fix this patch, do not delete the reproduction."
grep -qE '^  run_verify "\$CHIEF_PROJECT"' "$WORK/engine-old/agent.sh" \
  && fail "PART C: the patch left the streaming call behind — the control proves nothing"
grep -q 'rc=\${PIPESTATUS\[0\]}' "$WORK/engine-old/agent.sh" \
  && fail "PART C: the patch left the PIPESTATUS read behind — it would report the status of a pipeline that is no longer there"
bash -n "$WORK/engine-old/agent.sh" || fail "PART C: the patched engine does not parse"

write_hook green
REPO3="$WORK/repo-old"; scratch_repo "$REPO3"
probe c1 "$REPO3" "$WORK/engine-old" "$WORK/state-old" 1 "$TICKS_BUFFERED"
[ "$AGENT_RC" = 0 ] || fail "PART C: the iteration on the buffered engine exited $AGENT_RC"
grep -q "$MARK_FIRST" "$LAST_OUT" || fail "PART C: the buffered engine lost the output entirely — the control is not comparable"
[ "$FIRST_SEEN_LIVE" = 0 ] \
  || fail "PART C: the command-substitution engine ALSO streamed — PART A is not observing the change it claims to observe"
note "PART C ok — restoring the capture reinstates the silence; PART A is measuring the fix"


# ═══ PART D — the phase whose threshold was written for exactly this ════════
# The second half of the incident, and the nearly-free one. `monitor.sh`'s
# STALE_PHASE_SECONDS has given `verifying` 3060s since it was measured — a gate
# legitimately runs for tens of minutes — but the phase had exactly ONE publisher
# (driver.sh's merge-phase verify). `_agent_verify_final` never said it was verifying,
# so ITS gate was timed as an agent turn against 900s. talos:83 read
# `⚠ stalled in agent-turn — no activity for 1h06m` while the gate it was waiting on
# was doing its job. The right threshold existed; this path did not use it.
#
# Three facts, against a REAL running verify rather than a synthetic record:
#   1. while the hook is mid-run the record reads `phase=verifying`
#   2. the heartbeat is bumped BY THE OUTPUT — the record is backdated mid-verify and
#      the next line the hook emits brings it back. That is what makes it a ticker and
#      not a single publish, and it is why a gate that stops emitting stops beating
#      (the negative control that guards is US-3's).
#   3. `chief ps` renders it. A phase nobody can see in the monitor has not been
#      published where it matters — so the record is aged to 40m, which is past an
#      agent turn's 900s and inside a verify's 3060s, and the row is read.
GO2="$WORK/hook.go2"
STALE_AGE=2400          # 40m: > provider-waiting/agent-turn's 900s, < verifying's 3060s

# The three-marker hook: emit, block, wait out a beat interval, emit, block, exit.
# The 1.5s gap is the only sleep in this file and it is load-SAFE in the one direction
# that matters: $SECONDS can only be larger under load, never smaller, so the tick the
# second marker is asserted to cause can be late but cannot be skipped.
write_phase_hook() {
  cat > "$WORK/phook.sh" <<EOF
#!/usr/bin/env bash
printf 'ran\n' >> "$COUNT"
echo "$MARK_FIRST"
_w=0; while [ ! -f "$GO" ] && [ "\$_w" -lt $TICKS_STREAM ]; do sleep 0.2; _w=\$(( _w + 1 )); done
sleep 1.5
echo "$MARK_SECOND"
_w=0; while [ ! -f "$GO2" ] && [ "\$_w" -lt $TICKS_STREAM ]; do sleep 0.2; _w=\$(( _w + 1 )); done
: > "$DONE"
exit 0
EOF
  chmod +x "$WORK/phook.sh"
}

# await MARKER LOG PID -> 0 when the marker reached the log while $PID was still alive
await() {
  local m="$1" log="$2" pid="$3" deadline
  deadline=$(( $(date +%s) + 180 ))
  while kill -0 "$pid" 2>/dev/null; do
    grep -q "$m" "$log" 2>/dev/null && return 0
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.2
  done
  return 1
}
# Rewrite the record's clocks to AGE seconds ago, in place — live.sh always stamps
# `now`, so this is the only way to ask the render what it would say at 40m without
# waiting 40m. Same instrument test/stall-flag.sh's mkrow uses, and both fields for the
# same reason it uses both: `heartbeat` is what the stall flag reads and `phase_since`
# is what "verifying for 40m" reads, and the row has to be coherent in both.
# live_set preserves phase_since across a write that does not CHANGE the phase, so a
# backdate survives the ticker — which is exactly what makes it a probe of the ticker.
backdate() { # backdate FILE AGE
  local k v t now; now="$(date +%s)"
  for k in heartbeat phase_since; do
    v="$(live_get "$1" "$k")"; t="$1.bd"
    sed "s/\"$k\": $v/\"$k\": $(( now - $2 ))/" "$1" > "$t" && mv "$t" "$1"
  done
}

# THE ONE RACE THIS FILE HAS TO PROBE AROUND, and it is not a defect in the engine.
# `_verify_tick` prints a line and THEN writes the record — so at the instant a marker
# reaches the log, that write is still in flight. Sampling either side of it once is
# wrong in both directions, and both were observed under the parallel load of the
# bystander suite (6 concurrent runs of this file; standalone it never showed):
#
#   the backdate is CLOBBERED — the in-flight tick lands after the `sed` and restores
#   the record to `now`. PART D then measures a heartbeat that was never aged and reads
#   HB_TICKED=0; PART E's 40m row renders `↳ agent-turn for 40m · iter 1 · 0s ago` and
#   takes no flag, so the reproduction stops reproducing.
#
#   the tick HAS NOT LANDED — `hb_after` is read the moment the marker appears, which
#   is before the bump, and a working ticker reads as a dead one.
#
# PART F states the rule for the second half in its own words ("The marker reaching the
# LOG is not the tick") and establishes quiescence by hand for the first. These two
# helpers are that discipline, factored so D and E cannot drift from it.

# backdate_settled FILE AGE — backdate, and CONFIRM the write survived. Every call site
# is a point where the hook is BLOCKED on a release file, so at most one tick can be in
# flight: once a read-back comes back aged it STAYS aged, and re-asserting until it does
# is bounded. Also covers the quieter form of the clobber — a tick landing between
# `backdate`'s own `live_get` and its `sed` leaves the pattern unmatched and the file
# untouched, which looks identical to success.
backdate_settled() { # backdate_settled FILE AGE
  local v deadline; deadline=$(( $(date +%s) + 60 ))
  while :; do
    backdate "$1" "$2"
    v="$(live_get "$1" heartbeat)"; [ -n "$v" ] || v=0
    [ "$(( $(date +%s) - v ))" -ge "$(( $2 / 2 ))" ] && return 0
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.2
  done
}

# await_tick FILE FLOOR — wait for the heartbeat to rise past FLOOR, rather than
# sampling it once and calling a write that has not happened yet a ticker that is dead.
await_tick() { # await_tick FILE FLOOR
  local deadline; deadline=$(( $(date +%s) + 60 ))
  while [ "$(live_get "$1" heartbeat)" -le "$2" ]; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.2
  done
  return 0
}

# shellcheck source=engine/live.sh
. "$ROOT/engine/live.sh"

# spawn_iteration LABEL REPO ENGINE LIVE CACHE HOOK — ONE agent iteration in the
# background, logging to $LAST_OUT, with $HOOK as the project's gate. Sets $APID.
# Shared by the phase probe and by PART F's silent one so the two differ ONLY in the
# hook they are handed: a launcher copied per part is a launcher that drifts, and a
# control whose environment is not its subject's is not a control.
spawn_iteration() {
  LAST_OUT="$WORK/$1.out"; : > "$LAST_OUT"
  ( cd "$2" && env \
      -u CHIEF_PRESET -u CHIEF_TOOL -u CHIEF_VERBOSE -u CHIEF_MODEL -u CHIEF_AGENT_CONTEXT \
      -u CHIEF_PAUSE_FILE -u CHIEF_EVENTS_FILE -u CHIEF_ITER_HOOK \
      -u CHIEF_PRD_SNAPSHOT -u CHIEF_UNVERIFIED_FILE -u CHIEF_RESEARCH -u CHIEF_RESEARCH_FILE \
      -u CHIEF_REVIEW -u CHIEF_TASKS_DIR -u NO_VERIFY -u STRICT_VERIFY \
      FAKE_COMMIT=1 FAKE_COMMIT_TOKEN="$1" LIVE_BEAT_SECONDS=1 \
      CHIEF_PROVIDER=claude CHIEF_PROJECT="$2" CHIEF_HOME="$3" \
      CHIEF_STATE_DIR=.chief/state CHIEF_TASKLIST=vs CHIEF_LIVE_FILE="$4" \
      CHIEF_VERIFY_CACHE_STATE="$5" CHIEF_VERIFY_HOOK="$6" \
      CHIEF_VERIFY_TASKS_DIR="$2/tasks/chief" CHIEF_VERIFY_BASE=main \
      CHIEF_VERIFY_REPO="$2" STALL_LIMIT=1 \
      PATH="$WORK/fakebin:$PATH" bash "$3/agent.sh" 1 ) >"$LAST_OUT" 2>&1 &
  APID=$!
}

# ps_row LABEL PID REPO STATE — what `chief ps` renders for tasklist `vs` RIGHT NOW,
# as one joined string. This file drives engine/agent.sh directly (test/verify-cache.sh's
# discipline — no driver, one second), so the run registry the view reads has to be
# synthesized here. Callable repeatedly on purpose: PART F asks the same question of the
# same record twice, with nothing changing between the two renders but the gate's output.
ps_row() {
  local pid="$2" repo="$3" st="$4" rundir="$WORK/runs-$1"
  mkdir -p "$rundir" "$st/parallel" "$repo/tasks/chief"
  echo running > "$st/parallel/vs.state"
  cat > "$rundir/$pid.run" <<EOF
pid=$pid
repo=$repo
base=main
parallel=1
tool=claude
automerge=1
limitmax=3
started=$(date +%s)
state=$st
staterel=.chief/state
tasks=$repo/tasks/chief
wt=$WORK/wt
names=vs
EOF
  CHIEF_RUNS="$rundir" bash "$ROOT/engine/monitor.sh" once 2>/dev/null \
    | grep -A1 'vs ' | tr -d '\n'
}

# phase_probe LABEL ENGINE_DIR — one iteration whose gate is the three-marker hook,
# observed from outside while it runs. Sets $PHASE_AT_VERIFY, $HB_TICKED (1 = the
# output moved the record after it was backdated) and $PS_ROW.
phase_probe() {
  local label="$1" engine="$2" repo st live apid hb_before
  repo="$WORK/repo-$label"; scratch_repo "$repo"
  st="$WORK/state-$label"; live="$st/parallel/vs.live.json"
  mkdir -p "$st/parallel"
  rm -f "$DONE" "$GO" "$GO2"
  spawn_iteration "$label" "$repo" "$engine" "$live" "$WORK/cache-$label" "$WORK/phook.sh"
  apid=$APID

  PHASE_AT_VERIFY=""; HB_TICKED=0; PS_ROW=""; hb_before=""
  if await "$MARK_FIRST" "$LAST_OUT" "$apid"; then
    PHASE_AT_VERIFY="$(live_get "$live" phase)"
    # The ticker's only way to prove itself — and it has to SURVIVE the first line's
    # own tick, or the baseline it is measured against is just `now`.
    backdate_settled "$live" 4000 \
      || fail "PART D/E: the backdate never held — something kept restoring the record while the gate was blocked, so the ticker cannot be measured against it"
    hb_before="$(live_get "$live" heartbeat)"
  fi
  : > "$GO"
  if await "$MARK_SECOND" "$LAST_OUT" "$apid"; then
    if [ -n "$hb_before" ] && await_tick "$live" "$(( hb_before + 100 ))"; then HB_TICKED=1; fi
    # …and now what `chief ps` says about it at 40m of quiet. The second line's tick
    # has landed by here and the hook is blocked on $GO2, so the record is quiescent.
    backdate_settled "$live" "$STALE_AGE" \
      || fail "PART D/E: the record would not stay aged to ${STALE_AGE}s for the render"
    PS_ROW="$(ps_row "$label" "$apid" "$repo" "$st")"
  fi
  : > "$GO2"
  AGENT_RC=0; wait "$apid" || AGENT_RC=$?
  return 0
}

write_phase_hook
: > "$COUNT"
phase_probe d1 "$ROOT/engine"
[ "$AGENT_RC" = 0 ] || fail "PART D: the iteration exited $AGENT_RC (a green hook + a committed COMPLETE must end the loop at 0)"
[ "$PHASE_AT_VERIFY" = verifying ] \
  || fail "PART D: the record read '$PHASE_AT_VERIFY' while the final verify was running, not 'verifying' — the gate is still being timed as an agent turn (900s) instead of against the 3060s the phase already earns"
[ "$HB_TICKED" = 1 ] \
  || fail "PART D: the record was NOT bumped by the gate's own output — a phase published once and then left is a single write, not a heartbeat, and the row goes quiet exactly as it did before"
case "$PS_ROW" in
  *'verifying for 40m'*) ;;
  *) fail "PART D: chief ps did not render the running verify as 'verifying for 40m': $PS_ROW" ;;
esac
case "$PS_ROW" in
  *stalled*) fail "PART D: chief ps flagged a 40m verify as stalled — 40m is inside the 3060s that phase earned: $PS_ROW" ;;
  *'⚠'*)     fail "PART D: chief ps still took the ⚠ glyph on a 40m verify: $PS_ROW" ;;
esac
note "PART D ok — mid-gate the record reads 'verifying', the output keeps bumping it, and chief ps renders '$(printf '%s' "$PS_ROW" | sed 's/.*\(verifying for [0-9a-z]*\).*/\1/')' with no stall flag"

# ═══ PART E — REPRODUCTION ══════════════════════════════════════════════════
# Drop ONLY the phase publish from a copy of the engine — the streaming and the ticker
# stay — and the same 40m of a working gate becomes the incident's own line again.
cp -R "$ROOT/engine" "$WORK/engine-nophase"
sed -i.bak 's#^  live_set "$LIVE" phase=verifying$#  :#' "$WORK/engine-nophase/agent.sh" \
  && rm -f "$WORK/engine-nophase/agent.sh.bak"
grep -q '^  live_set "\$LIVE" phase=verifying$' "$WORK/engine-nophase/agent.sh" \
  && fail "PART E: the patch left the phase publish in place — the control proves nothing"
bash -n "$WORK/engine-nophase/agent.sh" || fail "PART E: the patched engine does not parse"

: > "$COUNT"
phase_probe e1 "$WORK/engine-nophase"
[ "$PHASE_AT_VERIFY" != verifying ] \
  || fail "PART E: the un-published engine ALSO read 'verifying' — PART D is not observing the change it claims to observe"
case "$PS_ROW" in
  *stalled*) ;;
  *) fail "PART E: without the publish a 40m gate was NOT flagged ('$PS_ROW'); the control has to reproduce the incident, or PART D's silence means nothing" ;;
esac
note "PART E ok — with the publish removed the same 40m gate reads '$(printf '%s' "$PS_ROW" | sed 's/.*\(stalled in [a-z-]*\).*/\1/')', which is the line the incident printed"

# ═══ PART F — THE NEGATIVE CONTROL: a gate that says nothing STILL flags ════
# The fix must not buy quiet by making `verifying` unflaggable. `monitor.sh` refuses
# that trade in writing for provider-waiting — "It wants a LONGER threshold, not
# silence" — and the same sentence binds here: PART D moved a healthy gate out of the
# flag's way, and if it moved a WEDGED one out with it, the incident has been traded
# for a blind spot rather than fixed.
#
# THE TWO CASES THE INCIDENT CONFLATED, held apart by ONE record. A single silent hook
# is driven through both readings, and between the two renders NOTHING changes but
# whether the gate emitted:
#
#   F1  the hook is inside the gate and has produced no bytes at all. The record is
#       aged to 70m — PAST the 3060s (51m) `verifying` itself earns, so the phase's
#       longer threshold has EXPIRED rather than exempted it — and nothing rescues it:
#       the heartbeat is still exactly where it was aged to, because the only ticker on
#       this path is the output, and there is none. `chief ps` must say so.
#   F2  the SAME record, the SAME phase, the SAME age IN the phase (`live_set`
#       preserves `phase_since` across a write that does not change the phase, so
#       `verifying for 1h10m` survives) — and one line of output arrives. The flag
#       must go, and only the flag.
#
# Same age, opposite verdicts, and the difference is the emission. That is the
# distinction `chief ps` failed to draw on talos:83, stated as an assertion.
STALE_VERIFY=4200        # 70m — past verifying's own 3060s, not merely past 900s

# The silent hook: not one byte on stdout, and it does not return. It signals its own
# start by APPENDING TO A FILE, which is the only channel a gate that produces no
# output has — and the point of the control is that the monitor has no such channel.
cat > "$WORK/shook.sh" <<EOF
#!/usr/bin/env bash
printf 'ran\n' >> "$COUNT"
_w=0; while [ ! -f "$GO" ] && [ "\$_w" -lt $TICKS_STREAM ]; do sleep 0.2; _w=\$(( _w + 1 )); done
echo "$MARK_FIRST"
_w=0; while [ ! -f "$GO2" ] && [ "\$_w" -lt $TICKS_STREAM ]; do sleep 0.2; _w=\$(( _w + 1 )); done
exit 0
EOF
chmod +x "$WORK/shook.sh"

: > "$COUNT"
rm -f "$DONE" "$GO" "$GO2"
FREPO="$WORK/repo-f1"; scratch_repo "$FREPO"
FST="$WORK/state-f1"; FLIVE="$FST/parallel/vs.live.json"; mkdir -p "$FST/parallel"
spawn_iteration f1 "$FREPO" "$ROOT/engine" "$FLIVE" "$WORK/cache-f1" "$WORK/shook.sh"
FPID=$APID

# Wait for the gate to be INSIDE the wedged hook — phase published and the hook entered.
# `verify_branch` prints nothing of its own before it execs the hook, so once the hook
# has recorded its start there is no in-flight byte left to tick the record.
fdeadline=$(( $(date +%s) + 180 ))
while kill -0 "$FPID" 2>/dev/null; do
  [ "$(live_get "$FLIVE" phase)" = verifying ] && [ "$(hook_runs)" -ge 1 ] && break
  [ "$(date +%s)" -ge "$fdeadline" ] && break
  sleep 0.2
done
[ "$(live_get "$FLIVE" phase)" = verifying ] && [ "$(hook_runs)" -ge 1 ] \
  || fail "PART F: the silent gate never entered — phase '$(live_get "$FLIVE" phase)', $(hook_runs) hook run(s)"

backdate "$FLIVE" "$STALE_VERIFY"
HB0="$(live_get "$FLIVE" heartbeat)"; PSINCE0="$(live_get "$FLIVE" phase_since)"
sleep 2.5     # several LIVE_BEAT_SECONDS: a TIMER-driven ticker would show itself here
STALE_ROW="$(ps_row f1 "$FPID" "$FREPO" "$FST")"
[ "$(live_get "$FLIVE" heartbeat)" = "$HB0" ] \
  || fail "PART F: something bumped the record while the gate produced nothing — a heartbeat that beats on a timer makes 'verifying' unflaggable, which is the bug in the other direction"
case "$STALE_ROW" in
  *'stalled in verifying'*) ;;
  *) fail "PART F: a wedged, silent gate at 70m was NOT reported stale — the phase has been exempted rather than given a longer threshold: $STALE_ROW" ;;
esac
case "$STALE_ROW" in
  *'past its 51m limit'*) ;;
  *) fail "PART F: the flag did not name verifying's own 3060s limit, so it is being timed against some other phase's: $STALE_ROW" ;;
esac
note "PART F1 ok — a gate that emits nothing still reads '$(printf '%s' "$STALE_ROW" | sed 's/.*\(stalled in verifying[^·]*\).*/\1/' | sed 's/ *$//')'"

# ── F2: the same record, the same age in phase, one line of output ───────────
: > "$GO"
await "$MARK_FIRST" "$LAST_OUT" "$FPID" || fail "PART F: the released gate never emitted"
# The marker reaching the LOG is not the tick: `_verify_tick` prints the line and THEN
# writes the record, so the heartbeat is what has to be waited on.
fdeadline=$(( $(date +%s) + 60 ))
while [ "$(live_get "$FLIVE" heartbeat)" -le "$HB0" ] && [ "$(date +%s)" -lt "$fdeadline" ]; do sleep 0.2; done
[ "$(live_get "$FLIVE" heartbeat)" -gt "$HB0" ] \
  || fail "PART F: the gate emitted and the record did not move — the output-driven ticker is dead, and every long verify goes back to reading as a hang"
[ "$(live_get "$FLIVE" phase_since)" = "$PSINCE0" ] \
  || fail "PART F: the tick moved phase_since as well — F1 and F2 must differ in the heartbeat ALONE, or they are not the same reading twice"
LIVE_ROW="$(ps_row f1 "$FPID" "$FREPO" "$FST")"
case "$LIVE_ROW" in
  *stalled*) fail "PART F: the gate resumed emitting and the row stayed flagged: $LIVE_ROW" ;;
  *'⚠'*)     fail "PART F: the gate resumed emitting and the row kept the ⚠ glyph: $LIVE_ROW" ;;
esac
case "$LIVE_ROW" in
  *'verifying for 1h'*) ;;
  *) fail "PART F: the row lost the phase clock — an emitting gate is still a gate that has been running over an hour, and the operator needs both numbers: $LIVE_ROW" ;;
esac
: > "$GO2"
AGENT_RC=0; wait "$FPID" || AGENT_RC=$?
[ "$AGENT_RC" = 0 ] || fail "PART F: the iteration exited $AGENT_RC (the silent hook exits green, so the completion must be accepted)"
[ "$(hook_runs)" = 1 ] || fail "PART F: the boundary verify ran $(hook_runs)x, expected 1"
note "PART F2 ok — one line of output on the SAME 70m-old record clears the flag and keeps the phase clock; long and hung are now two different rows"

echo "VERIFY-STREAM OK"
