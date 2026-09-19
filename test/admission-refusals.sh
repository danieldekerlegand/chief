#!/usr/bin/env bash
# test/admission-refusals.sh — EVERY REFUSAL MID-RUN ADMISSION MAKES, INCLUDING THE
# ONES THAT PROTECT THE RUN (engine/admit.sh · engine/driver.sh ·
# docs/reference/mid-run-admission.md).
#
# tasks/chief/127-a-live-run-accepts-new-work US-3. `test/mid-run-admission.sh` proves
# the YES: a tasklist offered mid-turn joins, runs, merges and is accounted for. This
# file proves the NOs, which are the half that keeps `chief offer` from being the
# silent auto-scan the feature refuses to be — a set that widens with ANYTHING is not a
# feature, it is the operator's set being taken away from them by a different route.
#
#   PART A  EVERY REFUSAL, ONE CASE EACH, at the keyboard against a live open window:
#           unknown name · parked · already in this run · already recorded done ·
#           failed lint · a dependency that can never be satisfied in the widened run
#           (both shapes: the one with an obvious fix and the one with none) · and a
#           request arriving once the run has stopped scheduling — the window shut
#           while its pid is STILL ALIVE, which is the discrimination the timing rule
#           is actually making. Two accept cases run beside them as controls, and the
#           queue is read afterwards: a refused name must not be recorded, or the run
#           would answer at its next boundary a question the operator was already told
#           no to.
#   PART B  THE SABOTAGE, at the keyboard. The same fixture and the same nine offers
#           against a COPY of this engine with `admit_check` neutered to `return 0`.
#           Every refusal flips to accepted and lands in the queue; both accept cases
#           are unchanged. That is what makes PART A a measurement of the rules rather
#           than of a fixture that happened to be quiet.
#   PART C  THE DEPENDENCY RULE IN BOTH DIRECTIONS, through the real driver. A newcomer
#           whose dependency is another tasklist in the SAME run is admitted and WAITS
#           for it; one whose dependency can never complete is admitted and then
#           BLOCKED with the reason — and the test pins WHICH of the two chief does
#           rather than accepting either. A parked tasklist offered in the same breath
#           is refused and never joins.
#   PART D  THE SABOTAGE, through the driver. The same fixture against the neutered
#           engine: the parked tasklist PART C refused is admitted, runs and merges.
#           PART C is its control — without this part, "it was refused" and "the offer
#           was never made" are the same log.
#
# Hermetic: a scripted fake `claude` on PATH, temp prefixes ($CHIEF_PREFIX included),
# never touches the real ~/.chief. Drives bin/chief straight out of this checkout, so
# it tests uncommitted work.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; . "$ROOT/test/lib.sh"
WORK="$(mktemp -d)"
HOLDER_PID=""
# `[ -z … ] ||` and not `[ -n … ] &&`, and that is not a style choice: this file runs
# under `set -euo pipefail`, an AND-list whose left side fails returns non-zero, and a
# non-zero command inside a trap handler ENDS THE SHELL THERE — before `rm -rf`. With
# $HOLDER_PID still empty (every exit before the holder starts, which is every signal
# during setup) the cleanup aborted and the tree stayed. Measured 2026-09-19: this file
# was the one $TMPDIR tree that survived an interrupted `test/all.sh`.
trap 'rc=$?; [ -z "$HOLDER_PID" ] || kill "$HOLDER_PID" 2>/dev/null || true; rm -rf "$WORK"; exit "$rc"' EXIT
export GIT_AUTHOR_NAME=ar GIT_AUTHOR_EMAIL=ar@test GIT_COMMITTER_NAME=ar GIT_COMMITTER_EMAIL=ar@test
export CHIEF_PREFIX="$WORK/ch" CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
# Either would hold a branch below, and "it merged" would then be asserting something
# else entirely.
unset CHIEF_ZONES CHIEF_DIFF_BUDGET CHIEF_DIFF_BUDGET_LINES CHIEF_DIFF_BUDGET_FILES 2>/dev/null || true
CHIEF="$ROOT/bin/chief"
LOG=""
fail() { echo "ADMISSION-REFUSALS FAIL: $*" >&2; [ -n "$LOG" ] && [ -f "$LOG" ] && tail -80 "$LOG" >&2; exit 1; }
command -v jq  >/dev/null || fail "jq is required"
command -v git >/dev/null || fail "git is required"

# ── the neutered engine, built once and used by PART B and PART D ─────────────
# A COPY of this checkout (never `git show HEAD~N`: CI clones shallow) with the whole
# of the admission rule removed — `admit_check` accepting everything, which is the
# engine `chief offer` would be if the rules were decoration.
NEUTERED="$WORK/unfixed"
mkdir -p "$NEUTERED"
cp -R "$ROOT/bin" "$ROOT/engine" "$ROOT/templates" "$NEUTERED/" || fail "could not copy the tool root"
[ -d "$ROOT/scripts" ] && cp -R "$ROOT/scripts" "$NEUTERED/"
cp "$ROOT/VERSION" "$NEUTERED/VERSION"
OLD="$NEUTERED/engine/admit.sh"
LC_ALL=C grep -q '^admit_check() {' "$OLD" \
  || fail "admit_check() is not where this file expects it — the 'unfixed' arm would silently be a copy of the RULED engine. Update the rewrite below, do not delete the reproduction."
LC_ALL=C awk '
  /^admit_check\(\) \{/ {
    print; print "  ADMIT_REASON=\"\"; return 0   # CHIEF-TEST-UNFIXED — no admission rules at all"
    inf = 1; next
  }
  inf && /^\}/ { print; inf = 0; next }
  inf { next }
  { print }' "$OLD" > "$OLD.new"
mv "$OLD.new" "$OLD"
LC_ALL=C grep -q 'CHIEF-TEST-UNFIXED' "$OLD" || fail "the neuter did not apply"
bash -n "$OLD" || fail "the neutered admit.sh does not parse"
NEUTERED_CHIEF="$NEUTERED/bin/chief"

# ── the fixture ───────────────────────────────────────────────────────────────
repo_of()  { printf '%s/repo.%s' "$WORK" "$1"; }
state_of() { cat "$(repo_of "$1")/.chief/state/parallel/$2.state" 2>/dev/null || echo MISSING; }
on_main()  { ( cd "$(repo_of "$1")" && git show "main:$2" >/dev/null 2>&1 ); }

# tasklist NAME DEPSJSON PARKED STORIES — one schema-valid tasklist in the cwd repo.
tasklist() {
  jq -n --arg n "$1" --argjson dep "$2" --argjson pk "$3" --argjson k "$4" '
    { project:"ar", branchName:("chief/" + $n), description:("admission fixture " + $n),
      iters:4, dependsOn:$dep, touches:["domain-" + $n], warmup:[], parked:$pk,
      parkedReason:(if $pk then "held until the schema lands" else "" end),
      userStories:[ range(1; $k + 1) | { id:("US-" + (tostring)), title:("story of " + $n),
                      description:"", acceptanceCriteria:[("the " + $n + " artifact is written")],
                      passes:false, notes:"" } ] }' > "tasks/chief/$1.json"
}

fixture() {   # $1 = arm name
  local repo; repo="$(repo_of "$1")"
  mkdir -p "$repo"
  ( cd "$repo"
    git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
    git commit -q --allow-empty -m init
    "$CHIEF" init >/dev/null
    rm -f tasks/chief/example.json
    printf '#!/usr/bin/env bash\nset -eu\necho "verify: ok"\nexit 0\n' > .chief/verify.sh
    chmod +x .chief/verify.sh
    # alpha gets TWO stories so its first turn is not also its last.
    tasklist alpha    '[]'        false 2
    tasklist beta     '[]'        false 1
    tasklist gamma    '["beta"]'  false 1   # dep is IN the run: admitted, and waits
    tasklist bad      '["ghost"]' false 1   # can never start: its dep does not exist
    tasklist delta    '["bad"]'   false 1   # dep is in the run and can never complete
    tasklist held     '[]'        true  1   # parked
    tasklist needy    '["loner"]' false 1   # dep is live, unmerged, NOT in the run
    tasklist loner    '[]'        false 1
    tasklist newcomer '[]'        false 1   # the plain accept case
    tasklist broken   '[]'        false 1
    jq '.branchName="chief/WRONG"' tasks/chief/broken.json > b.tmp && mv b.tmp tasks/chief/broken.json
    mkdir -p tasks/chief/completed
    echo '{"mergedToMain":"a1b2c3d","branchName":"chief/gone"}' > tasks/chief/completed/gone.json
    git add -A && git commit -q -m setup ) >/dev/null
}

# ══ PART A — every refusal, one case each, against a live open window ════════
echo "admission-refusals: PART A — the seven refusals at the keyboard, with two accept cases beside them"
fixture kb
K="$(repo_of kb)"

# THE RUN, stood up by the ENGINE'S OWN admit_open rather than by a hand-written
# marker: a fixture that writes the file itself can only ever pass against a format it
# alone knows how to produce (test/reap-escaped.sh's rule, same reason). The pid it
# publishes is this holder's, and it stays alive — so when the window shuts below, what
# changed is the WINDOW and not the process.
cat > "$WORK/holder.sh" <<'HOLD'
set -eu
ENGINE="$1"; REPO="$2"; shift 2
# shellcheck disable=SC1091
. "$ENGINE/reap.sh"
# shellcheck disable=SC1091
. "$ENGINE/admit.sh"
STATE_ROOT="$REPO/.chief/state"
REPO="$REPO"; CHIEF_RUN_ID="holder-$$"; CHIEF_EVENTS_FILE="$STATE_ROOT/holder.events.jsonl"
mkdir -p "$STATE_ROOT"
admit_open "$*"                      # the scheduler entered its loop, carrying this set
trap 'admit_close; : > "$STATE_ROOT/holder.closed"' USR1   # …and, on request, left it
: > "$STATE_ROOT/holder.ready"
while :; do sleep 1; done
HOLD

open_window() {   # $1 = engine dir; rest = the set the "run" is carrying
  local eng="$1"; shift
  rm -f "$K/.chief/state/holder.ready" "$K/.chief/state/holder.closed"
  bash "$WORK/holder.sh" "$eng" "$K" "$@" & HOLDER_PID=$!
  local i=0
  while [ ! -f "$K/.chief/state/holder.ready" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$(( i + 1 )); done
  [ -f "$K/.chief/state/admit/open" ] || fail "the admission window never opened"
}
shut_window() {
  kill -USR1 "$HOLDER_PID" 2>/dev/null || fail "the holder is gone — it was supposed to outlive its own window"
  local i=0
  while [ ! -f "$K/.chief/state/holder.closed" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$(( i + 1 )); done
  kill -0 "$HOLDER_PID" 2>/dev/null || fail "the holder died instead of closing its window — the refusal below would be about a dead pid, not a shut window"
}
close_window() { kill "$HOLDER_PID" 2>/dev/null || true; wait "$HOLDER_PID" 2>/dev/null || true; HOLDER_PID=""; }

# offer_says CLI NAME EXPECT ARGS… — run `chief offer`, expect the verdict glyph and a
# reason matching EXPECT. Every refusal is asserted by its REASON, never by the exit
# code alone: "refused" and "refused for the right reason" are different claims, and
# only the second one is worth anything to an operator reading it.
offer_out=""
offer_says() {
  local cli="$1" name="$2" want="$3"; shift 3
  offer_out="$( cd "$K" && "$cli" offer "$@" "$name" 2>&1 || true )"
  case "$offer_out" in
    *"$want"*) ;;
    *) printf '%s\n' "$offer_out" >&2; fail "offering '$name' did not say: $want" ;;
  esac
}
queued()     { [ -f "$K/.chief/state/admit/$1.req" ]; }

open_window "$ROOT/engine" alpha beta
grep -q '^names=alpha beta$' "$K/.chief/state/admit/open" || { cat "$K/.chief/state/admit/open" >&2; fail "A: the open marker does not carry the run's set"; }

offer_says "$CHIEF" nosuch   '✗ nosuch — no such tasklist'
offer_says "$CHIEF" held     '✗ held — parked: held until the schema lands'
offer_says "$CHIEF" alpha    '✗ alpha — already in this run'
offer_says "$CHIEF" gone     '✗ gone — already recorded done'
offer_says "$CHIEF" broken   '✗ broken — failed lint'
# BOTH SHAPES of the dependency refusal. `needy` names a live tasklist that is simply
# not in the run, which has an obvious fix, so the refusal gives the FIX rather than
# the classification; `bad` names one that does not exist at all and can never be
# satisfied in any widening of this run.
offer_says "$CHIEF" needy    'offer them together: chief offer loner needy'
offer_says "$CHIEF" bad      'dependency "ghost" cannot be satisfied in this run'
# …and the controls, or "everything is refused" would pass this part.
offer_says "$CHIEF" newcomer '✓ newcomer — offered'
offer_says "$CHIEF" held     '✓ held — offered' --parked
echo "   ok  seven refusals, each with its own reason; the plain name and the waived park accepted"

# THE QUEUE IS THE PROOF the refusals were refusals. A name told no at the keyboard
# that is recorded anyway is answered again at the run's next boundary — the operator
# heard one verdict and the run reaches another.
for n in nosuch alpha gone broken needy bad; do
  queued "$n" && fail "A: '$n' was refused and recorded anyway — the run would answer it again at its next boundary"
done
for n in newcomer held; do
  queued "$n" || fail "A: '$n' was accepted but no request was recorded — nothing would reach the run"
done
grep -q '^pid=' "$K/.chief/state/admit/newcomer.req" || fail "A: the request does not address a run by pid"
echo "   ok  the queue holds the two accepted names and neither of the six refused ones"

# THE WINDOW SHUTS while the pid stays alive: from here the run is computing its
# outcome, and a request that half-joined a finished run is the one thing the timing
# rule forbids. This is the case a test that simply killed the driver cannot make —
# there, "the run is gone" and "the run has stopped scheduling" are the same fact.
shut_window
offer_says "$CHIEF" loner 'no run in this repo is scheduling'
queued loner && fail "A: a request arriving after the window shut was recorded into a run that will never read it"
kill -0 "$HOLDER_PID" 2>/dev/null || fail "A: the holder was supposed to still be alive"
close_window
# …and the same name, into the same repo, with a window open again: accepted. So what
# refused it above was the WINDOW and nothing about `loner` — a one-sided refusal here
# would pass just as well against a name that was never admissible in the first place.
open_window "$ROOT/engine" alpha beta
offer_says "$CHIEF" loner '✓ loner — offered'
queued loner || fail "A: 'loner' was accepted with the window open but nothing was recorded"
close_window
echo "   ok  after the window shut — its pid still alive — the offer is refused with that reason and nothing is queued; with it open again the same name is accepted"

# AND REFUSING IS CHEAP. The commonest answer this command gives is "there is no run",
# and it must not leave litter behind to give it.
fixture bare
B="$(repo_of bare)"
rm -rf "$B/.chief/state"
( cd "$B" && "$CHIEF" offer newcomer >/dev/null 2>&1 ) && fail "A: offering into a repo with no run at all exited 0"
[ -e "$B/.chief/state/admit" ] && fail "A: refusing with no run wrote a queue directory"
echo "   ok  with no run at all: refused, and not so much as a directory created"

# ══ PART B — the sabotage: neuter the rules and every refusal flips ══════════
# What PART A is worth is exactly what this part proves. The same window, the same
# nine offers, the same fixture — against the engine with `admit_check` gone.
echo "admission-refusals: PART B — with admit_check neutered, every refusal is accepted and queued (the rules, reproduced as load-bearing)"
rm -rf "$K/.chief/state/admit"
open_window "$NEUTERED/engine" alpha beta
for n in nosuch held alpha gone broken needy bad newcomer; do
  offer_says "$NEUTERED_CHIEF" "$n" "✓ $n — offered"
  queued "$n" || fail "B: the neutered engine accepted '$n' without recording it — PART B is not exercising the path PART A measures"
done
offer_says "$NEUTERED_CHIEF" held '✓ held — offered' --parked
echo "   ok  all seven refused names now join, and both accept cases are unchanged"
close_window

# ══ PART C — the dependency rule, both directions, through the real driver ═══
# PART A asks the rule; this asks the RUN. A newcomer that is admitted still has to be
# scheduled, and "admitted" and "it waited for its dependency and then merged" are
# different claims.
echo "admission-refusals: PART C — a newcomer waits for its in-run dependency; one whose dependency can never complete is admitted and BLOCKED; a parked one never joins"

mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
: "${AR_WORK:?}" "${AR_CHIEF:?}" "${AR_REPO:?}"
cat >/dev/null                                  # drain the prompt on stdin
PRD=".chief/state/prd.json"                     # cwd = the worktree (set by the driver)
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
TRACKED="tasks/chief/$name.json"

# THE OFFERS ARE MADE FROM INSIDE A LIVE AGENT TURN, which is where an operator makes
# them, and from the PROJECT — `chief offer` resolves its project from the cwd upward
# and a worktree resolves to a state root the driver never reads.
if [ "$name" = alpha ] && [ ! -f "$AR_WORK/offered" ]; then
  : > "$AR_WORK/offered"
  for n in $AR_OFFERS; do
    ( cd "$AR_REPO" && "$AR_CHIEF" offer "$n" ) >> "$AR_WORK/offer.log" 2>&1 \
      || echo "offer of $n exited $?" >> "$AR_WORK/offer.log"
  done
fi

id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  mkdir -p out; printf 'impl %s of %s\n' "$id" "$name" > "out/$name.$id.txt"
  for f in "$PRD" "$TRACKED"; do
    [ -f "$f" ] || continue
    t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id)|.passes)=true
      | (.userStories[]|select(.id==$id)|.notes)="artifact written; verify green"' "$f" > "$t" && mv "$t" "$f"
  done
  git add -A >/dev/null 2>&1 || true
  git commit -q -m "feat: [$id] - story $id of $name" >/dev/null 2>&1 || true
fi
[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

run_arm() {   # $1 = arm, $2 = cli, $3 = log
  local arm="$1" cli="$2" log="$3"
  rm -f "$WORK/offered" "$WORK/offer.log"
  ( cd "$(repo_of "$arm")" \
      && AR_REPO="$(repo_of "$arm")" AR_WORK="$WORK" AR_CHIEF="$cli" AR_OFFERS="gamma delta held" \
         PATH="$WORK/fakebin:$PATH" POLL_SECONDS=1 "$cli" run alpha beta bad ) >"$log" 2>&1 || true
}

fixture dep
D="$(repo_of dep)"
LOG="$WORK/c.log"
run_arm dep "$CHIEF" "$LOG"
[ -s "$WORK/offer.log" ] || fail "C: the fake agent never ran chief offer — the fixture did not exercise the feature"

# --- direction 1: the dependency is in this run -> admitted, and it WAITS ------
grep -q '＋ ADMITTED gamma' "$LOG" || fail "C: gamma — whose dependency beta is in this run — was not admitted"
[ "$(state_of dep gamma)" = "done" ] || fail "C: gamma state is '$(state_of dep gamma)', want done"
on_main dep "out/gamma.US-1.txt" || fail "C: gamma's work is not on main"
order="$( cd "$D" && git log --first-parent --reverse --format=%s main | sed -n 's/^Merge chief\/\([a-z]*\).*/\1/p' | tr '\n' ' ' )"
case "$order" in
  *"beta gamma"*) ;;
  *) fail "C: merge order was '$order' — gamma must wait for the dependency that admitted it" ;;
esac
echo "   ok  a newcomer depending on a tasklist in the run is admitted and merges AFTER it (order: $order)"

# --- direction 2: the dependency can never complete ---------------------------
# WHICH of the two chief does, pinned rather than either-accepted: it ADMITS (the rule
# admission applies is "merged, or in the widened set", and `bad` IS in the set) and
# then BLOCKS with the reason, exactly as a launch name whose dependency broke. It does
# NOT refuse — refusing would be admission answering a question it is not asking.
grep -q '＋ ADMITTED delta' "$LOG" || fail "C: delta was not admitted — chief refused a newcomer whose dependency IS in the run"
grep -q 'REFUSED delta' "$LOG" && fail "C: delta was refused; this test asserts chief ADMITS-then-BLOCKS it, and the two are not interchangeable"
grep -q '⤬ delta BLOCKED' "$LOG" || { grep -n 'delta' "$LOG" >&2; fail "C: delta was admitted and never blocked — a newcomer that can never start must say so, not sit pending"; }
[ "$(state_of dep delta)" = "blocked" ] || fail "C: delta state is '$(state_of dep delta)', want blocked"
grep -q 'bad' "$D/.chief/state/parallel/delta.why" || { cat "$D/.chief/state/parallel/delta.why" >&2; fail "C: delta's reason does not name the dependency that blocked it"; }
if on_main dep "out/delta.US-1.txt"; then fail "C: a blocked newcomer's work reached main"; fi
echo "   ok  a newcomer whose in-run dependency can never complete is ADMITTED, then BLOCKED, naming it: $(head -1 "$D/.chief/state/parallel/delta.why")"

# --- and the parked one never joins -------------------------------------------
grep -q '✗ held — parked' "$WORK/offer.log" || { cat "$WORK/offer.log" >&2; fail "C: the parked tasklist was not refused at the keyboard"; }
grep -q 'ADMITTED held' "$LOG" && fail "C: a parked tasklist joined a live run"
[ "$(state_of dep held)" = "MISSING" ] || fail "C: held has a scheduler state of '$(state_of dep held)' in a run it never joined"
[ -f "$D/tasks/chief/held.json" ] || fail "C: held left tasks/chief/ without ever being admitted"
if on_main dep "out/held.US-1.txt"; then fail "C: a parked tasklist's work reached main"; fi
echo "   ok  the parked tasklist was refused at the keyboard and is untouched in tasks/chief/"

# ══ PART D — the sabotage, through the driver ═══════════════════════════════
# PART C's parked refusal is worth what this proves: with the rules gone, the SAME
# offer of the SAME parked tasklist joins the run and merges. Without it, "it was
# refused" and "the offer never happened" are the same log.
echo "admission-refusals: PART D — with admit_check neutered, the parked tasklist PART C refused joins the run and merges (the defect, reproduced)"
fixture sab
S="$(repo_of sab)"
LOG="$WORK/d.log"
run_arm sab "$NEUTERED_CHIEF" "$LOG"
grep -q '＋ ADMITTED held' "$LOG" || { grep -n 'held' "$LOG" >&2; fail "D: the neutered engine did not admit the parked tasklist — PART C is not testing the discrimination it claims to test"; }
[ "$(state_of sab held)" = "done" ] || fail "D: the neutered run admitted held but left it at '$(state_of sab held)'"
on_main sab "out/held.US-1.txt" || fail "D: the neutered run admitted the parked tasklist without merging it"
echo "   ok  neutered: the parked tasklist is admitted, runs and merges — that is the run widening with work nobody was allowed to hand it"

echo "ADMISSION-REFUSALS PASS — every refusal stated with its own reason and nothing queued behind it; the window shut refuses while its pid lives; a newcomer waits for its in-run dependency and is admitted-then-blocked when that dependency can never complete; and with the rules neutered every one of those refusals joins instead"
