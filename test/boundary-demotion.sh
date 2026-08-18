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
#            else) AND the prompt it was handed (which must name the demoted story and
#            quote its bar), then re-marks with the number and completes -> MERGED.
#   bd-last  marks and completes in the SAME turn, so the boundary is never reached.
#            The merge-time gate (engine/driver.sh) must still catch it -> UNVERIFIED.
#            That is the floor: the boundary check is an earlier moment for one rule,
#            never a replacement for it.
#   bd-remark THE GOOD CASE, isolated. Turn 1 marks with no value (and commits); turn 2
#            records the value and touches NOTHING ELSE — no commit, no file — so the
#            ONLY thing that can make iteration 2 read as progress is the pass count
#            rising above what the demotion left behind. If the boundary re-baselined
#            before demoting instead of after, the honest repair would land as a STALL
#            and the agent would be punished for doing exactly what it was asked.
#   bd-spin  THE PATHOLOGICAL CASE. Marks US-1 with no value on EVERY turn and never
#            completes — and commits each time, so HEAD moves and the stall counter
#            reads progress forever. This is the loop the boundary check would create
#            if nothing bounded it: on the pre-change engine it runs to HARD_MAX (20)
#            turns. Two consecutive demotions for the same story must end the run with
#            the demotion named -> UNVERIFIED, in exactly 2 turns.
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
W="@WORK@"
P="$(mktemp)"; cat > "$P"                        # THE PROMPT this turn was invoked with
PRD=".chief/state/prd.json"                      # cwd = the worktree
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
turn=$(( $(cat "$W/turns-$name" 2>/dev/null || echo 0) + 1 )); echo "$turn" > "$W/turns-$name"
cp "$P" "$W/prompt-$name-$turn"                  # kept outside the worktree, like the rest
# WHAT THIS TURN INHERITS, read before anything is touched: the pass-flag the previous
# turn left behind, as the runtime PRD reports it at the top of THIS turn.
jq -r '[.userStories[]|select(.id=="US-1")|.passes][0]' "$PRD" > "$W/seen-$name-$turn"
mark_only() {  # mark US-1 passing with the notes given, in the RUNTIME PRD and nowhere else
  local t; t="$(mktemp)"
  jq --arg n "$1" '.userStories |= map(if .id=="US-1" then .passes=true | .notes=$n else . end)' \
    "$PRD" > "$t" && mv "$t" "$PRD"
}
mark() {  # …and do a real turn's worth of work around it: tracked tasklist + a commit
  mark_only "$1"
  cp "$PRD" "tasks/chief/$name.json"
  mkdir -p out; printf 'impl %s turn %s\n' "$name" "$turn" > "out/$name.txt"
  git add -A >/dev/null 2>&1 || true
  git commit -q -m "feat: US-1 - $name (turn $turn)" >/dev/null 2>&1 || true
}
if [ "$name" = "bd-last" ]; then
  mark "Reworked the exporter seam."            # no observed value, and completes at once
  echo "<promise>COMPLETE</promise>"; exit 0
fi
if [ "$name" = "bd-spin" ]; then
  # Never records a value, never completes, commits every turn: the loop that HEAD-based
  # progress accounting cannot see. Only the repeat bound can stop this.
  mark "Reworked the exporter seam."
  echo "story marked; not done yet"; exit 0
fi
if [ "$name" = "bd-remark" ]; then
  if [ "$turn" = 1 ]; then
    mark "Reworked the exporter seam."          # no observed value -> demoted at the boundary
    echo "story marked; not done yet"; exit 0
  fi
  if [ "$turn" = 2 ]; then
    # THE REPAIR, AND NOTHING ELSE. No commit and no tracked file: if iteration 2 reads
    # as progress it can only be because the pass count rose past the demotion.
    mark_only "Re-ran the suite: 0 failed, down from the 77 baseline."
    echo "value recorded; not done yet"; exit 0
  fi
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
for n in bd-fix bd-last bd-remark bd-spin; do
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

# ── 3. …and the reason reaches the PROMPT the provider is handed, not just the log ──
# The log is read by an operator, hours later, on a run that has already ended — the
# same audience the merge-time report already had. The turn that can still ACT on the
# demotion only ever sees its prompt. Grep for strings only the ENGINE emits (the
# notice heading, and measure.sh's own report lines) plus the bar this fixture planted:
# instructions.md talks about bars and demotion on EVERY turn, so a loose match here
# would go green with nothing injected at all.
P2="$WORK/prompt-bd-fix-2"
[ -s "$P2" ] || fail "turn 2's prompt was never captured"
grep -q 'chief DEMOTED a story you marked' "$P2" \
  || fail "turn 2's prompt never tells the agent a story was demoted"
grep -q '✗ US-1 — reach GREEN acceptance' "$P2" \
  || fail "the notice in the prompt does not name the demoted story (id + title)"
grep -q 'claimed: "the suite reaches GREEN acceptance; the baseline to beat is 77 failed"' "$P2" \
  || fail "the notice in the prompt does not quote the bar the criterion states"
grep -q 'recorded: "Reworked the exporter seam." — no observed value in it' "$P2" \
  || fail "the notice in the prompt does not say what the notes DID say"
# …and it is absent when nothing was demoted. A notice that is always there is noise,
# and an agent that learns to skip it is back where this tasklist started.
! grep -q 'chief DEMOTED a story you marked' "$WORK/prompt-bd-fix-1" \
  || fail "turn 1's prompt carries a demotion notice with nothing yet demoted"
! grep -q 'chief DEMOTED a story you marked' "$WORK/prompt-bd-last-1" \
  || fail "bd-last's single turn carries a demotion notice with nothing yet demoted"

# ── 4. an agent that then records the number is not punished ──────────────────
case "$(status bd-fix)" in MERGED*) ;; *) fail "the re-marked branch did not merge, got: '$(status bd-fix)'" ;; esac
git checkout -q main
[ -f out/bd-fix.txt ]                    || fail "the re-marked branch's work is not on main"
[ -f tasks/chief/completed/bd-fix.json ] || fail "the re-marked tasklist was not retired"
grep -q 'down from the 77 baseline' tasks/chief/completed/bd-fix.json \
  || fail "the observed value the second turn recorded is not in the completed record"

# ── 5. the merge floor STAYS: a story marked by the LAST turn is still caught ──
case "$(status bd-last)" in UNVERIFIED*) ;; *) fail "the merge-time gate no longer catches a last-turn marking, got: '$(status bd-last)'" ;; esac
[ ! -f out/bd-last.txt ]                    || fail "the unmeasured branch was merged to main"
[ ! -f tasks/chief/completed/bd-last.json ] || fail "the unmeasured tasklist was retired"
[ "$(jq -r '.userStories[]|select(.id=="US-1")|.unverified' "$REPO/.chief/state/snapshots/bd-last.json")" = "true" ] \
  || fail "the last-turn marking was not marked unverified"

# ── 6. THE GOOD CASE: the repair the demotion asked for counts as PROGRESS ────
# bd-remark's turn 2 records the value and does nothing else — no commit, no file. So
# "iteration 2 made progress" can only be true if the boundary re-baselined the pass
# count AFTER demoting, leaving the honest re-mark to raise it. Get that order wrong and
# an agent that does exactly what it was told is charged a stall for it.
LOGR="$REPO/.chief/state/parallel/bd-remark.log"
[ -f "$LOGR" ] || fail "no worker log at $LOGR"
[ "$(cat "$WORK/seen-bd-remark-2" 2>/dev/null || echo MISSING)" = 'false' ] \
  || fail "bd-remark's turn 2 did not start from the demotion — the fixture is not exercising the re-mark path"
! grep -q 'Iteration 2: no progress' "$LOGR" \
  || fail "the evidenced re-mark was counted as a STALL — the demotion must re-baseline the pass count it left behind"
grep -q 'Iteration 2: progress' "$LOGR" \
  || fail "the evidenced re-mark was not counted as progress"
[ -f "$WORK/seen-bd-remark-3" ] || fail "bd-remark never reached a third turn — the run did not advance past the re-mark"
case "$(status bd-remark)" in MERGED*) ;; *) fail "the re-marked branch did not merge, got: '$(status bd-remark)'" ;; esac

# ── 7. THE PATHOLOGICAL CASE: it terminates, naming the demotion, instead of spinning ──
# bd-spin re-marks US-1 with no value on every turn AND commits every turn, so HEAD keeps
# moving and the stall counter never fires. Unbounded, this is the loop the boundary check
# itself creates: on the pre-change engine it runs to HARD_MAX (20 turns for iters:4).
LOGS="$REPO/.chief/state/parallel/bd-spin.log"
[ -f "$LOGS" ] || fail "no worker log at $LOGS"
spun="$(cat "$WORK/turns-bd-spin" 2>/dev/null || echo 0)"
[ "$spun" = "2" ] \
  || fail "bd-spin spent $spun turns re-marking one story — two consecutive demotions for the same story must end the run (expected 2)"
case "$(status bd-spin)" in UNVERIFIED*) ;; *) fail "the spinning branch did not stop as UNVERIFIED, got: '$(status bd-spin)'" ;; esac
grep -q 'consecutive iteration boundaries' "$LOGS" || fail "the stop never says WHY it stopped"
grep -q '✗ US-1 — reach GREEN acceptance' "$LOGS" || fail "the stop does not name the story and bar it stopped on"
grep -q 'stopped MID-RUN on the bar rule' "$LOGS" || fail "the driver does not report the in-run stop"
[ ! -f out/bd-spin.txt ]                    || fail "the spinning branch was merged to main"
[ ! -f tasks/chief/completed/bd-spin.json ] || fail "the spinning tasklist was retired"
# …and it is a STOP, not a fall-through: nothing may have been left marked as passing.
[ "$(jq -r '[.userStories[]|select(.passes==true)]|length' "$REPO/.chief/state/snapshots/bd-spin.json")" = "0" ] \
  || fail "the story chief stopped on is still marked passing"

echo "BOUNDARY PASS — an unmeasured story is back at passes:false before the next turn begins, the next turn's PROMPT names it and quotes its bar, an evidenced re-mark counts as progress, a story demoted twice running ends the run instead of spinning, and the merge floor still catches a last-turn marking"
