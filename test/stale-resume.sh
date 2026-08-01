#!/usr/bin/env bash
# test/stale-resume.sh — PICKUP-TIME BASE INTEGRATION (tasklist 70, US-1).
#
# The failure class this pins, observed in a real `chief run -p 4`: three tasklists
# failed the SAME way — their branches had drifted far behind base while siblings
# merged sequentially ahead of them, so the merge phase's rebase-onto-latest-base
# conflicted and stopped, leaving five dependents blocked. Part of the drift is
# structural: run_worker's RESUME path used to attach a pre-existing branch to its
# worktree and start the agent WITHOUT integrating the latest base, so a branch from
# a prior run began an entire run already behind.
#
# The fix integrates at pickup, and this test drives all three arms of it against a
# real driver with a scripted fake `claude` (offline, deterministic):
#
#   A. CLEAN drift      — base moved, the branch rebases cleanly: the worker says so
#                         and the tasklist merges. No REBASE-CONFLICT anywhere.
#   B. CONFLICTING      — base moved into the branch's own file: the rebase is
#      drift              ABORTED (branch left clean, attached and UN-rebased), an
#                         INTEGRATE-BASE note naming base/behind-count/conflicted
#                         file is written to the worktree's chief state dir, and the
#                         agent's iteration context actually carries the instruction.
#   C. CONFLICTING      — same drift, but every story already passes: the worker must
#      + all-pass          NOT skip the agent into a merge phase it already knows will
#                         conflict; it re-engages the agent, which integrates the base
#                         as ordinary work and the tasklist merges.
#
# The other half of the drift is MID-RUN (tasklist 70, US-2): base keeps advancing
# while a worker runs, because the serialized merge phase is landing its siblings.
# Both arms below start from a FRESH branch — nothing to integrate at pickup — so any
# integration in the log can only have come from an ITERATION BOUNDARY:
#
#   D. CLEAN mid-run    — a sibling merge lands between iterations: the boundary
#      drift              rebases onto it, exactly ONCE per moved base (the next
#                         boundary, with base unmoved, must be a no-op), before the
#                         merge phase — which then finds nothing to conflict over.
#   E. CONFLICTING      — the sibling merge collides with the branch's own edit: the
#      mid-run drift      boundary aborts, refreshes the INTEGRATE-BASE note and
#                         injects it, and the NEXT iteration resolves it and merges.
#
# Installs the COMMITTED state of this checkout (install.sh git-clones) — commit
# engine changes before trusting a green run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=sr GIT_AUTHOR_EMAIL=sr@test GIT_COMMITTER_NAME=sr GIT_COMMITTER_EMAIL=sr@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"     # hermetic: never touch ~/.chief
# The fake agent finishes (or gives up) in one turn; don't pay for agent.sh's
# generous stall/hard-cap budget in a test that asserts on the FIRST iteration.
export STALL_LIMIT=1 HARD_MAX=3
ARM=""
fail() {
  echo "STALE-RESUME FAIL: $*" >&2
  [ -n "$ARM" ] && [ -f "$WORK/$ARM/run.log" ] && { echo "--- run.log"; tail -40 "$WORK/$ARM/run.log"; } >&2
  [ -n "$ARM" ] && [ -f "$WORK/$ARM/repo/.chief/state/parallel/$ARM.log" ] \
    && { echo "--- worker log"; tail -60 "$WORK/$ARM/repo/.chief/state/parallel/$ARM.log"; } >&2
  exit 1
}
command -v jq  >/dev/null || fail "jq is required"
command -v git >/dev/null || fail "git is required"

# ── 1. Install chief from THIS checkout ───────────────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install.sh failed"
CHIEF="$BIN/chief"

# ── 2. The scripted agent ─────────────────────────────────────────────────────
# Five behaviours, selected per arm by $CHIEF_TEST_MODE:
#   implement — the ordinary one story per call
#   observe   — records what it was handed and does NOTHING else (so the arm ends
#               INCOMPLETE with the worktree intact for assertions)
#   resolve   — does what the INTEGRATE-BASE note asks (rebase, resolve keeping both
#               sides, continue), then carries on with the story loop
#   advance   — implement, and on the FIRST call also land a "sibling merge" on base
#               ($CHIEF_TEST_BASE_REPO) that does NOT touch the branch's files. This
#               is how the mid-run arms move base while a worker is running.
#   advance-  — the branch's first story edits shared.txt and the sibling merge edits
#   conflict    the same line; later calls resolve the note like `resolve` does.
# Every mode copies the note + progress.txt it was given to $CHIEF_TEST_EVIDENCE —
# that copy is the proof the instruction reached the agent's context, and it
# survives the worktree removal that a successful merge performs.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null                                   # drain the prompt on stdin
PRD=".chief/state/prd.json"                      # cwd = the worktree (set by the driver)
NOTE=".chief/state/INTEGRATE-BASE.md"
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
TRACKED="tasks/chief/$name.json"

if [ -n "${CHIEF_TEST_EVIDENCE:-}" ] && [ -f "$NOTE" ]; then
  mkdir -p "$CHIEF_TEST_EVIDENCE"
  cp "$NOTE" "$CHIEF_TEST_EVIDENCE/$name.note.md"
  cp ".chief/state/progress.txt" "$CHIEF_TEST_EVIDENCE/$name.progress.txt" 2>/dev/null || true
fi

if [ "${CHIEF_TEST_MODE:-implement}" = "observe" ]; then exit 0; fi

MODE="${CHIEF_TEST_MODE:-implement}"
ADVANCED=".chief/state/.advanced"                # marker: base was already moved once

resolve=""
case "$MODE" in resolve|advance-conflict) [ -f "$NOTE" ] && resolve=1 ;; esac
if [ -n "$resolve" ]; then
  base="$(sed -n 's/^base: \([^ ]*\) .*/\1/p' "$NOTE" | head -1)"
  git rebase "$base" >/dev/null 2>&1 || true
  n=0
  while [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; do
    n=$((n+1)); [ "$n" -gt 10 ] && { git rebase --abort >/dev/null 2>&1 || true; break; }
    for f in $(git diff --name-only --diff-filter=U); do
      sed -e '/^<<<<<<< /d' -e '/^=======$/d' -e '/^>>>>>>> /d' "$f" > "$f.resolved"
      mv "$f.resolved" "$f"; git add "$f"
    done
    GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 || true
  done
  rm -f "$NOTE"
fi

id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  mkdir -p out; printf 'impl %s\n' "$id" > "out/$id.txt"
  # The branch's side of the mid-run conflict, committed with the first story.
  if [ "$MODE" = "advance-conflict" ] && [ ! -f "$ADVANCED" ]; then
    printf 'the branch edited this line\n' > shared.txt
  fi
  for f in "$PRD" "$TRACKED"; do
    [ -f "$f" ] || continue
    t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id).passes)=true' "$f" > "$t" && mv "$t" "$f"
  done
  git add -A >/dev/null 2>&1 || true
  git commit -q -m "feat: $id - scripted" >/dev/null 2>&1 || true
fi
# A SIBLING MERGE lands on base while this worker is between iterations — exactly
# the window the mid-run integration exists for. Once per run, and only after the
# story commit, so the boundary hook finds a committed branch and a moved base.
case "$MODE" in
  advance|advance-conflict)
    if [ -n "${CHIEF_TEST_BASE_REPO:-}" ] && [ ! -f "$ADVANCED" ]; then
      : > "$ADVANCED"
      ( cd "$CHIEF_TEST_BASE_REPO"
        if [ "$MODE" = "advance-conflict" ]; then
          printf 'a merged sibling edited this line\n' > shared.txt
        else
          printf 'a sibling merged here\n' > sibling-mid.txt
        fi
        git add -A
        git commit -q -m "Merge chief/sibling (chief, auto-verified)" ) >/dev/null 2>&1 || true
    fi ;;
esac

[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── 3. Arm scaffolding ────────────────────────────────────────────────────────
# Each arm gets its own repo (so one arm's merge can't move another's base) with a
# tasklist, a trivially-passing verify hook, and shared.txt — the file the
# conflicting arms make both sides edit.
scaffold() {   # $1 = arm name, $2 = iters, $3 = story count
  local arm="$1" iters="$2" stories="$3" repo="$WORK/$1/repo"
  mkdir -p "$repo"; cd "$repo"
  git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
  git commit -q --allow-empty -m init
  "$CHIEF" init >/dev/null || fail "chief init failed in $arm"
  rm -f tasks/chief/example.json
  printf 'base line\n' > shared.txt
  jq -n --arg b "chief/$arm" --argjson it "$iters" --argjson n "$stories" \
     '{project:"sr",branchName:$b,description:"stale-resume fixture",iters:$it,
       dependsOn:[],touches:[],warmup:[],
       userStories:[range(1;$n+1)|{id:("US-"+(tostring)),title:"story",description:"",
                                   acceptanceCriteria:["out/US-x.txt"],passes:false,notes:""}]}' \
     > "tasks/chief/$arm.json"
  printf '#!/usr/bin/env bash\nset -eu\necho "verify: ok"\nexit 0\n' > .chief/verify.sh
  chmod +x .chief/verify.sh
  git add -A && git commit -q -m "$arm setup"
}

# A prior run's partial branch: real work committed, some stories flipped.
prior_run_branch() {   # $1 = arm, $2… = story ids already done ("" for none)
  local arm="$1"; shift
  git checkout -q -b "chief/$arm" main
  mkdir -p out
  local id
  for id in "$@"; do
    printf 'impl %s\n' "$id" > "out/$id.txt"
    local t; t="$(mktemp)"
    jq --arg id "$id" '(.userStories[]|select(.id==$id).passes)=true' "tasks/chief/$arm.json" > "$t"
    mv "$t" "tasks/chief/$arm.json"
  done
  git add -A && git commit -q -m "feat: prior run work"
  git checkout -q main
}

run_arm() {   # $1 = arm, $2 = CHIEF_TEST_MODE, $3 = HARD_MAX override (optional)
  ARM="$1"
  ( cd "$WORK/$1/repo" && PATH="$WORK/fakebin:$PATH" \
      WT_ROOT="$WORK/$1/wt" CHIEF_TEST_MODE="$2" CHIEF_TEST_EVIDENCE="$WORK/$1/evidence" \
      CHIEF_TEST_BASE_REPO="$WORK/$1/repo" HARD_MAX="${3:-$HARD_MAX}" \
      "$CHIEF" run "$1" ) >"$WORK/$1/run.log" 2>&1 || true
}
worker_log() { cat "$WORK/$1/repo/.chief/state/parallel/$1.log" 2>/dev/null || echo; }
status_of()  { cat "$WORK/$1/repo/.chief/state/parallel/$1.status" 2>/dev/null || echo MISSING; }
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }   # substring, SIGPIPE-safe
count()   { printf '%s\n' "$2" | grep -cF -- "$1" || true; }
line_of() { printf '%s\n' "$2" | grep -nF -m1 -- "$1" | cut -d: -f1; }   # '' when absent
# cd first: --git-path may answer relative to the worktree, not to our cwd.
rebase_in_progress() {
  ( cd "$1" && { [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; } )
}

# ── ARM A — clean drift: rebased at pickup, merges ────────────────────────────
scaffold sr-clean 2 2
prior_run_branch sr-clean US-1
printf 'a sibling merged here\n' > other.txt          # base advances, no file overlap
git add -A && git commit -q -m "Merge chief/sibling (chief, auto-verified)"
run_arm sr-clean implement

log="$(worker_log sr-clean)"
has "rebased chief/sr-clean onto main" "$log" || fail "A: no pickup rebase line in the worker log"
has "1 commit(s) behind" "$log"                || fail "A: the rebase line does not report how far behind the branch was"
has "REBASE-CONFLICT" "$log"                   && fail "A: a cleanly-drifting branch still hit a merge-phase REBASE-CONFLICT"
case "$(status_of sr-clean)" in MERGED*) ;; *) fail "A: expected MERGED, got '$(status_of sr-clean)'" ;; esac
cd "$WORK/sr-clean/repo"; git checkout -q main
[ -f out/US-1.txt ] && [ -f out/US-2.txt ] || fail "A: the resumed branch's work is not on main"
[ -f other.txt ]                           || fail "A: the base commit that advanced main was lost"
[ -f tasks/chief/completed/sr-clean.json ] || fail "A: tasklist not retired"

# ── ARM B — conflicting drift: aborted, noted, handed to the agent ────────────
scaffold sr-conf 1 2
prior_run_branch sr-conf US-1
git checkout -q "chief/sr-conf"
printf 'the branch edited this line\n' > shared.txt
git commit -q -am "feat: branch edits shared.txt"
git checkout -q main
printf 'a merged sibling edited this line\n' > shared.txt     # base moves into the same file
git commit -q -am "Merge chief/sibling (chief, auto-verified)"
branch_tip="$(git rev-parse "chief/sr-conf")"
main_tip="$(git rev-parse main)"
run_arm sr-conf observe

log="$(worker_log sr-conf)"
has "does NOT rebase cleanly" "$log" || fail "B: the worker log does not report the aborted pickup rebase"
NOTE="$WORK/sr-conf/wt/sr-conf/.chief/state/INTEGRATE-BASE.md"
[ -f "$NOTE" ] || fail "B: no INTEGRATE-BASE note in the worktree's chief state dir ($NOTE)"
note="$(cat "$NOTE")"
has "base: main @"     "$note" || fail "B: the note does not name the base branch"
has "1 commit(s) behind" "$note" || fail "B: the note does not report the behind count"
has "shared.txt"       "$note" || fail "B: the note does not list the conflicted file"
# The instruction has to REACH the agent, not merely exist on disk.
ev="$(cat "$WORK/sr-conf/evidence/sr-conf.progress.txt" 2>/dev/null || echo)"
[ -f "$WORK/sr-conf/evidence/sr-conf.note.md" ] || fail "B: the agent never saw the note (no evidence copy)"
has "BASE INTEGRATION REQUIRED" "$ev" || fail "B: the agent's progress.txt carries no integration instruction"
has "before any user story"     "$ev" || fail "B: the instruction does not put integration ahead of story work"
# …and the branch is left EXACTLY as it was: clean, attached, un-rebased.
cd "$WORK/sr-conf/repo"
[ "$(git rev-parse "chief/sr-conf")" = "$branch_tip" ] || fail "B: the branch was rewritten despite the conflict"
[ "$(git rev-parse main)" = "$main_tip" ]              || fail "B: main moved — a conflicted branch was merged"
WT="$WORK/sr-conf/wt/sr-conf"
[ -d "$WT" ] || fail "B: the worktree was torn down instead of being left for the agent"
[ -z "$(git -C "$WT" status --porcelain)" ] || fail "B: the worktree was left dirty by the aborted rebase"
rebase_in_progress "$WT" && fail "B: a rebase was left in progress in the worktree"
[ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" = "chief/sr-conf" ] || fail "B: the worktree is not on the branch"
case "$(status_of sr-conf)" in
  INCOMPLETE*) ;;
  *) fail "B: expected INCOMPLETE (the agent declined the work), got '$(status_of sr-conf)' — a pickup conflict must not fail the tasklist" ;;
esac

# ── ARM C — conflicting drift on an all-pass branch: re-engage, don't skip ────
scaffold sr-pass 2 1
prior_run_branch sr-pass US-1                      # the only story: branch is all-pass
git checkout -q "chief/sr-pass"
printf 'the branch edited this line\n' > shared.txt
git commit -q -am "feat: branch edits shared.txt"
git checkout -q main
printf 'a merged sibling edited this line\n' > shared.txt
git commit -q -am "Merge chief/sibling (chief, auto-verified)"
run_arm sr-pass resolve

log="$(worker_log sr-pass)"
has "all stories already pass" "$log" || fail "C: the fixture is wrong — the branch was not all-pass on pickup"
has "re-engaging the agent to integrate the base" "$log" \
  || fail "C: an un-rebasable all-pass branch was NOT re-engaged — it went straight to a known-conflicting merge phase"
[ -f "$WORK/sr-pass/evidence/sr-pass.note.md" ] || fail "C: the re-engaged agent was not given the note"
case "$(status_of sr-pass)" in MERGED*) ;; *) fail "C: expected MERGED after the agent integrated the base, got '$(status_of sr-pass)'" ;; esac
cd "$WORK/sr-pass/repo"; git checkout -q main
shared="$(cat shared.txt)"
has "the branch edited this line" "$shared"        || fail "C: the branch's side of the conflict was lost"
has "a merged sibling edited this line" "$shared"  || fail "C: the base's side of the conflict was lost"
[ -f tasks/chief/completed/sr-pass.json ]          || fail "C: tasklist not retired after the integrated merge"

# ── ARM D — MID-RUN clean drift: a sibling merge lands between iterations ─────
# A FRESH branch (nothing to integrate at pickup), so every integration line in the
# log necessarily came from the iteration boundary. The scripted agent lands one
# "sibling merge" on main after its first story; the boundary after that iteration
# must re-integrate, and the boundary after the NEXT one — base unmoved — must do
# nothing at all (the throttle).
scaffold sr-mid 3 3
run_arm sr-mid advance 6

log="$(worker_log sr-mid)"
has "Chief Iteration 2" "$log" || fail "D: the fixture is wrong — the agent never reached a second iteration"
has "main advanced to @" "$log" \
  || fail "D: base moved mid-run and the iteration boundary never noticed"
has "rebased chief/sr-mid onto main" "$log" \
  || fail "D: the mid-run drift was detected but the branch was not rebased onto it"
[ "$(count "since the last integration — re-integrating" "$log")" = "1" ] \
  || fail "D: expected exactly ONE mid-run integration (one moved base); got $(count "since the last integration — re-integrating" "$log") — the throttle is not holding"
# Integration has to happen while the AGENT still owns the branch, not after.
i_at="$(line_of "re-integrating" "$log")"; m_at="$(line_of "acquired merge lock" "$log")"
[ -n "$i_at" ] && [ -n "$m_at" ] && [ "$i_at" -lt "$m_at" ] \
  || fail "D: the branch was integrated at/after the merge phase, not at an iteration boundary"
has "REBASE-CONFLICT" "$log" && fail "D: a cleanly-drifting branch still hit a merge-phase REBASE-CONFLICT"
case "$(status_of sr-mid)" in MERGED*) ;; *) fail "D: expected MERGED, got '$(status_of sr-mid)'" ;; esac
cd "$WORK/sr-mid/repo"; git checkout -q main
[ -f out/US-1.txt ] && [ -f out/US-2.txt ] && [ -f out/US-3.txt ] || fail "D: the branch's work is not on main"
[ -f sibling-mid.txt ] || fail "D: the sibling commit that advanced main mid-run was lost"
[ -f tasks/chief/completed/sr-mid.json ] || fail "D: tasklist not retired"

# ── ARM E — MID-RUN conflicting drift: noted, and the NEXT iteration resolves ──
scaffold sr-drift 2 2
run_arm sr-drift advance-conflict 6

log="$(worker_log sr-drift)"
has "main advanced to @" "$log"       || fail "E: the iteration boundary never noticed the sibling merge"
has "does NOT rebase cleanly" "$log"  || fail "E: a conflicting mid-run rebase was not aborted-and-noted"
[ -f "$WORK/sr-drift/evidence/sr-drift.note.md" ] \
  || fail "E: the note never reached the agent (no evidence copy from a later iteration)"
ev="$(cat "$WORK/sr-drift/evidence/sr-drift.progress.txt" 2>/dev/null || echo)"
has "BASE INTEGRATION REQUIRED" "$ev" \
  || fail "E: the mid-run note was written but never injected into the agent's iteration context"
has "REBASE-CONFLICT" "$log" && fail "E: the agent resolved the base merge, yet the merge phase still conflicted"
case "$(status_of sr-drift)" in MERGED*) ;; *) fail "E: expected MERGED after the agent integrated the base, got '$(status_of sr-drift)'" ;; esac
cd "$WORK/sr-drift/repo"; git checkout -q main
shared="$(cat shared.txt)"
has "the branch edited this line" "$shared"       || fail "E: the branch's side of the conflict was lost"
has "a merged sibling edited this line" "$shared" || fail "E: the base's side of the conflict was lost"
[ -f tasks/chief/completed/sr-drift.json ]        || fail "E: tasklist not retired after the integrated merge"

ARM=""
echo "STALE-RESUME PASS — clean drift rebased at pickup and merged; a conflicting one was aborted, noted and handed to the agent (branch untouched, tasklist not failed); an all-pass branch was re-engaged instead of walking into the merge phase; a mid-run sibling merge was re-integrated at the iteration boundary (once per moved base) and a conflicting one was handed to the next iteration"
