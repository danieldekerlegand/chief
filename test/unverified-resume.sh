#!/usr/bin/env bash
# test/unverified-resume.sh — an UNVERIFIED stop must OUTLIVE the run that produced it.
#
# The failure it guards against (insimul 261-slice-corpus-babylon-reference, three runs):
# the merge gate demotes a story whose criteria state a bar and whose notes record no
# observed value, and the run ends UNVERIFIED. The demotion is written to the RUNTIME
# prd.json inside a worktree the next run deletes; the branch's COMMITTED tasklist still
# reads passes:true. So the next run computes `left = 0`, prints "all stories already
# pass — skip agent", spends no agent turn, and re-fails at the same gate — identically,
# forever. It took a human flipping the pass-flag back by hand to break the loop.
#
# The test drives the whole shape offline, and drives it TWICE — once against an engine
# with the fix surgically removed, once against the engine as shipped. Same repo layout,
# same tasklist, same fake agent: the ONLY difference is the engine, which is what makes
# arm 1 a reproduction rather than a restatement.
#
#   PART 1 — uv-old, against the UN-FIXED engine (a copy of this install with the marker
#            write neutralized, exactly as the engine behaved before this fix existed).
#            Run 1 marks the bar-stating story passing with no observed value -> UNVERIFIED.
#            Run 2 spends ZERO agent turns, takes the "skip agent" path, and ends
#            UNVERIFIED a second time. That is the defect, reproduced.
#   PART 2 — the same fixture against the shipped engine:
#     uv-loop  run 1 -> UNVERIFIED + a marker. Run 2 re-engages the agent, which is told
#              which story and which bar it owes, records the value -> MERGED, marker gone.
#     uv-done  THE NEGATIVE CASE, riding in the same run: a genuinely finished all-pass
#              branch with NO marker still skips the agent and merges, 0 turns spent. A fix
#              that spends an agent turn on every resume is worse than the loop it closes.
#     uv-spin  THE PATHOLOGICAL CASE: an agent that never records the value, on a branch
#              that is re-engaged every run. It must not spin — the existing demote limit
#              (MEASURE_DEMOTE_LIMIT, 2 consecutive boundary demotions for the same story)
#              ends each run at exactly 2 turns out of an iteration budget of 4, and the
#              run TERMINATES as UNVERIFIED rather than burning to HARD_MAX.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=uv GIT_AUTHOR_EMAIL=uv@test GIT_COMMITTER_NAME=uv GIT_COMMITTER_EMAIL=uv@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos" CHIEF_WORKTREE_ROOT="$WORK/wt"  # hermetic: don't touch ~/.chief
fail() { echo "UNVERIFIED-RESUME FAIL: $*" >&2
         for l in "$WORK/old2.log" "$WORK/run2.log" "$WORK/repo/.chief/state/parallel/uv-loop.log"; do
           [ -f "$l" ] && { echo "--- $l ---" >&2; tail -40 "$l" >&2; }
         done
         exit 1; }
command -v jq >/dev/null || fail "jq required"

# ── install chief from this checkout (HEAD — commit before trusting a green run) ──
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# ── …and a second copy of it with THE FIX REMOVED ─────────────────────────────
# The surgery is at the mechanism's source: `unverified_persist` is what writes the
# marker, and without a marker the resume arm that reads it cannot fire and the pickup
# that demotes the named stories no-ops — i.e. precisely the engine as it behaved before
# this tasklist. Cutting the resume ARM instead would leave the pickup demoting stories
# in the runtime record and the run would end INCOMPLETE, which is not the loop that was
# observed in the field. If this function ever moves or is renamed, the greps below fail
# LOUDLY rather than quietly turning arm 1 into a test of the fixed engine.
OLDSRC="$WORK/ch-old/src"; OLDBIN="$WORK/bin-old"
cp -R "$PREFIX" "$WORK/ch-old" || fail "could not copy the install prefix"
mkdir -p "$OLDBIN"; ln -sf "$OLDSRC/bin/chief" "$OLDBIN/chief"
grep -q '^unverified_persist() {$' "$OLDSRC/engine/measure.sh" \
  || fail "engine/measure.sh no longer defines unverified_persist() on its own line — update this test's un-fix surgery"
sed -i.bak 's/^unverified_persist() {$/unverified_persist() { return 0   # UN-FIXED by test\/unverified-resume.sh/' \
  "$OLDSRC/engine/measure.sh" && rm -f "$OLDSRC/engine/measure.sh.bak"
grep -q 'UN-FIXED by test' "$OLDSRC/engine/measure.sh" || fail "the un-fix surgery did not apply"
bash -n "$OLDSRC/engine/measure.sh" || fail "the un-fix surgery left measure.sh unparseable"
CHIEF_OLD="$OLDBIN/chief"

# ── one fake `claude`, shared by both engines ─────────────────────────────────
# It records an observed value ONLY when chief tells it which story and which bar it
# owes. Told nothing, it re-marks the same story unchanged — which is what a real agent
# handed a finished-looking tasklist does, and the whole reason the marker has to carry
# the report. Turn counters live OUTSIDE the worktree (the driver rebuilds that one), so
# "how many turns did this tasklist spend?" is answerable after the run has ended.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
W="@WORK@"
P="$(mktemp)"; cat > "$P"                        # THE PROMPT this turn was invoked with
PRD=".chief/state/prd.json"                      # cwd = the worktree
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
turn=$(( $(cat "$W/turns-$name" 2>/dev/null || echo 0) + 1 )); echo "$turn" > "$W/turns-$name"
cp "$P" "$W/prompt-$name-$turn"
cp .chief/state/progress.txt "$W/progress-$name-$turn" 2>/dev/null || true
# What this turn INHERITS, read before anything is touched.
jq -r '[.userStories[]|select(.id=="US-1")|.passes][0]' "$PRD" > "$W/seen-$name-$turn"
mark() {  # mark US-1 passing with the notes given: runtime PRD, tracked tasklist, a commit
  local t; t="$(mktemp)"
  jq --arg n "$1" '.userStories |= map(if .id=="US-1" then .passes=true | .notes=$n else . end)' \
    "$PRD" > "$t" && mv "$t" "$PRD"
  # …and in the git-tracked tasklist, exactly as the loop instructions tell an agent to.
  # That is what makes the NEXT run read the branch as finished.
  cp "$PRD" "tasks/chief/$name.json"
  mkdir -p out; printf 'impl %s turn %s\n' "$name" "$turn" > "out/$name.txt"
  git add -A >/dev/null 2>&1 || true
  git commit -q -m "feat: US-1 - $name (turn $turn)" >/dev/null 2>&1 || true
}
if [ "$name" = "uv-spin" ]; then
  # Never records a value and never completes, but commits every turn — so HEAD keeps
  # moving and the stall counter never fires. Only the demote limit can stop this.
  mark "Reworked the exporter seam."
  echo "story marked; not done yet"; exit 0
fi
if grep -q 'chief DEMOTED a story you marked' "$P"; then
  mark "Re-ran the suite: 0 failed, down from the 77 baseline."
else
  mark "Reworked the exporter seam."            # no observed value recorded
fi
echo "<promise>COMPLETE</promise>"
exit 0
FAKE
sed -i.bak "s#@WORK@#$WORK#" "$WORK/fakebin/claude" && rm -f "$WORK/fakebin/claude.bak"
chmod +x "$WORK/fakebin/claude"

# ── a repo scaffold, used identically by both arms ────────────────────────────
STORY='[
    {"id":"US-1","title":"reach GREEN acceptance","description":"",
     "acceptanceCriteria":["the suite reaches GREEN acceptance; the baseline to beat is 77 failed"],"passes":false,"notes":""}
  ]'
scaffold() {  # scaffold REPO CHIEF_BIN NAME[:ITERS]…
  local repo="$1" chief="$2"; shift 2
  mkdir -p "$repo"; ( cd "$repo"
    git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
    git commit -q --allow-empty -m init
    "$chief" init >/dev/null
    rm -f tasks/chief/example.json
    for spec in "$@"; do
      local n="${spec%%:*}" it="${spec##*:}"
      jq -n --arg n "$n" --argjson i "$it" --argjson s "$STORY" \
        '{project:"uv",branchName:("chief/"+$n),description:"an unmeasured bar survives the resume",
          iters:$i,dependsOn:[],touches:[$n],warmup:[],userStories:$s}' > "tasks/chief/$n.json"
    done
    printf '#!/usr/bin/env bash\nset -eu\necho "verify: (would pass)"\nexit 0\n' > .chief/verify.sh
    chmod +x .chief/verify.sh
    git add -A && git commit -q -m "uv setup" ) || fail "could not scaffold $repo"
}
status() { cat "$1/.chief/state/parallel/$2.status" 2>/dev/null || echo MISSING; }
turns()  { cat "$WORK/turns-$1" 2>/dev/null || echo 0; }

# ══ PART 1 — THE REPRODUCTION: the same fixture on the un-fixed engine ════════
OLDREPO="$WORK/repo-old"
scaffold "$OLDREPO" "$CHIEF_OLD" uv-old:2
run_old() { ( cd "$OLDREPO" && PATH="$WORK/fakebin:$PATH" \
    CHIEF_RUNS="$WORK/runs-old" CHIEF_REPOS="$WORK/repos-old" CHIEF_WORKTREE_ROOT="$WORK/wt-old" \
    "$CHIEF_OLD" run ) >"$1" 2>&1 || { cat "$1"; fail "un-fixed run exited non-zero"; }; }
run_old "$WORK/old1.log"

case "$(status "$OLDREPO" uv-old)" in UNVERIFIED*) ;; *) fail "run 1 on the un-fixed engine did not stop UNVERIFIED, got: '$(status "$OLDREPO" uv-old)'" ;; esac
[ "$(turns uv-old)" = "1" ] || fail "run 1 on the un-fixed engine spent $(turns uv-old) agent turns (expected 1)"
[ ! -f "$OLDREPO/.chief/state/snapshots/uv-old.unverified.md" ] \
  || fail "the un-fix surgery did not take — the un-fixed engine still recorded a marker, so arm 1 is not a reproduction"

# THE LOOP: the second run reads a branch whose committed tasklist still says passes:true,
# spends nothing, and re-fails at the same gate. Three of these in a row is what the field
# incident looked like before a human flipped the pass-flag back by hand.
run_old "$WORK/old2.log"
[ "$(turns uv-old)" = "1" ] \
  || fail "the un-fixed engine re-engaged the agent (turns now $(turns uv-old)) — the fix leaked into the copy and arm 1 proves nothing"
grep -q 'skip agent' "$OLDREPO/.chief/state/parallel/uv-old.log" \
  || fail "the un-fixed re-run did not take the agent-free all-pass path — the reproduction is not the observed defect"
case "$(status "$OLDREPO" uv-old)" in UNVERIFIED*) ;; *) fail "the un-fixed re-run did not end UNVERIFIED a second time, got: '$(status "$OLDREPO" uv-old)'" ;; esac
git -C "$OLDREPO" checkout -q main
[ ! -f "$OLDREPO/out/uv-old.txt" ]                    || fail "the un-fixed engine merged an unmeasured branch"
[ ! -f "$OLDREPO/tasks/chief/completed/uv-old.json" ] || fail "the un-fixed engine retired an unmeasured tasklist"

# ══ PART 2 — the engine as shipped, same fixture, plus its two boundary cases ══
REPO="$WORK/repo"
scaffold "$REPO" "$CHIEF" uv-loop:2 uv-spin:4
run_new() { ( cd "$REPO" && PATH="$WORK/fakebin:$PATH" "$CHIEF" run ) >"$1" 2>&1 \
              || { cat "$1"; fail "run exited non-zero"; }; }
run_new "$WORK/run1.log"
SNAP="$REPO/.chief/state/snapshots"
MARK="$SNAP/uv-loop.unverified.md"

case "$(status "$REPO" uv-loop)" in UNVERIFIED*) ;; *) fail "run 1 did not stop UNVERIFIED, got: '$(status "$REPO" uv-loop)'" ;; esac
[ "$(turns uv-loop)" = "1" ] || fail "run 1 spent $(turns uv-loop) agent turns on uv-loop (expected 1)"
[ -f "$MARK" ] || fail "the UNVERIFIED stop left no marker for the resume at $MARK"
grep -q '✗ US-1 — reach GREEN acceptance' "$MARK" || fail "the marker does not name the story still owed a value"

# ── the pathological case, run 1: bounded by the demote limit, not the budget ──
# uv-spin re-marks US-1 with no value on every turn and commits every turn, so nothing
# else in the engine can see it as stuck. iters:4 (HARD_MAX far above that) against a
# limit of 2 consecutive demotions for the same story: the run must END, at 2.
case "$(status "$REPO" uv-spin)" in UNVERIFIED*) ;; *) fail "the never-recording branch did not stop UNVERIFIED, got: '$(status "$REPO" uv-spin)'" ;; esac
[ "$(turns uv-spin)" = "2" ] \
  || fail "run 1 spent $(turns uv-spin) turns re-marking one story (expected 2 — the demote limit, not the iteration budget)"

# ── THE NEGATIVE CASE, planted before run two: an all-pass branch, NO marker ───
# What a run that genuinely finished leaves behind. It must still merge WITHOUT an agent
# turn, and it has to ride in the SAME run as the re-engagement above — only running both
# halves together proves the fix does not cost a turn on every resume.
git -C "$REPO" checkout -q main
( cd "$REPO"
  jq -n --argjson s "$STORY" \
    '{project:"uv",branchName:"chief/uv-done",description:"an unmeasured bar survives the resume",
      iters:2,dependsOn:[],touches:["uv-done"],warmup:[],userStories:$s}' > tasks/chief/uv-done.json
  git add -A && git commit -q -m "uv-done scheduled"
  git worktree add -q "$WORK/donewt" -b chief/uv-done main
  cd "$WORK/donewt"
  t="$(mktemp)"
  jq '.userStories |= map(.passes=true | .notes="Re-ran the suite: 0 failed, down from the 77 baseline.")' \
    tasks/chief/uv-done.json > "$t" && mv "$t" tasks/chief/uv-done.json
  mkdir -p out; printf 'impl uv-done\n' > out/uv-done.txt
  git add -A && git commit -q -m "feat: US-1 - uv-done" ) || fail "could not plant the finished branch"
git -C "$REPO" worktree remove --force "$WORK/donewt"

run_new "$WORK/run2.log"

# ── 1. the loop is closed: the re-run engages the agent and the tasklist MERGES ─
LOG2="$REPO/.chief/state/parallel/uv-loop.log"
grep -q 'stopped UNVERIFIED last run' "$LOG2" \
  || fail "the re-run did not re-engage the agent on the persisted UNVERIFIED stop"
! grep -q 'skip agent' "$LOG2" || fail "the re-run skipped the agent — the loop is still open"
[ "$(turns uv-loop)" = "2" ] || fail "the re-run spent $(turns uv-loop) total turns on uv-loop (expected 2)"
[ "$(cat "$WORK/seen-uv-loop-2")" = "false" ] \
  || fail "the re-engaged turn inherited US-1 as $(cat "$WORK/seen-uv-loop-2") — a demoted story read as finished work"
# It was TOLD which story and which bar, in the engine's own words — grep only for strings
# the ENGINE emits plus the bar this fixture planted (instructions.md discusses bars every turn).
P2="$WORK/prompt-uv-loop-2"
grep -q '✗ US-1 — reach GREEN acceptance' "$P2" || fail "the re-engaged turn's prompt does not name the story"
grep -q 'claimed: "the suite reaches GREEN acceptance; the baseline to beat is 77 failed"' "$P2" \
  || fail "the re-engaged turn's prompt does not quote the bar the criterion states"
case "$(status "$REPO" uv-loop)" in MERGED*) ;; *) fail "the re-engaged branch did not merge, got: '$(status "$REPO" uv-loop)'" ;; esac
git -C "$REPO" checkout -q main
[ -f "$REPO/out/uv-loop.txt" ]                    || fail "the re-engaged branch's work is not on main"
[ -f "$REPO/tasks/chief/completed/uv-loop.json" ] || fail "the re-engaged tasklist was not retired"
grep -q 'down from the 77 baseline' "$REPO/tasks/chief/completed/uv-loop.json" \
  || fail "the value the re-engaged turn recorded is not in the completed record"
[ ! -f "$MARK" ] || fail "the marker outlived the merge — every future resume of a finished tasklist would buy an agent turn"

# ── 2. the negative case: no marker, no turn, and it still merges ─────────────
case "$(status "$REPO" uv-done)" in MERGED*) ;; *) fail "the finished branch did not merge, got: '$(status "$REPO" uv-done)'" ;; esac
[ "$(turns uv-done)" = "0" ] \
  || fail "an all-pass branch with no marker spent $(turns uv-done) agent turn(s) — the fix costs a turn on every resume"
grep -q 'skip agent' "$REPO/.chief/state/parallel/uv-done.log" \
  || fail "the finished branch did not take the agent-free all-pass path"
[ -f "$REPO/tasks/chief/completed/uv-done.json" ] || fail "the finished tasklist was not retired"

# ── 3. the pathological case: re-engaged, still bounded, and it TERMINATES ────
# The marker put uv-spin back in front of an agent that never records anything. The run
# must not spin: two consecutive demotions for the same story end it, again at 2 turns.
SPINLOG="$REPO/.chief/state/parallel/uv-spin.log"
grep -q 'stopped UNVERIFIED last run' "$SPINLOG" || fail "the never-recording branch was not re-engaged on its marker"
[ "$(cat "$WORK/seen-uv-spin-3")" = "false" ] \
  || fail "the re-engaged turn inherited US-1 as $(cat "$WORK/seen-uv-spin-3") — the demotion did not reach the resumed record"
[ "$(turns uv-spin)" = "4" ] \
  || fail "the re-engaged never-recording branch spent $(( $(turns uv-spin) - 2 )) turns in run 2 (expected 2 — the demote limit)"
grep -q 'consecutive iteration boundaries' "$SPINLOG" || fail "the bounded stop never says WHY it stopped"
case "$(status "$REPO" uv-spin)" in UNVERIFIED*) ;; *) fail "the never-recording branch did not stop UNVERIFIED, got: '$(status "$REPO" uv-spin)'" ;; esac
[ ! -f "$REPO/out/uv-spin.txt" ]                    || fail "the never-recording branch was merged to main"
[ ! -f "$REPO/tasks/chief/completed/uv-spin.json" ] || fail "the never-recording tasklist was retired"

echo "UNVERIFIED-RESUME PASS — reproduced on the un-fixed engine (re-run: 0 agent turns, UNVERIFIED twice), closed on the shipped one (re-engaged, told the bar, MERGED), with a finished all-pass branch still merging agent-free and a never-recorded value bounded by the demote limit"
