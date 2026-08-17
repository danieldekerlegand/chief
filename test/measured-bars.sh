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
# Then mb-bad is run a SECOND time, to prove the stop is not one-shot: its committed
# tasklist still says passes:true, so run two skips the agent entirely.
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
cat >/dev/null                                   # drain the prompt
PRD=".chief/state/prd.json"                      # cwd = the worktree
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
mkdir -p out; printf 'impl %s\n' "$name" > "out/$name.txt"
if [ "$name" = "mb-bad" ]; then
  note="Reworked the exporter seam and re-ran the suite."          # no value recorded
else
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

# ── 5. the stop is not one-shot: a second run must not walk through it ────────
# The demotion lands in the RUNTIME record only — the branch's committed tasklist
# still says passes:true, so run two takes the agent-free "all stories already pass,
# skip agent" path. The bar gate has to hold there too or the stop costs one re-run.
PATH="$WORK/fakebin:$PATH" "$CHIEF" run >"$WORK/run2.log" 2>&1 || { cat "$WORK/run2.log"; fail "second run exited non-zero"; }
grep -q 'skip agent' "$REPO/.chief/state/parallel/mb-bad.log" || fail "run two did not take the agent-free all-pass path — the bypass is untested"
case "$(status mb-bad)" in UNVERIFIED*) ;; *) fail "the second run walked through the bar gate, got: '$(status mb-bad)'" ;; esac
git checkout -q main
[ ! -f out/mb-bad.txt ]                    || fail "the unmeasured branch merged on the second run"
[ ! -f tasks/chief/completed/mb-bad.json ] || fail "the unmeasured tasklist was retired on the second run"

echo "MEASURE PASS — a claimed bar with no observed value is 'unverified', not passing (story + bar + criterion quoted); a run that recorded its numbers still merges"
