#!/usr/bin/env bash
# test/ratelimit.sh — prove the token/usage-limit pause+resume survives the PARALLEL
# driver, offline & deterministically.
#
# A fake `claude` trips a usage-limit message on its FIRST call (doing no work) and
# then implements the story on later calls. With RATE_LIMIT_WAIT=1 the agent loop
# sleeps ~1s and resumes the SAME story; the parallel driver must keep the sleeping
# worker alive (never reap/kill it) and the tasklist must still complete + merge.
# This is the run-all.sh recovery mechanism, verified under run-parallel.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=rl GIT_AUTHOR_EMAIL=rl@test GIT_COMMITTER_NAME=rl GIT_COMMITTER_EMAIL=rl@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"   # hermetic: don't touch ~/.chief
fail() { echo "RATELIMIT FAIL: $*" >&2; [ -f "$WORK/run.log" ] && tail -30 "$WORK/run.log" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

# ── install chief from this checkout ──────────────────────────────────────────
PREFIX="$WORK/rh"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"
AGENT="$PREFIX/src/engine/agent.sh"

# ══ PART 1 — DETECTION + EXIT-CODE CONTRACT (fixtures of real CLI output) ═════
# The gap this pins: a limit phrasing the pattern MISSES is demoted to a "no
# progress" iteration, so agent.sh burns its budget and exits 1 (stall) — which
# the driver cannot tell apart from a genuinely failed tasklist. Each fixture is
# fed to the real agent loop through a fake `claude`, with RATE_LIMIT_RETRY=0 so
# a detected limit stops immediately:
#     exit 2 = limit (resumable, not a failure)   ·   exit 1 = stall/hard-cap
mkdir -p "$WORK/fixbin" "$WORK/fix"
cat > "$WORK/fixbin/claude" <<'FIXCLAUDE'
#!/usr/bin/env bash
set -eu
cat >/dev/null
cat "$FIX_TEXT"
exit "$(cat "$FIX_RC")"
FIXCLAUDE
chmod +x "$WORK/fixbin/claude"

FIXREPO="$WORK/fixrepo"; mkdir -p "$FIXREPO/.chief/state"
git -C "$FIXREPO" init -q 2>/dev/null || true
git -C "$FIXREPO" commit -q --allow-empty -m init 2>/dev/null || true
cat > "$FIXREPO/.chief/state/prd.json" <<'JSON'
{ "project":"fix","branchName":"chief/fix","userStories":[
  {"id":"US-1","title":"one","description":"","acceptanceCriteria":[],"passes":false,"notes":""}] }
JSON
export FIX_TEXT="$WORK/fix/text" FIX_RC="$WORK/fix/rc"

# Run one agent iteration against a fixture; echo the agent's exit code.
# STALL_LIMIT=1 + a 1-iteration budget means a NON-limit output exits 1 at once.
agent_exit_for() {  # <claude-rc> <fixture-text>
  local rc="$1" text="$2" code=0
  printf '%s\n' "$text" > "$FIX_TEXT"; printf '%s\n' "$rc" > "$FIX_RC"
  if ( cd "$FIXREPO" && PATH="$WORK/fixbin:$PATH" CHIEF_PROJECT="$FIXREPO" \
         RATE_LIMIT_RETRY=0 STALL_LIMIT=1 bash "$AGENT" 1 ) >"$WORK/fix/agent.log" 2>&1
  then code=0; else code=$?; fi
  echo "$code"
}
expect_exit() {  # <want-code> <claude-rc> <label> <fixture-text>
  local want="$1" rc="$2" label="$3" text="$4" got
  got="$(agent_exit_for "$rc" "$text")"
  [ "$got" = "$want" ] || { tail -20 "$WORK/fix/agent.log" >&2
    fail "fixture [$label] (claude rc=$rc): agent.sh exited $got, want $want"; }
  echo "   ok  exit $got  ← $label"
}

# The pattern the first version shipped with — kept here to PROVE the fixtures
# below are a real widening and not a restatement of what already worked.
OLD_PATTERN='(usage limit reached|session limit reached|(hit|reached) your (session|usage|rate) limit|rate limit exceeded|429 too many requests)'
missed_by_old() { ! printf '%s\n' "$1" | grep -qiE "$OLD_PATTERN"; }

echo "ratelimit: detection fixtures (exit 2 = limit, exit 1 = stall)"
# Known Claude Code limit phrasings → all must be read as a LIMIT (exit 2).
expect_exit 2 0 "--print epoch form"   'Claude AI usage limit reached|1795000000'
expect_exit 2 0 "reset-time sentence"  'Claude usage limit reached. Your limit will reset at 3pm (America/Chicago).'
expect_exit 2 0 "5-hour window"        '5-hour limit reached ∙ resets 3pm'
expect_exit 2 0 "weekly window"        'Weekly limit reached · resets Nov 5 at 9am'
expect_exit 2 0 "second person"        "You've reached your usage limit for this session."
expect_exit 2 1 "structured 429 body"  'API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"rate limited"}}'
expect_exit 2 1 "terse 429 + rc!=0"    'API Error: 429'

# …and at least the windowed phrasings must be ones the OLD pattern MISSED,
# otherwise this test would pass against the un-fixed engine.
for t in '5-hour limit reached ∙ resets 3pm' 'Weekly limit reached · resets Nov 5 at 9am' 'API Error: 429'; do
  missed_by_old "$t" || fail "fixture '$t' already matched the old pattern — widen the test, not just the code"
done

# The other half of the contract: exit 1 stays reserved for a genuine stall.
expect_exit 1 0 "no-progress turn"     'I read the code but could not finish this story yet.'
expect_exit 1 1 "non-limit CLI error"  'Error: the tool crashed while editing a file.'
expect_exit 1 0 "429 text, rc=0"       'API Error: 429'   # weak hint alone is NOT a limit

# ── the RESET ETA, not just the detection ────────────────────────────────────
# Detecting a limit is only half the contract: agent.sh also has to sleep for the
# RIGHT LENGTH. A provider that meters a rolling throughput window states the
# window as a RELATIVE duration ("reset in 16 minutes") and never as an epoch or a
# clock time. That used to miss every parse arm and fall back to RATE_LIMIT_WAIT,
# so a 16-minute block slept a full hour — and under -p N every co-scheduled worker
# slept it too. With RATE_LIMIT_RETRY=0 the loop records the ETA it computed in
# .limit-retry-at, which is exactly the number the driver re-dispatches on.
eta_minutes_for() {  # <claude-rc> <fixture-text> -> whole minutes from now
  rm -f "$FIXREPO/.chief/state/.limit-retry-at"
  agent_exit_for "$1" "$2" >/dev/null
  local at; at="$(cat "$FIXREPO/.chief/state/.limit-retry-at" 2>/dev/null || echo)"
  case "$at" in ''|*[!0-9]*) echo "unparsed"; return 0 ;; esac
  echo $(( (at - $(date +%s)) / 60 ))
}
expect_eta() {  # <lo-min> <hi-min> <label> <fixture-text>
  local lo="$1" hi="$2" label="$3" text="$4" got
  got="$(eta_minutes_for 0 "$text")"
  case "$got" in *[!0-9-]*) fail "eta [$label]: no ETA recorded ($got)" ;; esac
  { [ "$got" -ge "$lo" ] && [ "$got" -le "$hi" ]; } || \
    fail "eta [$label]: slept ~${got}min, want ${lo}-${hi}min"
  echo "   ok  ~${got}min  ← $label"
}

echo "ratelimit: reset-ETA parse (relative windows must not sleep the 60min fallback)"
# The real Devin message, verbatim — the one that regressed a 16-minute window
# into an hour of idle across four co-scheduled workers.
expect_eta 16 18 "devin throughput window (16 min)" \
  'Error: Agent error: Reached overall message rate limit. Please try again later. Your limit will reset in 16 minutes. (trace ID: 287e1e84): {"cognition.ai/retryable": true}'
expect_eta 1 2  "retry in 30 seconds"   'Rate limit exceeded. retry in 30 seconds'
expect_eta 5 7  "try again in 5 min"    'Too many requests, try again in 5 min'
expect_eta 60 62 "reset in 1 hour"      'Your limit will reset in 1 hour.'
# A clock time later TODAY must resolve on whatever date(1) this host ships —
# GNU (-d) or BSD/macOS (-j -f). This is the STANDARD Claude limit phrasing, and
# on a Mac the GNU-only call failed silently, so it slept the 60min fallback
# instead of the real window. Generated relative to now so the fixture can never
# go stale, and skipped near midnight where "later today" stops being true.
if [ "$(date +%H)" -lt 22 ]; then
  clk="$(date -v+90M '+%l:%M%p' 2>/dev/null || date -d '+90 minutes' '+%l:%M%p')"
  clk="$(printf '%s' "$clk" | tr -d ' ')"
  expect_eta 89 92 "clock time later today ($clk)" \
    "Claude usage limit reached. Your limit will reset at $clk."
else
  echo "   -- skipped: within 2h of midnight, 'later today' is not assertable"
fi
# The fallback must still be the fallback: a limit with NO stated window, and a
# duration that is just prose, both sleep RATE_LIMIT_WAIT rather than guess.
expect_eta 59 61 "no window stated → fallback" 'Claude AI usage limit reached.'
expect_eta 59 61 "prose duration must not arm the timer" \
  "You've reached your usage limit. I spent 5 minutes reading the code."

# ══ PART 2 — PAUSE + RESUME UNDER THE PARALLEL DRIVER ════════════════════════
# ── fake `claude`: trip the limit ONCE, then implement the story ──────────────
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null
: "${RL_COUNTER:?}"
n=$(( $(cat "$RL_COUNTER" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$RL_COUNTER"
if [ "$n" = "1" ]; then
  # No parseable reset time → the loop falls back to RATE_LIMIT_WAIT (set to 1s).
  echo "Error: usage limit reached. Please try again later."
  exit 0
fi
PRD=".chief/state/prd.json"
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"; TRACKED="tasks/chief/$name.json"
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  mkdir -p out; echo "impl $id" > "out/$id.txt"
  for f in "$PRD" "$TRACKED"; do t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id).passes)=true' "$f" > "$t" && mv "$t" "$f"; done
  git add -A >/dev/null 2>&1 || true; git commit -q -m "feat: $id" >/dev/null 2>&1 || true
fi
[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── scaffold a repo + a 1-story tasklist + a real verify hook ─────────────────
REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null
rm -f tasks/chief/example.json
cat > tasks/chief/rl.json <<'JSON'
{ "project":"rl","branchName":"chief/rl","description":"rate-limit recovery",
  "iters":3,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":["out/US-1.txt"],"passes":false,"notes":""}] }
JSON
printf '#!/usr/bin/env bash\nset -eu\n[ -f out/US-1.txt ] || { echo missing; exit 1; }\necho ok\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "rl setup"

# ── run under the PARALLEL driver; the first agent call trips the limit ────────
export RL_COUNTER="$WORK/rl-calls"
t0=$(date +%s)
PATH="$WORK/fakebin:$PATH" RATE_LIMIT_RETRY=1 RATE_LIMIT_WAIT=1 \
  "$CHIEF" run -p 2 >"$WORK/run.log" 2>&1 || { cat "$WORK/run.log"; fail "run exited non-zero"; }
elapsed=$(( $(date +%s) - t0 ))

# ── assertions: the limit was hit, slept, resumed, and the tasklist merged ────
worker_log="$REPO/.chief/state/parallel/rl.log"
case "$(cat "$worker_log" 2>/dev/null)" in
  *"usage/usage limit"*|*"session/usage limit"*|*"Sleeping"*) ;;
  *) fail "no rate-limit sleep recorded in the worker log (mechanism not exercised)" ;;
esac
[ "$(cat "$RL_COUNTER")" -ge 2 ] || fail "agent was not re-invoked after the limit (calls=$(cat "$RL_COUNTER"))"
git checkout -q main
[ -f out/US-1.txt ]                              || fail "artifact missing — tasklist did not complete after the limit"
[ -f tasks/chief/completed/rl.json ]             || fail "tasklist not retired after recovery"
[ -n "$(jq -r '.mergedToMain // empty' tasks/chief/completed/rl.json)" ] || fail "no merge stamp after recovery"

echo "RATELIMIT PASS — parallel driver kept the sleeping worker alive; agent slept ~${elapsed}s then resumed → merged"
