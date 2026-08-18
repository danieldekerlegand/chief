#!/usr/bin/env bash
# test/overlap-zones.sh — the MERGE POLICY LAYER end to end (engine/zones.sh +
# engine/budget.sh · docs/reference/overlap-zones.md · docs/reference/diff-budget.md).
#
# tasks/chief/91-enforceable-overlap-zones. The layer's whole claim is that it sits
# ABOVE the merge floor and never inside it: a branch is rebased and verified GREEN
# first, and only then can a declared zone — or an oversized story — withhold the
# merge until a human says yes. Four things have to be true for that claim to hold,
# and each is a part below:
#
#   PART A — NO REGRESSION: a branch touching a `serialize`-policy zone merges exactly
#            as it did before this layer existed. Nothing is written, nothing is held.
#   PART B — A `review` ZONE HOLDS A GREEN BRANCH: it rebases, verifies green, and
#            then parks in `awaiting-approval` with the branch kept and nothing merged.
#            The scheduler is never blocked (PART A's sibling merges in the same run).
#            `chief approve` lists it and grants it; granting twice is a no-op.
#   PART C — THE VERDICT SURVIVES A RESTART: a SEPARATE `chief run` process — the
#            worktree by then deleted — reads the verdict off disk, does not re-ask,
#            and merges. That is the only proof that the approval is not run state.
#   PART D — THE DIFF-SIZE BUDGET, both enforcements: an oversized story under the
#            default `warn` is REPORTED and merges anyway; the same story under
#            `block` is WITHHELD through the very same one approval.
#
# Hermetic: a scripted fake `claude` on PATH, temp prefixes ($CHIEF_PREFIX included),
# never touches the real ~/.chief. Drives bin/chief straight out of this checkout, so
# it tests uncommitted work.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rc=$?; rm -rf "$WORK"; exit "$rc"' EXIT
export GIT_AUTHOR_NAME=oz GIT_AUTHOR_EMAIL=oz@test GIT_COMMITTER_NAME=oz GIT_COMMITTER_EMAIL=oz@test
export CHIEF_PREFIX="$WORK/ch" CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
# The budget reads its enforcement from the ENVIRONMENT (a repo sets it in
# .chief/config). An inherited value would silently turn PART D's two halves into
# one, so every run below states the mode it means to test.
unset CHIEF_DIFF_BUDGET CHIEF_DIFF_BUDGET_LINES CHIEF_DIFF_BUDGET_FILES CHIEF_ZONES 2>/dev/null || true
CHIEF="$ROOT/bin/chief"
LOG=""
fail() { echo "OVERLAP-ZONES FAIL: $*" >&2; [ -n "$LOG" ] && [ -f "$LOG" ] && tail -60 "$LOG" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

REPO="$WORK/repo"
S="$REPO/.chief/state/parallel"
state()  { cat "$S/$1.state" 2>/dev/null || echo MISSING; }
status() { cat "$S/$1.status" 2>/dev/null || echo MISSING; }
calls()  { cat "$WORK/calls.$1" 2>/dev/null || echo 0; }
req()    { printf '%s/%s.zone-request.json'  "$S" "$1"; }
appr()   { printf '%s/%s.zone-approval.json' "$S" "$1"; }
on_main() { ( cd "$REPO" && git show "main:$1" >/dev/null 2>&1 ); }
# NOTE: `[ … ] && fail` would exit the whole script under `set -e` on the PASSING
# branch, so every negative assertion below is written as an `if … then fail; fi`.

mkdir -p "$WORK/fakebin"
export OZ_WORK="$WORK"

# ── the fake agent ────────────────────────────────────────────────────────────
# One story per turn, like every other fake in this suite, with one addition this
# test depends on: the commit SUBJECT carries the real `feat: [US-x] - Title` shape,
# because that is what engine/budget.sh decomposes the branch diff by. The artifact's
# LINE COUNT is scripted per tasklist ($WORK/size.<name>), which is how an oversized
# story is produced without a two-thousand-line fixture.
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
: "${OZ_WORK:?}"
cat >/dev/null
PRD=".chief/state/prd.json"
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"; TRACKED="tasks/chief/$name.json"
n=$(( $(cat "$OZ_WORK/calls.$name" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$OZ_WORK/calls.$name"
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
[ -n "$id" ] || exit 0
# Per-tasklist path ON PURPOSE: two tasklists writing the same bytes to the same path
# would leave the second branch with an EMPTY diff vs a base the first already merged
# into, and the no-work guard — not the policy layer — would be what this measured.
out="out/$name/$id.txt"
mkdir -p "$(dirname "$out")"
seq 1 "$(cat "$OZ_WORK/size.$name" 2>/dev/null || echo 3)" > "$out"
for f in "$PRD" "$TRACKED"; do
  [ -f "$f" ] || continue
  t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id)|.passes)=true
    | (.userStories[]|select(.id==$id)|.notes)="artifact written; verify green"' "$f" > "$t" && mv "$t" "$f"
done
git add -A >/dev/null 2>&1 || true
git commit -q -m "feat: [$id] - story $id of $name" >/dev/null 2>&1 || true
if [ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ]; then echo "<promise>COMPLETE</promise>"; fi
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── a chief repo: a serialize zone, a review zone, two oversized tasklists ─────
mkdir -p "$REPO"
( cd "$REPO"
  git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
  git commit -q --allow-empty -m init
  "$CHIEF" init >/dev/null
  rm -f tasks/chief/example.json
  printf '#!/usr/bin/env bash\nset -eu\necho "verify: ok"\nexit 0\n' > .chief/verify.sh
  chmod +x .chief/verify.sh
  # THE REGISTRY. Path matchers, not `touches` — the tags below are deliberately
  # conceptual (`design-a`, the 280 case), so a registry keyed on tags alone would
  # match nothing here and this whole test would pass while proving nothing.
  cat > .chief/zones.conf <<'CONF'
# hermetic fixture — one zone of each policy
serialize  path:out/sz/    scheduled apart, merged as usual
review     path:out/rz/    the shared design two branches must not diverge on
CONF
  for t in sz rz bw bb; do
    jq -n --arg n "$t" '
      { project:"oz", branchName:("chief/" + $n), description:("policy-layer fixture " + $n),
        iters:3, dependsOn:[], touches:["design-a-" + $n], warmup:[],
        userStories:[ { id:"US-1", title:("story of " + $n), description:"",
                        acceptanceCriteria:[("out/" + $n + "/US-1.txt exists")], passes:false, notes:"" } ] }' \
      > "tasks/chief/$t.json"
  done
  git add -A && git commit -q -m setup )

# 450 lines is over the documented 400-line default and under nothing else: the two
# budget tasklists differ only in the enforcement their run is given.
echo 450 > "$WORK/size.bw"; echo 450 > "$WORK/size.bb"

# $OZ_BUDGET states the enforcement a run means to test, and UNSET means "whatever
# the documented default is" — which is the only way PART D can assert that the
# default is `warn` rather than assert that setting `warn` works.
run_chief() {   # $1 = log; rest = args to `chief run`
  local log="$1"; shift
  if [ -n "${OZ_BUDGET:-}" ]; then
    ( cd "$REPO" && PATH="$WORK/fakebin:$PATH" POLL_SECONDS=1 \
        CHIEF_DIFF_BUDGET="$OZ_BUDGET" "$CHIEF" run "$@" ) >"$log" 2>&1
  else
    ( cd "$REPO" && PATH="$WORK/fakebin:$PATH" POLL_SECONDS=1 \
        "$CHIEF" run "$@" ) >"$log" 2>&1
  fi
}
approve() { ( cd "$REPO" && "$CHIEF" approve "$@" ) ; }

# ══ PARTS A + B — one run: the serialize zone merges, the review zone holds ═══
echo "overlap-zones: PART A — a serialize-policy zone behaves exactly as it did before"
echo "overlap-zones: PART B — a review-policy zone holds a rebased, GREEN branch"
LOG="$WORK/ab.log"
run_chief "$LOG" -p 2 sz rz || fail "a run that held a branch for approval exited non-zero (AWAITING-APPROVAL is not a failure)"

# --- PART A: no regression. -------------------------------------------------
[ "$(state sz)" = "done" ] || fail "sz state is '$(state sz)', want done — a serialize zone must not change the merge phase"
on_main "out/sz/US-1.txt" || fail "the serialize-zone tasklist did not merge"
[ -n "$(jq -r '.mergedToMain // empty' "$REPO/tasks/chief/completed/sz.json" 2>/dev/null || echo)" ] \
  || fail "the serialize-zone tasklist was not retired with a mergedToMain stamp"
if [ -f "$(req sz)" ]; then fail "a serialize zone wrote an approval request — it must ask for nothing"; fi
if grep -q 'HELD BY THE MERGE POLICY LAYER' "$S/sz.log"; then fail "a serialize zone held a branch"; fi
echo "   ok  serialize zone: merged, retired, nothing asked"

# --- PART B: the review zone held it, and held it AFTER the floor. ----------
[ "$(state rz)" = "awaiting-approval" ] || fail "rz state is '$(state rz)', want awaiting-approval"
case "$(status rz)" in AWAITING-APPROVAL*) ;; *) fail "rz status is '$(status rz)', want AWAITING-APPROVAL n/total" ;; esac
# THE ORDER IS THE CLAIM: rebase + verify ran and came back green, and only then was
# anything withheld. A hold that skipped the floor would be the feature inverted.
grep -q 'verifying chief/rz' "$S/rz.log" || { tail -40 "$S/rz.log" >&2; fail "the branch was held without the verify hook ever running"; }
grep -q 'verify: ok'          "$S/rz.log" || fail "the held branch's verify was not green"
grep -q 'HELD BY THE MERGE POLICY LAYER' "$S/rz.log" || { tail -40 "$S/rz.log" >&2; fail "the log does not say the policy layer held it"; }
grep -q 'its verify came back GREEN' "$S/rz.log" || fail "the hold message does not say the branch is already green"
if on_main "out/rz/US-1.txt"; then fail "a held branch was merged anyway"; fi
if [ -f "$REPO/tasks/chief/completed/rz.json" ]; then fail "a held tasklist was retired as completed"; fi
( cd "$REPO" && git rev-parse --verify chief/rz >/dev/null 2>&1 ) || fail "the held branch was not kept"
grep -q 'AWAITING APPROVAL' "$LOG" || fail "the run summary does not report the hold"
if grep -q 'EMPTY-NO-WORK' "$LOG"; then fail "the hold was mislabelled EMPTY-NO-WORK"; fi
# The request says WHAT was held and WHY, and names the real changed file that matched.
R="$(req rz)"; [ -s "$R" ] || fail "no approval request was written at $R"
[ "$(jq -r '.zones[0].policy' "$R")" = "review" ] || fail "the request's zone policy is '$(jq -r '.zones[0].policy' "$R")', want review"
[ "$(jq -r '.zones[0].zone'   "$R")" = "path:out/rz/" ] || fail "the request names zone '$(jq -r '.zones[0].zone' "$R")'"
[ "$(jq -r '.zones[0].matched' "$R")" = "out/rz/US-1.txt" ] \
  || fail "the zone matched '$(jq -r '.zones[0].matched' "$R")' — matching must key on the branch's REAL changed files"
[ "$(jq -r '.base' "$R")" = "main" ] || fail "the request does not record the base it was rebased onto"
[ -n "$(jq -r '.change // empty' "$R")" ] || fail "the request carries no change checksum to bind an approval to"
# THE SCHEDULER KEPT GOING — PART A's sibling merged in this same run.
[ "$(state sz)" = "done" ] || fail "the hold blocked the scheduler"
echo "   ok  review zone: rebased, verified green, then held — branch kept, nothing merged"

# ══ the operator's side: what is waiting, and granting it ════════════════════
echo "overlap-zones: PART B (cont.) — chief approve reports the hold and grants it once"
approve --list > "$WORK/list.txt" 2>&1 || fail "chief approve --list exited non-zero"
grep -q 'rz' "$WORK/list.txt" || { cat "$WORK/list.txt" >&2; fail "chief approve --list does not report the held tasklist"; }
grep -q 'awaiting approval' "$WORK/list.txt" || { cat "$WORK/list.txt" >&2; fail "the listing does not say it is awaiting approval"; }
if grep -q 'sz' "$WORK/list.txt"; then fail "chief approve --list reported a tasklist that was never held"; fi
approve rz -m "checked against sz's design" > "$WORK/appr.txt" 2>&1 || { cat "$WORK/appr.txt" >&2; fail "chief approve rz failed"; }
A="$(appr rz)"; [ -s "$A" ] || fail "no verdict was written at $A"
[ "$(jq -r '.decision' "$A")" = "approved" ] || fail "the banked verdict is '$(jq -r '.decision' "$A")', want approved"
[ "$(jq -r '.change' "$A")" = "$(jq -r '.change' "$R")" ] \
  || fail "the verdict's checksum is not the one the run computed — an approval must be bound to the change it saw"
[ "$(jq -r '.note' "$A")" = "checked against sz's design" ] || fail "the operator's note was not recorded"
approve rz > "$WORK/appr2.txt" 2>&1 || fail "approving twice exited non-zero — it must be idempotent"
grep -q 'already approved' "$WORK/appr2.txt" || { cat "$WORK/appr2.txt" >&2; fail "a second approval was not reported as a no-op"; }
echo "   ok  listed, granted, bound to the run's own checksum, idempotent"

# ══ PART C — the verdict survives a restart, and is never re-asked ═══════════
echo "overlap-zones: PART C — a separate process reads the verdict off disk and merges"
# The proof that the approval is not run state: by now the merge phase has already
# removed rz's worktree, so nothing under it could have carried the yes.
if [ -d "$CHIEF_PREFIX/worktrees" ] && ls -d "$CHIEF_PREFIX"/worktrees/*/rz >/dev/null 2>&1; then
  fail "the held tasklist's worktree still exists — this part would not prove durability"
fi
before="$(calls rz)"
LOG="$WORK/c.log"
run_chief "$LOG" rz || fail "the approved run exited non-zero"
[ "$(state rz)" = "done" ] || fail "rz state is '$(state rz)', want done after approval"
on_main "out/rz/US-1.txt" || fail "the approved branch did not merge"
[ -n "$(jq -r '.mergedToMain // empty' "$REPO/tasks/chief/completed/rz.json" 2>/dev/null || echo)" ] \
  || fail "the approved tasklist was not retired with a mergedToMain stamp"
grep -q 'this exact change is APPROVED' "$S/rz.log" || { tail -40 "$S/rz.log" >&2; fail "the resumed run does not say it found the verdict on disk"; }
if grep -q 'HELD BY THE MERGE POLICY LAYER' "$LOG"; then fail "an approved change was asked about a second time"; fi
[ "$(calls rz)" = "$before" ] || fail "the resumed run spent an agent turn ($before -> $(calls rz)) on a tasklist whose stories all pass"
# A merged change's request and verdict are cleared: what they were about is now on
# the base, and a verdict that outlived its subject can only mislead.
if [ -f "$(req rz)" ] || [ -f "$(appr rz)" ]; then fail "the request/verdict survived the merge they were about"; fi
echo "   ok  merged on a banked verdict, no re-ask, no agent turn, artifacts cleared"

# ══ PART D — the diff-size budget: warn reports, block withholds ═════════════
echo "overlap-zones: PART D — an oversized story is reported under warn and withheld under block"
LOG="$WORK/d-warn.log"
run_chief "$LOG" bw || fail "the default-mode run exited non-zero"   # NO enforcement set: the DEFAULT is under test
grep -q '(mode warn)' "$S/bw.log" || { tail -40 "$S/bw.log" >&2; fail "the documented default enforcement is not warn"; }
[ "$(state bw)" = "done" ] || fail "bw state is '$(state bw)', want done — warn must NOT block"
on_main "out/bw/US-1.txt" || fail "an over-budget story under 'warn' was withheld — the default must not be obstructive"
grep -q 'is OVER the per-story diff budget' "$S/bw.log" || { tail -40 "$S/bw.log" >&2; fail "the oversized story was not reported in the worker log"; }
grep -q 'diff-size budget: branch total' "$S/bw.log" || fail "the branch-total measurement line is missing"
# …and the finding outlives the run, in THE STORY'S OWN permanent record.
C="$REPO/tasks/chief/completed/bw.json"
[ "$(jq -r '.userStories[0].diffSize.overBudget' "$C" 2>/dev/null)" = "true" ] \
  || { jq '.userStories[0]' "$C" >&2; fail "the completed record does not carry the story's over-budget measurement"; }
[ "$(jq -r '.userStories[0].diffSize.lines' "$C")" -ge 450 ] \
  || fail "the recorded size ($(jq -r '.userStories[0].diffSize.lines' "$C") lines) is not the diff that was made"
[ "$(jq -r '.userStories[0].diffSize.budget.lines' "$C")" = "400" ] \
  || fail "the record does not carry the budget it was judged against"
echo "   ok  warn: merged, reported in the log and in the story's permanent record"

LOG="$WORK/d-block.log"
OZ_BUDGET=block run_chief "$LOG" bb || fail "the block-mode run exited non-zero (a hold is not a failure)"
[ "$(state bb)" = "awaiting-approval" ] || fail "bb state is '$(state bb)', want awaiting-approval under CHIEF_DIFF_BUDGET=block"
if on_main "out/bb/US-1.txt"; then fail "an over-budget story under 'block' merged anyway"; fi
grep -q 'verify: ok' "$S/bb.log" || fail "the withheld branch's verify was not green — the floor still runs first"
RB="$(req bb)"; [ -s "$RB" ] || fail "the budget hold wrote no approval request"
# ONE GATE, ONE APPROVAL: the budget contributes a hold in the ZONE shape, so it uses
# the same request file, the same checksum and the same `chief approve` — never a
# second checkpoint, and never a second prompt for a branch that trips both.
[ "$(jq -r '.zones[0].zone' "$RB")" = "budget:lines" ] \
  || fail "the budget hold appears as '$(jq -r '.zones[0].zone' "$RB")', want budget:lines"
[ "$(jq -r '.zones[0].policy' "$RB")" = "review" ] || fail "the budget hold is not a review-policy hold"
approve bb >/dev/null 2>&1 || fail "chief approve bb failed"
LOG="$WORK/d-block2.log"
OZ_BUDGET=block run_chief "$LOG" bb || fail "the approved block-mode run exited non-zero"
[ "$(state bb)" = "done" ] || fail "bb state is '$(state bb)', want done after approval"
on_main "out/bb/US-1.txt" || fail "the approved over-budget branch did not merge"
echo "   ok  block: withheld after a green floor, released by the same one approval, merged"

echo "OVERLAP-ZONES PASS — the policy layer only ever WITHHOLDS: a serialize zone changes nothing, a review zone and an over-budget story hold a rebased + verified-GREEN branch for one durable approval, and warn reports without blocking"
