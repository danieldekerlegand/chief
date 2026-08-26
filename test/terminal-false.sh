#!/usr/bin/env bash
# test/terminal-false.sh — prove a story whose CORRECT answer is `false` can SETTLE,
# that declaring it without measuring anything settles NOTHING, and that a tasklist
# which never declares it behaves exactly as it did before.
#
# The failure it guards against: cuneiform `283-nixos-bare-metal-vpn-topology-target`,
# 2026-08-22 → 2026-08-25. Its US-3 said in as many words "if it does not complete,
# THIS STORY STAYS `passes: false`". The flow genuinely does not complete, so
# `passes:false` was the CORRECT outcome — and chief, which has exactly one notion of
# done, re-drove the branch for three days: 63 commits, 59 iterations, 42 consecutive
# IDENTICAL measurements. The agent's terminal note read "this tasklist can NEVER
# report all-stories-true… It needs MANUAL RETIREMENT."
#
# THE MUTATION IS THE TEST. Three tasklists, one run, one fake agent. tf-neg and
# tf-plain are byte-identical apart from ONE field, and their fake-agent behaviour is
# identical too — same commits, same notes, same COMPLETE. Everything that differs
# downstream is caused by that field and by nothing else:
#   tf-neg    US-2 declares `terminalFalse` and records its measurement, and its
#             `passes` is left FALSE -> the tasklist COMPLETES, merges and retires, the
#             completed/ record still says false and carries the finding, and the agent
#             is never handed US-2 a second time.
#   tf-plain  the same story, the same notes, NO declaration -> the old path: chief
#             promotes it to passes:true and merges. Nothing changed for a story that
#             did not opt in.
#   tf-inert  US-2 declares `terminalFalse` and records NOTHING -> the declaration is
#             inert. The tasklist does NOT complete, does NOT merge, and the run says
#             so in its own words rather than "the iteration budget ran out". Without
#             this half the field is a way to mark hard stories complete.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=tf GIT_AUTHOR_EMAIL=tf@test GIT_COMMITTER_NAME=tf GIT_COMMITTER_EMAIL=tf@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos" CHIEF_WORKTREE_ROOT="$WORK/wt"  # hermetic
fail() { echo "TERMINAL FAIL: $*" >&2
         [ -f "$WORK/run.log" ] && tail -40 "$WORK/run.log" >&2
         exit 1; }
command -v jq >/dev/null || fail "jq required"

# ── 0. THE CORPUS INVARIANT, before anything is run ───────────────────────────
# Not one tasklist in this repo declares the field, so for every story in every one of
# them SETTLED must mean exactly what PASSING meant. This is the whole "nothing changes
# for a story without the declaration" claim, asserted over real data rather than over
# a fixture built to agree with it. It runs against the WORKING TREE's module (not the
# installed copy) on purpose: it is a property of the predicate, not of a run.
. "$ROOT/engine/terminal.sh"
corpus=0
for f in "$ROOT/tasks/chief"/*.json "$ROOT/tasks/chief/completed"/*.json; do
  [ -e "$f" ] || continue
  jq -e . "$f" >/dev/null 2>&1 || continue
  corpus=$((corpus + 1))
  before="$(jq '[.userStories[]?|select(.passes==true)]|length' "$f")"
  terminal_counts "$f"
  after=$(( TERMINAL_TOTAL - TERMINAL_OPEN ))
  [ "$before" = "$after" ] || fail "corpus $(basename "$f"): settled=$after but passing=$before"
  [ "$TERMINAL_NEGATIVE" = 0 ] || fail "corpus $(basename "$f"): declares terminalFalse but should not"
done
[ "$corpus" -ge 10 ] || fail "the corpus check saw only $corpus tasklists — it is not asserting on anything"
echo "  corpus: $corpus tasklists classify identically before and after"

# ── 0b. THE TWO REPORTS ARE NOT THE SAME SENTENCE ─────────────────────────────
# "we measured and the answer is no" and "we never measured" must not be spellable the
# same way, or the field is a way to bury work.
cat > "$WORK/fix.json" <<'JSON'
{"userStories":[
 {"id":"US-1","title":"delivered","passes":true,"notes":"green"},
 {"id":"US-2","title":"measured no","passes":false,"terminalFalse":true,"notes":"verdict maas-client-absent; 0 call sites"},
 {"id":"US-3","title":"declared, never tried","passes":false,"terminalFalse":true,"notes":""},
 {"id":"US-4","title":"ordinary open","passes":false,"notes":""}]}
JSON
terminal_counts "$WORK/fix.json"
[ "$TERMINAL_TOTAL:$TERMINAL_PASSED:$TERMINAL_NEGATIVE:$TERMINAL_OPEN" = "4:1:1:2" ] \
  || fail "counts wrong: total=$TERMINAL_TOTAL passed=$TERMINAL_PASSED neg=$TERMINAL_NEGATIVE open=$TERMINAL_OPEN"
[ "$(terminal_next "$WORK/fix.json")" = "US-3" ] || fail "the loop was handed a story that is already settled"
[ "$(terminal_negative_ids "$WORK/fix.json")" = "US-2" ] || fail "the settled negative is not US-2"
neg="$(terminal_negative_report "$WORK/fix.json")"; inert="$(terminal_inert_report "$WORK/fix.json")"
printf '%s' "$neg"   | grep -q 'US-2'          || fail "the negative report does not name US-2"
printf '%s' "$neg"   | grep -q 'maas-client-absent' || fail "the negative report drops the finding"
! printf '%s' "$neg"   | grep -q 'US-3'        || fail "the negative report claims the unmeasured story is done"
printf '%s' "$inert" | grep -q 'US-3'          || fail "the inert report does not name US-3"
! printf '%s' "$inert" | grep -q 'US-2'        || fail "the inert report claims the measured story is unmeasured"

# ── 0c. `chief ps` TELLS THEM APART ───────────────────────────────────────────
# 283 rendered as unfinished work for three days. A delivered negative may be neither
# folded into the passing count nor left out of it.
. "$ROOT/engine/monitor.sh" lib
mkdir -p "$WORK/snap/snapshots"
cp "$WORK/fix.json" "$WORK/snap/snapshots/tf-render.json"
jq '.userStories |= map(del(.terminalFalse))' "$WORK/fix.json" > "$WORK/snap/snapshots/tf-none.json"
[ "$(stories tf-render "$WORK/nowt" x "$WORK/snap" "$WORK/notasks")" = "1+1/4" ] \
  || fail "ps renders a settled negative as '$(stories tf-render "$WORK/nowt" x "$WORK/snap" "$WORK/notasks")', not '1+1/4'"
[ "$(stories tf-none "$WORK/nowt" x "$WORK/snap" "$WORK/notasks")" = "1/4" ] \
  || fail "ps changed the rendering of a tasklist that declares nothing"

# ── install chief from this checkout ──────────────────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# ── the fake agent: identical work on all three; only tf-inert withholds the value ──
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
W="@WORK@"
P="$(mktemp)"; cat > "$P"
PRD=".chief/state/prd.json"
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
turn=$(( $(cat "$W/turns-$name" 2>/dev/null || echo 0) + 1 )); echo "$turn" > "$W/turns-$name"
cp "$P" "$W/prompt-$name-$turn"
# WHICH STORY was this turn handed? Recorded from the prompt chief built, so the
# re-drive 283 suffered is observable as a fact about the prompt, not an inference.
grep -o 'Your work this turn is US-[0-9]*' "$P" | tail -1 > "$W/handed-$name-$turn" || true
mkdir -p out; printf 'impl %s turn %s\n' "$name" "$turn" > "out/$name.txt"
if [ "$name" = "tf-inert" ]; then
  finding=""                                    # declared, never measured
else
  finding="Ran the commission->deploy flow: verdict maas-client-absent, 0 call sites across core/ services/ apps/. Do this instead: land a MaaS client in services/ first."
fi
t="$(mktemp)"
# US-1 is delivered. US-2 is the verification: it records what it found and its
# `passes` is left FALSE, because the answer really is false.
jq --arg f "$finding" '.userStories |= map(
     if .id == "US-1" then .passes = true | .notes = "built the seam; 3 checks green"
     else .notes = $f end)' "$PRD" > "$t" && mv "$t" "$PRD"
cp "$PRD" "tasks/chief/$name.json"
git add -A >/dev/null 2>&1 || true
git commit -q -m "feat: US-1 - $name" >/dev/null 2>&1 || true
echo "<promise>COMPLETE</promise>"
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
# NO BAR in US-2's criteria, deliberately: this must be settled by the DECLARATION plus
# a recorded observation, never by measure.sh's bar rule happening to fire on the prose.
mkstories() { # $1 = 1 to declare terminalFalse on US-2
  jq -n --argjson decl "$1" '[
    {"id":"US-1","title":"build the seam","description":"",
     "acceptanceCriteria":["the output file for this tasklist exists"],"passes":false,"notes":""},
    ({"id":"US-2","title":"VERIFY the commission->deploy flow, honestly","description":"",
      "acceptanceCriteria":["report whether the flow completes end to end; a stub does not count"],
      "passes":false,"notes":""}
     + (if $decl == 1 then {"terminalFalse":true} else {} end))]'
}
for n in tf-neg tf-inert; do
  jq -n --arg n "$n" --argjson s "$(mkstories 1)" \
    '{project:"tf",branchName:("chief/"+$n),description:"terminal false",iters:2,
      dependsOn:[],touches:[$n],warmup:[],userStories:$s}' > "tasks/chief/$n.json"
done
jq -n --argjson s "$(mkstories 0)" \
  '{project:"tf",branchName:"chief/tf-plain",description:"terminal false",iters:2,
    dependsOn:[],touches:["tf-plain"],warmup:[],userStories:$s}' > tasks/chief/tf-plain.json
printf '#!/usr/bin/env bash\nset -eu\necho "verify: (would pass)"\nexit 0\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "tf setup"

# The declaration is a boolean, and `chief lint` says so.
"$CHIEF" lint >/dev/null 2>&1 || fail "the scaffolded tasklists do not lint clean"
t="$(mktemp)"; jq '.userStories |= map(if .id=="US-2" then .terminalFalse="true" else . end)' \
  tasks/chief/tf-neg.json > "$t" && cp "$t" "$WORK/stringy.json"
cp tasks/chief/tf-neg.json "$WORK/tf-neg.keep"; cp "$WORK/stringy.json" tasks/chief/tf-neg.json
if "$CHIEF" lint >/dev/null 2>&1; then fail "lint accepted a terminalFalse that is a string, not a boolean"; fi
cp "$WORK/tf-neg.keep" tasks/chief/tf-neg.json
git checkout -q -- . 2>/dev/null || true

PATH="$WORK/fakebin:$PATH" "$CHIEF" run >"$WORK/run.log" 2>&1 || { cat "$WORK/run.log"; fail "run exited non-zero"; }
status() { cat "$REPO/.chief/state/parallel/$1.status" 2>/dev/null || echo MISSING; }
git checkout -q main

# ── 1. THE DECLARED NEGATIVE COMPLETES ────────────────────────────────────────
case "$(status tf-neg)" in MERGED*) ;; *) fail "the declared-negative tasklist did not complete, got: '$(status tf-neg)'" ;; esac
[ -f out/tf-neg.txt ]                    || fail "its delivered work is not on main"
[ -f tasks/chief/completed/tf-neg.json ] || fail "it was not retired"
[ ! -f tasks/chief/tf-neg.json ]         || fail "the tasklist is still pending after merging"

# ── 2. THE ANSWER AND THE FINDING BOTH SURVIVE, IN THE COMPLETED RECORD ───────
# A merged record force-passes every story. This one may not: rewriting the negative to
# true would leave completed/ asserting the OPPOSITE of what the tasklist found, and a
# successor tasklist could not cite it.
REC=tasks/chief/completed/tf-neg.json
[ "$(jq -r '.userStories[]|select(.id=="US-1")|.passes' "$REC")" = "true" ]  || fail "the delivered story is not recorded as passing"
[ "$(jq -r '.userStories[]|select(.id=="US-2")|.passes' "$REC")" = "false" ] || fail "the negative answer was rewritten to true in completed/"
[ "$(jq -r '.userStories[]|select(.id=="US-2")|.terminalFalse' "$REC")" = "true" ] || fail "the declaration did not survive into completed/"
jq -r '.userStories[]|select(.id=="US-2")|.notes' "$REC" | grep -q 'maas-client-absent' \
  || fail "the finding is not in the completed record — it survives only in a run log"
jq -r '.userStories[]|select(.id=="US-2")|.notes' "$REC" | grep -q 'Do this instead' \
  || fail "the closing action a successor tasklist would cite was dropped"
grep -q 'terminated with a NEGATIVE answer' "$REPO/.chief/state/parallel/tf-neg.log" \
  || fail "the run never says the tasklist finished on a negative"

# ── 3. AND IT IS NEVER RE-DRIVEN. This is the incident. ───────────────────────
[ "$(cat "$WORK/turns-tf-neg" 2>/dev/null || echo 0)" = "1" ] \
  || fail "the settled negative bought extra agent turns ($(cat "$WORK/turns-tf-neg" 2>/dev/null)) — 283 in miniature"
if grep -rq 'Your work this turn is US-2' "$WORK/prompt-tf-neg-"* 2>/dev/null; then
  fail "the agent was handed a story that is already settled"
fi

# ── 4. NOTHING CHANGED FOR THE STORY THAT DID NOT OPT IN ─────────────────────
# Same story, same notes, same commits — only the field is missing. The old path runs:
# chief promotes it and the record says true.
case "$(status tf-plain)" in MERGED*) ;; *) fail "the undeclared tasklist stopped behaving as it did before, got: '$(status tf-plain)'" ;; esac
[ "$(jq -r '.userStories[]|select(.id=="US-2")|.passes' tasks/chief/completed/tf-plain.json)" = "true" ] \
  || fail "an undeclared story was left false — the change leaked outside the opt-in"

# ── 5. A DECLARATION WITH NOTHING MEASURED SETTLES NOTHING ───────────────────
case "$(status tf-inert)" in MERGED*) fail "a story that declared the negative and measured NOTHING was merged as done" ;; *) : ;; esac
[ ! -f tasks/chief/completed/tf-inert.json ] || fail "an unmeasured declaration was retired"
[ -f tasks/chief/tf-inert.json ]             || fail "the unmeasured tasklist was retired out of the backlog"
LOG="$REPO/.chief/state/parallel/tf-inert.log"
grep -q 'recorded NO measurement' "$LOG" \
  || fail "the stop never says the declaration was inert — it reads as an ordinary budget overrun"
grep -q 'US-2' "$LOG" || fail "the stop does not name the story whose declaration is inert"

echo "TERMINAL PASS — a declared negative settles, survives into completed/, and is never re-driven;"
echo "               an undeclared story is untouched; an unmeasured declaration settles nothing."
