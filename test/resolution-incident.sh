#!/usr/bin/env bash
# test/resolution-incident.sh — THE INCIDENT, END TO END, THROUGH THE REAL DRIVER.
#
# tasks/chief/123-a-resolution-that-erases-merged-work, US-4. test/resolution-deletions.sh
# drives engine/resolution.sh directly against hand-built repos — fast, and blind to
# whether any of it is WIRED. This file is the other half: a real `chief run`, a real
# worktree, a real pickup conflict, a real agent turn, a real merge phase. Nothing
# below calls a function of the engine by name.
#
# WHAT IS REPRODUCED (PART A). A branch forks. While it is in flight a sibling
# tasklist merges into the base and edits the same file — one line that collides with
# the branch's own edit, and lines beside it that do NOT. Chief's pickup rebase
# conflicts, so it hands the resolution off. The agent does what the incident's agent
# did: it keeps the BRANCH's copy of the whole file (`git checkout --theirs`, which in
# a rebase is the commit being replayed). Every base-side line in that file goes with
# it — including the ones that never conflicted and so were never on screen. Then the
# story is implemented, the gate comes back GREEN, and before tasklist 123 chief
# merged. The assertion is that it does not: the tasklist ends AWAITING-APPROVAL, the
# base has not moved, and the report names the file, the erased lines and the sibling
# whose work they were.
#
# WHY PART B EXISTS. "Chief did not merge it" is worth exactly what the mutation run
# proves. PART B runs the SAME fixture, built by the same function, against a COPY of
# this engine with the detector neutered — and that copy MERGES, leaving the sibling's
# marker line gone from the base. That is the incident, committed to the base branch,
# under a green gate. (A copy, not `git show HEAD~N`: CI clones shallow.)
#
# THE NEGATIVE CONTROLS ARE THE EXPENSIVE HALF. A rule that holds everything is not a
# rule. PART C resolves a conflict CORRECTLY on a branch whose own intent is a
# deletion — the shape most likely to be mistaken for the incident — and it merges
# untouched. PART D never conflicts at all, and pays a file-existence test for the
# privilege. PART E is the operator's way through: one `chief approve`, and the
# approval is still readable in the completed record afterwards.
#
# Hermetic: a scripted fake `claude` on PATH and temp prefixes ($CHIEF_PREFIX
# included) — it never touches the real ~/.chief. Drives bin/chief straight out of
# this checkout, so it tests uncommitted work.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rc=$?; rm -rf "$WORK"; exit "$rc"' EXIT
export GIT_AUTHOR_NAME=ri GIT_AUTHOR_EMAIL=ri@test GIT_COMMITTER_NAME=ri GIT_COMMITTER_EMAIL=ri@test
export CHIEF_PREFIX="$WORK/ch" CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
# The policy layer's OTHER two rules read the environment, and this file's whole
# claim is that the resolution rule is armed without either of them. An inherited
# CHIEF_DIFF_BUDGET=block or CHIEF_ZONES would make every hold below ambiguous.
unset CHIEF_DIFF_BUDGET CHIEF_DIFF_BUDGET_LINES CHIEF_DIFF_BUDGET_FILES CHIEF_ZONES 2>/dev/null || true
unset CHIEF_MERGE_BATCH CHIEF_RESEARCH 2>/dev/null || true
# The fake agent finishes in one turn; don't pay agent.sh's generous stall budget.
export STALL_LIMIT=1 HARD_MAX=3
CHIEF="$ROOT/bin/chief"

ARM=""
fail() {
  echo "RESOLUTION-INCIDENT FAIL: $*" >&2
  if [ -n "$ARM" ]; then
    [ -f "$WORK/$ARM/run.log" ] && { echo "--- run.log"; tail -40 "$WORK/$ARM/run.log"; } >&2
    [ -f "$WORK/$ARM/repo/.chief/state/parallel/$ARM.log" ] \
      && { echo "--- worker log"; tail -60 "$WORK/$ARM/repo/.chief/state/parallel/$ARM.log"; } >&2
  fi
  exit 1
}
command -v jq  >/dev/null || fail "jq is required"
command -v git >/dev/null || fail "git is required"

# NOTE: `[ … ] && fail` exits the whole script under `set -e` on the PASSING branch,
# so every negative assertion below is written as `if … then fail; fi`.
has()  { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }   # substring, SIGPIPE-safe
repo_of()   { printf '%s/%s/repo' "$WORK" "$1"; }
state_dir() { printf '%s/%s/repo/.chief/state/parallel' "$WORK" "$1"; }
worker_log(){ cat "$(state_dir "$1")/$1.log" 2>/dev/null || echo; }
status_of() { cat "$(state_dir "$1")/$1.status" 2>/dev/null || echo MISSING; }
state_of()  { cat "$(state_dir "$1")/$1.state" 2>/dev/null || echo MISSING; }
calls()     { cat "$WORK/calls.$1" 2>/dev/null || echo 0; }
on_main()   { ( cd "$(repo_of "$1")" && git show "main:$2" >/dev/null 2>&1 ); }
main_file() { ( cd "$(repo_of "$1")" && git show "main:$2" 2>/dev/null || echo ); }

# The lines the sibling tasklist put on the base. THE MARKER IS THE POINT: it is the
# line that did NOT conflict, so no resolver ever saw it, and it is what a whole-file
# resolution takes with it.
MARKER="RI-BASE-MARKER-4f2a"
SIB_EXTRA="a sibling registered another command"
SIBLING="61-register-commands"

# ── the scripted agent ────────────────────────────────────────────────────────
# One story per turn, plus a resolution behaviour chosen by $RI_MODE:
#   incident — keep the BRANCH's copy of every conflicted file. `--theirs` during a
#              rebase is the commit being replayed, i.e. this branch: the exact
#              mechanism of the incident, not a simulation of its outcome.
#   correct  — write the known-good merged content ($RI_RESOLVED), which keeps every
#              base-side line AND honours the branch's own deletion.
#   implement— never resolves anything (no conflict is handed to it).
# Every mode records that it resolved, so an arm can prove its fixture really did
# conflict rather than passing by never exercising the path at all.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
: "${RI_WORK:?}"
cat >/dev/null                                   # drain the prompt on stdin
PRD=".chief/state/prd.json"                      # cwd = the worktree (set by the driver)
NOTE=".chief/state/INTEGRATE-BASE.md"
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
TRACKED="tasks/chief/$name.json"
n=$(( $(cat "$RI_WORK/calls.$name" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$RI_WORK/calls.$name"
MODE="${RI_MODE:-implement}"

if [ -f "$NOTE" ] && [ "$MODE" != "implement" ]; then
  base="$(sed -n 's/^base: \([^ ]*\) .*/\1/p' "$NOTE" | head -1)"; [ -n "$base" ] || base=main
  git rebase "$base" >/dev/null 2>&1 || true
  i=0
  while [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; do
    i=$((i+1)); [ "$i" -gt 10 ] && { git rebase --abort >/dev/null 2>&1 || true; break; }
    for f in $(git diff --name-only --diff-filter=U); do
      case "$MODE" in
        incident) git checkout --theirs -- "$f" >/dev/null 2>&1 || true ;;
        correct)  [ -n "${RI_RESOLVED:-}" ] && [ -f "$RI_RESOLVED" ] && cp "$RI_RESOLVED" "$f" ;;
      esac
      git add "$f" >/dev/null 2>&1 || true
    done
    GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 || true
  done
  rm -f "$NOTE"
  echo "$MODE" > "$RI_WORK/resolved.$name"
fi

id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  mkdir -p "out/$name"; printf 'impl %s\n' "$id" > "out/$name/$id.txt"
  for f in "$PRD" "$TRACKED"; do
    [ -f "$f" ] || continue
    t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id)|.passes)=true
      | (.userStories[]|select(.id==$id)|.notes)="artifact written"' "$f" > "$t" && mv "$t" "$f"
  done
  git add -A >/dev/null 2>&1 || true
  git commit -q -m "feat: [$id] - story $id of $name" >/dev/null 2>&1 || true
fi
[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── arm scaffolding ───────────────────────────────────────────────────────────
# One repo per arm, so no arm's merge can move another's base. Two stories: the
# first is a PRIOR RUN's committed work (that is what makes the branch stale), the
# second is what the agent implements in the turn where it also resolves — which is
# the common shape, and the one the post-resolution-commit window exists for.
scaffold() {   # $1 = arm name; stdin = the initial content of shared.txt
  local arm="$1" repo; repo="$(repo_of "$arm")"
  mkdir -p "$repo"; cd "$repo"
  git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
  git commit -q --allow-empty -m init
  "$CHIEF" init >/dev/null || fail "chief init failed in $arm"
  rm -f tasks/chief/example.json
  cat > shared.txt
  jq -n --arg b "chief/$arm" '
    { project:"ri", branchName:$b, description:"resolution-incident fixture", iters:3,
      dependsOn:[], touches:[], warmup:[],
      userStories:[ range(1;3) | { id:("US-"+(tostring)), title:"story", description:"",
                                   acceptanceCriteria:["the artifact file is written"],
                                   passes:false, notes:"" } ] }' \
    > "tasks/chief/$arm.json"
  printf '#!/usr/bin/env bash\nset -eu\necho "verify: ok"\nexit 0\n' > .chief/verify.sh
  chmod +x .chief/verify.sh
  git add -A && git commit -q -m "$arm setup"
}

# A prior run's branch: US-1 done, and the branch's own edit to shared.txt committed.
prior_branch() {   # $1 = arm; stdin = the branch's shared.txt
  local arm="$1" t repo; repo="$(repo_of "$arm")"; cd "$repo"
  git checkout -q -b "chief/$arm" main
  mkdir -p "out/$arm"; printf 'impl US-1\n' > "out/$arm/US-1.txt"
  t="$(mktemp)"; jq '(.userStories[]|select(.id=="US-1")|.passes)=true' "tasks/chief/$arm.json" > "$t"
  mv "$t" "tasks/chief/$arm.json"
  cat > shared.txt
  git add -A && git commit -q -m "feat: [US-1] - prior run work"
  git checkout -q main
}

# A sibling tasklist merges into the base while the branch is in flight. The subject
# is a chief auto-merge, which is how the detector can name the tasklist and not just
# the sha. stdin = the base's new shared.txt.
sibling_merge() {   # $1 = arm, $2 = sibling stem
  local arm="$1" repo; repo="$(repo_of "$arm")"; cd "$repo"
  cat > shared.txt
  git commit -q -am "Merge chief/$2 (chief, auto-verified)"
}

run_arm() {   # $1 = arm, $2 = mode, [$3 = tool root]
  ARM="$1"
  local tool="${3:-$ROOT}"
  ( cd "$(repo_of "$1")" && PATH="$WORK/fakebin:$PATH" POLL_SECONDS=1 \
      RI_WORK="$WORK" RI_MODE="$2" RI_RESOLVED="${RI_RESOLVED:-}" \
      "$tool/bin/chief" run "$1" ) >"$WORK/$1/run.log" 2>&1 || true
}

# THE INCIDENT FIXTURE, built once and used by PART A and PART B. Same bytes, same
# history, same agent — the only thing that differs between them is the engine.
incident_fixture() {   # $1 = arm
  local arm="$1"
  scaffold "$arm" <<EOF
shared header
base line
EOF
  prior_branch "$arm" <<EOF
shared header
the branch edited this line
EOF
  # The base's side: ONE line that collides with the branch's edit, and two that do
  # not. The two are the incident — already-merged work in the same FILE but not in
  # the conflicted HUNK, which a whole-file resolution takes without anyone seeing it.
  sibling_merge "$arm" "$SIBLING" <<EOF
shared header
base line, edited by the sibling
$MARKER
$SIB_EXTRA
EOF
}

# ══ PART A — the incident is held ════════════════════════════════════════════
echo "resolution-incident: PART A — a resolution that erases merged work is NOT merged"
incident_fixture inc
cd "$(repo_of inc)"
inc_sib_sha="$(git rev-parse --short main)"
inc_main_tip="$(git rev-parse main)"
run_arm inc incident

log="$(worker_log inc)"
[ -f "$WORK/resolved.inc" ] || { echo "$log" >&2; fail "A: the fixture never conflicted — the agent was handed no resolution, so this arm proves nothing"; }
has "does NOT rebase cleanly" "$log" || fail "A: chief did not hand the conflict off at pickup"
# THE FLOOR RAN FIRST. A hold that skipped rebase+verify would be the feature inverted.
has "verify: ok" "$log" || fail "A: the branch was held without a green verify — the floor must run first"
case "$(status_of inc)" in
  AWAITING-APPROVAL*) ;;
  *) fail "A: status is '$(status_of inc)', want AWAITING-APPROVAL — a resolution that erases merged work was allowed through" ;;
esac
[ "$(state_of inc)" = "awaiting-approval" ] || fail "A: state is '$(state_of inc)', want awaiting-approval"
[ "$(git -C "$(repo_of inc)" rev-parse main)" = "$inc_main_tip" ] || fail "A: main MOVED — the held branch was merged anyway"
if on_main inc "out/inc/US-2.txt"; then fail "A: the held branch's work is on main"; fi
if [ -f "$(repo_of inc)/tasks/chief/completed/inc.json" ]; then fail "A: a held tasklist was retired as completed"; fi
( cd "$(repo_of inc)" && git rev-parse --verify chief/inc >/dev/null 2>&1 ) || fail "A: the held branch was not kept"
# THE REPORT NAMES WHOSE WORK IT WAS — file, line, base commit, sibling tasklist.
has "would ERASE" "$log"   || fail "A: the worker log does not say that merged work would be erased"
has "shared.txt" "$log"    || fail "A: the report does not name the file"
has "$MARKER" "$log"       || fail "A: the report does not name the planted line that was erased"
has "$SIB_EXTRA" "$log"    || fail "A: the report names only the conflicting line, not the rest of the base's work in that file"
has "$inc_sib_sha" "$log"  || fail "A: the report does not name the base commit that introduced the line"
has "$SIBLING" "$log"      || fail "A: the report does not name the sibling tasklist whose merge brought it in"
# …and in the durable request, which is what `chief approve` and any UI read.
REQ="$(state_dir inc)/inc.zone-request.json"
[ -s "$REQ" ] || fail "A: no approval request was written at $REQ"
zmatched="$(jq -r '(.zones // [])[] | [.zone, .matched, .reason] | @tsv' "$REQ")"
has "resolution:deleted" "$zmatched" || fail "A: the request does not carry the resolution hold ($zmatched)"
has "$MARKER" "$zmatched"            || fail "A: the request does not name the erased line"
has "$SIBLING" "$zmatched"           || fail "A: the request does not name the sibling tasklist"
# …and in the run summary, and in `chief approve --list`.
has "AWAITING APPROVAL" "$(cat "$WORK/inc/run.log")" || fail "A: the run summary does not report the hold"
( cd "$(repo_of inc)" && "$CHIEF" approve --list ) > "$WORK/inc/list.txt" 2>&1 || fail "A: chief approve --list exited non-zero"
has "inc" "$(cat "$WORK/inc/list.txt")" || fail "A: chief approve --list does not report the held tasklist"
has "resolution:deleted" "$(cat "$WORK/inc/list.txt")" \
  || { cat "$WORK/inc/list.txt" >&2; fail "A: the listing does not say WHY it is held"; }
echo "   ok  held at AWAITING-APPROVAL after a green floor; the report names shared.txt, the erased lines, $inc_sib_sha and $SIBLING"

# ══ PART B — the mutation run: neuter the detector and the incident MERGES ═══
# The claim this file makes is only worth what this part proves. Same fixture, same
# scripted agent, a COPY of this engine with resolution_deletions() returning nothing.
echo "resolution-incident: PART B — with the detector neutered, the same fixture merges (the incident, reproduced)"
mkdir -p "$WORK/unfixed"
cp -R "$ROOT/bin" "$ROOT/engine" "$ROOT/templates" "$WORK/unfixed/" || fail "B: could not copy the tool root"
cp "$ROOT/VERSION" "$WORK/unfixed/VERSION"
OLD="$WORK/unfixed/engine/resolution.sh"
LC_ALL=C grep -q '^resolution_deletions() {' "$OLD" \
  || fail "B: resolution_deletions() is not where this file expects it — the 'unfixed' arm would silently be a copy of the FIXED engine. Update the rewrite below, do not delete the reproduction."
LC_ALL=C awk '
  /^resolution_deletions\(\) \{/ {
    print; print "  return 0   # CHIEF-TEST-UNFIXED — the pre-123 floor could not see a resolution deletion"
    inf = 1; next
  }
  inf && /^\}/ { print; inf = 0; next }
  inf { next }
  { print }' "$OLD" > "$OLD.new"
mv "$OLD.new" "$OLD"
LC_ALL=C grep -q 'CHIEF-TEST-UNFIXED' "$OLD" || fail "B: the neuter did not apply"
bash -n "$OLD" || fail "B: the neutered resolution.sh does not parse"

incident_fixture mut
mut_main_tip="$(git -C "$(repo_of mut)" rev-parse main)"
run_arm mut incident "$WORK/unfixed"

[ -f "$WORK/resolved.mut" ] || fail "B: the mutation fixture never conflicted"
case "$(status_of mut)" in
  MERGED*) ;;
  *) fail "B: the neutered engine did NOT merge (status '$(status_of mut)') — PART A is not testing the detector it claims to test" ;;
esac
[ "$(git -C "$(repo_of mut)" rev-parse main)" != "$mut_main_tip" ] || fail "B: the neutered run reported MERGED but main did not move"
mut_shared="$(main_file mut shared.txt)"
if has "$MARKER" "$mut_shared"; then fail "B: the neutered run merged, but the base's line survived — the fixture does not reproduce the incident"; fi
if has "$SIB_EXTRA" "$mut_shared"; then fail "B: the sibling's second line survived the neutered merge — the fixture does not erase what it claims to"; fi
[ -f "$(repo_of mut)/tasks/chief/completed/mut.json" ] || fail "B: the neutered run did not retire the tasklist"
echo "   ok  neutered: MERGED, and $MARKER is GONE from main — that is the incident, on the base branch, under a green gate"

# ══ PART C — negative control (a): a branch whose own intent is a deletion ═══
# The shape most easily mistaken for the incident. The branch deletes a line
# deliberately; the base adds one right beside it, so the rebase conflicts; the
# resolution honours BOTH (base line kept, branch's deletion kept). Nothing is held.
echo "resolution-incident: PART C — a correctly-resolved conflict on a branch that MEANT to delete merges untouched"
NEGA_MARKER="RI-NEGA-BASE-MARKER-9d17"
scaffold nega <<EOF
alpha
DOOMED-LINE
omega
EOF
prior_branch nega <<EOF
alpha
omega
EOF
sibling_merge nega "62-a-sibling" <<EOF
alpha
DOOMED-LINE
$NEGA_MARKER
omega
EOF
cat > "$WORK/nega.resolved" <<EOF
alpha
$NEGA_MARKER
omega
EOF
nega_main_tip="$(git -C "$(repo_of nega)" rev-parse main)"
RI_RESOLVED="$WORK/nega.resolved" run_arm nega correct

log="$(worker_log nega)"
[ -f "$WORK/resolved.nega" ] || { echo "$log" >&2; fail "C: the fixture never conflicted — a correct resolution was never exercised"; }
has "does NOT rebase cleanly" "$log" || fail "C: chief did not hand this conflict off — the arm proves nothing"
case "$(status_of nega)" in
  MERGED*) ;;
  *) fail "C: status is '$(status_of nega)', want MERGED — a correctly-resolved conflict was held" ;;
esac
if has "would ERASE" "$log"; then fail "C: the branch's OWN deletion was reported as erased merged work"; fi
if has "HELD BY THE MERGE POLICY LAYER" "$log"; then fail "C: a correct resolution was held"; fi
if [ -f "$(state_dir nega)/nega.zone-request.json" ]; then fail "C: an approval was requested for a correct resolution"; fi
[ "$(git -C "$(repo_of nega)" rev-parse main)" != "$nega_main_tip" ] || fail "C: main did not move despite MERGED"
nega_shared="$(main_file nega shared.txt)"
has "$NEGA_MARKER" "$nega_shared" || fail "C: the base's line is not on main after the merge — the fixture's resolution was not correct"
if has "DOOMED-LINE" "$nega_shared"; then fail "C: the branch's intended deletion did not survive the merge"; fi
[ -f "$(repo_of nega)/tasks/chief/completed/nega.json" ] || fail "C: tasklist not retired"
echo "   ok  conflicted, resolved correctly, merged: intent kept, $NEGA_MARKER kept, nothing asked"

# ══ PART D — negative control (b): a clean rebase pays a file-existence test ══
echo "resolution-incident: PART D — a branch that never conflicted merges unchanged, and the check costs one stat"
scaffold negb <<EOF
shared header
base line
EOF
prior_branch negb <<EOF
shared header
the branch edited this line
EOF
( cd "$(repo_of negb)"
  printf 'a sibling merged here\n' > other.txt        # base advances on an UNRELATED file
  git add -A && git commit -q -m "Merge chief/63-elsewhere (chief, auto-verified)" )
run_arm negb implement

log="$(worker_log negb)"
has "rebased chief/negb onto main" "$log" || fail "D: the fixture is wrong — the branch did not rebase cleanly at pickup"
if has "does NOT rebase cleanly" "$log"; then fail "D: the clean fixture conflicted"; fi
if [ -f "$WORK/resolved.negb" ]; then fail "D: a resolution was handed off on a cleanly-rebasing branch"; fi
case "$(status_of negb)" in MERGED*) ;; *) fail "D: status is '$(status_of negb)', want MERGED" ;; esac
if has "would ERASE" "$log"; then fail "D: a branch that never conflicted was reported as erasing work"; fi
if has "resolution check" "$log"; then fail "D: the check reported on a branch with no recorded resolution"; fi
# THE COST, pinned rather than asserted in prose: no handoff means no record, which
# is the ONE file-existence test the detector's fast path performs — no git process,
# and nothing to clear at merge either.
if [ -f "$(state_dir negb)/negb.resolution.json" ]; then fail "D: a resolution record was written for a branch that never had a conflict handed to it"; fi
if ( cd "$(repo_of negb)" && git show-ref --verify --quiet refs/chief/resolution/negb ); then
  fail "D: a resolution pin ref was created for a branch that never had a conflict handed to it"
fi
on_main negb "out/negb/US-2.txt" || fail "D: the branch's work is not on main"
on_main negb "other.txt"        || fail "D: the base commit that advanced main was lost"
[ -f "$(repo_of negb)/tasks/chief/completed/negb.json" ] || fail "D: tasklist not retired"
echo "   ok  clean rebase merged; no record, no pin, no git — the fast path is one stat"

# ══ PART E — the override, and what survives the merge ═══════════════════════
# The hold is not a wall. One `chief approve` releases it, and the verdict outlives
# the merge in the completed record — zones_clear_record deletes the FILE, so the
# file alone was never the record.
echo "resolution-incident: PART E — chief approve releases the hold, and the approval survives in completed/"
ARM=inc
REASON="the sibling's registrations were re-added by hand on the branch"
before_calls="$(calls inc)"
( cd "$(repo_of inc)" && "$CHIEF" approve inc -m "$REASON" ) > "$WORK/inc/approve.txt" 2>&1 \
  || { cat "$WORK/inc/approve.txt" >&2; fail "E: chief approve inc failed"; }
run_arm inc incident

case "$(status_of inc)" in MERGED*) ;; *) fail "E: status is '$(status_of inc)', want MERGED after approval" ;; esac
[ "$(state_of inc)" = "done" ] || fail "E: state is '$(state_of inc)', want done"
on_main inc "out/inc/US-2.txt" || fail "E: the approved branch did not merge"
[ "$(calls inc)" = "$before_calls" ] \
  || fail "E: the resumed run spent an agent turn ($before_calls -> $(calls inc)) on a tasklist whose stories all pass"
C="$(repo_of inc)/tasks/chief/completed/inc.json"
[ -s "$C" ] || fail "E: the approved tasklist was not retired"
[ "$(jq -r '.approval.decision // empty' "$C")" = "approved" ] \
  || { jq '.approval' "$C" >&2; fail "E: the completed record carries no approval"; }
[ "$(jq -r '.approval.note // empty' "$C")" = "$REASON" ] || fail "E: the operator's note is not in the completed record"
[ -n "$(jq -r '.approval.by // empty' "$C")" ] || fail "E: the completed record does not say who approved it"
[ -n "$(jq -r '.approval.at // empty' "$C")" ] || fail "E: the completed record does not say when"
covered="$(jq -r '(.approval.zones // [])[] | [.zone, .matched] | @tsv' "$C")"
has "resolution:deleted" "$covered" || fail "E: the approval does not record WHAT it covered ($covered)"
has "$MARKER" "$covered" || fail "E: the approval does not record the erased lines it covered"
# The request and the verdict FILES are cleared on merge — which is exactly why the
# assertions above had to be about the completed record.
if [ -f "$(state_dir inc)/inc.zone-request.json" ] || [ -f "$(state_dir inc)/inc.zone-approval.json" ]; then
  fail "E: the request/verdict survived the merge they were about"
fi
if [ -f "$(state_dir inc)/inc.resolution.json" ]; then fail "E: the resolution record was not cleared on merge"; fi
if ( cd "$(repo_of inc)" && git show-ref --verify --quiet refs/chief/resolution/inc ); then
  fail "E: the resolution pin ref was not cleared on merge"
fi
echo "   ok  approved, merged, and the verdict (who · when · why · which lines) is in completed/inc.json"

ARM=""
echo "RESOLUTION-INCIDENT PASS — a whole-file resolution that erased a merged sibling's lines was HELD by a real run (branch kept, base unmoved, the lines and their sibling named); the same fixture MERGES with the detector neutered and the marker is gone from main; a correctly-resolved deletion and a clean rebase merge untouched; one chief approve releases it and the verdict survives in completed/"
