#!/usr/bin/env bash
# test/provider-unavailable.sh — an iteration that never reached the model is not an
# attempt the agent made.
#
# THE REGRESSION, verbatim (talos, 2026-08-24). Tasklist 71 ran three consecutive
# iterations whose entire output was `API Error: 529 Overloaded. This is a
# server-side issue, usually temporary`. Chief scored each "no progress", hit
# `stall 3/2`, and left the branch INCOMPLETE — with 2,029 correctly-placed files
# sitting uncommitted in its worktree and `chief ps` reporting `✗ failed · no
# progress last iter`. The agent was never given a chance, and the run reported a
# verdict on work it had learned nothing about.
#
# THREE PARTS, and the middle one is the whole point:
#   1. CLASSIFICATION — real provider outputs through the real agent loop.
#      exit 8 = the request was never served · exit 2 = a usage limit (UNCHANGED)
#      exit 1 = a genuine stall (UNCHANGED)
#   2. THE PAIR — one run containing BOTH: an iteration that ran and made progress,
#      and iterations that never reached the model. They must be classified
#      differently, the stall counter must stay at zero, and the refused iterations
#      must consume no budget.
#   3. THE REPORT — under the real parallel driver, the run summary must not call it
#      a failure and must not say `no progress`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"

# HERMETIC IN STATE IS NOT HERMETIC IN ENV — see test/ratelimit.sh's note. This suite
# may itself be running inside a chief worktree whose driver exported a pause flag.
unset CHIEF_PAUSE_FILE
unset CHIEF_PROVIDER CHIEF_TOOL CHIEF_MODEL CHIEF_PRESET
unset PROVIDER_BACKOFF PROVIDER_BACKOFF_CAP PROVIDER_NOTURN_LIMIT
# …and the research phase's, for PART 4. $CHIEF_RESEARCH_FILE is a path OUTSIDE the
# worktree, so an inherited one would have the phase seed itself from — and promote
# into — the real checkout's research document instead of this test's.
unset CHIEF_RESEARCH CHIEF_RESEARCH_FILE CHIEF_RESEARCH_MAX_ATTEMPTS
export CHIEF_PROVIDER=claude CHIEF_TOOL=claude
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=pu GIT_AUTHOR_EMAIL=pu@test GIT_COMMITTER_NAME=pu GIT_COMMITTER_EMAIL=pu@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"   # hermetic: don't touch ~/.chief
fail() { echo "PROVIDER-UNAVAILABLE FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

# ── install chief from this checkout ──────────────────────────────────────────
PREFIX="$WORK/ph"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"
AGENT="$PREFIX/src/engine/agent.sh"

# ══ PART 1 — CLASSIFICATION (fixtures of real provider output) ════════════════
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
# PROVIDER_NOTURN_LIMIT=1 so a single refusal stops at once; STALL_LIMIT=1 with a
# 1-iteration budget means anything NOT classified exits 1 immediately.
agent_exit_for() {  # <claude-rc> <fixture-text> [env…]
  local rc="$1" text="$2" code=0; shift 2
  printf '%s\n' "$text" > "$FIX_TEXT"; printf '%s\n' "$rc" > "$FIX_RC"
  if ( cd "$FIXREPO" && PATH="$WORK/fixbin:$PATH" CHIEF_PROJECT="$FIXREPO" \
         RATE_LIMIT_RETRY=0 STALL_LIMIT=1 PROVIDER_NOTURN_LIMIT=1 PROVIDER_BACKOFF=0 \
         env "$@" bash "$AGENT" 1 ) >"$WORK/fix/agent.log" 2>&1
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

echo "provider-unavailable: classification (exit 8 = never served, 2 = limit, 1 = stall)"
# THE OBSERVED MESSAGE, verbatim from talos 2026-08-24. No JSON envelope was printed:
# the `API Error: <code>` prefix is the only structure in it.
expect_exit 8 1 "529 (the observed message)" \
  'API Error: 529 Overloaded. This is a server-side issue, usually temporary — try again in a moment'
# The structured arms — what must keep working when a vendor rewords the sentence.
expect_exit 8 1 "structured overloaded_error" \
  'API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}'
expect_exit 8 1 "status key, pretty-printed"  '{
  "type": "error",
  "status": 503
}'
expect_exit 8 1 "502 bad gateway"     'API Error: 502 Bad Gateway'
expect_exit 8 1 "500 internal"        'API Error: 500 Internal Server Error'
# A transport failure never reaches HTTP, so it carries no code and no envelope.
expect_exit 8 1 "connection reset"    'request to https://api.anthropic.com/v1/messages failed, reason: read ECONNRESET'
expect_exit 8 1 "socket hang up"      'FetchError: socket hang up'
# An auth/quota REFUSAL is also a request that was never served — US-2 is what
# decides to fail fast on it rather than wait; the classification is the same.
expect_exit 8 1 "401 revoked key"     'API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}'

echo "provider-unavailable: the UNCHANGED classifications"
# A GENUINE STALL — the agent ran, produced a turn, and the story count did not move.
# This is exactly what the counter exists for and nothing here may weaken it.
expect_exit 1 0 "no-progress turn"    'I read the code but could not finish this story yet.'
expect_exit 1 1 "non-provider crash"  'Error: the tool crashed while editing a file.'
# CONDITION 1: a provider that exited 0 produced a turn, whatever its text says.
# This is what keeps an agent WRITING about a 529 from being classified as one.
expect_exit 1 0 "529 text, rc=0"      'API Error: 529 Overloaded. I am adding a retry for this.'
# A USAGE LIMIT still takes the limit path (a window to wait out, exit 2), not this one.
expect_exit 2 1 "429 rate_limit_error" 'API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"rate limited"}}'
expect_exit 2 0 "usage limit prose"    'Claude usage limit reached. Your limit will reset at 3pm (America/Chicago).'
# The escape hatch: PROVIDER_NOTURN_LIMIT=0 restores the pre-fix behaviour exactly —
# the 529 is scored as a no-progress iteration and the loop exits 1 as a stall.
got="$(agent_exit_for 1 'API Error: 529 Overloaded. This is a server-side issue, usually temporary' PROVIDER_NOTURN_LIMIT=0)"
[ "$got" = "1" ] || fail "PROVIDER_NOTURN_LIMIT=0 must restore the pre-fix stall behaviour (got exit $got, want 1)"
echo "   ok  exit 1  ← PROVIDER_NOTURN_LIMIT=0 restores the pre-fix behaviour"

# ══ PART 2 — THE PAIR: progress and no-turn in ONE run ════════════════════════
# A fake `claude` that IMPLEMENTS on its first call and then returns the observed 529
# on every call after it. This is tasklist 71's shape: iteration 1 was
# `progress (1/2 passing)`, iterations 3-5 never reached the model. The two must be
# classified differently, by the same loop, in the same run.
mkdir -p "$WORK/pairbin"
cat > "$WORK/pairbin/claude" <<'PAIR'
#!/usr/bin/env bash
set -eu
cat >/dev/null
: "${PU_COUNTER:?}"
n=$(( $(cat "$PU_COUNTER" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$PU_COUNTER"
if [ "$n" != "1" ]; then
  echo 'API Error: 529 Overloaded. This is a server-side issue, usually temporary'
  exit 1
fi
PRD=".chief/state/prd.json"
mkdir -p out; echo "impl US-1" > out/US-1.txt
t="$(mktemp)"; jq '(.userStories[]|select(.id=="US-1").passes)=true' "$PRD" > "$t" && mv "$t" "$PRD"
git add -A >/dev/null 2>&1 || true; git commit -q -m "feat: US-1" >/dev/null 2>&1 || true
exit 0
PAIR
chmod +x "$WORK/pairbin/claude"

PAIRREPO="$WORK/pairrepo"; mkdir -p "$PAIRREPO/.chief/state"
git -C "$PAIRREPO" init -q -b main 2>/dev/null || { git -C "$PAIRREPO" init -q; }
git -C "$PAIRREPO" commit -q --allow-empty -m init
cat > "$PAIRREPO/.chief/state/prd.json" <<'JSON'
{ "project":"pair","branchName":"chief/pair","userStories":[
  {"id":"US-1","title":"one","description":"","acceptanceCriteria":[],"passes":false,"notes":""},
  {"id":"US-2","title":"two","description":"","acceptanceCriteria":[],"passes":false,"notes":""}] }
JSON

export PU_COUNTER="$WORK/pu-calls"
pair_rc=0
# PROVIDER_BACKOFF=0 throughout this file: what it asserts is CLASSIFICATION, and the
# wait between refusals is test/provider-backoff.sh's subject. Leaving the default on
# would add ~20s of real sleeping to a file that never looks at the clock.
( cd "$PAIRREPO" && PATH="$WORK/pairbin:$PATH" CHIEF_PROJECT="$PAIRREPO" \
    RATE_LIMIT_RETRY=0 STALL_LIMIT=2 PROVIDER_NOTURN_LIMIT=3 PROVIDER_BACKOFF=0 \
    bash "$AGENT" 5 ) \
  >"$WORK/pair.log" 2>&1 || pair_rc=$?
PL="$WORK/pair.log"

echo "provider-unavailable: the pair (a turn that ran vs turns that never reached the model)"
[ "$pair_rc" = "8" ] || { tail -30 "$PL" >&2; fail "the run must end exit 8 (never served), got $pair_rc"; }
echo "   ok  exit 8"

# THE ITERATION THAT RAN is scored as progress — unchanged, and asserted in the same
# breath as the ones that did not, because a test that only pins the new behaviour
# cannot show the two are told apart.
grep -q 'progress (1/2 passing)' "$PL" \
  || { tail -30 "$PL" >&2; fail "the iteration that RAN was not scored as progress"; }
echo "   ok  iteration 1 → 'progress (1/2 passing)'"

# THE ITERATIONS THAT DID NOT REACH THE MODEL are never scored against the work.
# This is the regression, stated as flatly as it can be: the words 'no progress'
# must not appear anywhere in a run whose only non-progress iterations were 529s.
if grep -q 'no progress (stall' "$PL"; then
  grep -n 'no progress (stall' "$PL" >&2
  fail "a 529 was charged to the stall counter — this is the exact regression"
fi
echo "   ok  the stall counter was never charged"
grep -q 'never reached the model' "$PL" \
  || { tail -30 "$PL" >&2; fail "the refused iterations were not reported as such"; }
echo "   ok  the refused iterations are named as such"

# AND THEY COST NO BUDGET. The iteration counter is rolled back on each refusal, so
# the SAME iteration number is announced by every attempt after the one that worked —
# three attempts at iteration 2, not iterations 2, 3 and 4.
iter2="$(grep -c 'Chief Iteration 2 ' "$PL" || true)"
[ "$iter2" -ge 3 ] || { grep -n 'Chief Iteration' "$PL" >&2
  fail "refused iterations consumed the budget: iteration 2 was announced $iter2 time(s), want >= 3"; }
echo "   ok  iteration 2 re-attempted ${iter2}× — the budget was not charged"   # braced: × is multibyte
grep -q 'Chief Iteration 3 ' "$PL" \
  && fail "the budget advanced past iteration 2 on turns that never reached the model"
[ "$(cat "$PU_COUNTER")" = "4" ] || fail "expected 4 provider calls (1 progress + 3 refusals), got $(cat "$PU_COUNTER")"

# The work the first iteration did is still on the branch, untouched by the stop.
[ -f "$PAIRREPO/out/US-1.txt" ] || fail "the committed work was lost"
[ "$(jq '[.userStories[]|select(.passes)]|length' "$PAIRREPO/.chief/state/prd.json")" = "1" ] \
  || fail "the pass-state banked by the iteration that RAN did not survive"
# The reason is handed to the driver rather than left in a log for someone to find.
grep -qi '529' "$PAIRREPO/.chief/state/.provider-unavailable" \
  || fail "no reason recorded for the driver in .provider-unavailable"
echo "   ok  the committed work and the reason both survive the stop"

# ══ PART 3 — THE REPORT under the real parallel driver ════════════════════════
# The half an operator actually reads. A tasklist blocked by the API must not render
# as a failure and must not say 'no progress' — that display is what sent someone to
# re-scope a tasklist whose work was intact.
mkdir -p "$WORK/downbin"
cat > "$WORK/downbin/claude" <<'DOWN'
#!/usr/bin/env bash
set -eu
cat >/dev/null
echo 'API Error: 529 Overloaded. This is a server-side issue, usually temporary'
exit 1
DOWN
chmod +x "$WORK/downbin/claude"

REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null
rm -f tasks/chief/example.json
cat > tasks/chief/pu.json <<'JSON'
{ "project":"pu","branchName":"chief/pu","description":"the API never answered",
  "iters":3,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":[],"passes":false,"notes":""}] }
JSON
printf '#!/usr/bin/env bash\nexit 0\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "pu setup"

run_rc=0
PATH="$WORK/downbin:$PATH" PROVIDER_NOTURN_LIMIT=2 PROVIDER_BACKOFF=0 \
  "$CHIEF" run >"$WORK/run.log" 2>&1 || run_rc=$?
RL="$WORK/run.log"

echo "provider-unavailable: the run summary"
st="$(cat "$REPO/.chief/state/parallel/pu.status" 2>/dev/null || echo NONE)"
case "$st" in
  PROVIDER-UNAVAILABLE*) ;;
  *) tail -40 "$RL" >&2; fail "status is '$st', want PROVIDER-UNAVAILABLE (INCOMPLETE/EMPTY-NO-WORK is the bug)" ;;
esac
echo "   ok  status = $st"
[ "$(cat "$REPO/.chief/state/parallel/pu.state" 2>/dev/null || echo)" = "provider-unavailable" ] \
  || fail "scheduler state is not 'provider-unavailable' (it must not be 'failed')"
[ "$run_rc" = "0" ] || { tail -40 "$RL" >&2; fail "a blocked run must not exit non-zero (got $run_rc)"; }
grep -q 'PROVIDER UNAVAILABLE' "$RL" || { tail -40 "$RL" >&2; fail "the summary does not name the block"; }
grep -q 'not failed and not stalled' "$RL" || fail "the summary does not say it is not a failure"
# Neither the summary NOR the worker log may describe this as no progress or as an
# incomplete tasklist — those are claims about the work, and no turn was ever taken.
WL="$REPO/.chief/state/parallel/pu.log"
for f in "$RL" "$WL"; do
  [ -f "$f" ] || continue
  grep -q 'no progress' "$f" && { grep -n 'no progress' "$f" >&2
    fail "$f reported 'no progress' on a tasklist that never reached the model"; }
  grep -q 'INCOMPLETE' "$f" && { grep -n 'INCOMPLETE' "$f" >&2
    fail "$f reported INCOMPLETE on a tasklist that never reached the model"; }
done
grep -q 'never reached the model' "$WL" 2>/dev/null \
  || { tail -40 "$WL" 2>/dev/null >&2; fail "the worker log does not name what happened"; }
echo "   ok  reported as a block, never as a failure or a stall"
# Not retired, not merged, and its branch is kept for the re-run.
[ -f tasks/chief/completed/pu.json ] && fail "a tasklist that never ran must not be retired"
git show-ref --verify --quiet refs/heads/chief/pu || fail "the branch was not kept"
echo "   ok  branch kept, nothing merged or retired"

# ══ PART 4 — THE RESEARCH PHASE, on the same terms as the story loop ══════════
# The phase runs BEFORE the first story and had its own copy of the problem: it took
# the rate-limit path but not this one, so a 529 there burned one of
# $RESEARCH_MAX_ATTEMPTS and the run ended exit 6 RESEARCH-FAILED — "chief could not
# draw the map", a claim about the CODEBASE from a turn that never reached the model.
mkdir -p "$WORK/rsbin"
cat > "$WORK/rsbin/claude" <<'RSCLAUDE'
#!/usr/bin/env bash
set -eu
cat >/dev/null
: "${RS_COUNTER:?}"
n=$(( $(cat "$RS_COUNTER" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$RS_COUNTER"
echo 'API Error: 529 Overloaded. This is a server-side issue, usually temporary'
exit 1
RSCLAUDE
chmod +x "$WORK/rsbin/claude"

RSREPO="$WORK/rsrepo"; mkdir -p "$RSREPO/.chief/state"
git -C "$RSREPO" init -q -b main 2>/dev/null || { git -C "$RSREPO" init -q; }
git -C "$RSREPO" commit -q --allow-empty -m init
cat > "$RSREPO/.chief/state/prd.json" <<'JSON'
{ "project":"rs","branchName":"chief/rs","research":true,"userStories":[
  {"id":"US-1","title":"one","description":"","acceptanceCriteria":[],"passes":false,"notes":""}] }
JSON

export RS_COUNTER="$WORK/rs-calls"; printf '0' > "$RS_COUNTER"
rs_rc=0
( cd "$RSREPO" && PATH="$WORK/rsbin:$PATH" CHIEF_PROJECT="$RSREPO" \
    CHIEF_RESEARCH=1 CHIEF_RESEARCH_MAX_ATTEMPTS=2 \
    RATE_LIMIT_RETRY=0 PROVIDER_NOTURN_LIMIT=3 PROVIDER_BACKOFF=0 \
    bash "$AGENT" 5 ) \
  >"$WORK/rs.log" 2>&1 || rs_rc=$?
RS="$WORK/rs.log"

echo "provider-unavailable: the research phase"
# EXIT 8, NOT 6. The distinction is the entire point: 6 says the map could not be
# drawn, 8 says nobody was ever asked to draw one.
[ "$rs_rc" = "8" ] || { tail -30 "$RS" >&2
  fail "a 529 in the research phase must exit 8 (never served), not $rs_rc (6 = RESEARCH FAILED)"; }
grep -q 'RESEARCH FAILED' "$RS" && { tail -30 "$RS" >&2
  fail "the run blamed the research phase for a request the provider never served"; }
echo "   ok  exit 8, and never reported as RESEARCH FAILED"

# AND IT COST NO ATTEMPT. $CHIEF_RESEARCH_MAX_ATTEMPTS is 2, so if refusals were
# charged the loop would stop after two provider calls; the counter bounding it here
# is PROVIDER_NOTURN_LIMIT (3), which is the one that should be.
[ "$(cat "$RS_COUNTER")" = "3" ] || { grep -n 'attempt' "$RS" >&2
  fail "expected 3 provider calls (PROVIDER_NOTURN_LIMIT), got $(cat "$RS_COUNTER") — refusals were charged to the research attempt budget"; }
grep -q 'attempt 1/2' "$RS" || { tail -30 "$RS" >&2; fail "the research attempt was never announced"; }
[ "$(grep -c 'attempt 2/2' "$RS" || true)" = "0" ] || { grep -n 'attempt .../2' "$RS" >&2
  fail "the research attempt budget advanced on a turn that never reached the model"; }
echo "   ok  3 calls bounded by PROVIDER_NOTURN_LIMIT; the attempt budget was untouched"
grep -q 'never reached the model' "$RS" \
  || { tail -30 "$RS" >&2; fail "the refused research turn was not named as such"; }
echo "   ok  named as a refusal, not as a phase that failed"

echo "PROVIDER-UNAVAILABLE PASS — a request the API refused is not an attempt the agent made"
