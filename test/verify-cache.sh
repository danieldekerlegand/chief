#!/usr/bin/env bash
# test/verify-cache.sh — the AGENT BOUNDARY's half of the verdict cache, proved in
# both directions: it skips when it may, and it runs when it must.
#
# 117/US-1 taught `_agent_verify_final` (engine/agent.sh) to call `verify_cache_try`
# before `run_verify`. That is one line, and one line is exactly the kind of change
# that can be reverted by a rebase, "simplified" by a later refactor, or keyed
# differently from the `verify_cache_record` beside it — and NOTHING WOULD FAIL. The
# only symptom is a suite that runs twice and a merge that takes twice as long, which
# is what the tasklist was opened for in the first place (measured on cuneiform
# 2026-09-02: ~20 minutes in-turn, then ~21 more at the boundary, over a tree neither
# run had moved). So the skip gets a test, and so does every way it must NOT happen.
#
# WHAT IS COUNTED, AND WHY NOT THE LOG. Every assertion here is on the number of times
# the verify HOOK ITSELF executed — it appends one line to a counter file on every
# invocation. A log line saying `verify SKIPPED` is chief's CLAIM about what it did;
# the counter is the observation. (The log line is asserted too, but only as the
# operator-facing half of a skip that the counter has already proved happened.)
#
# THE HOOK LIVES OUTSIDE THE REPO ($WORK/hook.sh, via $CHIEF_VERIFY_HOOK) and that is
# load-bearing, not tidiness: the cache key is `tree.base.hook`, and PART C has to
# change the hook blob while the tree stands still. A hook committed inside the repo
# could not be edited without also moving the tree, so the two halves of the key would
# be impossible to tell apart.
#
#   PART A  a GREEN verdict for an unmoved tree SKIPS the re-run   (hook runs 1x, not 2x)
#   PART B  the tree moves -> the hook RUNS                        (negative control)
#   PART C  the hook blob changes, tree unmoved -> it RUNS         (negative control)
#   PART D  a RED verdict is REUSED too, and still refuses completion (120)
#   PART E  REPRODUCTION — the same PART A sequence against an engine whose
#           `verify_cache_try` call is neutered must NOT skip, or this file is
#           restating behaviour that always worked.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=vc GIT_AUTHOR_EMAIL=vc@test GIT_COMMITTER_NAME=vc GIT_COMMITTER_EMAIL=vc@test
# hermetic: never touch the operator's ~/.chief, even though this test drives agent.sh
# directly rather than through the driver.
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos" CHIEF_WORKTREE_ROOT="$WORK/wt" CHIEF_PREFIX="$WORK/ch"

note() { printf 'verify-cache: %s\n' "$*"; }
fail() { echo "VERIFY-CACHE FAIL: $*" >&2; [ -f "${LAST_OUT:-}" ] && tail -25 "$LAST_OUT" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

COUNT="$WORK/hook.count"; : > "$COUNT"
hook_runs() { wc -l < "$COUNT" | tr -d ' '; }

# ── the verify hook, in three variants ───────────────────────────────────────
# GREEN and GREEN2 differ only in a comment, so `git hash-object` sees two different
# blobs over a hook that behaves identically — which is precisely PART C's question.
write_hook() { # write_hook A|B|RED
  local variant="$1" rc=0
  [ "$variant" = RED ] && rc=1
  cat > "$WORK/hook.sh" <<EOF
#!/usr/bin/env bash
# variant $variant
printf 'ran\n' >> "$COUNT"
echo "fixture verify hook ($variant) ran in \$PWD"
exit $rc
EOF
  chmod +x "$WORK/hook.sh"
}

# ── the fake provider ────────────────────────────────────────────────────────
# It does the minimum for the loop to reach the completion path: optionally land a
# commit (COMMIT=1 — this is how the test MOVES THE TREE), mark the story passing,
# and emit the token on a line by itself. Everything interesting happens after it
# returns, in _agent_verify_final.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat > /dev/null
jq '(.userStories[0].passes)=true' .chief/state/prd.json > .chief/state/prd.tmp
mv .chief/state/prd.tmp .chief/state/prd.json
# ONCE per run_agent, not once per turn: a red gate refuses the completion, so the
# loop takes another turn, and a provider that commits every time never stops making
# progress and runs to the hard iteration ceiling. The label is unique per run.
if [ "${FAKE_COMMIT:-0}" = 1 ] && ! grep -qxF "$FAKE_COMMIT_TOKEN" product.txt; then
  printf '%s\n' "$FAKE_COMMIT_TOKEN" >> product.txt
  git add -A product.txt
  git commit -q -m "fixture: move the tree ($FAKE_COMMIT_TOKEN)"
fi
printf '%s\n' '{"type":"result","result":"<promise>COMPLETE</promise>","total_cost_usd":0.01,"usage":{"input_tokens":3,"output_tokens":2}}'
FAKE
chmod +x "$WORK/fakebin/claude"

# ── the scratch project ──────────────────────────────────────────────────────
scratch_repo() {
  local repo="$1"
  mkdir -p "$repo/.chief/state" "$repo/tasks/chief"
  git -C "$repo" init -q -b main 2>/dev/null || git -C "$repo" init -q
  cat > "$repo/.chief/state/prd.json" <<'JSON'
{"branchName":"chief/vc","userStories":[{"id":"US-1","title":"t","passes":false,"acceptanceCriteria":["do the thing"],"notes":null}]}
JSON
  # No `"verify"` array: a per-tasklist command list makes verify_cache_try decline
  # outright (engine/lib.sh), and this test is about the project-hook path.
  cat > "$repo/tasks/chief/vc.json" <<'JSON'
{"branchName":"chief/vc","userStories":[{"id":"US-1","title":"t","passes":false}]}
JSON
  printf '%s\n' '# Chief Progress Log' > "$repo/.chief/state/progress.txt"
  printf '%s\n' 'seed' > "$repo/product.txt"
  git -C "$repo" add -A && git -C "$repo" commit -q -m scaffold
}

# ── one agent iteration, against a chosen engine ─────────────────────────────
# `env -u` every CHIEF_* the engine reads and this harness does not set: the suite is
# routinely run from INSIDE a chief worktree, whose driver exports CHIEF_VERIFY_HOOK,
# CHIEF_VERIFY_CACHE_STATE, CHIEF_PAUSE_FILE and friends. Inheriting any of them would
# point the run at the real repository's gate — a 20-minute one, against the wrong tree.
run_agent() { # run_agent LABEL REPO ENGINE_DIR COMMIT ; sets $LAST_OUT, returns agent rc
  local label="$1" repo="$2" engine="$3" commit="$4" rc=0
  LAST_OUT="$WORK/$label.out"
  ( cd "$repo" && env \
      -u CHIEF_PRESET -u CHIEF_TOOL -u CHIEF_VERBOSE -u CHIEF_MODEL -u CHIEF_AGENT_CONTEXT \
      -u CHIEF_PAUSE_FILE -u CHIEF_LIVE_FILE -u CHIEF_EVENTS_FILE -u CHIEF_ITER_HOOK \
      -u CHIEF_PRD_SNAPSHOT -u CHIEF_UNVERIFIED_FILE -u CHIEF_RESEARCH -u CHIEF_RESEARCH_FILE \
      -u CHIEF_REVIEW -u CHIEF_TASKS_DIR -u NO_VERIFY -u STRICT_VERIFY \
      FAKE_COMMIT="$commit" FAKE_COMMIT_TOKEN="$label" \
      CHIEF_PROVIDER=claude CHIEF_PROJECT="$repo" CHIEF_HOME="$engine" \
      CHIEF_STATE_DIR=.chief/state CHIEF_TASKLIST=vc \
      CHIEF_VERIFY_CACHE_STATE="$WORK/state" CHIEF_VERIFY_HOOK="$WORK/hook.sh" \
      CHIEF_VERIFY_TASKS_DIR="$repo/tasks/chief" CHIEF_VERIFY_BASE=main \
      CHIEF_VERIFY_REPO="$repo" STALL_LIMIT=1 \
      PATH="$WORK/fakebin:$PATH" bash "$engine/agent.sh" 1 ) >"$LAST_OUT" 2>&1 || rc=$?
  return $rc
}

skipped() { grep -q 'verify SKIPPED' "$LAST_OUT"; }

# ═══ PART A — a GREEN verdict for an unmoved tree SKIPS the re-run ═══════════
write_hook A
REPO="$WORK/repo"; scratch_repo "$REPO"

run_agent a1 "$REPO" "$ROOT/engine" 1 || fail "PART A: the first iteration exited non-zero (a green hook + a committed COMPLETE must end the loop at 0)"
[ "$(hook_runs)" = 1 ] || fail "PART A: the fresh boundary verify did not run exactly once (hook ran $(hook_runs)x)"
skipped && fail "PART A: the FIRST run reported a skip — there was no recorded verdict to skip on"
ls "$WORK/state/verify-cache/"*/* >/dev/null 2>&1 || fail "PART A: no verdict was recorded under \$CHIEF_VERIFY_CACHE_STATE/verify-cache"

# The same tree, the same base, the same hook. This is the whole tasklist.
run_agent a2 "$REPO" "$ROOT/engine" 0 || fail "PART A: the second iteration exited non-zero — a cache HIT must return through the same door a fresh green does (COMPLETE_OK unchanged)"
[ "$(hook_runs)" = 1 ] \
  || fail "PART A: THE SKIP DID NOT HAPPEN — the hook ran $(hook_runs)x for two boundary verifies over one unmoved tree. _agent_verify_final is recording a verdict it does not read."
skipped || fail "PART A: the gate was skipped but nothing said so — a silent skip makes a stale-cache bug undiagnosable"
note "PART A ok — green verdict reused, hook ran 1x for two boundary verifies, and the skip is in the log"

# ═══ PART B — the tree moves, so the hook RUNS (negative control) ════════════
run_agent b1 "$REPO" "$ROOT/engine" 1 || fail "PART B: iteration exited non-zero"
[ "$(hook_runs)" = 2 ] || fail "PART B: OVER-SKIP — the agent committed (HEAD's tree moved) and the hook ran $(hook_runs)x, expected 2"
skipped && fail "PART B: a moved tree was served from the cache — the tree is the correctness key"
note "PART B ok — a moved tree re-runs the gate"

# ═══ PART C — the hook blob changes, the tree does not (negative control) ════
# The verdict from PART B is GREEN and its tree is still HEAD's. Only the gate itself
# is different, and a verdict taken under the old gate says nothing about the new one.
write_hook B
run_agent c1 "$REPO" "$ROOT/engine" 0 || fail "PART C: iteration exited non-zero"
[ "$(hook_runs)" = 3 ] || fail "PART C: OVER-SKIP — the verify hook's own content changed and the hook ran $(hook_runs)x, expected 3. The hook blob is in the key precisely so an edited gate is not skipped."
skipped && fail "PART C: an edited verify hook was skipped on a verdict taken under the old one"
note "PART C ok — an edited gate re-runs even at an unmoved tree"

# ═══ PART D — a RED verdict is REUSED, and still refuses completion ═════════
# The key is `tree.base.hook`. If none of the three moved, the gate is the same
# computation and its verdict cannot have changed — a statement about the INPUTS,
# which does not become false when the answer is red. Until 120 only `status=0` was
# honoured, so an agent that could not fix a gate paid the whole gate again every
# iteration to be told the same thing (cuneiform 2026-09-03: five full ~11.6-minute
# runs, six identical failures, one byte-identical tree).
#
# What must NOT change is what the reuse MEANS to the caller: a reused red refuses
# the completion exactly as a fresh red does. That is the assertion this part exists
# for — a status inverted on the way out of the cache is a way to merge a red tree,
# and it would look like a speedup.
write_hook RED
red_rc=0; run_agent d1 "$REPO" "$ROOT/engine" 0 || red_rc=$?
[ "$red_rc" != 0 ] || fail "PART D: a failing boundary verify was accepted as a completion"
[ "$(hook_runs)" = 4 ] || fail "PART D: the red gate ran $(hook_runs)x, expected 4"
grep -q 'agent verification failed' "$LAST_OUT" || fail "PART D: the failure was not reported"
# The RED verdict must be ON DISK, with the gate's own report beside it — the reuse
# below is only safe if it can say WHY, and a record with no output would make the
# next assertion pass while leaving the agent with a blocked completion and no reason.
RED_REC="$(grep -l '^status=1' "$WORK/state/verify-cache/"*/* 2>/dev/null | head -1)"
[ -n "$RED_REC" ] || fail "PART D: the red verdict was not recorded, so the reuse below cannot be tested"
[ -s "$RED_REC.out" ] || fail "PART D: the red verdict was recorded WITHOUT the gate's output — a reused red could then name no failing test, which is the 119 invisibility bug through another door"
grep -q 'fixture verify hook (RED) ran' "$RED_REC.out" \
  || fail "PART D: the retained output is not the gate's own report"

red_rc=0; run_agent d2 "$REPO" "$ROOT/engine" 0 || red_rc=$?
[ "$red_rc" != 0 ] \
  || fail "PART D: A REUSED RED WAS ACCEPTED AS A COMPLETION — the recorded status was inverted on the way out of the cache"
[ "$(hook_runs)" = 4 ] \
  || fail "PART D: THE RED SKIP DID NOT HAPPEN — the hook ran $(hook_runs)x, expected 4. Nothing moved between the two iterations, so the gate was re-derived for a verdict already on disk."
skipped || fail "PART D: the gate was skipped but nothing said so"
grep -q 'RED verdict' "$LAST_OUT" \
  || fail "PART D: the skip did not say the verdict it reused was RED — an operator cannot tell a reused failure from a reused pass"
grep -qF "$RED_REC" "$LAST_OUT" || fail "PART D: the skip did not name the record it came from"
grep -q 'fixture verify hook (RED) ran' "$LAST_OUT" \
  || fail "PART D: the recorded failure OUTPUT was not replayed — a blocked completion with no failing test named"
grep -q 'agent verification failed' "$LAST_OUT" || fail "PART D: the reused failure was not reported as a failure"
note "PART D ok — a recorded red is reused (hook 4x for two red boundary verifies), replayed, and still refuses completion"

# The invalidation half, on the RED path specifically: a fix must be re-gated. The
# green path proves this in PARTS B and C, but a cache that never invalidates a red
# is the over-application of this fix — an agent that FIXED the gate would be served
# its own stale failure forever.
red_rc=0; run_agent d3 "$REPO" "$ROOT/engine" 1 || red_rc=$?
[ "$red_rc" != 0 ] || fail "PART D: the hook is still RED, so this run must still refuse completion"
[ "$(hook_runs)" = 5 ] \
  || fail "PART D: OVER-SKIP — the agent committed (the tree moved) and the hook ran $(hook_runs)x, expected 5. A red record must invalidate exactly as a green one does, or an agent that FIXED the gate would be served its own stale failure forever."
note "PART D ok — and a moved tree re-runs the red gate rather than replaying it"

# ═══ PART E — REPRODUCTION ═══════════════════════════════════════════════════
# Neuter the one call US-1 added, in a COPY of the engine (not `git show HEAD~N`: CI
# clones shallow), and run PART A's sequence again. If the hook still runs only once,
# the skip this file claims to pin is coming from somewhere else and every assertion
# above is vacuous.
cp -R "$ROOT/engine" "$WORK/engine-old"
sed -i.bak 's/^  if verify_cache_try /  if false /' "$WORK/engine-old/agent.sh" && rm -f "$WORK/engine-old/agent.sh.bak"
grep -q '^  if false ' "$WORK/engine-old/agent.sh" \
  || fail "PART E: could not neuter the verify_cache_try call — its anchor moved. Fix this patch, do not delete the reproduction."
grep -q 'if verify_cache_try ' "$WORK/engine-old/agent.sh" \
  && fail "PART E: the neuter left a live verify_cache_try call behind — the control proves nothing"

write_hook A
REPO2="$WORK/repo-old"; scratch_repo "$REPO2"
: > "$COUNT"
run_agent e1 "$REPO2" "$WORK/engine-old" 1 || fail "PART E: the first iteration on the neutered engine exited non-zero"
[ "$(hook_runs)" = 1 ] || fail "PART E: expected 1 hook run on the neutered engine's first iteration, got $(hook_runs)"
run_agent e2 "$REPO2" "$WORK/engine-old" 0 || fail "PART E: the second iteration on the neutered engine exited non-zero"
[ "$(hook_runs)" = 2 ] \
  || fail "PART E: the neutered engine ALSO skipped (hook ran $(hook_runs)x) — PART A is not testing the call it claims to test"
skipped && fail "PART E: the neutered engine logged a skip"
note "PART E ok — without the try call the gate is paid twice; that is the regression this file guards"

echo "VERIFY-CACHE OK"
