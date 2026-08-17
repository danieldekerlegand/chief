#!/usr/bin/env bash
# test/plan-review.sh — the PLAN CHECKPOINT end to end (docs/plan-review.md).
#
# tasks/chief/89-plan-review-checkpoint. Plan review is the one opt-in phase that
# can WITHHOLD a run's work on a human, so the three ways it can end all have to be
# provable without a browser and without a person. They are, because the reviewer is
# a documented CLI contract (plannotator's annotate gate) rather than a UI chief
# reaches into — this test scripts a FAKE reviewer against the same five flags:
#
#   PART A — NO REVIEWER: an enabled tasklist plans, finds nobody who can approve it,
#            and PARKS in `awaiting-review` with branch + worktree + plan kept. The
#            scheduler is never blocked: a sibling tasklist merges in the same run.
#   PART B — A LATER APPROVAL RESUMES IT: with the reviewer reachable, the SAME
#            tasklist re-reads the plan it already paid for (no second plan turn),
#            hands it over, gets `{"decision":"approved"}`, implements, verifies and
#            merges. The verdict is banked next to the plan.
#   PART C — REJECTED WITH FEEDBACK: an annotating reviewer sends the plan back; the
#            next turn is a PLAN turn briefed with the reviewer's own words, and the
#            annotate -> re-plan budget ($CHIEF_REVIEW_MAX_ROUNDS) is honoured — it
#            parks rather than spending a third turn. No code is ever written.
#   PART D — THE ABSENCE + STALENESS RULES, as pure functions (engine/review.sh, no
#            driver, no agent): what counts as "no reviewer", and why an approval
#            cannot be inherited by a plan it was not given for.
#
# Hermetic: a scripted fake `claude` AND a scripted fake reviewer on PATH, temp
# prefixes ($CHIEF_PREFIX included), never touches the real ~/.chief. Drives
# bin/chief straight out of this checkout, so it tests uncommitted work.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rc=$?; rm -rf "$WORK"; exit "$rc"' EXIT
export GIT_AUTHOR_NAME=pr GIT_AUTHOR_EMAIL=pr@test GIT_COMMITTER_NAME=pr GIT_COMMITTER_EMAIL=pr@test
export CHIEF_PREFIX="$WORK/ch" CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
# THE HOST MUST LOOK INTERACTIVE. review_unavailable_reason() treats $CI (and
# $CHIEF_REVIEW_NONINTERACTIVE) as "nobody is in front of this machine" and parks —
# correctly, and it is asserted in PART D. Leaving it set under GitHub Actions would
# silently turn PARTs B and C into two more copies of PART A.
unset CI CHIEF_REVIEW_NONINTERACTIVE CHIEF_REVIEW CHIEF_REVIEWER CHIEF_REVIEW_TIMEOUT CHIEF_REVIEW_MAX_ROUNDS 2>/dev/null || true
CHIEF="$ROOT/bin/chief"
LOG=""
fail() { echo "PLAN-REVIEW FAIL: $*" >&2; [ -n "$LOG" ] && [ -f "$LOG" ] && tail -60 "$LOG" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

REPO="$WORK/repo"
S="$REPO/.chief/state/parallel"
SNAP="$REPO/.chief/state/snapshots"
state()  { cat "$S/$1.state" 2>/dev/null || echo MISSING; }
status() { cat "$S/$1.status" 2>/dev/null || echo MISSING; }
calls()  { cat "$WORK/calls.$1" 2>/dev/null || echo 0; }
# reviewer calls for tasklist $1 (awk, not `grep -c`: grep prints 0 AND exits 1 on no
# match, so the `|| echo 0` fallback would print it twice).
rcalls() { awk -F'\t' -v n="/$1/" '$3 ~ n {c++} END{print c+0}' "$WORK/reviewer.log" 2>/dev/null || echo 0; }
# NOTE: `[ … ] && fail` would exit the whole script under `set -e` on the PASSING
# branch, so every negative assertion below is written as an `if … then fail; fi`.

mkdir -p "$WORK/fakebin"
export PZ_WORK="$WORK"

# ── the fake agent ────────────────────────────────────────────────────────────
# Two turn shapes, told apart the way a real agent tells them apart: the PLAN turn's
# prompt names the artifact path ("- Write the plan artifact to: `…`"). On a plan
# turn it writes THAT FILE AND NOTHING ELSE — no edits, no commits, no passes flip,
# which is exactly what engine/plan-instructions.md asks for and what makes "no code
# was written before approval" assertable further down. Otherwise it implements one
# story like every other fake in this suite. Every prompt is kept, so a later part
# can assert what the agent was actually briefed with.
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
: "${PZ_WORK:?}"
prompt="$(cat)"
PRD=".chief/state/prd.json"
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"; TRACKED="tasks/chief/$name.json"
n=$(( $(cat "$PZ_WORK/calls.$name" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$PZ_WORK/calls.$name"
printf '%s' "$prompt" > "$PZ_WORK/prompt.$name.$n"
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
[ -n "$id" ] || exit 0
# Per-tasklist path ON PURPOSE: two tasklists writing the same file with the same
# bytes would leave the second branch with an EMPTY diff vs a base the first already
# merged into — the no-work guard would fire and the test would be measuring that
# collision instead of the review gate.
artifact="out/$name/$id.txt"
plan="$(printf '%s\n' "$prompt" | sed -n 's/^- Write the plan artifact to: `\(.*\)` (relative to the repo root)$/\1/p' | head -1)"
if [ -n "$plan" ]; then
  mkdir -p "$(dirname "$plan")"
  # The revision marker keeps a re-plan from being byte-identical to the plan it
  # replaces — a real re-plan is a different plan, and the verdict's checksum should
  # move with it.
  jq -n --arg id "$id" --arg rev "$n" --arg out "$artifact" '
    { story: $id,
      summary: ("revision " + $rev + ": create the story artifact " + $out),
      changes: [ { path: $out, action: "create",
                   change: "write the story marker the acceptance criteria name" } ],
      verification: [ { phase: "test", command: ("test -f " + $out) } ] }' > "$plan"
  echo "plan written for $id -> $plan"
  exit 0
fi
mkdir -p "$(dirname "$artifact")"; echo "impl $id" > "$artifact"
for f in "$PRD" "$TRACKED"; do
  [ -f "$f" ] || continue
  t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id).passes)=true' "$f" > "$t" && mv "$t" "$f"
done
git add -A >/dev/null 2>&1 || true; git commit -q -m "feat: $id" >/dev/null 2>&1 || true
if [ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ]; then echo "<promise>COMPLETE</promise>"; fi
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── the fake reviewer ─────────────────────────────────────────────────────────
# It asserts the CONTRACT chief claims to speak. plannotator's one-shot gate is
#     plannotator annotate <file.md> --gate --json --require-approval --result-file <out>
# and anything chief sends that is not that shape is a contract drift this test must
# catch, not tolerate — so an unexpected argv exits 2 (startup failure) and the run
# parks, loudly. The verdict itself is scripted by $PZ_VERDICT.
cat > "$WORK/fakebin/pn-fake" <<'REV'
#!/usr/bin/env bash
set -eu
: "${PZ_WORK:?}"
bad() { echo "fake reviewer: $*" >&2; exit 2; }
[ "${1:-}" = "annotate" ] || bad "subcommand is '${1:-}', want 'annotate'"
md="${2:-}"; shift 2 || bad "no document argument"
out=""; gate=0; json=0; req=0
while [ $# -gt 0 ]; do
  case "$1" in
    --gate)             gate=1 ;;
    --json)             json=1 ;;
    --require-approval) req=1 ;;
    --result-file)      out="${2:-}"; shift ;;
    *) bad "unknown flag '$1'" ;;
  esac
  shift
done
[ "$gate$json$req" = "111" ] || bad "missing gate flags (gate=$gate json=$json require-approval=$req)"
[ -n "$out" ] || bad "--result-file was not passed"
[ -s "$md" ] || bad "the plan document '$md' is missing or empty"
n=$(( $(cat "$PZ_WORK/rcalls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$PZ_WORK/rcalls"
cp "$md" "$PZ_WORK/reviewed.$n.md"
printf '%s\t%s\t%s\n' "$n" "${PZ_VERDICT:-approved}" "$md" >> "$PZ_WORK/reviewer.log"
case "${PZ_VERDICT:-approved}" in
  approved) printf '{"decision":"approved"}\n' > "$out"; exit 0 ;;
  *)        jq -n --arg f "${PZ_FEEDBACK:-}" '{decision:"annotated",feedback:$f}' > "$out"; exit 1 ;;
esac
REV
chmod +x "$WORK/fakebin/pn-fake"

# ── a chief repo: one review-enabled tasklist, one plain sibling, one rejectee ─
mkdir -p "$REPO"
( cd "$REPO"
  git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
  git commit -q --allow-empty -m init
  "$CHIEF" init >/dev/null
  rm -f tasks/chief/example.json
  printf '#!/usr/bin/env bash\nset -eu\necho "verify: ok"\nexit 0\n' > .chief/verify.sh
  chmod +x .chief/verify.sh
  cat > tasks/chief/rv.json <<'JSON'
{ "project":"pr","branchName":"chief/rv","description":"plan review enabled",
  "review":"plan","iters":4,"dependsOn":[],"touches":["rv"],"warmup":[],
  "userStories":[
    {"id":"US-1","title":"reviewed story","description":"","acceptanceCriteria":["out/rv/US-1.txt"],"passes":false,"notes":""}
  ] }
JSON
  cat > tasks/chief/rj.json <<'JSON'
{ "project":"pr","branchName":"chief/rj","description":"plan review, reviewer sends it back",
  "review":"plan","iters":5,"dependsOn":[],"touches":["rj"],"warmup":[],
  "userStories":[
    {"id":"US-1","title":"rejected story","description":"","acceptanceCriteria":["out/rj/US-1.txt"],"passes":false,"notes":""}
  ] }
JSON
  cat > tasks/chief/sib.json <<'JSON'
{ "project":"pr","branchName":"chief/sib","description":"an ordinary sibling — no review",
  "iters":4,"dependsOn":[],"touches":["sib"],"warmup":[],
  "userStories":[
    {"id":"US-1","title":"plain story","description":"","acceptanceCriteria":["out/sib/US-1.txt"],"passes":false,"notes":""}
  ] }
JSON
  git add -A && git commit -q -m setup )

run_chief() {   # $1 = log; rest = args to `chief run`
  local log="$1"; shift
  ( cd "$REPO" && PATH="$WORK/fakebin:$PATH" POLL_SECONDS=1 \
      CHIEF_REVIEWER="${PZ_REVIEWER:-pn-fake}" \
      CHIEF_REVIEW_TIMEOUT=60 CHIEF_REVIEW_MAX_ROUNDS="${PZ_MAX_ROUNDS:-3}" \
      "$CHIEF" run "$@" ) >"$log" 2>&1
}

# ══ PART A — nobody can approve it: park, and let the siblings run ════════════
echo "plan-review: PART A — no reviewer parks the tasklist and never blocks the scheduler"
LOG="$WORK/a.log"
PZ_REVIEWER=pn-absent-by-design run_chief "$LOG" -p 2 rv sib \
  || fail "a run that parked on a missing reviewer exited non-zero (AWAITING-REVIEW is not a failure)"

[ "$(calls rv)" = "1" ] || fail "rv spent $(calls rv) agent turn(s), want exactly 1 (the PLAN turn, then the park)"
grep -q 'Write the plan artifact to' "$WORK/prompt.rv.1" || fail "the first turn was not a PLAN turn (its prompt names no artifact path)"
[ "$(state rv)" = "awaiting-review" ] || fail "rv state is '$(state rv)', want awaiting-review"
case "$(status rv)" in AWAITING-REVIEW*) ;; *) fail "rv status is '$(status rv)', want AWAITING-REVIEW n/total" ;; esac
grep -q 'is not on PATH' "$S/rv.log" || { tail -30 "$S/rv.log" >&2; fail "the log does not say WHY no reviewer could be reached"; }
grep -q 'AWAITING REVIEW' "$LOG" || fail "the run summary does not report the park"
# NOT a failure, NOT the false-complete guard, and NOT merged — a plan turn writes no
# code, and the park is checked before the no-work guard for exactly that reason.
if grep -q 'EMPTY-NO-WORK' "$LOG"; then fail "the park was mislabelled EMPTY-NO-WORK"; fi
if [ -f "$REPO/tasks/chief/completed/rv.json" ]; then fail "a parked tasklist was retired as completed"; fi
( cd "$REPO" && git rev-parse --verify chief/rv >/dev/null 2>&1 ) || fail "the branch was not kept"
if ( cd "$REPO" && git show chief/rv:out/rv/US-1.txt >/dev/null 2>&1 ); then
  fail "code was implemented for an UNAPPROVED plan — the whole checkpoint is void"
fi
# Branch, worktree and the plan all survive: the plan is banked in the snapshots, so
# it outlives even the worktree being rebuilt.
WT="$(ls -d "$CHIEF_PREFIX"/worktrees/*/rv 2>/dev/null | head -1 || true)"
[ -n "$WT" ] && [ -d "$WT" ] || fail "the parked tasklist's worktree was removed"
[ -s "$WT/.chief/state/plans/US-1.plan.json" ] || fail "the plan artifact is not in the worktree"
[ -s "$SNAP/rv.plans/US-1.plan.json" ] || fail "the plan was not banked in $SNAP/rv.plans (it would be re-bought after a rebuild)"
if [ -f "$SNAP/rv.plans/US-1.review.json" ]; then fail "a verdict was recorded when no reviewer was ever asked"; fi
# THE SCHEDULER KEPT GOING. The sibling shares nothing with rv and must have merged.
[ "$(state sib)" = "done" ] || fail "the sibling tasklist is '$(state sib)', want done — the park blocked the scheduler"
( cd "$REPO" && git checkout -q main && [ -f out/sib/US-1.txt ] ) \
  || fail "the sibling did not merge while rv was parked"
echo "   ok  1 plan turn, no code, parked awaiting-review, plan banked, sibling merged"

# ══ PART B — a later approval resumes it, and the plan is not re-bought ═══════
echo "plan-review: PART B — an approval implements exactly that plan, and is asked for once"
LOG="$WORK/b.log"
PZ_VERDICT=approved run_chief "$LOG" rv || fail "the approved run exited non-zero"

[ "$(rcalls rv)" = "1" ] || fail "the reviewer was asked $(rcalls rv) time(s) for rv, want exactly 1"
[ "$(calls rv)" = "2" ] || fail "rv spent $(calls rv) agent turns total, want 2 (one PLAN before the park, one IMPLEMENT after)"
if grep -q 'Write the plan artifact to' "$WORK/prompt.rv.2"; then
  fail "the resumed run bought a SECOND plan — an approved plan on disk must never be re-planned"
fi
# The human read a DOCUMENT, not the raw artifact: the file table and the checks the
# agent committed to are both in it.
REVIEWED="$WORK/reviewed.$(awk -F'\t' '$3 ~ /\/rv\// {print $1}' "$WORK/reviewer.log" | head -1).md"
grep -q '`out/rv/US-1.txt`' "$REVIEWED" || { cat "$REVIEWED" >&2; fail "the rendered plan document has no file table"; }
grep -q 'test -f out/rv/US-1.txt'  "$REVIEWED" || fail "the rendered plan document does not show the verification the agent committed to"
# The verdict is a FILE, banked next to the plan, bound to the plan it approved.
V="$SNAP/rv.plans/US-1.review.json"
[ -s "$V" ] || fail "no verdict was banked at $V"
[ "$(jq -r '.decision' "$V")" = "approved" ] || fail "the banked verdict is '$(jq -r '.decision' "$V")', want approved"
[ -n "$(jq -r '.plan // empty' "$V")" ] || fail "the verdict does not name the plan it was given for"
# …and the story it approved actually got built, verified and merged.
[ "$(state rv)" = "done" ] || fail "rv state is '$(state rv)', want done"
( cd "$REPO" && git checkout -q main
  [ -f out/rv/US-1.txt ] || exit 3
  [ -n "$(jq -r '.mergedToMain // empty' tasks/chief/completed/rv.json 2>/dev/null)" ] || exit 4 ) \
  || fail "the approved tasklist did not implement + merge (missing artifact or merge stamp)"
echo "   ok  asked once, implemented the approved plan, verified, merged, verdict banked"

# ══ PART C — sent back with annotations, and the retry budget is honoured ═════
echo "plan-review: PART C — a rejection re-plans with the annotations, bounded by the budget"
LOG="$WORK/c.log"
FB="the out/ path is wrong — write the marker under artifacts/ instead"
PZ_VERDICT=annotated PZ_FEEDBACK="$FB" PZ_MAX_ROUNDS=2 run_chief "$LOG" rj \
  || fail "a run that parked on a spent review budget exited non-zero"

[ "$(rcalls rj)" = "2" ] || fail "the reviewer was asked $(rcalls rj) time(s) for rj, want exactly 2 (CHIEF_REVIEW_MAX_ROUNDS=2)"
[ "$(calls rj)" = "2" ] || fail "rj spent $(calls rj) agent turns, want 2 (the plan, then the re-plan — never an implement turn)"
grep -q 'Write the plan artifact to' "$WORK/prompt.rj.2" \
  || fail "the turn after the rejection was not a PLAN turn — the reviewer's send-back did not re-derive a re-plan"
# THE REJECTION'S ENTIRE VALUE: the reviewer's own words reach the next plan.
grep -q 'sent it back' "$WORK/prompt.rj.2" || fail "the re-plan prompt does not say the plan was sent back"
grep -qF "$FB" "$WORK/prompt.rj.2" || { fail "the re-plan prompt does not carry the reviewer's annotations verbatim"; }
# Round 2's document shows round 1's feedback, so a reviewer can see whether the
# re-plan answered them.
R2="$WORK/reviewed.$(awk -F'\t' '$3 ~ /\/rj\// {print $1}' "$WORK/reviewer.log" | sed -n 2p).md"
grep -qF "$FB" "$R2" || { cat "$R2" >&2; fail "the second review document does not show the previous round's feedback"; }
# The annotation history is append-only and is what the budget counts.
V="$SNAP/rj.plans/US-1.review.json"
[ -s "$V" ] || fail "no verdict/annotation record was banked at $V"
[ "$(jq '[.rounds[]|select(.decision=="annotated")]|length' "$V")" = "2" ] \
  || fail "the annotation history has $(jq '.rounds|length' "$V") round(s), want 2"
[ "$(jq -r '[.rounds[].plan]|unique|length' "$V")" = "2" ] \
  || fail "both rounds recorded the same plan checksum — a re-plan was not treated as a new plan"
# Budget spent -> park. Not a failure, not an implementation.
[ "$(state rj)" = "awaiting-review" ] || fail "rj state is '$(state rj)', want awaiting-review"
grep -q 'retry budget is spent' "$S/rj.log" || { tail -30 "$S/rj.log" >&2; fail "the log does not say the annotate -> re-plan budget ran out"; }
if ( cd "$REPO" && git show chief/rj:out/rj/US-1.txt >/dev/null 2>&1 ); then
  fail "code was written for a plan the reviewer never approved"
fi
if [ -f "$REPO/tasks/chief/completed/rj.json" ]; then fail "a rejected tasklist was retired as completed"; fi
echo "   ok  re-planned with the annotations, stopped at 2 rounds, parked, no code written"

# ══ PART D — the absence + staleness rules, as pure functions ═════════════════
echo "plan-review: PART D — what counts as 'no reviewer', and what an approval covers"
reason() { (   # $1.. = env assignments; prints review_unavailable_reason
  set +u
  # shellcheck source=engine/review.sh
  . "$ROOT/engine/review.sh"
  review_unavailable_reason ); }
r_absent="$(CHIEF_REVIEWER=pn-absent-by-design PATH="$WORK/fakebin:$PATH" reason)"
r_ci="$(CHIEF_REVIEWER=pn-fake CI=1 PATH="$WORK/fakebin:$PATH" reason)"
r_ni="$(CHIEF_REVIEWER=pn-fake CHIEF_REVIEW_NONINTERACTIVE=1 PATH="$WORK/fakebin:$PATH" reason)"
r_t0="$(CHIEF_REVIEWER=pn-fake CHIEF_REVIEW_TIMEOUT=0 PATH="$WORK/fakebin:$PATH" reason)"
r_bad="$(CHIEF_REVIEWER=pn-fake CHIEF_REVIEW_TIMEOUT=soon PATH="$WORK/fakebin:$PATH" reason)"
r_ok="$(CHIEF_REVIEWER=pn-fake PATH="$WORK/fakebin:$PATH" reason)"
case "$r_absent" in *"not on PATH"*) ;; *) fail "an uninstalled reviewer reads as: '$r_absent'" ;; esac
case "$r_ci"     in *non-interactive*) ;; *) fail "\$CI does not read as a non-interactive host: '$r_ci'" ;; esac
case "$r_ni"     in *non-interactive*) ;; *) fail "CHIEF_REVIEW_NONINTERACTIVE does not read as non-interactive: '$r_ni'" ;; esac
case "$r_t0"     in *"never wait"*)    ;; *) fail "CHIEF_REVIEW_TIMEOUT=0 does not read as 'never wait': '$r_t0'" ;; esac
case "$r_bad"    in *"whole number"*)  ;; *) fail "a non-numeric timeout is not rejected: '$r_bad'" ;; esac
[ -z "$r_ok" ] || fail "an installed reviewer on an interactive host reads as unavailable: '$r_ok'"

# An approval covers ONE plan — the bytes it was given for. This is the guard that
# keeps "don't re-ask on resume" from waving through a plan nobody agreed to.
staleness() { (
  set +u
  # shellcheck source=engine/review.sh
  . "$ROOT/engine/review.sh"
  P="$WORK/stale.plan.json"; V="$WORK/stale.review.json"
  cp "$SNAP/rv.plans/US-1.plan.json" "$P"; cp "$SNAP/rv.plans/US-1.review.json" "$V"
  review_approved "$V" "$P" || { echo "REAL-APPROVAL-REJECTED"; exit 0; }
  printf '\n' >> "$P"                       # the story was re-planned
  review_approved "$V" "$P" && { echo "STALE-APPROVAL-ACCEPTED"; exit 0; }
  cp "$SNAP/rj.plans/US-1.review.json" "$V" # an ANNOTATED verdict is not an approval
  cp "$SNAP/rv.plans/US-1.plan.json" "$P"
  review_approved "$V" "$P" && { echo "ANNOTATION-READ-AS-APPROVAL"; exit 0; }
  echo OK ); }
st="$(staleness)"
[ "$st" = "OK" ] || fail "the approval/plan binding is wrong: $st"
echo "   ok  five ways to have no reviewer, and an approval that covers exactly one plan"

echo "PLAN-REVIEW PASS — an unapproved plan never becomes code: it parks (siblings run on), a later approval resumes it, and a rejection re-plans within its budget"
