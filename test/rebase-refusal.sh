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
#               3. REFUSED  the agent leaves uncommitted tracked work in the WORK
#                           repo, so git declines with zero unmerged paths: the
#                           distinct REBASE-REFUSED state, its own note naming the
#                           cause and the command that clears it, and no conflict
#                           report anywhere near it.
#
# Order matters: REFUSED runs last because it leaves the work repo dirty on
# purpose, and `chief run` refuses to start on a dirty base repo.
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
#   refuse  — leave uncommitted TRACKED work in the WORK repo, the way a crashed
#             tool or an operator's stray edit does. git declines to rebase there,
#             with zero unmerged paths — the whole point of the distinction.
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
      printf 'an operator was editing this\n' >> "$CHIEF_TEST_BASE_REPO/dirt.txt" ;;
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
printf 'a tracked file no branch touches\n' > dirt.txt
for n in rr-ahead rr-conflict rr-refuse; do
  jq -n --arg b "chief/$n" \
     '{project:"rr",branchName:$b,description:"rebase-refusal fixture",iters:2,
       dependsOn:[],touches:[],warmup:[],
       userStories:[{id:"US-1",title:"story",description:"",
                     acceptanceCriteria:["out/<name>-US-1.txt"],passes:false,notes:""}]}' \
     > "tasks/chief/$n.json"
done
printf '#!/usr/bin/env bash\nset -eu\necho "verify: ok"\nexit 0\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "fixture"

run_chief() {   # $1 = tasklist name, $2 = CHIEF_TEST_MODE
  CUR="$1"
  ( cd "$REPO" && PATH="$WORK/fakebin:$PATH" \
      WT_ROOT="$WORK/wt" CHIEF_TEST_MODE="$2" CHIEF_TEST_SIBLING="$SIBLING" \
      CHIEF_TEST_BASE_REPO="$REPO" \
      "$CHIEF" run "$1" ) >"$WORK/$1.log" 2>&1 || true
}
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

# ── 3. REFUSED — dirty work repo, ZERO unmerged paths: NOT a conflict ─────────
run_chief rr-refuse refuse
status="$(status_of rr-refuse)"
[ "$(token_of rr-refuse)" = "REBASE-REFUSED" ] \
  || fail "a rebase refused by a dirty work repo must report its own state, not a conflict — got '$status'"
has "uncommitted" "$status" || fail "the REBASE-REFUSED status does not name the cause ('$status')"
has ".chief/state/snapshots/rr-refuse.rebase-refused.md" "$status" \
  || fail "the .status file does not point at the refusal note ('$status')"
[ -f "$SNAP/rr-refuse.rebase-conflict.md" ] && fail "a REFUSED rebase wrote a CONFLICT report — it has no conflicted files to resolve"
note="$(cat "$SNAP/rr-refuse.rebase-refused.md" 2>/dev/null || echo)"
[ -n "$note" ] || fail "a refused rebase wrote no $SNAP/rr-refuse.rebase-refused.md"
has "not a merge conflict" "$note" || fail "the refusal note does not deny the conflict"
has "ZERO unmerged paths" "$note"  || fail "the refusal note does not say WHY it is not a conflict"
has "uncommitted" "$note"          || fail "the refusal note does not name the cause"
has "dirt.txt" "$note"             || fail "the refusal note does not show the work repo's dirty state"
has "git stash" "$note"            || fail "the refusal note does not give the command that clears this cause"
has "chief run rr-refuse" "$note"  || fail "the refusal note does not say how to pick the tasklist back up"
log="$(worker_log rr-refuse)"
has "NOT a content conflict" "$log" || fail "the worker log calls a refusal a conflict"
has "rr-refuse.rebase-refused.md" "$log" || fail "the worker log does not point at the refusal note"
# Nothing merged, and the branch is exactly as the agent left it.
has "scripted (refuse)" "$(git -C "$REPO" log --oneline main)" && fail "a refused branch was merged into main"
has "scripted (refuse)" "$(git -C "$REPO" log --oneline chief/rr-refuse)" \
  || fail "the refused branch lost the agent's commit"
[ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" = main ] || fail "the work repo was not restored to main"
[ -f "$REPO/tasks/chief/completed/rr-refuse.json" ] && fail "a refused tasklist was retired as if it had merged"
git -C "$REPO" checkout -q -- dirt.txt                        # release the fixture's dirt

echo "REBASE-REFUSAL PASS — a strictly-ahead branch merges with no rebase at all; a real content conflict is still REBASE-CONFLICT naming its files; a rebase refused by a dirty work repo is REBASE-REFUSED with its own cause-and-fix note, and never a conflict"
