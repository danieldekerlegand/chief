#!/usr/bin/env bash
# test/measured-bars.sh — prove a story claiming a MEASURABLE BAR must record what it
# observed, and is marked `unverified` rather than passing when it does not.
#
# The failure it guards against: cuneiform:348/US-2 claimed "reach GREEN acceptance,
# the baseline to beat is 77 failed", delivered 25 failed, and reported 3/3. The bar
# was falsifiable and nothing ever falsified it, because nothing ever recorded a
# result to hold against it.
#
# Two tasklists, one run, one fake agent, so both halves are proven together — a gate
# that fails honest work is worse than no gate:
#   mb-bad   marks its own stories passing with notes that say what it did but record
#            no value → UNVERIFIED, nothing merged or retired, the stories carry
#            `unverified:true` with `passes:false`, and the message names the story,
#            the bar that fired and the criterion verbatim.
#   mb-good  identical criteria, but its notes carry the observed numbers → merged.
# Then a SECOND run measures the resume BOTH WAYS at once, which is the whole risk of
# re-engaging on a marker — a fix that spends an agent turn on every resume is worse
# than the loop it closes:
#   mb-bad   committed tasklist still reads passes:true, marker present -> the agent IS
#            re-engaged (it reads US-1 back at passes:false and is handed the bar it
#            owes), records the value, and the branch MERGES with the marker cleared.
#   mb-skip  an all-pass branch with NO marker, planted by hand exactly as a run that
#            genuinely finished would leave one -> 0 agent turns, and it still merges.
# mb-bad marks its stories ITSELF on purpose: the evidence gate (test/evidence-gate.sh)
# exempts self-reported work from having to say HOW, and this rule deliberately does
# not — an unrecorded number is unrecorded whoever typed the pass-flag.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=mb GIT_AUTHOR_EMAIL=mb@test GIT_COMMITTER_NAME=mb GIT_COMMITTER_EMAIL=mb@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos" CHIEF_WORKTREE_ROOT="$WORK/wt"  # hermetic: don't touch ~/.chief
fail() { echo "MEASURE FAIL: $*" >&2; [ -f "$WORK/run.log" ] && tail -40 "$WORK/run.log" >&2
         [ -f "$WORK/repo/.chief/state/parallel/mb-bad.log" ] && tail -40 "$WORK/repo/.chief/state/parallel/mb-bad.log" >&2
         exit 1; }
command -v jq >/dev/null || fail "jq required"

# ── install chief from this checkout ──────────────────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# ── fake `claude`: both tasklists self-report; only the notes differ ───────────
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
W="@WORK@"
P="$(mktemp)"; cat > "$P"                        # THE PROMPT this turn was invoked with
PRD=".chief/state/prd.json"                      # cwd = the worktree
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
# Turn counter and prompt kept OUTSIDE the worktree (the driver rebuilds that one), so
# "how many turns did this tasklist spend?" is answerable after the run has ended.
turn=$(( $(cat "$W/turns-$name" 2>/dev/null || echo 0) + 1 )); echo "$turn" > "$W/turns-$name"
cp "$P" "$W/prompt-$name-$turn"
cp .chief/state/progress.txt "$W/progress-$name-$turn" 2>/dev/null || true
# What this turn INHERITS, read before anything is touched.
jq -r '[.userStories[]|select(.id=="US-1")|.passes][0]' "$PRD" > "$W/seen-$name-$turn"
mkdir -p out; printf 'impl %s\n' "$name" > "out/$name.txt"
if [ "$name" = "mb-bad" ] && ! grep -q 'chief DEMOTED a story you marked' "$P"; then
  note="Reworked the exporter seam and re-ran the suite."          # no value recorded
else
  # TOLD which stories and which bars, it answers with the value — the behaviour the
  # re-engagement exists to buy. Told nothing, it re-marks the same story unchanged.
  note="Re-ran the suite: 0 failed, down from the 77 baseline; the hook exits 0."
fi
t="$(mktemp)"
jq --arg n "$note" '.userStories |= map(.passes=true | .notes=$n)' "$PRD" > "$t" && mv "$t" "$PRD"
# …and in the git-tracked tasklist, exactly as the loop instructions tell an agent to.
# That is what makes a SECOND run take the agent-free "all stories already pass" path.
cp "$PRD" "tasks/chief/$name.json"
git add -A >/dev/null 2>&1 || true
git commit -q -m "feat: US-1 - $name" >/dev/null 2>&1 || true
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
# The bars are the incident's own three shapes: a state word, a numeric baseline, and
# an exit status. US-3 states no bar at all — it must pass on either branch, which is
# what keeps the rule from becoming "every story owes a number".
stories='[
    {"id":"US-1","title":"reach GREEN acceptance","description":"",
     "acceptanceCriteria":["the suite reaches GREEN acceptance; the baseline to beat is 77 failed"],"passes":false,"notes":""},
    {"id":"US-2","title":"the hook exits 0","description":"",
     "acceptanceCriteria":["the verify hook exits 0 on a clean tree"],"passes":false,"notes":""},
    {"id":"US-3","title":"no bar is claimed here","description":"",
     "acceptanceCriteria":["the output file for this tasklist exists"],"passes":false,"notes":""}
  ]'
for n in mb-bad mb-good; do
  jq -n --arg n "$n" --argjson s "$stories" \
    '{project:"mb",branchName:("chief/"+$n),description:"measurable bars",iters:2,
      dependsOn:[],touches:[$n],warmup:[],userStories:$s}' > "tasks/chief/$n.json"
done
printf '#!/usr/bin/env bash\nset -eu\necho "verify: (would pass)"\nexit 0\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "mb setup"

PATH="$WORK/fakebin:$PATH" "$CHIEF" run >"$WORK/run.log" 2>&1 || { cat "$WORK/run.log"; fail "run exited non-zero"; }
status() { cat "$REPO/.chief/state/parallel/$1.status" 2>/dev/null || echo MISSING; }
SNAP="$REPO/.chief/state/snapshots"

# ── 1. an unmeasured bar does not pass, and nothing of it lands ───────────────
case "$(status mb-bad)" in UNVERIFIED*) ;; *) fail "expected UNVERIFIED for the unmeasured branch, got: '$(status mb-bad)'" ;; esac
git checkout -q main
[ ! -f out/mb-bad.txt ]                    || fail "the unmeasured branch was merged to main"
[ -f tasks/chief/mb-bad.json ]             || fail "the unmeasured tasklist was retired"
[ ! -f tasks/chief/completed/mb-bad.json ] || fail "a completed record was written for an unmeasured run"

# ── 2. the third state: `unverified`, not `passes`, and only on the bar stories ─
[ -f "$SNAP/mb-bad.json" ] || fail "no snapshot at $SNAP/mb-bad.json"
for id in US-1 US-2; do
  [ "$(jq -r --arg i "$id" '.userStories[]|select(.id==$i)|.unverified' "$SNAP/mb-bad.json")" = "true" ] \
    || fail "$id was not marked unverified"
  [ "$(jq -r --arg i "$id" '.userStories[]|select(.id==$i)|.passes' "$SNAP/mb-bad.json")" = "false" ] \
    || fail "$id claims a bar nothing measured and still reads as passing"
done
[ "$(jq -r '.userStories[]|select(.id=="US-3")|.passes' "$SNAP/mb-bad.json")" = "true" ] \
  || fail "US-3 states no bar and must not be held to one"
[ "$(jq -r '.userStories[]|select(.id=="US-3")|has("unverified")' "$SNAP/mb-bad.json")" = "false" ] \
  || fail "US-3 states no bar and must not be marked unverified"

# ── 2b. the stop is RECORDED where the NEXT run can read it ──────────────────
# The demotion itself lives only in the runtime prd.json, which the next run rebuilds
# from the branch's committed tasklist — still passes:true. Without a marker outside
# the worktree the resume reads the branch as finished, spends no agent turn, and
# re-fails here identically forever (insimul 261-slice-corpus-babylon-reference, three
# runs). Same place and same lifetime as the post-rebase verify-failed log.
MARK="$SNAP/mb-bad.unverified.md"
[ -f "$MARK" ] || fail "the UNVERIFIED stop left no marker for the resume at $MARK"
grep -q '✗ US-1' "$MARK" || fail "the marker does not name the story whose bar went unmeasured"
grep -q '✗ US-2' "$MARK" || fail "the marker names only the first unmeasured story"
grep -q 'the baseline to beat is 77 failed' "$MARK" \
  || fail "the marker does not carry the bar the resumed agent has to measure"
if [ -f "$SNAP/mb-good.unverified.md" ]; then fail "the MEASURED branch got an UNVERIFIED marker"; fi

# ── 3. the operator is told WHAT was claimed and WHICH bar fired ──────────────
LOG="$REPO/.chief/state/parallel/mb-bad.log"
[ -f "$LOG" ]                          || fail "no worker log at $LOG"
grep -q 'UNVERIFIED' "$WORK/run.log"   || fail "the run summary never surfaces the UNVERIFIED status"
grep -q '✗ US-1 — reach GREEN acceptance' "$LOG" || fail "the failure never names the story (id + title)"
grep -q 'the baseline to beat is 77 failed'  "$LOG" || fail "the failure never quotes the criterion the story claimed"
grep -q 'states a bar'                 "$LOG" || fail "the failure never names the bar that fired"
grep -q 'the verify hook exits 0 on a clean tree' "$LOG" || fail "only the first unmeasured story was reported"
grep -q "Reworked the exporter seam" "$LOG" || fail "the failure never shows what the notes DID say"
# Not INCOMPLETE: the iteration budget did not run out, the measurement did.
case "$(status mb-bad)" in *INCOMPLETE*) fail "reported as INCOMPLETE rather than UNVERIFIED" ;; *) ;; esac

# ── 4. a run that DID measure is not held back ────────────────────────────────
case "$(status mb-good)" in MERGED*) ;; *) fail "the measured branch did not merge, got: '$(status mb-good)'" ;; esac
[ -f out/mb-good.txt ]                    || fail "the measured branch's work is not on main"
[ -f tasks/chief/completed/mb-good.json ] || fail "the measured tasklist was not retired"
if grep -q 'unverified' "$REPO/tasks/chief/completed/mb-good.json"; then fail "a measured story was marked unverified"; fi

# ── 5. THE NEGATIVE CASE, planted before run two: an all-pass branch, NO marker ─
# A run that genuinely finished leaves exactly this — every story passing on a branch
# with real commits behind it — and it must still merge WITHOUT an agent turn. Planted
# by hand because the tasklists that could produce it have already been retired, and
# because it has to ride in the SAME run as the re-engagement below: a fix that spends
# a turn on every resume is worse than the loop it closes, and only running both halves
# together proves it does not.
git checkout -q main
jq -n --argjson s "$stories" \
  '{project:"mb",branchName:"chief/mb-skip",description:"measurable bars",iters:2,
    dependsOn:[],touches:["mb-skip"],warmup:[],userStories:$s}' > tasks/chief/mb-skip.json
git add -A && git commit -q -m "mb-skip scheduled"
git worktree add -q "$WORK/skipwt" -b chief/mb-skip main || fail "could not plant the finished branch"
( cd "$WORK/skipwt"
  t="$(mktemp)"
  jq '.userStories |= map(.passes=true
        | .notes="Re-ran the suite: 0 failed, down from the 77 baseline; the hook exits 0.")' \
     tasks/chief/mb-skip.json > "$t" && mv "$t" tasks/chief/mb-skip.json
  mkdir -p out; printf 'impl mb-skip\n' > out/mb-skip.txt
  git add -A && git commit -q -m "feat: US-1 - mb-skip" ) || fail "could not commit the finished branch"
git worktree remove --force "$WORK/skipwt"

# ── 6. the stop is not one-shot: run two RE-ENGAGES instead of skipping past it ─
# The demotion landed in the RUNTIME record only — mb-bad's committed tasklist still
# says passes:true, so without the marker this run reads the branch as finished, spends
# no agent turn, and re-fails at the same gate forever (insimul 261, three runs). With
# it, the agent is engaged, is TOLD which stories and which bars, records the values,
# and the branch merges.
PATH="$WORK/fakebin:$PATH" "$CHIEF" run >"$WORK/run2.log" 2>&1 || { cat "$WORK/run2.log"; fail "second run exited non-zero"; }
LOG2="$REPO/.chief/state/parallel/mb-bad.log"
grep -q 'stopped UNVERIFIED last run' "$LOG2" \
  || fail "run two did not re-engage the agent on the persisted UNVERIFIED stop"
! grep -q 'skip agent' "$LOG2" \
  || fail "run two skipped the agent on a branch whose bars are still unmeasured — the loop is open"
[ "$(cat "$WORK/turns-mb-bad" 2>/dev/null || echo 0)" -ge 2 ] \
  || fail "run two spent no agent turn on the UNVERIFIED branch"

# …and the re-engaged turn was given what it needed: the story back at passes:false,
# and the bar quoted in measure.sh's own words. Told only "something is unverified" it
# would re-mark the same story unchanged, which is the loop this closes. Grep for
# strings only the ENGINE emits — instructions.md discusses bars on every turn.
P2="$WORK/prompt-mb-bad-2"
[ -s "$P2" ] || fail "the re-engaged turn's prompt was never captured"
[ "$(cat "$WORK/seen-mb-bad-2")" = 'false' ] \
  || fail "the re-engaged turn inherited US-1 as $(cat "$WORK/seen-mb-bad-2") — a demoted story read as finished work"
grep -q 'chief DEMOTED a story you marked' "$P2" \
  || fail "the re-engaged turn is never told a story was demoted"
grep -q '✗ US-1 — reach GREEN acceptance' "$P2" \
  || fail "the notice does not name the story still owed a value (id + title)"
grep -q 'claimed: "the suite reaches GREEN acceptance; the baseline to beat is 77 failed"' "$P2" \
  || fail "the notice does not quote the bar the criterion states"
# The same thing said in the progress log the agent re-reads at the top of every
# iteration — the copy that outlives turn one, exactly as a prior verify failure is.
grep -q 'PRIOR RUN STOPPED UNVERIFIED' "$WORK/progress-mb-bad-2" \
  || fail "the resumed run's progress log never carries the UNVERIFIED stop"

# ── 7. …and having recorded them, it merges — and the marker goes with the merge ─
case "$(status mb-bad)" in MERGED*) ;; *) fail "the re-engaged branch did not merge, got: '$(status mb-bad)'" ;; esac
git checkout -q main
[ -f out/mb-bad.txt ]                    || fail "the re-engaged branch's work is not on main"
[ -f tasks/chief/completed/mb-bad.json ] || fail "the re-engaged tasklist was not retired"
grep -q 'down from the 77 baseline' tasks/chief/completed/mb-bad.json \
  || fail "the value the re-engaged turn recorded is not in the completed record"
if [ -f "$MARK" ]; then fail "the marker outlived the merge — every future resume of a finished tasklist would re-engage the agent"; fi

# ── 8. the other half of the same run: NO marker, so NO agent turn ────────────
case "$(status mb-skip)" in MERGED*) ;; *) fail "the finished branch did not merge, got: '$(status mb-skip)'" ;; esac
[ -f out/mb-skip.txt ]                    || fail "the finished branch's work is not on main"
[ -f tasks/chief/completed/mb-skip.json ] || fail "the finished tasklist was not retired"
[ ! -f "$WORK/turns-mb-skip" ] \
  || fail "an all-pass branch with no marker spent $(cat "$WORK/turns-mb-skip") agent turn(s) — the fix costs a turn on every resume"
grep -q 'skip agent' "$REPO/.chief/state/parallel/mb-skip.log" \
  || fail "the finished branch did not take the agent-free all-pass path"

echo "MEASURE PASS — a claimed bar with no observed value is 'unverified', not passing (story + bar + criterion quoted); the stop is recorded for the resume, re-engages the agent on exactly those bars, and is cleared by the merge, while an all-pass branch with no marker still merges agent-free"
