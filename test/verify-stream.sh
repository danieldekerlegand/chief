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
  || fail "PART B: a RED gate was accepted as a completion — a streamed run must not lose the hook's exit status (this is why the fix is a redirection and not a \`| tee\` pipeline)"
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
sed -i.bak 's#^  run_verify "$CHIEF_PROJECT" "$CHIEF_TASKLIST" 2>&1 || rc=\$?#  _o="$(run_verify "$CHIEF_PROJECT" "$CHIEF_TASKLIST" 2>\&1)" || rc=$?; printf "%s\\n" "$_o"#' \
  "$WORK/engine-old/agent.sh" && rm -f "$WORK/engine-old/agent.sh.bak"
grep -q '_o="\$(run_verify ' "$WORK/engine-old/agent.sh" \
  || fail "PART C: could not restore the command-substitution form — its anchor moved. Fix this patch, do not delete the reproduction."
grep -qE '^  run_verify "\$CHIEF_PROJECT"' "$WORK/engine-old/agent.sh" \
  && fail "PART C: the patch left the streaming call behind — the control proves nothing"
bash -n "$WORK/engine-old/agent.sh" || fail "PART C: the patched engine does not parse"

write_hook green
REPO3="$WORK/repo-old"; scratch_repo "$REPO3"
probe c1 "$REPO3" "$WORK/engine-old" "$WORK/state-old" 1 "$TICKS_BUFFERED"
[ "$AGENT_RC" = 0 ] || fail "PART C: the iteration on the buffered engine exited $AGENT_RC"
grep -q "$MARK_FIRST" "$LAST_OUT" || fail "PART C: the buffered engine lost the output entirely — the control is not comparable"
[ "$FIRST_SEEN_LIVE" = 0 ] \
  || fail "PART C: the command-substitution engine ALSO streamed — PART A is not observing the change it claims to observe"
note "PART C ok — restoring the capture reinstates the silence; PART A is measuring the fix"

echo "VERIFY-STREAM OK"
