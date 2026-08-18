#!/usr/bin/env bash
# test/dirty-checkout.sh — the merge phase no longer requires a clean operator
# checkout, and never loses what it borrowed (tasklist 93, US-2).
#
# THE FIELD FAILURE. `chief run` checks the working tree ONCE, at startup, and
# nothing re-checks it. But the merge phase does its rebase → verify → merge IN the
# operator's own checkout, so a single uncommitted line typed while the run was in
# flight — in a file no branch touches — made `git rebase` refuse, parked the
# tasklist, and blocked its dependents. Observed twice in one afternoon: two
# tasklists that had finished every story, each failing to merge over one modified
# tracked file. The gate could not protect the merge it existed to protect.
#
# THE FIX, and what this pins. The merge phase PARKS the operator's uncommitted
# tracked work in git's own stash for the length of its critical section and gives it
# back on the way out. Three properties have to hold, and each is a section below:
#
#   A. UNIT   — merge_stash_push/merge_stash_pop are lifted straight out of
#               engine/driver.sh (the same trick test/rebase-refusal.sh uses on
#               rebase_refusal_cause, and for the same reason: the assertions cannot
#               drift from the shipped functions). Round-trip, staged state, the
#               no-op arms a trap depends on, entry selection BY SHA when the
#               operator has stashes of their own, and — the one that matters —
#               a replay that conflicts DROPS NOTHING.
#   B. MERGE  — the field case end to end: a real run whose work repo goes dirty
#               mid-flight merges anyway, and the operator's edit is byte-identical
#               afterwards. The fixture's verify hook FAILS if it can see the
#               operator's marker, which is what pins the honesty of the gate — and
#               is exactly why `git rebase --autostash` was not the fix: autostash
#               pops before verify runs, so the gate would be measuring the branch
#               plus someone's half-finished edit.
#   C. KILL   — the driver is SIGKILLed mid-critical-section, with the operator's
#               work parked and no trap left to run. The work must still be there,
#               and the next run must hand it back on its own.
#
# Installs the COMMITTED state of this checkout (install.sh git-clones) — commit
# engine changes before trusting a green run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=dc GIT_AUTHOR_EMAIL=dc@test GIT_COMMITTER_NAME=dc GIT_COMMITTER_EMAIL=dc@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"     # hermetic: never touch ~/.chief
export STALL_LIMIT=1 HARD_MAX=3
REPO="$WORK/repo"
CUR=""
fail() {
  echo "DIRTY-CHECKOUT FAIL: $*" >&2
  [ -n "$CUR" ] && [ -f "$WORK/$CUR.log" ] && { echo "--- $CUR.log"; tail -40 "$WORK/$CUR.log"; } >&2
  [ -n "$CUR" ] && [ -f "$REPO/.chief/state/parallel/$CUR.log" ] \
    && { echo "--- worker log"; tail -60 "$REPO/.chief/state/parallel/$CUR.log"; } >&2
  exit 1
}
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }   # substring, SIGPIPE-safe
command -v jq  >/dev/null || fail "jq is required"
command -v git >/dev/null || fail "git is required"

MARK="OPERATOR-WIP-DO-NOT-MERGE"

# ── A. UNIT — park and give back, lifted from the engine itself ───────────────
eval "$(awk '/^CHIEF_STASH_TAG=/{print} /^merge_stash_push\(\) \{/,/^}/{print} /^merge_stash_pop\(\) \{/,/^}/{print}' "$ROOT/engine/driver.sh")"
[ "$(type -t merge_stash_push)" = function ] \
  || fail "could not lift merge_stash_push() out of engine/driver.sh — did it get renamed?"
[ "$(type -t merge_stash_pop)" = function ] \
  || fail "could not lift merge_stash_pop() out of engine/driver.sh — did it get renamed?"

U="$WORK/unit"; mkdir -p "$U"; ( cd "$U"
  git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
  printf 'one\n' > f.txt; printf 'staged\n' > s.txt; printf 'untouched\n' > u.txt
  git add -A; git commit -q -m init ) >/dev/null
stashes() { git -C "$U" stash list 2>/dev/null | wc -l | tr -d ' '; }

# Nothing to park is the COMMON path and must cost nothing and say nothing.
out="$(merge_stash_push "$U" unit-clean)"
[ -z "$out" ] || fail "unit: a clean repo must park nothing and echo nothing, got '$out'"
[ "$(stashes)" = 0 ] || fail "unit: a clean repo grew a stash entry"

# An empty sha is the no-op a trap fires with when nothing was parked. It must be
# silent and successful, and it must stay that way when fired twice.
merge_stash_pop "$U" "" unit-clean >/dev/null || fail "unit: pop with no sha must be a successful no-op"

printf 'edited by the operator\n' > "$U/f.txt"
printf 'staged by the operator\n'  > "$U/s.txt"; git -C "$U" add s.txt
sha="$(merge_stash_push "$U" unit-dirty)"
[ -n "$sha" ] || fail "unit: a dirty repo must park its work and echo the stash sha"
[ -z "$(git -C "$U" status --porcelain --untracked-files=no)" ] \
  || fail "unit: the tree is still dirty after parking — the merge phase would still be refused"
[ "$(stashes)" = 1 ] || fail "unit: the parked work is not in the stash (got $(stashes) entries)"
has "one" "$(cat "$U/f.txt")" || fail "unit: parking did not restore the committed content"

# The operator stashes something of their own WHILE the merge runs. Popping
# `stash@{0}` blind would hand back the wrong entry; pop takes the one it named.
printf 'the operator stashed this themselves\n' > "$U/u.txt"
git -C "$U" stash push --quiet -m "the operator's own" >/dev/null 2>&1
[ "$(stashes)" = 2 ] || fail "unit: fixture — the operator's own stash was not created"

merge_stash_pop "$U" "$sha" unit-dirty >/dev/null || fail "unit: a clean replay must succeed"
has "edited by the operator" "$(cat "$U/f.txt")" || fail "unit: the operator's unstaged edit did not come back"
git -C "$U" diff --cached --name-only | grep -q '^s.txt$' \
  || fail "unit: the operator's STAGED change came back unstaged — --index was not honoured"
[ "$(stashes)" = 1 ] || fail "unit: pop dropped the wrong entry — the operator's own stash must survive"
has "the operator's own" "$(git -C "$U" stash list)" || fail "unit: pop dropped the OPERATOR's stash instead of chief's"
git -C "$U" stash drop --quiet stash@{0} >/dev/null 2>&1 || true
git -C "$U" reset -q --hard >/dev/null 2>&1

# Popping an object that is already gone is the other no-op a trap depends on:
# teardown and the merge subshell can both reach for the same sha.
merge_stash_pop "$U" "$sha" unit-dirty >/dev/null || fail "unit: popping an already-restored stash must be a successful no-op"

# THE ONE THAT MATTERS. The replay conflicts (the merge rewrote the same line the
# operator was editing). Nothing may be dropped, and the run must say where it is.
printf 'the operator was editing this line\n' > "$U/f.txt"
sha="$(merge_stash_push "$U" unit-conflict)"
[ -n "$sha" ] || fail "unit: fixture — nothing was parked for the conflict case"
printf 'a merge rewrote the very same line\n' > "$U/f.txt"
git -C "$U" commit -q -am "a merge landed on the same line"
msg="$(merge_stash_pop "$U" "$sha" unit-conflict 2>&1)" && fail "unit: a replay that cannot apply must report failure"
[ "$(git -C "$U" rev-parse --verify --quiet refs/stash)" = "$sha" ] \
  || fail "unit: a replay that could not apply DROPPED the operator's work — the one thing that must never happen"
has "NOTHING WAS DROPPED" "$msg" || fail "unit: the failed replay does not say the work is safe ('$msg')"
has "$sha" "$msg"                || fail "unit: the failed replay does not name the stash sha to apply ('$msg')"
has "stash apply" "$msg"         || fail "unit: the failed replay does not give the command that recovers it ('$msg')"

# ── B. DRIVER — install chief from THIS checkout ──────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install.sh failed"
CHIEF="$BIN/chief"

# The scripted agent: implement the one story, commit it, and — ONCE per tasklist —
# dirty the WORK repo the way an operator editing their own checkout mid-run does.
# `docs.txt` and `staged.txt` are tracked, on main, and touched by no branch.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null                                   # drain the prompt on stdin
PRD=".chief/state/prd.json"                      # cwd = the worktree (set by the driver)
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
TRACKED="tasks/chief/$name.json"
ONCE=".chief/state/.dc-dirtied"

id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  mkdir -p out; printf 'impl %s\n' "$id" > "out/$name-$id.txt"
  for f in "$PRD" "$TRACKED"; do
    [ -f "$f" ] || continue
    t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id).passes)=true' "$f" > "$t" && mv "$t" "$f"
  done
  git add -A >/dev/null 2>&1 || true
  git commit -q -m "feat: $id - scripted" >/dev/null 2>&1 || true
fi

# THE OPERATOR, typing in their own checkout while the run is in flight.
if [ ! -f "$ONCE" ] && [ -n "${CHIEF_TEST_BASE_REPO:-}" ] && [ -n "${id:-}" ]; then
  : > "$ONCE"
  printf '%s\n' "${CHIEF_TEST_MARK:-WIP}" >> "$CHIEF_TEST_BASE_REPO/docs.txt"
  printf '%s staged\n' "${CHIEF_TEST_MARK:-WIP}" >> "$CHIEF_TEST_BASE_REPO/staged.txt"
  git -C "$CHIEF_TEST_BASE_REPO" add staged.txt >/dev/null 2>&1 || true
fi

[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── The fixture ───────────────────────────────────────────────────────────────
mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null || fail "chief init failed"
rm -f tasks/chief/example.json
printf 'the operator owns this file\n' > docs.txt
printf 'and this one\n' > staged.txt
for n in dc-merge dc-kill; do
  jq -n --arg b "chief/$n" \
     '{project:"dc",branchName:$b,description:"dirty-checkout fixture",iters:2,
       dependsOn:[],touches:[],warmup:[],
       userStories:[{id:"US-1",title:"story",description:"",
                     acceptanceCriteria:["out/<name>-US-1.txt"],passes:false,notes:""}]}' \
     > "tasks/chief/$n.json"
done
# THE HONESTY GATE. verify runs in the work repo with the branch checked out, so if
# the operator's uncommitted edit is still in the tree when it runs, the gate is
# measuring the branch PLUS that edit. Failing here is what makes the difference
# between parking for the whole critical section and `git rebase --autostash`
# (which pops before verify) an assertion rather than a claim in a comment.
cat > .chief/verify.sh <<VERIFY
#!/usr/bin/env bash
set -eu
if grep -q '$MARK' docs.txt 2>/dev/null || grep -q '$MARK' staged.txt 2>/dev/null; then
  echo "verify: the operator's uncommitted work is in the tree — the gate is not measuring the branch"
  exit 1
fi
if [ "\${CHIEF_TEST_SLOW_VERIFY:-0}" = 1 ]; then sleep 8; fi
echo "verify: ok"
exit 0
VERIFY
chmod +x .chief/verify.sh
git add -A && git commit -q -m "fixture"

run_chief() {   # $1 = tasklist name (also the log name)
  CUR="$1"
  ( cd "$REPO" && PATH="$WORK/fakebin:$PATH" \
      WT_ROOT="$WORK/wt" CHIEF_TEST_BASE_REPO="$REPO" CHIEF_TEST_MARK="$MARK" \
      "$CHIEF" run "$1" ) >"$WORK/$1.log" 2>&1 || true
}
run_log()    { cat "$WORK/$1.log" 2>/dev/null || echo; }
worker_log() { cat "$REPO/.chief/state/parallel/$1.log" 2>/dev/null || echo; }
status_of()  { cat "$REPO/.chief/state/parallel/$1.status" 2>/dev/null || echo MISSING; }
stash_list() { git -C "$REPO" stash list 2>/dev/null || echo; }

# ── B. THE FIELD CASE — dirty mid-run, merges anyway, nothing lost ────────────
run_chief dc-merge
status="$(status_of dc-merge)"
case "$status" in
  MERGED*) ;;
  *) fail "a branch could not merge because the OPERATOR's checkout was dirty — got '$status' (this is the field failure this test exists for)" ;;
esac
has "scripted" "$(git -C "$REPO" log --oneline main)" || fail "the branch never reached main"
[ -f "$REPO/tasks/chief/completed/dc-merge.json" ] || fail "the merged tasklist was not retired"

# The operator's work is BACK, byte for byte, in both of its states.
has "$MARK" "$(cat "$REPO/docs.txt")" \
  || fail "the operator's uncommitted edit to docs.txt did not survive the merge — chief took it and did not give it back"
has "$MARK" "$(cat "$REPO/staged.txt")" \
  || fail "the operator's STAGED edit to staged.txt did not survive the merge"
git -C "$REPO" diff --cached --name-only | grep -q '^staged.txt$' \
  || fail "the operator's staged change came back UNSTAGED — the index state was not restored"
has "the operator owns this file" "$(cat "$REPO/docs.txt")" \
  || fail "docs.txt lost its committed content — the replay clobbered instead of applying"
[ -z "$(stash_list)" ] || fail "the parked work was left in the stash after a clean run: $(stash_list)"

# It was really parked (not merely tolerated), and the gate really ran clean.
has "PARKED in the stash" "$(worker_log dc-merge)" \
  || fail "the worker log does not record that the operator's work was parked — was it just never noticed?"
has "restored the uncommitted changes" "$(worker_log dc-merge)" \
  || fail "the worker log does not record giving the operator's work back"
has "verify: ok" "$(worker_log dc-merge)" \
  || fail "the merge-time verify did not run clean — it saw the operator's uncommitted work (this is what --autostash would do)"
# The operator's edit must not have been swept into any commit chief made. Scoped to
# THEIR files: the fixture's own verify hook greps for the marker, so an unscoped
# `-S` matches the fixture commit and asserts nothing.
git -C "$REPO" log --oneline -20 -S"$MARK" main -- docs.txt staged.txt | grep -q . \
  && fail "the operator's uncommitted work was COMMITTED by chief — parking must never turn into authorship"

# ── C. KILLED MID-MERGE — the work outlives the process that borrowed it ──────
git -C "$REPO" reset -q --hard HEAD >/dev/null 2>&1 || true   # hand the fixture back a pristine checkout
CUR=dc-kill
set -m
( cd "$REPO" && PATH="$WORK/fakebin:$PATH" \
    WT_ROOT="$WORK/wt" CHIEF_TEST_BASE_REPO="$REPO" CHIEF_TEST_MARK="$MARK" \
    CHIEF_TEST_SLOW_VERIFY=1 "$CHIEF" run dc-kill ) >"$WORK/dc-kill.log" 2>&1 &
RUNPID=$!
set +m
CRIT="$REPO/.chief/state/parallel/dc-kill.critical"
w=0
while [ "$w" -lt 400 ]; do
  [ -f "$CRIT" ] && grep -q '^stash=' "$CRIT" 2>/dev/null && break
  sleep 0.25; w=$(( w + 1 ))
done
grep -q '^stash=' "$CRIT" 2>/dev/null \
  || { kill -9 -"$RUNPID" 2>/dev/null || kill -9 "$RUNPID" 2>/dev/null || true
       fail "the merge phase never recorded the parked stash in its .critical marker — a hard kill would have no trail to follow"; }
KSHA="$(sed -n 's/^stash=//p' "$CRIT" | head -1)"
# SIGKILL the whole process group: no trap runs, nothing gets a chance to clean up.
kill -9 -"$RUNPID" 2>/dev/null || kill -9 "$RUNPID" 2>/dev/null || true
wait "$RUNPID" 2>/dev/null || true
sleep 1

# THE ASSERTION. The operator's work is still there — in git's own object store, not
# in a temp file the dead process owned.
has "chief: parked operator work" "$(stash_list)" \
  || fail "a SIGKILL mid-merge lost the operator's parked work — the stash entry is gone: $(stash_list)"
has "$MARK" "$(git -C "$REPO" show "$KSHA:docs.txt" 2>/dev/null || echo)" \
  || fail "the surviving stash does not contain the operator's edit"

# And the next run hands it back without being asked.
run_chief dc-kill
klog="$(run_log dc-kill)"
has "killed mid-merge" "$klog" \
  || fail "the next run did not announce that it was giving back work a killed run had parked"
has "$MARK" "$(cat "$REPO/docs.txt")" \
  || fail "the next run did not restore the operator's work — it is recoverable but chief still owes it back automatically"
[ -z "$(stash_list)" ] || fail "the recovered stash entry was not dropped after a clean replay: $(stash_list)"
case "$(status_of dc-kill)" in MERGED*) ;; *) fail "the killed tasklist did not merge on the re-run — got '$(status_of dc-kill)'" ;; esac

echo "DIRTY-CHECKOUT PASS — a work repo that goes dirty mid-run still merges, the merge-time gate never sees the operator's edit, the edit comes back in both its staged and unstaged states, a conflicting replay drops nothing and names the stash, and a SIGKILL mid-merge leaves the work in git's stash for the next run to hand back"
