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
#   PART F  CHIEF_VERIFY_CACHE=0 re-runs the gate over that same red record,
#           and overwrites it; unset, the same run skips                    (120)
#   PART G  THE SAVING, in the shape that produced it: a red gate and three
#           iterations against a cache that has never held anything — two that
#           change nothing pay the gate ONCE between them and both refuse
#           completion; the one that MOVES THE TREE pays it again        (120)
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
  # $VC_HATCH is PART F's knob, and when it is unset the variable is UNSET in the run
  # rather than set to its default — every other part must exercise the default the
  # operator actually gets, or a hatch that defaulted to "cache off" would pass this
  # file. It sits at the end of the -u list because `env` stops reading options at the
  # first NAME=VALUE, so it is the last position that is legal in both forms.
  local -a hatch=(-u CHIEF_VERIFY_CACHE)
  [ -n "${VC_HATCH:-}" ] && hatch=(CHIEF_VERIFY_CACHE="$VC_HATCH")
  LAST_OUT="$WORK/$label.out"
  ( cd "$repo" && env \
      -u CHIEF_PRESET -u CHIEF_TOOL -u CHIEF_VERBOSE -u CHIEF_MODEL -u CHIEF_AGENT_CONTEXT \
      -u CHIEF_PAUSE_FILE -u CHIEF_LIVE_FILE -u CHIEF_EVENTS_FILE -u CHIEF_ITER_HOOK \
      -u CHIEF_PRD_SNAPSHOT -u CHIEF_UNVERIFIED_FILE -u CHIEF_RESEARCH -u CHIEF_RESEARCH_FILE \
      -u CHIEF_REVIEW -u CHIEF_TASKS_DIR -u NO_VERIFY -u STRICT_VERIFY \
      "${hatch[@]}" \
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

# ═══ PART F — the operator's escape hatch (CHIEF_VERIFY_CACHE=0) ═════════════
# The reuse above rests on the gate being a deterministic function of its four keyed
# inputs. For a gate where that is false — a real clock, a real network, a race —
# chief cannot tell from the outside (both runs are just a status), so the OPERATOR
# says so. Both directions are asserted against the SAME red record over the SAME
# unmoved tree, because "the hook ran" only means something beside a run in which it
# demonstrably did not.
TREE="$(git -C "$REPO" rev-parse 'HEAD^{tree}')"
F_REC="$(ls "$WORK/state/verify-cache/"*/"$TREE".* 2>/dev/null | grep -v '\.out$' | grep -v '\.tmp\.' | head -1)"
[ -n "$F_REC" ] || fail "PART F: no verdict is recorded for the current tree — the hatch has nothing to override"
grep -q '^status=1' "$F_REC" || fail "PART F: the record for the current tree is not the RED one PART D left"

# Unset (the default): the record stands and the hook does not run.
before="$(hook_runs)"
red_rc=0; run_agent f1 "$REPO" "$ROOT/engine" 0 || red_rc=$?
[ "$red_rc" != 0 ] || fail "PART F: the control run accepted a completion over a red record"
[ "$(hook_runs)" = "$before" ] \
  || fail "PART F: the CONTROL ran the hook ($before -> $(hook_runs)) with the hatch unset — the hatch test below would prove nothing"
skipped || fail "PART F: the control did not report the skip it was supposed to be a control for"

# A sentinel in the record, to prove the hatch OVERWRITES rather than merely bypasses:
# a hatch that leaves the stale verdict on disk hands the next un-hatched run the very
# answer the operator just spent the gate to disbelieve.
printf 'sentinel=stale-f\n' >> "$F_REC"
red_rc=0
export VC_HATCH=0
run_agent f2 "$REPO" "$ROOT/engine" 0 || red_rc=$?
unset VC_HATCH
[ "$(hook_runs)" = "$(( before + 1 ))" ] \
  || fail "PART F: THE HATCH DID NOT RE-RUN THE GATE — the hook ran $(hook_runs)x with CHIEF_VERIFY_CACHE=0 set, expected $(( before + 1 )). A cached red would then be unreachable and a flaky gate unfixable."
grep -q 'verify cache DISABLED' "$LAST_OUT" \
  || fail "PART F: the hatch re-ran the gate and said nothing — an operator cannot tell a forced run from an ordinary miss"
skipped && fail "PART F: the hatched run reported a SKIP"
[ "$red_rc" != 0 ] || fail "PART F: the freshly-run red was accepted as a completion"
F_REC2="$(ls "$WORK/state/verify-cache/"*/"$TREE".* 2>/dev/null | grep -v '\.out$' | grep -v '\.tmp\.' | head -1)"
grep -q '^sentinel=stale-f' "$F_REC2" \
  && fail "PART F: the hatch bypassed the record without REPLACING it — the stale verdict is still on disk for the next run to reuse"
grep -q '^status=1' "$F_REC2" || fail "PART F: the re-run did not record its own verdict"
note "PART F ok — CHIEF_VERIFY_CACHE=0 re-runs the gate ($before -> $(hook_runs)) and overwrites the record; unset, it does not"

# ═══ PART G — THE SAVING, in the shape that produced it ══════════════════════
# PART D proves the MECHANISM, but it proves it over a repo whose cache already
# holds the green records PARTS A-C put there, with counts that only mean anything
# read against the parts above them. This part is the INCIDENT itself, end to end,
# against a cache that has never held a thing — and what it asserts is the COST,
# because the cost is the whole claim of this tasklist.
#
# The shape, from cuneiform:388-the-panel-emission-contract (2026-09-03, 01:55 ->
# 07:52, merged nothing): a gate the agent could not fix, an agent that reported in
# its own words 'nothing left to implement this iteration', and therefore a tree
# that was BYTE-IDENTICAL across FIVE full gate runs. One of those runs is 11.6
# minutes of test execution in that repo; four of the five were re-derivations of a
# verdict already on disk — ~46 minutes of a six-hour run spent proving a known red
# verdict four more times.
#
# So: three iterations. Red gate, nothing changes, nothing changes, then something
# does. Iterations 1 and 2 must cost ONE gate run between them, and iteration 3 must
# cost another — the saving and its limit in the same sequence, so the fix cannot be
# over-applied into a cache that never invalidates.
REPO3="$WORK/repo-loop"; scratch_repo "$REPO3"
# Its own repo root, so `verify_cache_dir` keys it to its own directory; and its own
# CONTENT, so its tree sha differs from the scratch tree PARTS A-E recorded verdicts
# for and the record asserted on below cannot be one of theirs.
printf '%s\n' 'the loop shape that produced 120' >> "$REPO3/product.txt"
git -C "$REPO3" commit -aqm 'fixture: the incident repo'
G_TREE="$(git -C "$REPO3" rev-parse 'HEAD^{tree}')"
[ -z "$(grep -l "^tree=$G_TREE" "$WORK/state/verify-cache/"*/* 2>/dev/null || true)" ] \
  || fail "PART G: a verdict for this tree already exists — the saving below would be inherited from another part rather than made here"
write_hook RED
: > "$COUNT"

# Iteration 1 — the gate is red, and it is red the expensive way: it runs.
g_rc=0; run_agent g1 "$REPO3" "$ROOT/engine" 0 || g_rc=$?
[ "$g_rc" != 0 ] || fail "PART G: iteration 1 accepted a completion over a red gate"
[ "$(hook_runs)" = 1 ] \
  || fail "PART G: iteration 1 paid the gate $(hook_runs)x, expected 1. A red boundary verify sends the loop round for another turn, whose own verify is over the SAME unmoved tree and must be served from the record this iteration just wrote — the saving starts INSIDE one iteration, and the two-iteration one below is measured against this."
G_REC="$(grep -l "^tree=$G_TREE" "$WORK/state/verify-cache/"*/* 2>/dev/null | head -1)"
[ -n "$G_REC" ] || fail "PART G: iteration 1 recorded no verdict for its own tree, so iteration 2 has nothing to be served from"
grep -q '^status=1' "$G_REC" || fail "PART G: the recorded verdict for this tree is not the RED one the hook just returned"

# Iteration 2 — the agent could not fix it and changed nothing. This is the line in
# cuneiform's log that repeated six times. It now costs zero.
g_rc=0; run_agent g2 "$REPO3" "$ROOT/engine" 0 || g_rc=$?
[ "$g_rc" != 0 ] \
  || fail "PART G: iteration 2 accepted a completion — a reused red must refuse it exactly as the fresh red in iteration 1 did"
[ "$(hook_runs)" = 1 ] \
  || fail "PART G: THE SAVING WAS NOT MADE — two iterations over one unmoved tree paid the gate $(hook_runs)x, expected 1. This is the ~46 minutes of cuneiform:388's six hours that this tasklist exists to stop spending."
grep -q 'RED verdict' "$LAST_OUT" \
  || fail "PART G: iteration 2 was refused without saying the verdict came from a record"
grep -q 'fixture verify hook (RED) ran' "$LAST_OUT" \
  || fail "PART G: iteration 2 was refused with NO REASON — the recorded gate output was not replayed, which leaves the agent exactly where 119 left it"
note "PART G ok — two iterations that changed nothing, ONE gate run between them, both completions refused"

# Iteration 3 — the agent finally changes the tree. The key moves, the cache misses,
# and the gate is paid again. Without this the fix is a cache that never invalidates,
# and an agent that FIXED the gate would be served its own stale failure forever.
# (Precisely: the fixture commits ON the base branch, so BOTH the tree and the base
# component of the key move here — this part asserts that the key moved, not which
# half of it did. PART C is the component isolation: it changes the hook blob alone
# while the tree stands still, which is the only one of the four that can be moved
# on its own from outside the repo.)
# (No `skipped` assertion here: a red boundary verify sends the loop round for another
# turn, whose own verify legitimately hits the cache for the tree turn 1 committed —
# the saving inside one iteration. The COUNT is the observation; the log line is not.)
g_rc=0; run_agent g3 "$REPO3" "$ROOT/engine" 1 || g_rc=$?
[ "$g_rc" != 0 ] || fail "PART G: the gate is still RED, so iteration 3 must refuse completion too"
[ "$(hook_runs)" = 2 ] \
  || fail "PART G: OVER-APPLIED — iteration 3 moved the tree and the gate ran $(hook_runs)x, expected 2. A verdict is a statement about a tree; a new tree has no verdict."
note "PART G ok — and the iteration that MOVED the tree paid the gate again (1 -> 2): three iterations, two gate runs"

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
