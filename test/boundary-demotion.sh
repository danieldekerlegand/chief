#!/usr/bin/env bash
# test/boundary-demotion.sh — prove the BAR rule fires at the ITERATION BOUNDARY, not
# only at the merge, and that the merge floor is still there underneath it.
#
# The failure it guards against (measured 2026-08-17, four runs across three repos):
# an agent marks a story `passes:true` with empty `notes`, keeps going, finishes the
# tasklist, and nothing is said until the run reaches MERGE — by which time the agent
# is gone and a human has to re-run the check and type the number in. Not one of those
# runs was a defect in the WORK; every one was missing only the value that proves it.
# Told at the boundary instead, the agent still has the output in context.
#
# Two tasklists, one run, one fake agent:
#   bd-fix   turn 1 marks US-1 passing with NO observed value and does not complete.
#            Turn 2 records what the runtime PRD says at the TOP of the turn (the
#            assertion this test exists for — `passes:false`, before it does anything
#            else), then re-marks with the number and completes -> MERGED.
#   bd-last  marks and completes in the SAME turn, so the boundary is never reached.
#            The merge-time gate (engine/driver.sh) must still catch it -> UNVERIFIED.
#            That is the floor: the boundary check is an earlier moment for one rule,
#            never a replacement for it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=bd GIT_AUTHOR_EMAIL=bd@test GIT_COMMITTER_NAME=bd GIT_COMMITTER_EMAIL=bd@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos" CHIEF_WORKTREE_ROOT="$WORK/wt"  # hermetic: don't touch ~/.chief
fail() { echo "BOUNDARY FAIL: $*" >&2
         [ -f "$WORK/run.log" ] && tail -30 "$WORK/run.log" >&2
         [ -f "$WORK/repo/.chief/state/parallel/bd-fix.log" ] && tail -60 "$WORK/repo/.chief/state/parallel/bd-fix.log" >&2
         exit 1; }
command -v jq >/dev/null || fail "jq required"

# ── install chief from this checkout (HEAD — commit before trusting a green run) ──
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# ── fake `claude` ─────────────────────────────────────────────────────────────
# Its turn counter lives OUTSIDE the worktree (the driver rebuilds that), and so does
# the record of what it SAW — the test reads it after the run rather than trying to
# observe a mid-run file that the merge phase has already moved on from.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null                                   # drain the prompt
W="@WORK@"
PRD=".chief/state/prd.json"                      # cwd = the worktree
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
turn=$(( $(cat "$W/turns-$name" 2>/dev/null || echo 0) + 1 )); echo "$turn" > "$W/turns-$name"
# WHAT THIS TURN INHERITS, read before anything is touched: the pass-flag the previous
# turn left behind, as the runtime PRD reports it at the top of THIS turn.
jq -r '[.userStories[]|select(.id=="US-1")|.passes][0]' "$PRD" > "$W/seen-$name-$turn"
mark() {  # mark US-1 passing with the notes given
  local t; t="$(mktemp)"
  jq --arg n "$1" '.userStories |= map(if .id=="US-1" then .passes=true | .notes=$n else . end)' \
    "$PRD" > "$t" && mv "$t" "$PRD"
  cp "$PRD" "tasks/chief/$name.json"
  mkdir -p out; printf 'impl %s turn %s\n' "$name" "$turn" > "out/$name.txt"
  git add -A >/dev/null 2>&1 || true
  git commit -q -m "feat: US-1 - $name (turn $turn)" >/dev/null 2>&1 || true
}
if [ "$name" = "bd-last" ]; then
  mark "Reworked the exporter seam."            # no observed value, and completes at once
  echo "<promise>COMPLETE</promise>"; exit 0
fi
if [ "$turn" = 1 ]; then
  mark "Reworked the exporter seam."            # no observed value -> demoted at the boundary
  echo "story marked; not done yet"; exit 0     # deliberately NOT complete: reach the boundary
fi
mark "Re-ran the suite: 0 failed, down from the 77 baseline."
echo "<promise>COMPLETE</promise>"
exit 0
FAKE
sed -i.bak "s#@WORK@#$WORK#" "$WORK/fakebin/claude" && rm -f "$WORK/fakebin/claude.bak"
chmod +x "$WORK/fakebin/claude"

# ── scaffold a repo with the two tasklists + a verify hook that would PASS ─────
REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null
rm -f tasks/chief/example.json
stories='[
    {"id":"US-1","title":"reach GREEN acceptance","description":"",
     "acceptanceCriteria":["the suite reaches GREEN acceptance; the baseline to beat is 77 failed"],"passes":false,"notes":""}
  ]'
for n in bd-fix bd-last; do
  jq -n --arg n "$n" --argjson s "$stories" \
    '{project:"bd",branchName:("chief/"+$n),description:"the bar rule at the boundary",iters:4,
      dependsOn:[],touches:[$n],warmup:[],userStories:$s}' > "tasks/chief/$n.json"
done
printf '#!/usr/bin/env bash\nset -eu\necho "verify: (would pass)"\nexit 0\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "bd setup"

PATH="$WORK/fakebin:$PATH" "$CHIEF" run >"$WORK/run.log" 2>&1 || { cat "$WORK/run.log"; fail "run exited non-zero"; }
status() { cat "$REPO/.chief/state/parallel/$1.status" 2>/dev/null || echo MISSING; }
LOG="$REPO/.chief/state/parallel/bd-fix.log"

# ── 1. THE ASSERTION: the next TURN starts with the story back at passes:false ──
# Not "the run eventually failed" — what the agent itself read at the top of turn 2.
[ -f "$WORK/seen-bd-fix-2" ] || fail "there was never a second iteration — the fake agent completed too early"
[ "$(cat "$WORK/seen-bd-fix-1")" = 'false' ] || fail "turn 1 did not start from a fresh story"
[ "$(cat "$WORK/seen-bd-fix-2")" = 'false' ] \
  || fail "turn 2 inherited US-1 as $(cat "$WORK/seen-bd-fix-2") — an unmeasured story survived the iteration boundary"

# ── 2. …and it was said out loud, at the boundary, naming the story and the bar ──
[ -f "$LOG" ] || fail "no worker log at $LOG"
grep -q 'demoted back to passes:false' "$LOG" || fail "the boundary demotion is never reported"
grep -q '✗ US-1 — reach GREEN acceptance' "$LOG" || fail "the demotion never names the story (id + title)"
grep -q 'the baseline to beat is 77 failed' "$LOG" || fail "the demotion never quotes the criterion's bar"
# TIMING, from the log's own order: the demotion has to land between the two turns.
d="$(grep -n 'demoted back to passes:false' "$LOG" | head -1 | cut -d: -f1)"
i2="$(grep -n 'Chief Iteration 2' "$LOG" | head -1 | cut -d: -f1)"
[ -n "$i2" ] || fail "the log never shows a second iteration"
[ "$d" -lt "$i2" ] || fail "the demotion was reported AFTER iteration 2 started — that is not the boundary"

# ── 3. an agent that then records the number is not punished ──────────────────
case "$(status bd-fix)" in MERGED*) ;; *) fail "the re-marked branch did not merge, got: '$(status bd-fix)'" ;; esac
git checkout -q main
[ -f out/bd-fix.txt ]                    || fail "the re-marked branch's work is not on main"
[ -f tasks/chief/completed/bd-fix.json ] || fail "the re-marked tasklist was not retired"
grep -q 'down from the 77 baseline' tasks/chief/completed/bd-fix.json \
  || fail "the observed value the second turn recorded is not in the completed record"

# ── 4. the merge floor STAYS: a story marked by the LAST turn is still caught ──
case "$(status bd-last)" in UNVERIFIED*) ;; *) fail "the merge-time gate no longer catches a last-turn marking, got: '$(status bd-last)'" ;; esac
[ ! -f out/bd-last.txt ]                    || fail "the unmeasured branch was merged to main"
[ ! -f tasks/chief/completed/bd-last.json ] || fail "the unmeasured tasklist was retired"
[ "$(jq -r '.userStories[]|select(.id=="US-1")|.unverified' "$REPO/.chief/state/snapshots/bd-last.json")" = "true" ] \
  || fail "the last-turn marking was not marked unverified"

echo "BOUNDARY PASS — an unmeasured story is back at passes:false before the next turn begins, and the merge floor still catches a last-turn marking"
