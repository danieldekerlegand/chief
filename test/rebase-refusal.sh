#!/usr/bin/env bash
# test/rebase-refusal.sh — REFUSED rebase vs REAL content conflict (tasklist 78, US-3).
#
# The merge phase used to read ANY non-zero `git rebase` exit as a content
# collision. It is not one: git also REFUSES to rebase a dirty repo, one left
# mid-rebase/merge, or one it will not open at all — and every one of those leaves
# ZERO unmerged paths, so the report read "## Conflicted files: (git reported
# none)". That is the field incident this pins: three branches strictly AHEAD of
# main (base an ancestor → the rebase is a provable no-op) all parked as
# REBASE-CONFLICT, blocking merges that had nothing to merge.
#
# Tasklist 93 (US-1) added the accounting half: a refusal is not just labelled
# correctly, it is not RE-DISPATCHED. Re-running an agent cannot clean an operator's
# working tree, so the two extra attempts a retryable status buys are knowably doomed
# before they are spent — observed in the field as two finished tasklists each burning
# 3/3 attempts to re-refuse over one uncommitted line.
#
# Two layers, cheapest first:
#
#   A. UNIT   — rebase_refusal_cause() is lifted straight out of engine/driver.sh
#               and asked about a clean repo (silence = "go ahead and rebase"), a
#               dirty one, a leftover rebase-merge, a leftover MERGE_HEAD, and a
#               path that is not a repo at all.
#   B. DRIVER — three real runs against a scripted fake `claude`, one per outcome:
#               1. AHEAD    the branch is strictly ahead of an unmoved main: the
#                           rebase is skipped, and it merges. Neither report exists.
#               2. CONFLICT a sibling merges over the same file mid-turn: still
#                           REBASE-CONFLICT, still naming the conflicted file (the
#                           real-conflict path must not regress).
#               3. REFUSED  the agent leaves a REBASE in progress (a stray rebase-merge
#                           directory) in the WORK repo, so git declines with zero
#                           unmerged paths:
#                           the distinct REBASE-REFUSED state, its own note naming the
#                           cause and the command that clears it, and no conflict
#                           report anywhere near it. Scheduled WITH a dependent, and
#                           asserted on ATTEMPTS as well as labels: exactly one agent
#                           run (vs. RETRY_MAX for the real conflict above), a summary
#                           that names the precondition and the fix instead of
#                           "exhausted its retries", and a dependency cascade that did
#                           not change shape.
#
# NOT covered here any more, on purpose: a work repo carrying plain UNCOMMITTED
# TRACKED CHANGES. That used to be this file's refusal scenario, and as of tasklist 93
# (US-2) it is no longer a refusal at all — the merge phase parks the operator's work
# in the stash for the length of its critical section and gives it back on the way out.
# test/dirty-checkout.sh owns that case now, including the data-safety half.
#
# Order matters: REFUSED runs last because it leaves a rebase in progress in the work
# repo on purpose, and nothing after it should have to reason about that.
#
# Installs the COMMITTED state of this checkout (install.sh git-clones) — commit
# engine changes before trusting a green run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=rr GIT_AUTHOR_EMAIL=rr@test GIT_COMMITTER_NAME=rr GIT_COMMITTER_EMAIL=rr@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"     # hermetic: never touch ~/.chief
export STALL_LIMIT=1 HARD_MAX=3
REPO="$WORK/repo"
CUR=""                                                        # scenario under test, for fail()
fail() {
  echo "REBASE-REFUSAL FAIL: $*" >&2
  [ -n "$CUR" ] && [ -f "$WORK/$CUR.log" ] && { echo "--- $CUR.log"; tail -30 "$WORK/$CUR.log"; } >&2
  [ -n "$CUR" ] && [ -f "$REPO/.chief/state/parallel/$CUR.log" ] \
    && { echo "--- worker log"; tail -60 "$REPO/.chief/state/parallel/$CUR.log"; } >&2
  exit 1
}
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }   # substring, SIGPIPE-safe
command -v jq  >/dev/null || fail "jq is required"
command -v git >/dev/null || fail "git is required"

# ── A. UNIT — rebase_refusal_cause() names the cause, or stays silent ─────────
# Lifted from the engine itself, so the assertions cannot drift from the shipped
# function. It is self-contained (a subshell `cd` + git), which is what makes this
# possible at all.
eval "$(awk '/^rebase_refusal_cause\(\) \{/,/^}/' "$ROOT/engine/driver.sh")"
[ "$(type -t rebase_refusal_cause)" = function ] \
  || fail "could not lift rebase_refusal_cause() out of engine/driver.sh — did it get renamed?"

U="$WORK/unit"; mkdir -p "$U"; ( cd "$U"
  git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
  printf 'one\n' > f.txt; git add -A; git commit -q -m init ) >/dev/null

cause="$(rebase_refusal_cause "$U")"
[ -z "$cause" ] || fail "unit: a clean repo must report NO refusal cause (rebase may proceed), got '$cause'"

printf 'edited\n' > "$U/f.txt"
cause="$(rebase_refusal_cause "$U")"
has "uncommitted" "$cause" || fail "unit: a dirty repo must be named as uncommitted work, got '$cause'"
git -C "$U" checkout -q -- f.txt

printf 'untracked\n' > "$U/stray.txt"
cause="$(rebase_refusal_cause "$U")"
[ -z "$cause" ] || fail "unit: an UNTRACKED file does not stop a rebase and must not be reported, got '$cause'"
rm -f "$U/stray.txt"

mkdir -p "$U/.git/rebase-merge"
cause="$(rebase_refusal_cause "$U")"
has "rebase" "$cause" || fail "unit: a leftover rebase-merge must be named, got '$cause'"
has "abort"  "$cause" || fail "unit: a leftover rebase-merge must say how to clear it, got '$cause'"
rmdir "$U/.git/rebase-merge"

git -C "$U" rev-parse HEAD > "$U/.git/MERGE_HEAD"
cause="$(rebase_refusal_cause "$U")"
has "merge" "$cause" || fail "unit: a leftover MERGE_HEAD must be named, got '$cause'"
rm -f "$U/.git/MERGE_HEAD"

cause="$(rebase_refusal_cause "$WORK/not-a-repo-at-all")"
[ -n "$cause" ] || fail "unit: a path that is not a repo must produce a cause, not silence"

# ── B. DRIVER — install chief from THIS checkout ──────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install.sh failed"
CHIEF="$BIN/chief"

# ── The scripted agent ────────────────────────────────────────────────────────
# Every mode implements the one story and commits it. What each does EXTRA, once
# per run and only after that commit exists, is the scenario:
#   ahead   — nothing. Base never moves, so the branch is strictly ahead of it.
#   collide — land a REAL sibling merge on base over the same file (a genuine
#             content conflict for the merge-phase rebase to hit).
#   refuse  — leave a REBASE IN PROGRESS in the WORK repo (a stray rebase-merge
#             directory), the way a crashed tool or an abandoned `git rebase` does.
#             git declines to rebase there, with zero unmerged paths — the point of
#             the distinction. A stray MERGE_HEAD would NOT do: `git checkout` clears
#             merge state on its way past, and the merge phase checks the branch out
#             before it asks whether a rebase can start.
#             (Plain uncommitted work is deliberately NOT used: since tasklist 93 the
#             merge phase parks that and merges anyway — see test/dirty-checkout.sh.)
# COMPLETE in the same turn makes agent.sh exit before its iteration-boundary
# hook, which is what lets the drift/dirt survive to the merge phase.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null                                   # drain the prompt on stdin
PRD=".chief/state/prd.json"                      # cwd = the worktree (set by the driver)
MODE="${CHIEF_TEST_MODE:-ahead}"
ONCE=".chief/state/.rr-scenario-done"
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
TRACKED="tasks/chief/$name.json"

# One line per invocation, in a directory OUTSIDE the worktree (which the driver
# rm -rf's at the top of every attempt). This is what makes "how many agent runs did
# that failure cost?" answerable at all.
if [ -n "${CHIEF_TEST_RUNS_DIR:-}" ]; then
  mkdir -p "$CHIEF_TEST_RUNS_DIR"; echo "turn" >> "$CHIEF_TEST_RUNS_DIR/$name"
fi

id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  # Per-TASKLIST path: an artifact shared with an already-merged scenario would
  # commit no diff, and the false-complete guard would (rightly) refuse to merge.
  mkdir -p out; printf 'impl %s\n' "$id" > "out/$name-$id.txt"
  if [ "$MODE" = collide ]; then printf 'the branch edited this line\n' > shared.txt; fi
  for f in "$PRD" "$TRACKED"; do
    [ -f "$f" ] || continue
    t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id).passes)=true' "$f" > "$t" && mv "$t" "$f"
  done
  git add -A >/dev/null 2>&1 || true
  git commit -q -m "feat: $id - scripted ($MODE)" >/dev/null 2>&1 || true
fi

if [ ! -f "$ONCE" ] && [ -n "${CHIEF_TEST_BASE_REPO:-}" ] && [ -n "${id:-}" ]; then
  : > "$ONCE"
  case "$MODE" in
    collide)
      ( cd "$CHIEF_TEST_BASE_REPO"
        git checkout -q -b "chief/$CHIEF_TEST_SIBLING" main
        printf 'a merged sibling edited this line\n' > shared.txt
        git commit -q -am "feat: [US-1] - sibling rewrites shared.txt"
        git checkout -q main
        git merge -q --no-ff "chief/$CHIEF_TEST_SIBLING" \
          -m "Merge chief/$CHIEF_TEST_SIBLING (chief, auto-verified)" ) >/dev/null 2>&1 || true ;;
    refuse)
      mkdir -p "$CHIEF_TEST_BASE_REPO/.git/rebase-merge" 2>/dev/null || true ;;
  esac
fi

[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── The fixture — one repo, one tasklist per scenario ─────────────────────────
SIBLING=rr-sibling
mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null || fail "chief init failed"
rm -f tasks/chief/example.json
printf 'base line\n' > shared.txt
for n in rr-ahead rr-conflict rr-refuse; do
  jq -n --arg b "chief/$n" \
     '{project:"rr",branchName:$b,description:"rebase-refusal fixture",iters:2,
       dependsOn:[],touches:[],warmup:[],
       userStories:[{id:"US-1",title:"story",description:"",
                     acceptanceCriteria:["out/<name>-US-1.txt"],passes:false,notes:""}]}' \
     > "tasks/chief/$n.json"
done
# A dependent of the REFUSED tasklist. Excluding a refusal from the retry allowlist
# changes what is RE-DISPATCHED and nothing else — the dependency cascade below must
# read exactly as it did when the refusal was (uselessly) retried three times first.
jq -n '{project:"rr",branchName:"chief/rr-refuse-dep",description:"blocked-by-a-refusal probe",
        iters:2,dependsOn:["rr-refuse"],touches:[],warmup:[],
        userStories:[{id:"US-1",title:"story",description:"",
                      acceptanceCriteria:["out/rr-refuse-dep-US-1.txt"],passes:false,notes:""}]}' \
   > tasks/chief/rr-refuse-dep.json
printf '#!/usr/bin/env bash\nset -eu\necho "verify: ok"\nexit 0\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "fixture"

run_chief() {   # $1 = tasklist name (also the log name), $2 = CHIEF_TEST_MODE, $3.. = extra names to schedule
  CUR="$1"; nm="$1"; mode="$2"; shift 2
  # RETRY_MAX is pinned rather than inherited so the attempt assertions below state a
  # number this test controls, not whatever the driver's default happens to be.
  ( cd "$REPO" && PATH="$WORK/fakebin:$PATH" \
      WT_ROOT="$WORK/wt" CHIEF_TEST_MODE="$mode" CHIEF_TEST_SIBLING="$SIBLING" \
      CHIEF_TEST_BASE_REPO="$REPO" CHIEF_TEST_RUNS_DIR="$WORK/agentruns" RETRY_MAX=3 \
      "$CHIEF" run "$nm" "$@" ) >"$WORK/$nm.log" 2>&1 || true
}
run_log()    { cat "$WORK/$1.log" 2>/dev/null || echo; }
attempts_of(){ cat "$REPO/.chief/state/parallel/$1.attempts" 2>/dev/null || echo 1; }
turns_of()   { local f="$WORK/agentruns/$1"; [ -f "$f" ] && wc -l < "$f" | tr -d ' ' || echo 0; }
worker_log() { cat "$REPO/.chief/state/parallel/$1.log" 2>/dev/null || echo; }
status_of()  { cat "$REPO/.chief/state/parallel/$1.status" 2>/dev/null || echo MISSING; }
token_of()   { status_of "$1" | awk '{print $1}'; }
SNAP="$REPO/.chief/state/snapshots"

# ── 1. STRICTLY AHEAD — base is an ancestor: no conflict, no refusal, a merge ──
# The field case. A rebase here is a provable no-op, so the engine does not even
# ask git — the one place an environment fault used to turn a no-op into a bogus
# REBASE-CONFLICT.
run_chief rr-ahead ahead
status="$(status_of rr-ahead)"
case "$status" in
  MERGED*) ;;
  *) fail "a strictly-ahead branch must merge, got '$status' — the no-op rebase was reported as a failure" ;;
esac
[ -f "$SNAP/rr-ahead.rebase-conflict.md" ] && fail "a strictly-ahead branch wrote a CONFLICT report — this is the exact field bug"
[ -f "$SNAP/rr-ahead.rebase-refused.md" ] && fail "a strictly-ahead branch wrote a REFUSAL report — nothing refused anything"
has "strictly ahead" "$(worker_log rr-ahead)" \
  || fail "the worker log does not record that the rebase was skipped as a no-op"
has "scripted (ahead)" "$(git -C "$REPO" log --oneline main)" || fail "the strictly-ahead branch never reached main"
[ -f "$REPO/tasks/chief/completed/rr-ahead.json" ] || fail "the strictly-ahead tasklist was not retired"

# ── 2. REAL CONTENT CONFLICT — unchanged: REBASE-CONFLICT + the conflicted file ─
run_chief rr-conflict collide
status="$(status_of rr-conflict)"
[ "$(token_of rr-conflict)" = "REBASE-CONFLICT" ] \
  || fail "a REAL content conflict must still report REBASE-CONFLICT (first token) — got '$status'"
report="$(cat "$SNAP/rr-conflict.rebase-conflict.md" 2>/dev/null || echo)"
[ -n "$report" ] || fail "a real content conflict wrote no $SNAP/rr-conflict.rebase-conflict.md"
has "shared.txt" "$report" || fail "the conflict report does not name the conflicted file"
has "## Conflicted files" "$report" || fail "the conflict report has no conflicted-files section"
has "git reported none" "$report" && fail "a REAL conflict reported no conflicted files — the index was read after the abort"
[ -f "$SNAP/rr-conflict.rebase-refused.md" ] && fail "a real content conflict also wrote a REFUSAL note — the two arms must be exclusive"
has "scripted (collide)" "$(git -C "$REPO" log --oneline main)" && fail "a conflicting branch was merged into main"
[ -z "$(git -C "$REPO" status --porcelain)" ] || fail "the work repo was left dirty by the aborted rebase"
# ATTEMPT ACCOUNTING (tasklist 93, US-1) — the retryable half of the pair. A content
# collision decays as the base moves and chief's pickup path re-engages the agent to
# integrate it, so it is worth RETRY_MAX attempts and must keep spending them.
[ "$(attempts_of rr-conflict)" = 3 ] \
  || fail "a real content conflict took $(attempts_of rr-conflict) attempt(s), want 3 (RETRY_MAX) — the retry allowlist stopped covering it"
has "↻ retrying rr-conflict (attempt 2/3)" "$(run_log rr-conflict)" \
  || fail "a real content conflict was not re-dispatched to the agent"
has "exhausted its retries (3/3)" "$(run_log rr-conflict)" \
  || fail "the conflict's retry budget was not reported as spent"

# ── 3. REFUSED — a merge left in progress, ZERO unmerged paths: NOT a conflict ─
run_chief rr-refuse refuse rr-refuse-dep
status="$(status_of rr-refuse)"
[ "$(token_of rr-refuse)" = "REBASE-REFUSED" ] \
  || fail "a rebase refused by a half-operated-on work repo must report its own state, not a conflict — got '$status'"
has "rebase-merge" "$status" || fail "the REBASE-REFUSED status does not name the cause ('$status')"
has ".chief/state/snapshots/rr-refuse.rebase-refused.md" "$status" \
  || fail "the .status file does not point at the refusal note ('$status')"
[ -f "$SNAP/rr-refuse.rebase-conflict.md" ] && fail "a REFUSED rebase wrote a CONFLICT report — it has no conflicted files to resolve"
note="$(cat "$SNAP/rr-refuse.rebase-refused.md" 2>/dev/null || echo)"
[ -n "$note" ] || fail "a refused rebase wrote no $SNAP/rr-refuse.rebase-refused.md"
has "not a merge conflict" "$note"  || fail "the refusal note does not deny the conflict"
has "ZERO unmerged paths" "$note"   || fail "the refusal note does not say WHY it is not a conflict"
has "rebase-merge" "$note"          || fail "the refusal note does not name the cause"
has "git rebase --abort" "$note"    || fail "the refusal note does not give the command that clears THIS cause"
has "chief run rr-refuse" "$note"   || fail "the refusal note does not say how to pick the tasklist back up"
log="$(worker_log rr-refuse)"
has "NOT a content conflict" "$log" || fail "the worker log calls a refusal a conflict"
has "rr-refuse.rebase-refused.md" "$log" || fail "the worker log does not point at the refusal note"
# Nothing merged, and the branch is exactly as the agent left it.
has "scripted (refuse)" "$(git -C "$REPO" log --oneline main)" && fail "a refused branch was merged into main"
has "scripted (refuse)" "$(git -C "$REPO" log --oneline chief/rr-refuse)" \
  || fail "the refused branch lost the agent's commit"
[ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" = main ] || fail "the work repo was not restored to main"
[ -f "$REPO/tasks/chief/completed/rr-refuse.json" ] && fail "a refused tasklist was retired as if it had merged"

# ── 4. ATTEMPT ACCOUNTING (tasklist 93, US-1) — a refusal costs ONE agent run ──
# The field incident: two tasklists that had already finished every story failed to
# merge over one uncommitted line in the operator's checkout, were classified as
# something a retry could fix, and each burned 3/3 attempts to re-refuse identically —
# six agent iterations for work that was already done. Re-running an agent cannot
# clean someone else's working tree, so the second and third attempts were knowably
# doomed before they were dispatched.
rrun="$(run_log rr-refuse)"
[ "$(attempts_of rr-refuse)" = 1 ] \
  || fail "a REFUSED rebase took $(attempts_of rr-refuse) attempt(s), want exactly 1 — a refusal is being retried again"
[ "$(turns_of rr-refuse)" = 1 ] \
  || fail "the agent ran $(turns_of rr-refuse) time(s) for a refused rebase, want exactly 1 — retries are being spent on a precondition no agent can change"
has "↻ retrying rr-refuse" "$rrun" && fail "a refused rebase was re-dispatched to the agent"
has "rr-refuse exhausted its retries" "$rrun" \
  && fail "a refusal reported 'exhausted its retries', which reads as a hard problem with the WORK rather than a precondition in the repo"
# The summary names the precondition and the operator's move, not just a red line.
has "git REFUSED to rebase" "$rrun" || fail "the run summary does not separate a refusal from the other failures"
has "NOT retried" "$rrun"           || fail "the run summary does not say that not retrying was the decision"
has "rebase-merge" "$rrun"          || fail "the run summary does not name the precondition (the half-finished git operation)"
has "chief run rr-refuse" "$rrun"   || fail "the run summary does not give the operator's move"
has "rr-refuse.rebase-refused.md" "$rrun" || fail "the run summary does not point at the cause-and-fix note"

# ── 5. The dependency cascade is UNCHANGED — this story retries less, nothing more ─
[ "$(cat "$REPO/.chief/state/parallel/rr-refuse-dep.state" 2>/dev/null || echo '?')" = blocked ] \
  || fail "the dependent of a refused tasklist is not BLOCKED"
has "⤬ rr-refuse-dep BLOCKED" "$rrun" || fail "the BLOCKED announcement changed shape"
has 'needs "rr-refuse", which FAILED in this run' "$rrun" \
  || fail "the dependent's reason no longer names the refused tasklist the way it always did"
[ "$(turns_of rr-refuse-dep)" = 0 ] || fail "a blocked dependent still ran its agent"

rm -rf "$REPO/.git/rebase-merge"                              # release the fixture's stuck rebase

echo "REBASE-REFUSAL PASS — a strictly-ahead branch merges with no rebase at all; a real content conflict is still REBASE-CONFLICT naming its files and still spends all 3 attempts; a rebase refused by a half-operated-on work repo is REBASE-REFUSED with its own cause-and-fix note, never a conflict, and costs exactly ONE agent run while its dependents block as they always did"
