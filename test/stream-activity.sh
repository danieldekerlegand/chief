#!/usr/bin/env bash
# test/stream-activity.sh — WHAT THE AGENT IS DOING, WHILE IT IS STILL DOING IT.
#
# THE INCIDENT (2026-09-15, a live run). A tasklist sat at `provider-waiting for 16m
# · iter 1` with its per-iteration log untouched for seventeen minutes and an operator
# could not tell work from a hang. It was working — the provider had run a Bash tool
# call 8 seconds earlier — but `claude --print --output-format json` emits ONE object
# when the whole turn FINISHES, so chief had nothing to display. The silence was not a
# rendering choice; it was an absence of data. `stream-json` is where the data is.
#
# WHAT IS ASSERTED, AND WHY EACH PART EXISTS:
#   PART A  THE INVOCATION, and the capability that decides it. Streaming is asked
#           for only when the CLI's own help says it exists; the operator's knob and
#           a CLI that never heard of it both produce BYTE-FOR-BYTE today's argv.
#   PART B  USAGE PARITY, MEASURED. The tasklist's third refusal: a turn's cost may
#           not depend on a display feature. Both modes are RUN over the same result
#           object and the two `agent.turn` events' `usage` must be identical — a
#           measurement, not a reading of _parse_usage.
#   PART C  A LIMIT THAT ARRIVES IN A STREAM is still a limit (exit 2), not a stall.
#   PART D  THE LIVE RECORD, SAMPLED MID-TURN. The fields only exist while the turn
#           runs, so the fixture provider samples them itself and then finishes.
#   PART E  A MALFORMED AND A TRUNCATED LINE, in the SAME turn: neither invents a
#           tool call, neither breaks the turn, and the truncated one is counted once
#           it completes — proving the offset survived it rather than stalling on it.
#   PART F  CAPABILITY OFF = today. Same result, same usage, and a live record whose
#           new fields are empty — which is also what an older engine's record is.
#   PART G  REPRODUCTION. Against an engine whose _stream_activity is neutered, the
#           PART D sample carries nothing — so PART D cannot be restating a row that
#           was already being written.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=sa GIT_AUTHOR_EMAIL=sa@test GIT_COMMITTER_NAME=sa GIT_COMMITTER_EMAIL=sa@test
# hermetic: this drives agent.sh directly, but must still never touch ~/.chief
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos" CHIEF_WORKTREE_ROOT="$WORK/wt" CHIEF_PREFIX="$WORK/ch"

note() { printf 'stream-activity: %s\n' "$*"; }
fail() { echo "STREAM-ACTIVITY FAIL: $*" >&2; [ -f "${LAST_OUT:-}" ] && tail -30 "$LAST_OUT" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

ARGV_LOG="$WORK/argv.log"; : > "$ARGV_LOG"

# ── the verify hook: trivially green, and OUTSIDE the repo so it never moves the tree
cat > "$WORK/hook.sh" <<'EOF'
#!/usr/bin/env bash
echo "fixture verify hook ran in $PWD"
exit 0
EOF
chmod +x "$WORK/hook.sh"

# ── the fake provider ────────────────────────────────────────────────────────
# ONE binary, four behaviours, all chosen by env — so every part below is compared
# against the same program and a difference in the log is a difference in the ENGINE.
#
# It answers `--help` because the capability probe asks it: that IS the seam under
# test, and $FAKE_HELP_STREAM is how PART A withdraws the capability. Note the probe
# must not be able to hang on a provider that reads stdin — the help arm returns
# before the `cat`, and the engine redirects the probe's stdin from /dev/null.
#
# THE RESULT OBJECT IS ONE STRING, shared verbatim by both modes. That is what makes
# PART B a parity measurement rather than two unrelated runs: in streaming mode it is
# the LAST line of an NDJSON stream, in json mode it is the WHOLE output.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$ARGV_LOG"

streaming=0
case " $* " in *" stream-json "*) streaming=1 ;; esac

# A CLI OLDER THAN THE FLAG. It refuses the OPTION — before the request, in
# milliseconds, with no result envelope and nothing spent — which is exactly the
# event chief recognises. Note it refuses BEFORE reading stdin, as a real CLI
# rejecting an unknown option does.
if [ "$streaming" = 1 ] && [ "${FAKE_OLD_CLI:-0}" = 1 ]; then
  printf 'error: unknown option: --output-format stream-json\n' >&2
  exit 2
fi

cat > /dev/null   # swallow the composed prompt, exactly as a real --print turn does

RESULT='{"type":"result","subtype":"success","duration_ms":1234,"num_turns":3,"total_cost_usd":0.0421,"usage":{"input_tokens":1200,"output_tokens":340},"result":"%RESULT_TEXT%"}'
case "${FAKE_LIMIT:-0}" in
  1) RESULT="${RESULT/\%RESULT_TEXT\%/Claude AI usage limit reached|1795000000}" ;;
  *) RESULT="${RESULT/\%RESULT_TEXT\%/<promise>COMPLETE</promise>}" ;;
esac

# Land a commit and pass the story ONCE per run, so a repeated turn cannot run the
# loop to its ceiling (verify-cache.sh's rule, same reason).
land() {
  jq '(.userStories[0].passes)=true' .chief/state/prd.json > .chief/state/prd.tmp
  mv .chief/state/prd.tmp .chief/state/prd.json
  if ! grep -qxF "$FAKE_TOKEN" product.txt; then
    printf '%s\n' "$FAKE_TOKEN" >> product.txt
    git add -A product.txt && git commit -q -m "fixture: $FAKE_TOKEN"
  fi
}

if [ "$streaming" = 1 ]; then
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"s1","tools":["Bash","Read","Grep"]}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"let me look at the engine"},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/engine/agent.sh"}}]}}'
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"...file body..."}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"grep -n \"type\": \"tool_use\" engine/agent.sh"}}]}}'
  if [ "${FAKE_MALFORMED:-0}" = 1 ]; then
    # (a) prose that is not JSON at all, and (b) a tool_use envelope with NO name —
    # neither may be counted.  (c) a line CUT IN HALF, left dangling with no newline.
    printf '%s\n' 'warning: this line is not JSON at all {{{'
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t9"}]}}'
    printf '%s' '{"type":"assistant","message":{"content":[{"type":"tool_'
  fi
  sleep "${FAKE_SLEEP:-3}"
  [ -n "${FAKE_MID1:-}" ] && cp "$CHIEF_LIVE_FILE" "$FAKE_MID1"
  if [ "${FAKE_MALFORMED:-0}" = 1 ]; then
    printf '%s\n' 'use","id":"t3","name":"Grep","input":{"pattern":"x"}}]}}'
    sleep "${FAKE_SLEEP:-3}"
    [ -n "${FAKE_MID2:-}" ] && cp "$CHIEF_LIVE_FILE" "$FAKE_MID2"
  fi
  [ "${FAKE_LIMIT:-0}" = 1 ] || land
  printf '%s\n' "$RESULT"
else
  sleep "${FAKE_SLEEP:-3}"
  [ -n "${FAKE_MID1:-}" ] && cp "$CHIEF_LIVE_FILE" "$FAKE_MID1"
  [ "${FAKE_LIMIT:-0}" = 1 ] || land
  printf '%s\n' "$RESULT"
fi
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── the scratch project ──────────────────────────────────────────────────────
scratch_repo() {
  local repo="$1"
  mkdir -p "$repo/.chief/state" "$repo/tasks/chief"
  git -C "$repo" init -q -b main 2>/dev/null || git -C "$repo" init -q
  cat > "$repo/.chief/state/prd.json" <<'JSON'
{"branchName":"chief/sa","userStories":[{"id":"US-1","title":"t","passes":false,"acceptanceCriteria":["do the thing"],"notes":"observed: green"}]}
JSON
  cat > "$repo/tasks/chief/sa.json" <<'JSON'
{"branchName":"chief/sa","userStories":[{"id":"US-1","title":"t","passes":false}]}
JSON
  printf '%s\n' '# Chief Progress Log' > "$repo/.chief/state/progress.txt"
  printf '%s\n' 'seed' > "$repo/product.txt"
  git -C "$repo" add -A && git -C "$repo" commit -q -m scaffold
}

# ── one agent run, against a chosen engine ───────────────────────────────────
# `env -u` every CHIEF_* the engine reads and this harness does not set: the suite is
# routinely run from INSIDE a chief worktree whose driver exports a dozen of them, and
# inheriting one would point this run at the real repository (verify-cache.sh's rule).
run_agent() { # run_agent LABEL REPO ENGINE_DIR ; sets $LAST_OUT/$LAST_LIVE/$LAST_EV, returns agent rc
  local label="$1" repo="$2" engine="$3" rc=0
  LAST_OUT="$WORK/$label.out"; LAST_LIVE="$WORK/$label.live"; LAST_EV="$WORK/$label.events"
  : > "$LAST_EV"
  ( cd "$repo" && env \
      -u CHIEF_PRESET -u CHIEF_TOOL -u CHIEF_VERBOSE -u CHIEF_MODEL -u CHIEF_AGENT_CONTEXT \
      -u CHIEF_PAUSE_FILE -u CHIEF_ITER_HOOK -u CHIEF_PRD_SNAPSHOT -u CHIEF_UNVERIFIED_FILE \
      -u CHIEF_RESEARCH -u CHIEF_RESEARCH_FILE -u CHIEF_REVIEW -u CHIEF_TASKS_DIR \
      -u NO_VERIFY -u STRICT_VERIFY -u CHIEF_VERIFY_CACHE \
      ${SA_STREAM_ENV:+CHIEF_STREAM_ACTIVITY="$SA_STREAM_ENV"} \
      FAKE_TOKEN="$label" FAKE_MID1="${SA_MID1:-}" FAKE_MID2="${SA_MID2:-}" \
      FAKE_MALFORMED="${SA_MALFORMED:-0}" FAKE_LIMIT="${SA_LIMIT:-0}" \
      FAKE_OLD_CLI="${SA_OLD_CLI:-0}" FAKE_SLEEP="${SA_SLEEP:-3}" \
      ARGV_LOG="$ARGV_LOG" \
      CHIEF_PROVIDER=claude CHIEF_PROJECT="$repo" CHIEF_HOME="$engine" \
      CHIEF_STATE_DIR=.chief/state CHIEF_TASKLIST=sa \
      CHIEF_LIVE_FILE="$LAST_LIVE" CHIEF_EVENTS_FILE="$LAST_EV" \
      LIVE_BEAT_SECONDS=1 RATE_LIMIT_RETRY=0 \
      CHIEF_VERIFY_CACHE_STATE="$WORK/vstate" CHIEF_VERIFY_HOOK="$WORK/hook.sh" \
      CHIEF_VERIFY_TASKS_DIR="$repo/tasks/chief" CHIEF_VERIFY_BASE=main \
      CHIEF_VERIFY_REPO="$repo" STALL_LIMIT=1 \
      PATH="$WORK/fakebin:$PATH" bash "$engine/agent.sh" 1 ) >"$LAST_OUT" 2>&1 || rc=$?
  return $rc
}

# live_field FILE KEY -> the value live_set wrote (the engine's own line-wise reader
# shape; a record must only ever be read the way live_get reads it).
live_field() { sed -n "s/^[[:space:]]*\"$2\":[[:space:]]*//p" "$1" 2>/dev/null | head -1 | sed 's/,$//; s/^"//; s/"$//'; }
turn_usage() { jq -c 'select(.event=="agent.turn") | .usage' "$1" | tail -1; }
argv_last()  { grep -v '^--help$' "$ARGV_LOG" | tail -1; }

# ═══ PART A — the invocation, and the capability that decides it ═════════════
# The count matters as much as the argv. An engine that ASKED the CLI whether it
# could stream would invoke the provider an extra time per run before taking a single
# turn — measured against test/provider-backoff.sh, which counts provider calls and
# went from 3 to 4. So each of these three runs must show EXACTLY the invocations its
# turns required, and no more.
: > "$ARGV_LOG"
REPO_A="$WORK/repo-a"; scratch_repo "$REPO_A"
SA_SLEEP=0 run_agent a1 "$REPO_A" "$ROOT/engine" || fail "PART A: the streaming run exited non-zero"
A1="$(cat "$ARGV_LOG")"
[ "$A1" = "--dangerously-skip-permissions --print --output-format stream-json --verbose" ] \
  || fail "PART A: one turn did not produce exactly one streaming invocation — the log was:
$A1"
note "PART A1 ok — one turn, one invocation, streaming: $A1"

# The knob. `disabled` has to mean TODAY'S INVOCATION EXACTLY — not a stream that is
# captured and ignored, which would be a different code path wearing the same name.
: > "$ARGV_LOG"
REPO_A2="$WORK/repo-a2"; scratch_repo "$REPO_A2"
SA_STREAM_ENV=0 SA_SLEEP=0 run_agent a2 "$REPO_A2" "$ROOT/engine" || fail "PART A: the knob-off run exited non-zero"
A2="$(cat "$ARGV_LOG")"
[ "$A2" = "--dangerously-skip-permissions --print --output-format json" ] \
  || fail "PART A: CHIEF_STREAM_ACTIVITY=0 did not give exactly today's single invocation — the log was:
$A2"
note "PART A2 ok — CHIEF_STREAM_ACTIVITY=0 gives exactly today's argv, once"

# A CLI OLDER THAN THE FLAG, answered by observation rather than by a probe: the turn
# is attempted, the refusal of the OPTION is recognised (non-zero, no result envelope,
# and it names what it would not take), and the SAME prompt is re-run on the transport
# that has always worked. The turn still completes — which is the whole claim.
: > "$ARGV_LOG"
REPO_A3="$WORK/repo-a3"; scratch_repo "$REPO_A3"
SA_OLD_CLI=1 SA_SLEEP=0 run_agent a3 "$REPO_A3" "$ROOT/engine" \
  || fail "PART A: a CLI that refuses the flag took the whole turn down with it"
A3="$(cat "$ARGV_LOG")"
[ "$A3" = "--dangerously-skip-permissions --print --output-format stream-json --verbose
--dangerously-skip-permissions --print --output-format json" ] \
  || fail "PART A: the refusal was not recovered on the old transport — the log was:
$A3"
grep -q 'refused --output-format stream-json' "$LAST_OUT" \
  || fail "PART A: streaming was switched off with nothing in the log saying why"
grep -q 'Chief completed all tasks' "$LAST_OUT" \
  || fail "PART A: the re-run turn did not complete"
note "PART A3 ok — a CLI that refuses the flag is recovered on the old transport, once, and says so"

# ═══ PART B — usage parity, measured in both modes ═══════════════════════════
# Refusal (3) of the tasklist: a turn's cost may not depend on a display feature.
# Both runs above did the SAME work and ended on the SAME result object; the two
# `agent.turn` events' usage must therefore be byte-identical.
U_STREAM="$(turn_usage "$WORK/a1.events")"
U_PLAIN="$(turn_usage "$WORK/a2.events")"
[ -n "$U_STREAM" ] && [ "$U_STREAM" != null ] || fail "PART B: the STREAMED turn reported no usage at all — _parse_usage cannot read a stream"
[ "$U_STREAM" = "$U_PLAIN" ] \
  || fail "PART B: usage DIFFERS between modes — streamed $U_STREAM vs json $U_PLAIN. A display feature is moving the spend ledger."
echo "$U_STREAM" | jq -e '.cost_usd == 0.0421 and .input_tokens == 1200 and .output_tokens == 340 and .duration_ms == 1234 and .turns == 3' >/dev/null \
  || fail "PART B: the parsed usage is not the fixture's own figures: $U_STREAM"
note "PART B ok — identical usage in both modes, measured: $U_STREAM"

# ═══ PART C — a limit that arrives in a stream is still a limit ══════════════
REPO_C="$WORK/repo-c"; scratch_repo "$REPO_C"
c_rc=0; SA_LIMIT=1 SA_SLEEP=0 run_agent c1 "$REPO_C" "$ROOT/engine" || c_rc=$?
[ "$c_rc" = 2 ] || fail "PART C: a usage limit delivered in a stream exited $c_rc, not 2 — it was classified as something other than a limit"
grep -qi 'limit' "$LAST_OUT" || fail "PART C: exit 2 with nothing in the log naming a limit"
note "PART C ok — a limit inside a stream still exits 2 (_is_rate_limit reads the captured output, not the stream)"

# ═══ PART D + E — the live record mid-turn, over a stream carrying junk ══════
# The fields only exist WHILE the turn runs, so the fixture provider samples the
# record itself, twice: once with a malformed line, a nameless envelope and a line
# cut in half outstanding, and once after that half-line completes.
REPO_D="$WORK/repo-d"; scratch_repo "$REPO_D"
SA_MID1="$WORK/mid1.live" SA_MID2="$WORK/mid2.live" SA_MALFORMED=1 SA_SLEEP=3 \
  run_agent d1 "$REPO_D" "$ROOT/engine" || fail "PART D: the turn did not survive a stream carrying junk"
[ -f "$WORK/mid1.live" ] || fail "PART D: no mid-turn sample was taken"
D_TOOL="$(live_field "$WORK/mid1.live" tool)"
D_N="$(live_field "$WORK/mid1.live" tools)"
D_SINCE="$(live_field "$WORK/mid1.live" tool_since)"
[ "$D_TOOL" = Bash ] || fail "PART D: mid-turn the record says tool='$D_TOOL', expected the most recent tool call (Bash)"
[ "$D_N" = 2 ] || fail "PART E: tools=$D_N mid-turn, expected 2 — a malformed line, a nameless tool_use envelope or a half-written line was counted as a tool call"
[ "$D_SINCE" -gt 0 ] 2>/dev/null || fail "PART D: tool_since is $D_SINCE — the row cannot say HOW LONG AGO"
[ "$D_SINCE" -le "$(date +%s)" ] || fail "PART D: tool_since is in the future ($D_SINCE) — the row would render a negative age"
note "PART D ok — mid-turn the record reads tool=$D_TOOL tools=$D_N tool_since=$D_SINCE"

[ -f "$WORK/mid2.live" ] || fail "PART E: no second mid-turn sample was taken"
E_TOOL="$(live_field "$WORK/mid2.live" tool)"; E_N="$(live_field "$WORK/mid2.live" tools)"
[ "$E_TOOL" = Grep ] && [ "$E_N" = 3 ] \
  || fail "PART E: after the half-written line COMPLETED the record reads tool=$E_TOOL tools=$E_N, expected Grep/3 — the reader stalled on the partial line instead of waiting for it"
note "PART E ok — junk counted nothing, and the half-written line was counted once it completed"

# THE TURN'S INTERIOR ENDS WITH THE TURN: a tool name that outlived the turn that
# produced it is the same present-tense lie the `stalled` phase was corrected for.
F_TOOL="$(live_field "$WORK/d1.live" tool)"; F_N="$(live_field "$WORK/d1.live" tools)"
[ -z "$F_TOOL" ] && [ "$F_N" = 0 ] \
  || fail "PART D: after the turn ended the record still claims tool='$F_TOOL' tools=$F_N"
note "PART D ok — the fields are cleared when the turn ends"

# ═══ PART F — capability off is exactly today ════════════════════════════════
# a2 above ran with the knob off. Its record must carry NOTHING in the new fields —
# which is byte-for-byte what an older engine's record, and a non-streaming provider,
# also produce. The result text still reached the completion detector (the run exited
# 0 through the same door), and PART B already pinned the usage.
[ -z "$(live_field "$WORK/a2.live" tool)" ] || fail "PART F: streaming is off and the record still carries a tool name"
[ "$(live_field "$WORK/a2.live" tools)" = 0 ] || fail "PART F: streaming is off and the record claims tool calls"
grep -q 'Chief completed all tasks' "$WORK/a2.out" || fail "PART F: the non-streaming turn did not complete as it always has"
grep -q 'Chief completed all tasks' "$WORK/a1.out" || fail "PART F: the STREAMING turn did not reach the completion path — humanizing a stream lost the result text"
note "PART F ok — knob off behaves as today, and streaming still completes through the same door"

# ═══ PART G — REPRODUCTION against a neutered engine ═════════════════════════
# Without this, PART D could be restating a row that was already being written. A
# COPY of the engine has _stream_activity return nothing at all; the same fixture must
# then produce a mid-turn sample with no activity in it.
cp -R "$ROOT/engine" "$WORK/engine-x"
python3 - "$WORK/engine-x/agent.sh" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
i = s.index("_stream_activity() {")
j = s.index("\n_beat_start() {", i)
s = s[:i] + "_stream_activity() { return 0; }\n" + s[j+1:]
open(p, "w").write(s)
PY
bash -n "$WORK/engine-x/agent.sh" || fail "PART G: the neutered engine copy does not parse"
REPO_G="$WORK/repo-g"; scratch_repo "$REPO_G"
SA_MID1="$WORK/midg.live" SA_MALFORMED=1 SA_SLEEP=3 \
  run_agent g1 "$REPO_G" "$WORK/engine-x" || fail "PART G: the neutered run exited non-zero"
G_TOOL="$(live_field "$WORK/midg.live" tool)"; G_N="$(live_field "$WORK/midg.live" tools)"
[ -z "$G_TOOL" ] && [ "$G_N" = 0 ] \
  || fail "PART G: the mid-turn record carried tool='$G_TOOL' tools=$G_N with _stream_activity neutered — PART D is not testing the new code"
note "PART G ok — neutered, the same fixture publishes nothing (PART D discriminates)"

note "OK — a streaming turn publishes its interior, and every other path is untouched"
