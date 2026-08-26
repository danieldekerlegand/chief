#!/usr/bin/env bash
# test/repeat-stop.sh — a tasklist that CANNOT COMPLETE is detected from its own
# record and stopped, instead of running out its budget and being called INCOMPLETE.
#
# The incident: cuneiform `283-nixos-bare-metal-vpn-topology-target`, 2026-08-22 →
# 2026-08-25. Its US-3 verified a flow that genuinely does not complete, so the agent
# re-measured it and wrote down the same verdict — 42 consecutive IDENTICAL
# measurements, 63 commits, 59 iterations. Every one of those iterations committed real
# work, so the stall counter read progress every time; every one recorded a real
# observation, so the bar rule had nothing to demote. The run ended INCOMPLETE, which is
# a WRONG verdict on finished work rather than a cheap one.
#
# What is asserted, cheapest first:
#   1. THE PREDICATE   — repeat_fingerprint / repeat_bump directly: an identical outcome
#                        trips at N, an unmeasured one NEVER trips however long it runs,
#                        and a changed measurement, a changed story or a flipped `passes`
#                        all RESET. N is the knob, and the stated default is 3.
#   2. THE STOP        — a real (hermetic) run of the 283 shape: the fake agent commits
#                        real product files every iteration and re-records one fixed
#                        finding. It must stop at N turns, name the story, quote the
#                        finding, and name BOTH fixes.
#   3. INDEPENDENT OF `112` — asserted in the same run, and this is the whole point of
#                        the rule: every iteration is scored as PROGRESS (real paths
#                        outside .chief/state/ changed), the bookkeeping fix is fully in
#                        place, and the stop fires anyway. A run log that says
#                        `no progress` would mean the fixture proved the wrong thing.
#   4. NO FALSE STOP   — the same fixture with a measurement that MOVES each turn runs
#                        past N and merges. A rule that cannot be shown not to fire is
#                        a way to kill working tasklists.
#   5. THE KNOB, END TO END — a second run with REPEAT_LIMIT=2 stops at two turns, so
#                        the default is a default and not a constant.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=rs GIT_AUTHOR_EMAIL=rs@test GIT_COMMITTER_NAME=rs GIT_COMMITTER_EMAIL=rs@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos" CHIEF_WORKTREE_ROOT="$WORK/wt"  # hermetic
fail() { echo "REPEAT FAIL: $*" >&2
         [ -f "$WORK/run.log" ] && tail -60 "$WORK/run.log" >&2
         exit 1; }
command -v jq >/dev/null || fail "jq required"

# ── 1. THE PREDICATE, against the working tree's module ───────────────────────
. "$ROOT/engine/repeat.sh"
[ "$REPEAT_LIMIT" = 3 ] || fail "the stated default N is 3, got $REPEAT_LIMIT"

mkprd() { # $1 = US-2's notes, $2 = US-2's passes
  jq -n --arg n "$1" --argjson p "$2" '{userStories:[
    {id:"US-1",title:"delivered",passes:true,notes:"green"},
    {id:"US-2",title:"VERIFY the flow, honestly",passes:$p,notes:$n}]}'
}
mkprd "verdict maas-client-absent, 0 call sites" false > "$WORK/same.json"
REPEAT_KEY=""; REPEAT_COUNT=0
for i in 1 2 3; do
  if repeat_bump "$WORK/same.json"; then
    [ "$i" = 3 ] || fail "an identical outcome tripped at boundary $i, not at N=3"
  else
    [ "$i" != 3 ] || fail "an identical outcome never tripped at N=3"
  fi
done
[ "$REPEAT_STORY" = "US-2" ] || fail "the rule names '$REPEAT_STORY', not the story being re-answered"

# NOTHING RECORDED IS NOT AN OUTCOME. A story mid-implementation must be able to run
# forever without accumulating repeats — this is the false-positive that would make the
# rule unusable, so it is asserted well past N.
mkprd "" false > "$WORK/quiet.json"
REPEAT_KEY=""; REPEAT_COUNT=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  repeat_bump "$WORK/quiet.json" && fail "a story that has recorded NOTHING tripped the rule at boundary $i"
done
[ "$REPEAT_COUNT" = 0 ] || fail "an unmeasured story accumulated a count of $REPEAT_COUNT"
# Nor is prose with no observation in it — the same bar the inert rule and the bar rule use.
mkprd "still looking into it" false > "$WORK/vague.json"
REPEAT_KEY=""; REPEAT_COUNT=0
for i in 1 2 3 4; do
  repeat_bump "$WORK/vague.json" && fail "a note carrying no observed value tripped the rule at boundary $i"
done

# A MEASUREMENT THAT MOVES RESETS. So does a flipped `passes` (the story settles and the
# next open one is a different question).
REPEAT_KEY=""; REPEAT_COUNT=0
for i in 1 2 3 4 5; do
  mkprd "attempt $i: 3 tests failed" false > "$WORK/moving.json"
  repeat_bump "$WORK/moving.json" && fail "a measurement that changed every boundary tripped the rule at $i"
done
[ "$REPEAT_COUNT" = 1 ] || fail "a changed measurement left the count at $REPEAT_COUNT, not 1"
REPEAT_KEY=""; REPEAT_COUNT=0
repeat_bump "$WORK/same.json" || true
mkprd "verdict maas-client-absent, 0 call sites" true > "$WORK/flipped.json"
repeat_bump "$WORK/flipped.json" && fail "the rule tripped after the story it was watching passed"
[ "$REPEAT_COUNT" = 0 ] || fail "a story that passed left a live count of $REPEAT_COUNT"

# N IS THE KNOB, in both directions.
REPEAT_LIMIT=5; REPEAT_KEY=""; REPEAT_COUNT=0
for i in 1 2 3 4 5; do
  if repeat_bump "$WORK/same.json"; then [ "$i" = 5 ] || fail "REPEAT_LIMIT=5 tripped at $i"; fi
done
[ "$REPEAT_COUNT" = 5 ] || fail "REPEAT_LIMIT=5 never reached 5"
REPEAT_LIMIT=2; REPEAT_KEY=""; REPEAT_COUNT=0
repeat_bump "$WORK/same.json" && fail "REPEAT_LIMIT=2 tripped on the first boundary"
repeat_bump "$WORK/same.json" || fail "REPEAT_LIMIT=2 did not trip on the second"
REPEAT_LIMIT=3
echo "  predicate: N is the knob (default 3); identical trips, unmeasured and moving do not"

# THE REPORT CARRIES THE FINDING AND BOTH FIXES. "It stalled" is what sent 283's
# operator to re-scope a tasklist whose work was intact.
rep="$(repeat_stop_report "$WORK/same.json" 3)"
printf '%s' "$rep" | grep -q 'US-2'                 || fail "the report does not name the story"
printf '%s' "$rep" | grep -q 'maas-client-absent'   || fail "the report drops the finding it keeps rediscovering"
printf '%s' "$rep" | grep -q 'AMEND THE CRITERION'  || fail "the report does not name the first fix"
printf '%s' "$rep" | grep -q 'terminalFalse'        || fail "the report does not name the second fix (declare the negative terminal)"

# ── install chief from this checkout ──────────────────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# ── the fake agent: 283's shape, and its control ──────────────────────────────
# BOTH tasklists commit a NEW product file outside .chief/state/ on every single turn,
# so `112`'s progress rule scores PROGRESS every iteration for both. The ONLY difference
# is whether the recorded measurement moves.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
W="@WORK@"
P="$(mktemp)"; cat > "$P"
PRD=".chief/state/prd.json"
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
turn=$(( $(cat "$W/turns-$name" 2>/dev/null || echo 0) + 1 )); echo "$turn" > "$W/turns-$name"
mkdir -p out; printf 'impl %s turn %s\n' "$name" "$turn" > "out/$name-$turn.txt"
done_now=0
case "$name" in
  rs-working)
    # A verification that LEARNS something each turn, and lands.
    if [ "$turn" -ge 4 ]; then
      finding="the flow completes end to end: 12 checks passed, 0 failed"; done_now=1
    else
      finding="attempt $turn: got $turn of 12 checks through, still failing at the commission step"
    fi ;;
  *)
    # 283: re-measured honestly, every time, with the same answer.
    finding="Ran the commission->deploy flow: verdict maas-client-absent, 0 call sites across core/ services/ apps/. Do this instead: land a MaaS client in services/ first." ;;
esac
t="$(mktemp)"
jq --arg f "$finding" --argjson d "$done_now" '.userStories |= map(
     if .id == "US-1" then .passes = true | .notes = "built the seam; 3 checks green"
     else .notes = $f | (if $d == 1 then .passes = true else . end) end)' "$PRD" > "$t" && mv "$t" "$PRD"
cp "$PRD" "tasks/chief/$name.json"
git add -A >/dev/null 2>&1 || true
git commit -q -m "feat: US-2 - $name turn $turn" >/dev/null 2>&1 || true
[ "$done_now" = 1 ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
sed -i.bak "s#@WORK@#$WORK#" "$WORK/fakebin/claude" && rm -f "$WORK/fakebin/claude.bak"
chmod +x "$WORK/fakebin/claude"

# ── scaffold ──────────────────────────────────────────────────────────────────
REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null
rm -f tasks/chief/example.json
# NO BAR in the criteria, deliberately: this stop must come from the REPEAT rule and
# never from measure.sh's bar rule happening to fire on the prose.
for n in rs-stuck rs-working rs-knob; do
  jq -n --arg n "$n" '{project:"rs",branchName:("chief/"+$n),description:"the 283 shape",
    iters:8,dependsOn:[],touches:[$n],warmup:[],userStories:[
      {id:"US-1",title:"build the seam",description:"",
       acceptanceCriteria:["the output file for this tasklist exists"],passes:false,notes:""},
      {id:"US-2",title:"VERIFY the commission->deploy flow, honestly",description:"",
       acceptanceCriteria:["report whether the flow completes end to end; a stub does not count"],
       passes:false,notes:""}]}' > "tasks/chief/$n.json"
done
printf '#!/usr/bin/env bash\nset -eu\necho "verify: (would pass)"\nexit 0\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "rs setup"

# iters:8 is deliberately GENEROUS. The budget must not be what stops rs-stuck — if it
# were, this test would pass on the pre-fix engine.
PATH="$WORK/fakebin:$PATH" "$CHIEF" run rs-stuck rs-working >"$WORK/run.log" 2>&1 \
  || { cat "$WORK/run.log"; fail "run exited non-zero"; }
status() { cat "$REPO/.chief/state/parallel/$1.status" 2>/dev/null || echo MISSING; }
git checkout -q main
LOG="$REPO/.chief/state/parallel/rs-stuck.log"

# ── 2. THE STOP ───────────────────────────────────────────────────────────────
case "$(status rs-stuck)" in CANNOT-COMPLETE*) ;; *) fail "the stuck tasklist ended '$(status rs-stuck)', not CANNOT-COMPLETE" ;; esac
[ "$(cat "$WORK/turns-rs-stuck" 2>/dev/null || echo 0)" = "3" ] \
  || fail "the stuck tasklist bought $(cat "$WORK/turns-rs-stuck" 2>/dev/null || echo 0) agent turns; N=3 means three"
grep -q 'UNABLE TO COMPLETE' "$LOG" || fail "the run never says the tasklist appears unable to complete"
grep -q 'US-2' "$LOG"               || fail "the stop does not name the story being re-answered"
grep -q 'maas-client-absent' "$LOG" || fail "the stop does not quote the repeated finding"
grep -q 'AMEND THE CRITERION' "$LOG" || fail "the stop does not name the first resolving action"
grep -q 'terminalFalse' "$LOG"      || fail "the stop does not name the second resolving action"
grep -q 'iteration budget ran out' "$LOG" \
  && fail "the stop still reports itself as a budget overrun — the INCOMPLETE verdict 283 got"
[ -s "$REPO/.chief/state/parallel/rs-stuck.cannot-complete" ] \
  || fail "the diagnosis was not kept for the summary — it survives only in a worktree that gets removed"
grep -q 'CANNOT COMPLETE AS WRITTEN' "$WORK/run.log" \
  || fail "the run summary folds it in with the other red lines instead of naming it"

# The work is KEPT — this is a diagnosis, not a teardown.
[ -f tasks/chief/rs-stuck.json ]            || fail "the stuck tasklist was retired out of the backlog"
[ ! -f tasks/chief/completed/rs-stuck.json ] || fail "a tasklist that cannot complete was filed as completed"
git rev-parse --verify chief/rs-stuck >/dev/null 2>&1 || fail "the branch and its commits were not kept"
[ "$(git rev-list --count main..chief/rs-stuck)" -ge 3 ] \
  || fail "the branch does not carry the commits every one of those iterations made"

# ── 3. AND IT FIRED WITH `112`'s PROGRESS RULE FULLY IN PLACE ─────────────────
# Every iteration changed real paths outside .chief/state/, so the progress rule scored
# progress every time and the stall counter never moved. If this fixture ever produces a
# `no progress` line, it is no longer reproducing 283 and assertion 2 proves nothing.
grep -q 'Iteration 2: progress' "$LOG" \
  || fail "the fixture did not score progress on iteration 2 — it is not reproducing 283"
grep -q 'no progress' "$LOG" \
  && fail "an iteration scored NO progress — the stop may be the stall counter, not the repeat rule"

# ── 4. NO FALSE STOP ──────────────────────────────────────────────────────────
# Same fixture, same commits, same story — only the measurement moves. It must run PAST
# N and finish.
case "$(status rs-working)" in MERGED*) ;; *) fail "a tasklist recording a NEW measurement each turn was stopped: '$(status rs-working)'" ;; esac
[ "$(cat "$WORK/turns-rs-working" 2>/dev/null || echo 0)" = "4" ] \
  || fail "the working tasklist took $(cat "$WORK/turns-rs-working" 2>/dev/null || echo 0) turns, not the 4 it needed"
[ -f tasks/chief/completed/rs-working.json ] || fail "the working tasklist was not retired"

# ── 5. N IS CONFIGURABLE, END TO END ──────────────────────────────────────────
# Through `chief run`'s environment and down into the agent loop — a default nobody can
# change is a constant, and 283's operator needed a smaller one.
PATH="$WORK/fakebin:$PATH" REPEAT_LIMIT=2 "$CHIEF" run rs-knob >"$WORK/run2.log" 2>&1 \
  || { cat "$WORK/run2.log"; fail "the REPEAT_LIMIT=2 run exited non-zero"; }
git checkout -q main
case "$(status rs-knob)" in CANNOT-COMPLETE*) ;; *) fail "REPEAT_LIMIT=2 did not stop the tasklist: '$(status rs-knob)'" ;; esac
[ "$(cat "$WORK/turns-rs-knob" 2>/dev/null || echo 0)" = "2" ] \
  || fail "REPEAT_LIMIT=2 stopped after $(cat "$WORK/turns-rs-knob" 2>/dev/null || echo 0) turns, not 2"
grep -q 'limit 2' "$REPO/.chief/state/parallel/rs-knob.log" \
  || fail "the stop does not state the N it used, so a reader cannot tell a tuned run from a default one"

echo "REPEAT PASS — an outcome recorded identically at N consecutive boundaries stops the tasklist,"
echo "              names the story, quotes the finding and both fixes, fires with progress scoring"
echo "              every iteration, never fires on a measurement that moves, and N is a knob."
