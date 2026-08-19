#!/usr/bin/env bash
# test/limitresume.sh — the WHOLE-RUN self-heal: a run interrupted by a Claude
# usage limit must wait out the window and re-dispatch itself, with no operator.
#
# test/ratelimit.sh covers recovery INSIDE one agent loop (agent.sh sleeps and
# resumes the same story). test/limitstate.sh covers the classification (a limit
# is 'rate-limited', not 'failed'). This one covers the gap between them: the
# agent has GIVEN UP (exit 2) and only the scheduler can restart it.
#
#   PART A — limit, then capacity: the driver pauses, re-dispatches, and the
#            tasklist RESUMES from its committed passes state (branch reused,
#            not rebuilt) and merges.
#   PART B — limit that never lifts, PARALLEL=2: the scheduler backs off as a
#            whole instead of thrashing every worker into the same wall, and
#            stops cleanly once the re-dispatch cap is spent.
#
# Hermetic: a scripted fake `claude`, temp prefixes, never touches ~/.chief.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=lr GIT_AUTHOR_EMAIL=lr@test GIT_COMMITTER_NAME=lr GIT_COMMITTER_EMAIL=lr@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"   # hermetic: don't touch ~/.chief
LOG=""
fail() { echo "LIMITRESUME FAIL: $*" >&2; [ -n "$LOG" ] && [ -f "$LOG" ] && tail -60 "$LOG" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

# ── install chief from this checkout ──────────────────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"
# Also export the prefix for the RUNS, not just the install: driver.sh derives
# WT_ROOT from it, so without this the worktrees land in the developer's real
# ~/.chief/worktrees and outlive the test.
export CHIEF_PREFIX="$PREFIX"

mkdir -p "$WORK/fakebin"
# Shared fake `claude`. $LR_COUNTER counts EVERY invocation across the run (that
# count is what proves re-dispatch is bounded); $LR_MODE picks the behaviour.
#   always-limit   : never does anything but hit the wall
#   work-then-limit: implement one story per call; hit the wall AFTER call 1's
#                    commit, so the pause leaves REAL passes-state to resume from
# The limit line carries NO parseable reset time on purpose, so the ETA comes from
# RATE_LIMIT_WAIT.
#
# WHICH KNOB SHRINKS THE WINDOW, and why it is NOT RATE_LIMIT_WAIT. The obvious
# lever — RATE_LIMIT_WAIT=3, a three-second "hour" — is a RACE, and it lost on a
# loaded host: the worker stamps retry-at = <its exit> + 3s, but the scheduler only
# reads it after that worker has torn down (worktree sweep + removal + status), so
# under load the window has ALREADY elapsed by the time limit_resume() looks and the
# run correctly re-dispatches without ever printing the pause it never had to take.
# The deterministic lever is the driver's CEILING, RATE_LIMIT_REDISPATCH_MAX_WAIT:
# limit_pause() clamps to `now + ceiling` where `now` is the SCHEDULER's clock at
# arming time, so a far-future ETA (an hour, as a real limit would be) becomes a
# window that is guaranteed still open when the pause is evaluated — no matter how
# long teardown took. Cost: the ~4s the run genuinely sleeps. Bonus: the clamp
# itself, the thing that keeps a bogus six-hour ETA from stranding a run, is now
# covered too.
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null
: "${LR_COUNTER:?}" "${LR_MODE:?}"
n=$(( $(cat "$LR_COUNTER" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$LR_COUNTER"
limit() { echo "Error: usage limit reached. Please try again later."; exit 0; }
if [ "$LR_MODE" = always-limit ]; then limit; fi
PRD=".chief/state/prd.json"
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"; TRACKED="tasks/chief/$name.json"
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  mkdir -p out; echo "impl $id" > "out/$id.txt"
  for f in "$PRD" "$TRACKED"; do t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id).passes)=true' "$f" > "$t" && mv "$t" "$f"; done
  git add -A >/dev/null 2>&1 || true; git commit -q -m "feat: $id" >/dev/null 2>&1 || true
fi
if [ "$n" = 1 ]; then limit; fi
if [ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ]; then echo "<promise>COMPLETE</promise>"; fi
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# scaffold <dir> — a chief repo with a verify hook that passes on the artifacts.
scaffold() {
  local repo="$1"; mkdir -p "$repo"; ( cd "$repo"
    git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
    git commit -q --allow-empty -m init
    "$CHIEF" init >/dev/null
    rm -f tasks/chief/example.json
    printf '#!/usr/bin/env bash\nset -eu\necho "verify: ok"\nexit 0\n' > .chief/verify.sh
    chmod +x .chief/verify.sh )
}
mk() {   # <repo> <name> <n-stories>
  local repo="$1" name="$2" k="$3" stories="" i
  for i in $(seq 1 "$k"); do
    [ -n "$stories" ] && stories="$stories,"
    stories="$stories{\"id\":\"US-$i\",\"title\":\"s$i\",\"description\":\"\",\"acceptanceCriteria\":[\"out/US-$i.txt\"],\"passes\":false,\"notes\":\"\"}"
  done
  cat > "$repo/tasks/chief/$name.json" <<JSON
{ "project":"lr","branchName":"chief/$name","description":"limit-resume $name",
  "iters":$(( k + 1 )),"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[$stories] }
JSON
}

# ══ PART A — pause → re-dispatch → resume from passes state → merge ══════════
# Story 1 lands and is committed, THEN the limit hits (agent.sh exits 2 with
# RATE_LIMIT_RETRY=0). Only the scheduler can restart it — and when it does, the
# branch must be REUSED, so the agent picks up at story 2 rather than story 1.
echo "limitresume: PART A — a limit-interrupted run heals itself"
REPO="$WORK/a"; scaffold "$REPO"; mk "$REPO" lr 2
( cd "$REPO" && git add -A && git commit -q -m "part A setup" )

LOG="$WORK/a.log"
export LR_COUNTER="$WORK/a-calls" LR_MODE=work-then-limit
t0=$(date +%s)
( cd "$REPO" && PATH="$WORK/fakebin:$PATH" \
    RATE_LIMIT_RETRY=0 RATE_LIMIT_WAIT=3600 RATE_LIMIT_REDISPATCH_MAX_WAIT=4 POLL_SECONDS=1 \
    "$CHIEF" run ) >"$LOG" 2>&1 || fail "run exited non-zero (a self-healed run is a successful run)"
elapsed=$(( $(date +%s) - t0 ))

S="$REPO/.chief/state/parallel"
state() { cat "$S/$1.state" 2>/dev/null || echo MISSING; }

grep -q 'the run is PAUSED until' "$LOG" || fail "the scheduler did not wait out the limit window"
[ "$elapsed" -ge 4 ] || fail "the run finished in ${elapsed}s — it re-dispatched without waiting out the limit window"
grep -q 're-dispatching lr' "$LOG" || fail "the scheduler never re-dispatched the paused tasklist"
[ "$(cat "$S/lr.retries" 2>/dev/null || echo 0)" = "1" ] || fail "re-dispatch count is '$(cat "$S/lr.retries" 2>/dev/null)', want 1"
# Branch REUSED, not rebuilt: the second dispatch found story 1 already passing.
grep -q 'RESUMING chief/lr (1 story left)' "$S/lr.log" \
  || { tail -40 "$S/lr.log" >&2; fail "the re-dispatch did not RESUME the branch from its committed passes state"; }
[ "$(state lr)" = "done" ] || fail "lr state is '$(state lr)', want done"
( cd "$REPO" && git checkout -q main
  [ -f out/US-1.txt ] || exit 3
  [ -f out/US-2.txt ] || exit 4
  [ -n "$(jq -r '.mergedToMain // empty' tasks/chief/completed/lr.json 2>/dev/null)" ] || exit 5
) || fail "the tasklist did not complete+merge after the self-heal (missing artifact or merge stamp)"
[ "$(cat "$LR_COUNTER")" = "2" ] || fail "agent invocations = $(cat "$LR_COUNTER"), want 2 (US-1 then the limit; US-2 after the re-dispatch)"
echo "   ok  paused, waited ~${elapsed}s, resumed at story 2, merged"

# ══ PART B — the limit never lifts: back off as a whole, stop at the cap ═════
# PARALLEL=2 with one shared account. Every dispatch walls. The scheduler must
# pause the WHOLE run (not relaunch each worker on its own), and once
# RATE_LIMIT_REDISPATCH_MAX is spent it must END — cleanly, saying why.
echo "limitresume: PART B — a limit that never lifts is bounded, not a hang"
REPO="$WORK/b"; scaffold "$REPO"; mk "$REPO" cap-a 1; mk "$REPO" cap-b 1
( cd "$REPO" && git add -A && git commit -q -m "part B setup" )

LOG="$WORK/b.log"
export LR_COUNTER="$WORK/b-calls" LR_MODE=always-limit
t0=$(date +%s)
( cd "$REPO" && PATH="$WORK/fakebin:$PATH" \
    RATE_LIMIT_RETRY=0 RATE_LIMIT_WAIT=3600 RATE_LIMIT_REDISPATCH_MAX_WAIT=4 POLL_SECONDS=1 \
    RATE_LIMIT_REDISPATCH_MAX=1 \
    "$CHIEF" run -p 2 ) >"$LOG" 2>&1 || fail "run exited non-zero (a usage-limit pause is not a run failure)"
elapsed=$(( $(date +%s) - t0 ))

S="$REPO/.chief/state/parallel"
grep -q 'the run is PAUSED until' "$LOG" || fail "the scheduler did not report pausing the run on the shared limit"
[ "$elapsed" -ge 4 ] || fail "the run finished in ${elapsed}s — it re-dispatched without waiting out the limit window"
for n in cap-a cap-b; do
  [ "$(state "$n")" = "rate-limited" ] || fail "$n state is '$(state "$n")', want rate-limited"
  [ "$(cat "$S/$n.retries" 2>/dev/null || echo 0)" = "1" ] || fail "$n re-dispatched $(cat "$S/$n.retries" 2>/dev/null) time(s), want exactly 1 (the cap)"
done
# 2 tasklists x (1 initial + 1 re-dispatch) = 4. More than that is thrash; the
# whole point of the shared-account pause is that it cannot happen.
[ "$(cat "$LR_COUNTER")" = "4" ] || fail "agent invocations = $(cat "$LR_COUNTER"), want exactly 4 (cap=1 x 2 tasklists) — the scheduler thrashed"
grep -q 'RATE_LIMIT_REDISPATCH_MAX=1) is spent' "$LOG" || fail "the run ended without saying the re-dispatch cap was spent"
( cd "$REPO" && git checkout -q main
  for n in cap-a cap-b; do [ -f "tasks/chief/completed/$n.json" ] && exit 6; done; exit 0 ) \
  || fail "a paused tasklist was recorded as completed"
echo "   ok  backed off once, capped at 1 re-dispatch each, ended cleanly in ${elapsed}s"

echo "LIMITRESUME PASS — the driver waits out a usage limit and re-dispatches (bounded, reset-aware, no thrash)"
