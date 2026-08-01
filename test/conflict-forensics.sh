#!/usr/bin/env bash
# test/conflict-forensics.sh — MERGE-PHASE CONFLICT FORENSICS (tasklist 70, US-3).
#
# Pickup-time and mid-run integration (US-1/US-2) remove most base drift, but the
# merge phase's rebase is still the floor and it can still stop — most plausibly
# when a sibling merges during the agent's LAST iteration, after which there is no
# iteration boundary left to integrate at. What used to happen then was a single
# line, "left for manual merge": no conflicted files, no hint of WHICH merged
# sibling collided, and a human re-deriving all of it by hand.
#
# This drives that exact race against a real driver with a scripted fake `claude`:
#
#   1. CONFLICT  — the agent finishes its only story (editing shared.txt) and, in
#                  the SAME turn, a sibling tasklist merges into main over the same
#                  file. The agent emits COMPLETE, so agent.sh exits before the
#                  iteration-boundary hook and the drift reaches the merge phase.
#                  Asserted: a $SNAP/<name>.rebase-conflict.md report naming the
#                  conflicted file, the base tip, the merge-base and the colliding
#                  sibling BY TASKLIST NAME; a worker log line and a .status file
#                  that point at it; and an unchanged REBASE-CONFLICT status VALUE.
#   2. CLEARED   — the same tasklist is re-run, the agent integrates the base as
#                  ordinary work, and the merge succeeds: the now-stale report must
#                  be gone (the <name>.verify-failed.log precedent).
#
# The MERGE-CONFLICT arm writes the same report through the same conflict_report()
# call — it is not separately drivable here, because after a clean rebase the
# --no-ff merge cannot conflict while the merge lock is held.
#
# Installs the COMMITTED state of this checkout (install.sh git-clones) — commit
# engine changes before trusting a green run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=cf GIT_AUTHOR_EMAIL=cf@test GIT_COMMITTER_NAME=cf GIT_COMMITTER_EMAIL=cf@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"     # hermetic: never touch ~/.chief
export STALL_LIMIT=1 HARD_MAX=3
NAME=cf-collide
REPO="$WORK/repo"
fail() {
  echo "CONFLICT-FORENSICS FAIL: $*" >&2
  [ -f "$WORK/run1.log" ] && { echo "--- run1.log"; tail -30 "$WORK/run1.log"; } >&2
  [ -f "$REPO/.chief/state/parallel/$NAME.log" ] \
    && { echo "--- worker log"; tail -60 "$REPO/.chief/state/parallel/$NAME.log"; } >&2
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
# collide — implement the story over shared.txt and then land a REAL sibling merge
#           ("Merge chief/<sibling> (chief, auto-verified)", --no-ff, over the same
#           file) on base, all inside one turn, then report COMPLETE. The completion
#           token makes agent.sh exit BEFORE its iteration-boundary hook, which is
#           what lets the drift survive to the merge phase.
# resolve — do what the INTEGRATE-BASE note asks (rebase, resolve keeping both
#           sides, continue) and then finish the loop. Never rewrites shared.txt:
#           that would throw away the resolution it just made.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null                                   # drain the prompt on stdin
PRD=".chief/state/prd.json"                      # cwd = the worktree (set by the driver)
NOTE=".chief/state/INTEGRATE-BASE.md"
MODE="${CHIEF_TEST_MODE:-collide}"
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
TRACKED="tasks/chief/$name.json"
ADVANCED=".chief/state/.advanced"                # marker: the sibling already merged

if [ "$MODE" = resolve ] && [ -f "$NOTE" ]; then
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
  [ "$MODE" = collide ] && printf 'the branch edited this line\n' > shared.txt
  for f in "$PRD" "$TRACKED"; do
    [ -f "$f" ] || continue
    t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id).passes)=true' "$f" > "$t" && mv "$t" "$f"
  done
  git add -A >/dev/null 2>&1 || true
  git commit -q -m "feat: $id - scripted" >/dev/null 2>&1 || true
fi

# The sibling tasklist merges into base over the same file — once per run, and only
# after the branch's own commit exists.
if [ "$MODE" = collide ] && [ -n "${CHIEF_TEST_BASE_REPO:-}" ] && [ ! -f "$ADVANCED" ]; then
  : > "$ADVANCED"
  ( cd "$CHIEF_TEST_BASE_REPO"
    git checkout -q -b "chief/$CHIEF_TEST_SIBLING" main
    printf 'a merged sibling edited this line\n' > shared.txt
    git commit -q -am "feat: [US-1] - sibling rewrites shared.txt"
    git checkout -q main
    git merge -q --no-ff "chief/$CHIEF_TEST_SIBLING" \
      -m "Merge chief/$CHIEF_TEST_SIBLING (chief, auto-verified)" ) >/dev/null 2>&1 || true
fi

[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── 3. The fixture ────────────────────────────────────────────────────────────
SIBLING=cf-sibling
mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null || fail "chief init failed"
rm -f tasks/chief/example.json
printf 'base line\n' > shared.txt
jq -n --arg b "chief/$NAME" \
   '{project:"cf",branchName:$b,description:"conflict-forensics fixture",iters:2,
     dependsOn:[],touches:[],warmup:[],
     userStories:[{id:"US-1",title:"story",description:"",
                   acceptanceCriteria:["out/US-1.txt"],passes:false,notes:""}]}' \
   > "tasks/chief/$NAME.json"
printf '#!/usr/bin/env bash\nset -eu\necho "verify: ok"\nexit 0\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "fixture"

run_chief() {   # $1 = CHIEF_TEST_MODE, $2 = log file
  ( cd "$REPO" && PATH="$WORK/fakebin:$PATH" \
      WT_ROOT="$WORK/wt" CHIEF_TEST_MODE="$1" CHIEF_TEST_SIBLING="$SIBLING" \
      CHIEF_TEST_BASE_REPO="$REPO" \
      "$CHIEF" run "$NAME" ) >"$2" 2>&1 || true
}
worker_log() { cat "$REPO/.chief/state/parallel/$NAME.log" 2>/dev/null || echo; }
status_of()  { cat "$REPO/.chief/state/parallel/$NAME.status" 2>/dev/null || echo MISSING; }
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }   # substring, SIGPIPE-safe

# ── RUN 1 — the collision reaches the merge phase, and is explained ───────────
run_chief collide "$WORK/run1.log"

REPORT="$REPO/.chief/state/snapshots/$NAME.rebase-conflict.md"
log="$(worker_log)"
status="$(status_of)"
case "$status" in
  REBASE-CONFLICT*) ;;
  *) fail "the fixture did not produce a merge-phase rebase conflict (status '$status') — the collision never reached the merge phase" ;;
esac
# The status VALUE is what the app's recovery table matches on: the first token
# must still be exactly REBASE-CONFLICT, with the report as a trailing pointer.
[ "$(printf '%s' "$status" | awk '{print $1}')" = "REBASE-CONFLICT" ] \
  || fail "the REBASE-CONFLICT status value changed — the app's status parsing keys off the first token ('$status')"
has ".chief/state/snapshots/$NAME.rebase-conflict.md" "$status" \
  || fail "the .status file does not point at the conflict report ('$status')"
has ".chief/state/snapshots/$NAME.rebase-conflict.md" "$log" \
  || fail "the worker log's failure line does not point at the conflict report"

[ -f "$REPORT" ] || fail "no conflict report at $REPORT"
report="$(cat "$REPORT")"
cd "$REPO"
base_tip="$(git rev-parse --short main)"
has "shared.txt" "$report"      || fail "the report does not name the conflicted file"
has "## Conflicted files" "$report" || fail "the report has no conflicted-files section"
has "base: \`main\` @$base_tip" "$report" \
  || fail "the report does not record the base tip sha (@$base_tip)"
has "merge-base: @" "$report"   || fail "the report does not record the branch's merge-base"
# The attribution — the point of the whole story: WHICH sibling collided.
has "chief auto-merge of sibling tasklist \`$SIBLING\`" "$report" \
  || fail "the report does not attribute the colliding base commit to the sibling tasklist '$SIBLING'"
has "sibling rewrites shared.txt" "$report" \
  || fail "the report does not list the sibling's own commit under the conflicted file"
has "## Likely collider" "$report" || fail "the report has no collider summary"
has "touches" "$report" || fail "the collider summary does not suggest a touches/dependsOn fix"

# Nothing merged, and the branch is exactly as the agent left it.
[ -z "$(git status --porcelain)" ] || fail "the work repo was left dirty by the aborted rebase"
has "scripted" "$(git log --oneline main)" && fail "a conflicting branch was merged into main"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail "the work repo was not restored to main"

# ── RUN 2 — the tasklist merges later: the stale report is cleared ────────────
run_chief resolve "$WORK/run2.log"

status="$(status_of)"
case "$status" in MERGED*) ;; *) fail "run 2: expected MERGED after the agent integrated the base, got '$status'" ;; esac
[ -f "$REPORT" ] && fail "the conflict report survived a successful merge — a stale report is worse than none"
[ -f "$REPO/tasks/chief/completed/$NAME.json" ] || fail "run 2: tasklist not retired"

echo "CONFLICT-FORENSICS PASS — a merge-phase rebase conflict wrote a report naming the conflicted file, the base tip, the merge-base and the colliding sibling tasklist; the worker log and .status point at it (status value unchanged); a later successful merge cleared it"
