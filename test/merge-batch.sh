#!/usr/bin/env bash
# test/merge-batch.sh — the OPT-IN batch merge queue (engine/mergequeue.sh ·
# docs/explanation/drivers-and-safety.md).
#
# tasks/chief/92-opt-in-batch-then-bisect-merge-queue. The feature's whole claim is a
# trade: pay the verify gate ONCE for N branches instead of N times, without weakening
# anything the serialized floor guarantees. Six parts assert it, and the FIRST one is
# the one that matters most:
#
#   PART A — THE NEGATIVE CONTROL. With the opt-in absent, the merge phase is the
#            serialized floor and performs exactly N verifications for N tasklists.
#            A feature that is "off by default" is only off if something checks.
#   PART B — THE AMORTIZATION. With `--merge-batch=N`, the same three tasklists merge
#            — all three, `--no-ff`, one commit each, every one retired — off exactly
#            ONE verification of the batch tip, and the run summary reports the ratio.
#            It also asserts the policy layer stayed PER BRANCH inside the batch: the
#            LAST member of a batch of three is stacked on the other two, so a diff
#            budget measured from the base would charge it with all three branches.
#   PART C — THE POLICY LAYER IS NOT WEAKENED. A branch that changed a `review`
#            OVERLAP ZONE is excluded from batching ENTIRELY (band 91): it never
#            appears in a batch, it takes the serialized floor, and it ends
#            AWAITING-APPROVAL with nothing of it on the base — while its peers batch
#            without it. A batch-tip verify is never a human's yes.
#   PART D — THE BISECT, against the floor as a CONTROL. The same poisoned fixture of
#            four tasklists is run twice — once on the floor, once batched — and the
#            culprit's end state is compared field by field. Batched, the red tip is
#            binary-searched: the isolation costs ceil(log2 N)+1 extra gate runs (3,
#            not 4), the good branches merge, and the bad one is left in a state
#            INDISTINGUISHABLE from the one the floor left it in on the first run.
#   PART E — THE RATCHET, ATTRIBUTED. A red tip carrying a band-88 quality-ratchet
#            block is never bisected — each member is re-measured ALONE. The one
#            branch that regresses a tracked metric on its own is blamed, the others
#            re-form a batch and merge, and its slop never reaches the base.
#   PART F — THE RATCHET, NOT ATTRIBUTABLE. Two branches that are each individually
#            within tolerance and jointly regress the metric produce the NAMED
#            outcome: nobody is blamed, the batch is dissolved, and its members go
#            through the serialized floor — where the second of the pair is blocked
#            by the ratchet against the first, so the regressing tree never lands.
#
# Every part counts the SAME thing the same way: the project's verify hook increments
# a counter outside the repo, so "how many times did the gate run" is measured rather
# than inferred from log text.
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
# The queue reads its size from the ENVIRONMENT (a repo sets it in .chief/config). An
# inherited value would turn PART A — the whole negative control — into a second copy
# of PART B, so every setting this test depends on is stated by the test.
unset CHIEF_MERGE_BATCH CHIEF_MERGE_BATCH_WAIT MERGE_BATCH MERGE_BATCH_WAIT \
      CHIEF_DIFF_BUDGET CHIEF_ZONES 2>/dev/null || true
# One attempt per tasklist. A VERIFY-FAILED tasklist is otherwise RE-ARMED inside the
# same run, and each re-arm ends in another trip through the merge phase — which is a
# perfectly good behaviour and would make every gate-invocation count below a range
# instead of a number. Parts D/E/F assert exact counts, so the budget is pinned here.
export RETRY_MAX=1
CHIEF="$ROOT/bin/chief"
LOG=""
fail() { echo "MERGE-BATCH FAIL: $*" >&2; [ -n "$LOG" ] && [ -f "$LOG" ] && tail -80 "$LOG" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

export OZ_WORK="$WORK" OZ_ROOT="$ROOT"
NAMES="alpha bravo charlie"

mkdir -p "$WORK/fakebin" "$WORK/payload" "$WORK/delay"
# ── the fake agent: one story per turn, one artifact, one commit ──────────────
# A per-tasklist artifact path ON PURPOSE: two tasklists writing the same bytes to
# the same path would leave the second branch with an EMPTY diff vs a base the first
# already merged into, and the no-work guard — not the merge queue — would be what
# this measured.
#
# Two hooks for the parts that need more than an artifact, both keyed by tasklist name
# and both OUTSIDE the repo (the worktree is rebuilt every run):
#   · $OZ_WORK/delay/<name>   seconds to sleep before finishing. Batch order IS
#     completion order, so a part whose arithmetic depends on WHICH member is the
#     culprit staggers the finishes instead of racing them.
#   · $OZ_WORK/payload/<name>.sh  extra work committed with the story — the source
#     edit whose quality-metric delta parts E and F are about.
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
: "${OZ_WORK:?}"
cat >/dev/null
PRD=".chief/state/prd.json"
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"; TRACKED="tasks/chief/$name.json"
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
[ -n "$id" ] || exit 0
if [ -f "$OZ_WORK/delay/$name" ]; then sleep "$(cat "$OZ_WORK/delay/$name")"; fi
out="out/$name/$id.txt"
mkdir -p "$(dirname "$out")"
printf 'artifact %s of %s\n' "$id" "$name" > "$out"
if [ -f "$OZ_WORK/payload/$name.sh" ]; then bash "$OZ_WORK/payload/$name.sh"; fi
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

# ── a chief repo whose verify hook COUNTS its own invocations ─────────────────
# One counter file per repo, outside the tree, so the number survives the worktree
# churn and is readable from here. Serialized by $MERGE_LOCK in every part, so the
# read-modify-write needs no lock of its own.
make_repo() {
  local repo="$1"; shift
  mkdir -p "$repo"
  ( cd "$repo"
    git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
    git commit -q --allow-empty -m init
    "$CHIEF" init >/dev/null
    rm -f tasks/chief/example.json
    cat > .chief/verify.sh <<'HOOK'
#!/usr/bin/env bash
set -eu
: "${OZ_WORK:?}"
c="$OZ_WORK/$(basename "$PWD").verifies"
n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$c"
echo "verify: ok (invocation #$n)"
exit 0
HOOK
    chmod +x .chief/verify.sh
    local t
    for t in "$@"; do
      jq -n --arg n "$t" '
        { project:"oz", branchName:("chief/" + $n), description:("merge-queue fixture " + $n),
          iters:3, dependsOn:[], touches:["domain-" + $n], warmup:[],
          userStories:[ { id:"US-1", title:("story of " + $n), description:"",
                          acceptanceCriteria:[("out/" + $n + "/US-1.txt exists")], passes:false, notes:"" } ] }' \
        > "tasks/chief/$t.json"
    done
    git add -A && git commit -q -m setup )
}

# Finish the named tasklists two seconds apart, in the order given — see the fake
# agent's header. Cleared first, because these files outlive a part.
stagger() {
  local i=0 n
  rm -f "$WORK/delay"/* 2>/dev/null || true
  for n in "$@"; do printf '%s' "$i" > "$WORK/delay/$n"; i=$(( i + 2 )); done
}
no_payloads() { rm -f "$WORK/payload"/* 2>/dev/null || true; }

verifies() { cat "$WORK/$(basename "$1").verifies" 2>/dev/null || echo 0; }
# The queue's own narration goes to the LEADER's per-tasklist log, not to the driver's
# stdout — a worker redirects everything it prints into $STATE/parallel/<name>.log. So
# every assertion about what the queue said reads those, and the driver stdout ($LOG)
# is only asserted on for what the SUMMARY prints.
wlogs()    { cat "$1"/.chief/state/parallel/*.log 2>/dev/null || true; }
status()   { cat "$1/.chief/state/parallel/$2.status" 2>/dev/null || echo MISSING; }
merges()   { ( cd "$1" && git log main --oneline | grep -c 'Merge chief/' ) || true; }
retired()  { [ -f "$1/tasks/chief/completed/$2.json" ]; }
on_main()  { ( cd "$1" && git cat-file -e "main:$2" 2>/dev/null ); }

# ══ PART A — THE NEGATIVE CONTROL: no flag, no batching, N verifies for N ═════
echo "merge-batch: PART A — with the opt-in absent, the merge phase is the serialized floor"
REPO_A="$WORK/plain"
make_repo "$REPO_A" alpha bravo charlie
LOG="$WORK/a.log"
( cd "$REPO_A" && PATH="$WORK/fakebin:$PATH" POLL_SECONDS=1 "$CHIEF" run -p 3 ) >"$LOG" 2>&1 \
  || fail "PART A: chief run exited non-zero"

for n in $NAMES; do
  case "$(status "$REPO_A" "$n")" in MERGED*) ;; *) fail "PART A: $n is $(status "$REPO_A" "$n"), expected MERGED" ;; esac
  retired "$REPO_A" "$n" || fail "PART A: $n was not retired to completed/"
done
[ "$(merges "$REPO_A")" = 3 ] || fail "PART A: expected 3 --no-ff merge commits on main, got $(merges "$REPO_A")"
# THE ASSERTION THIS PART EXISTS FOR. Three tasklists, three trips through the floor,
# three gate invocations — the cost the merge queue is offered as a way to avoid.
[ "$(verifies "$REPO_A")" = 3 ] || fail "PART A: expected exactly 3 verifications for 3 tasklists, got $(verifies "$REPO_A")"
# And the queue said nothing at all: an off feature is silent, not merely inactive.
if grep -q 'merge queue:' "$LOG"; then fail "PART A: the merge queue reported itself on a run that never enabled it"; fi
if wlogs "$REPO_A" | grep -q 'batch merge queue'; then fail "PART A: a tasklist was queued on a run that never enabled batching"; fi
echo "merge-batch: PART A ok — 3 merges, 3 verifications, no queue"

# ══ PART B — THE AMORTIZATION: one batch, one verification, three merges ══════
echo "merge-batch: PART B — --merge-batch=3 verifies the batch TIP once for three branches"
REPO_B="$WORK/batched"
make_repo "$REPO_B" alpha bravo charlie
LOG="$WORK/b.log"
# The leader waits for peers to finish before it closes the batch; 60s is far longer
# than three fake turns need and is never actually spent (the wait ends the moment
# the queue is full), so this bounds the test rather than pacing it.
( cd "$REPO_B" && PATH="$WORK/fakebin:$PATH" POLL_SECONDS=1 CHIEF_MERGE_BATCH_WAIT=60 \
    "$CHIEF" run -p 3 --merge-batch=3 ) >"$LOG" 2>&1 \
  || fail "PART B: chief run exited non-zero"

for n in $NAMES; do
  case "$(status "$REPO_B" "$n")" in MERGED*) ;; *) fail "PART B: $n is $(status "$REPO_B" "$n"), expected MERGED" ;; esac
  retired "$REPO_B" "$n" || fail "PART B: $n was not retired to completed/"
done
# Merges are still --no-ff and still one commit per tasklist: the batch amortized the
# VERIFY, it did not collapse three tasklists into one merge.
[ "$(merges "$REPO_B")" = 3 ] || fail "PART B: expected 3 --no-ff merge commits on main, got $(merges "$REPO_B")"
[ "$(verifies "$REPO_B")" = 1 ] || fail "PART B: expected exactly 1 batch-tip verification for 3 branches, got $(verifies "$REPO_B")"
wlogs "$REPO_B" | grep -q 'leading a merge batch of 3 branch' \
  || fail "PART B: no batch of 3 was ever formed (see the per-tasklist logs)"
grep -q 'merge queue: 1 batch-tip verification(s) covering 3 branch(es)' "$LOG" \
  || fail "PART B: the run summary did not report the amortization ratio it achieved"
# Every artifact reached main: a green batch tip is a tree containing every member,
# and all of them landed.
for n in $NAMES; do
  on_main "$REPO_B" "out/$n/US-1.txt" || fail "PART B: $n's artifact never reached main"
done
# THE POLICY LAYER STAYED PER BRANCH. A batch member is rebased onto its predecessors,
# so `main...<member>` is the whole stack up to it — measured from the base, the second
# member of the batch would be charged with two branches' diffs and the third with all
# three. The budget is measured from the tip each member was STACKED ON instead, so
# every record reports that branch's own two files (out/<n>/US-1.txt +
# tasks/chief/<n>.json). Asserted for ALL THREE because the batch order is completion
# order: whichever one happened to lead, the other two are stacked on something.
for n in $NAMES; do
  b="$REPO_B/.chief/state/parallel/$n.budget.json"
  [ -s "$b" ] || fail "PART B: no diff-budget record for $n — the policy layer never ran for a batch member"
  [ "$(jq -r '.total.files' "$b")" = 2 ] \
    || fail "PART B: $n's diff budget counted $(jq -r '.total.files' "$b") file(s), expected its own 2 — a batch member was measured against the batch tip, not against its own branch"
done
echo "merge-batch: PART B ok — 3 merges off 1 verification, budget measured per branch"

# ══ PART C — the policy layer: a `review` zone is NEVER a batch member ════════
echo "merge-batch: PART C — a branch in a \`review\` overlap zone is excluded from batching"
REPO_C="$WORK/zoned"
make_repo "$REPO_C" alpha bravo charlie
# Band 91's registry, declaring ONE domain that needs a human: the files charlie writes.
# alpha and bravo touch nothing in it, so they are still batchable and still batch.
( cd "$REPO_C"
  printf '%s\n' 'review  path:out/charlie/*   charlie writes a declared design domain' > .chief/zones.conf
  git add -A && git commit -q -m zones )
LOG="$WORK/c.log"
( cd "$REPO_C" && PATH="$WORK/fakebin:$PATH" POLL_SECONDS=1 CHIEF_MERGE_BATCH_WAIT=60 \
    "$CHIEF" run -p 3 --merge-batch=3 ) >"$LOG" 2>&1 || true

for n in alpha bravo; do
  case "$(status "$REPO_C" "$n")" in MERGED*) ;; *) fail "PART C: $n is $(status "$REPO_C" "$n"), expected MERGED" ;; esac
done
# THE ASSERTION THIS PART EXISTS FOR, in three independent shapes: the zoned branch was
# never batched, it was held by the policy layer on the floor, and nothing of it landed.
case "$(status "$REPO_C" charlie)" in
  AWAITING-APPROVAL*) ;;
  *) fail "PART C: charlie is $(status "$REPO_C" charlie), expected AWAITING-APPROVAL — a review-zone branch was not held" ;;
esac
wlogs "$REPO_C" | grep -q 'charlie is NOT eligible for the merge queue' \
  || fail "PART C: charlie was never excluded from the merge queue"
if wlogs "$REPO_C" | grep -q 'leading a merge batch of 3 branch'; then
  fail "PART C: a review-zone branch was taken into a batch"
fi
wlogs "$REPO_C" | grep -q 'leading a merge batch of 2 branch' \
  || fail "PART C: alpha and bravo did not batch without charlie (see the per-tasklist logs)"
if on_main "$REPO_C" "out/charlie/US-1.txt"; then
  fail "PART C: the review-zone branch reached main without an approval"
fi
[ -s "$REPO_C/.chief/state/parallel/charlie.zone-request.json" ] \
  || fail "PART C: no approval request was written for the held branch"
# Two gate runs for three tasklists: one batch tip covering alpha+bravo, and charlie's
# own trip through the floor. The exclusion costs exactly the floor, and nothing more.
[ "$(verifies "$REPO_C")" = 2 ] \
  || fail "PART C: expected 2 verifications (1 batch tip for 2 + 1 floor for charlie), got $(verifies "$REPO_C")"
grep -q 'merge queue: 1 batch-tip verification(s) covering 2 branch(es)' "$LOG" \
  || fail "PART C: the summary did not report a batch of 2"
echo "merge-batch: PART C ok — the zoned branch took the floor and was held; its peers batched without it"

# ══ PART D — THE BISECT, with the serialized floor as the control ════════════
# One poisoned fixture, run twice. The gate is red on any tree containing charlie's
# artifact — a deterministic function of the tree, which is exactly the assumption the
# bisect is documented to rest on. Everything about the two runs is identical except
# the flag, so the culprit's end state can be COMPARED rather than described.
echo "merge-batch: PART D — a batch of four with one bad branch bisects to it"
no_payloads
# The culprit must be at a KNOWN index: batch order is completion order, so the four
# finish two seconds apart and charlie is member #3 of 4. That makes the whole
# arithmetic below exact — probes, survivors and all — instead of a range.
stagger alpha bravo charlie delta
poison_repo() {
  local repo="$1"
  make_repo "$repo" alpha bravo charlie delta
  ( cd "$repo"
    cat > .chief/verify.sh <<'HOOK'
#!/usr/bin/env bash
set -eu
: "${OZ_WORK:?}"
c="$OZ_WORK/$(basename "$PWD").verifies"
n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$c"
if [ -f out/charlie/US-1.txt ]; then
  echo "verify: FAIL (invocation #$n) — charlie's artifact is in this tree"; exit 1
fi
echo "verify: ok (invocation #$n)"
exit 0
HOOK
    chmod +x .chief/verify.sh
    git add -A && git commit -q -m poison )
}
# Everything about a finished tasklist an operator (or the next run) can observe. The
# point of comparing the two runs field by field is that "the isolated culprit is left
# in exactly the state a serialized failure leaves it in" becomes a measurement — note
# that BOTH paths free the worktree at the top of the merge phase, so `worktrees` is
# part of the comparison rather than an expectation stated here.
end_state() {
  local repo="$1" n="$2"
  printf 'status=%s\n'    "$(status "$repo" "$n")"
  printf 'branch=%s\n'    "$( ( cd "$repo" && git rev-parse --verify -q "chief/$n" >/dev/null ) && echo present || echo gone)"
  printf 'work-kept=%s\n' "$( ( cd "$repo" && git cat-file -e "chief/$n:out/$n/US-1.txt" 2>/dev/null ) && echo yes || echo no)"
  printf 'on-main=%s\n'   "$(on_main "$repo" "out/$n/US-1.txt" && echo yes || echo no)"
  printf 'log=%s\n'       "$([ -s "$repo/.chief/state/snapshots/$n.verify-failed.log" ] && echo present || echo absent)"
  printf 'retired=%s\n'   "$(retired "$repo" "$n" && echo yes || echo no)"
  printf 'worktrees=%s\n' "$( cd "$repo" && git worktree list | wc -l | tr -d ' ')"
}

REPO_DF="$WORK/floorpoison"
poison_repo "$REPO_DF"
LOG="$WORK/df.log"
( cd "$REPO_DF" && PATH="$WORK/fakebin:$PATH" POLL_SECONDS=1 "$CHIEF" run -p 4 ) >"$LOG" 2>&1 || true
[ "$(verifies "$REPO_DF")" = 4 ] \
  || fail "PART D (floor control): expected 4 verifications for 4 tasklists, got $(verifies "$REPO_DF")"
case "$(status "$REPO_DF" charlie)" in
  VERIFY-FAILED*) ;;
  *) fail "PART D (floor control): charlie is $(status "$REPO_DF" charlie), expected VERIFY-FAILED" ;;
esac
[ "$(merges "$REPO_DF")" = 3 ] || fail "PART D (floor control): expected 3 merges, got $(merges "$REPO_DF")"

REPO_DB="$WORK/batchpoison"
poison_repo "$REPO_DB"
LOG="$WORK/db.log"
( cd "$REPO_DB" && PATH="$WORK/fakebin:$PATH" POLL_SECONDS=1 CHIEF_MERGE_BATCH_WAIT=60 \
    "$CHIEF" run -p 4 --merge-batch=4 ) >"$LOG" 2>&1 || true

# The three good branches merged; the culprit did not, and nothing of it is on main.
for n in alpha bravo delta; do
  case "$(status "$REPO_DB" "$n")" in MERGED*) ;; *) fail "PART D: $n is $(status "$REPO_DB" "$n"), expected MERGED" ;; esac
  retired "$REPO_DB" "$n" || fail "PART D: $n was not retired to completed/"
  on_main "$REPO_DB" "out/$n/US-1.txt" || fail "PART D: $n's artifact never reached main"
done
[ "$(merges "$REPO_DB")" = 3 ] || fail "PART D: expected 3 --no-ff merge commits on main, got $(merges "$REPO_DB")"
if on_main "$REPO_DB" "out/charlie/US-1.txt"; then
  fail "PART D: THE INVARIANT BROKE — the branch that fails the gate reached main inside a batch"
fi
# THE BISECT ITSELF, read off the leader's narration: it probed PREFIXES (not branches
# one by one), it named the member the poison is in, and it did not blame it on that
# one observation — it re-verified charlie ALONE on the base first.
wlogs "$REPO_DB" | grep -q 'BISECT points at member #3 of 4 — charlie' \
  || fail "PART D: the bisect did not isolate charlie as member #3 of 4"
wlogs "$REPO_DB" | grep -q 'CONFIRMED — chief/charlie fails on its own' \
  || fail "PART D: charlie was blamed without a confirming verification of it alone"
wlogs "$REPO_DB" | grep -q 'merging the 2 branch(es) the bisect PROVED green together' \
  || fail "PART D: the culprit's predecessors were not merged on the green prefix the bisect observed"
wlogs "$REPO_DB" | grep -q 'RE-FORMING a batch from the 1 surviving branch' \
  || fail "PART D: the survivor was not re-formed into a batch (it was never verified without charlie)"
# THE COST, and it is the reason to bisect rather than discard: isolating the culprit
# took ceil(log2 4) probes + 1 confirming run = 3 EXTRA gate runs — the O(log N) bound,
# not the N the floor pays. Total: 1 tip + 3 isolating + 1 survivor tip = 5 (the floor
# paid 4 for the same fixture; batching wins as N grows, and at N=4 it does not — the
# counters report what it cost rather than what it was supposed to).
grep -q 'merge queue: 3 extra verification(s) spent bisecting — 1 branch(es) isolated, 0 batch(es) dissolved' "$LOG" \
  || fail "PART D: the summary did not report a log-bounded isolation cost (3 extra runs, 1 branch isolated)"
[ "$(verifies "$REPO_DB")" = 5 ] \
  || fail "PART D: expected 5 gate runs (1 tip + 2 bisect probes + 1 confirm + 1 survivor tip), got $(verifies "$REPO_DB")"
# AND THE CONTROL. Field for field, the bisected culprit is where the floor left it.
if [ "$(end_state "$REPO_DF" charlie)" != "$(end_state "$REPO_DB" charlie)" ]; then
  echo "--- floor:";   end_state "$REPO_DF" charlie >&2
  echo "--- batched:"; end_state "$REPO_DB" charlie >&2
  fail "PART D: the isolated culprit is NOT in the state a serialized verify failure leaves it in"
fi
echo "merge-batch: PART D ok — culprit isolated in 3 extra gate runs, left exactly as the floor leaves it"

# ══ the quality-ratchet fixture (parts E and F) ══════════════════════════════
# The band-88 ratchet is the gate's OTHER axis, and it is not a boolean: it is a metric
# DELTA. `duplicate_blocks` is the sharpest one to test with because it is a relation
# BETWEEN files — which is precisely why a batch tip cannot attribute it by bisection.
# Only that metric is tracked (a committed .chief/quality.conf) so the hook and the
# engine's own attribution probe cannot disagree about what is being measured.
cat > "$WORK/block.txt" <<'BLK'

shared_helper_body() {
  local acc=0
  for item in "$@"; do
    acc=$(( acc + item ))
    printf 'accumulated %s\n' "$acc"
  done
  printf 'total %s\n' "$acc"
  return 0
}
BLK
make_quality_repo() {
  local repo="$1"; shift
  make_repo "$repo" "$@"
  ( cd "$repo"
    mkdir -p src
    printf '#!/usr/bin/env bash\nalpha_entry() {\n  echo "alpha entry"\n}\n'      > src/a.sh
    printf '#!/usr/bin/env bash\nbravo_entry() {\n  printf "bravo entry\\n"\n}\n' > src/b.sh
    printf '#!/usr/bin/env bash\ncharlie_entry() {\n  echo "charlie entry"\n}\n'  > src/c.sh
    printf '%s\n' 'CHIEF_QUALITY_METRICS="duplicate_blocks"' > .chief/quality.conf
    # The gate IS the ratchet here (plus the counter), so a red tip carries the
    # `quality: BLOCK` marker the queue keys its attribution arm on.
    cat > .chief/verify.sh <<'HOOK'
#!/usr/bin/env bash
set -eu
: "${OZ_WORK:?}" "${OZ_ROOT:?}"
c="$OZ_WORK/$(basename "$PWD").verifies"
n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$c"
echo "verify: gate invocation #$n"
exec bash "$OZ_ROOT/engine/quality.sh" ratchet --root "$PWD" --base main
HOOK
    chmod +x .chief/verify.sh
    git add -A && git commit -q -m quality-fixture
    # The committed whole-tree floor. Without it only the changed-file scope axis runs,
    # and a JOINT regression is invisible to it — see PART F, which is the case that
    # needs the baseline to be caught on the floor at all.
    bash "$OZ_ROOT/engine/quality.sh" ratchet --root "$PWD" --base main --write-baseline >/dev/null 2>&1
    git add -A && git commit -q -m baseline )
}
dup_on_main() {   # how many of main's source files carry the duplicated block
  ( cd "$1" && git grep -l shared_helper_body main -- src 2>/dev/null | wc -l | tr -d ' ' )
}

# ══ PART E — THE RATCHET, ATTRIBUTED to the one branch that regressed alone ═══
echo "merge-batch: PART E — a ratchet regression attributable to one branch blocks that branch only"
REPO_E="$WORK/ratchet-one"
make_quality_repo "$REPO_E" alpha bravo charlie
stagger alpha bravo charlie
no_payloads
# alpha duplicates a block INSIDE ITS OWN FILE: out of tolerance on its own, so a
# per-branch re-measurement finds it without any reference to its peers.
{ printf 'cat "%s/block.txt" >> src/a.sh\n' "$WORK"
  printf 'cat "%s/block.txt" >> src/a.sh\n' "$WORK"; } > "$WORK/payload/alpha.sh"
LOG="$WORK/e.log"
( cd "$REPO_E" && PATH="$WORK/fakebin:$PATH" POLL_SECONDS=1 CHIEF_MERGE_BATCH_WAIT=60 \
    "$CHIEF" run -p 3 --merge-batch=3 ) >"$LOG" 2>&1 || true

case "$(status "$REPO_E" alpha)" in
  VERIFY-FAILED*) ;;
  *) fail "PART E: alpha is $(status "$REPO_E" alpha), expected VERIFY-FAILED — the ratchet regression was not attributed to it" ;;
esac
for n in bravo charlie; do
  case "$(status "$REPO_E" "$n")" in MERGED*) ;; *) fail "PART E: $n is $(status "$REPO_E" "$n"), expected MERGED" ;; esac
done
[ "$(dup_on_main "$REPO_E")" = 0 ] \
  || fail "PART E: THE INVARIANT BROKE — the duplicated block reached main"
# A ratchet tip is ATTRIBUTED, never bisected: every member re-measured alone, one
# blamed, and not a single bisect probe spent on a question binary search cannot answer.
wlogs "$REPO_E" | grep -q 'the red tip carries a QUALITY-RATCHET block' \
  || fail "PART E: the queue did not recognise the red tip as a ratchet block"
wlogs "$REPO_E" | grep -q 'alpha RATCHET-ATTRIBUTED' \
  || fail "PART E: alpha was not named as the branch that regresses the metric on its own"
if wlogs "$REPO_E" | grep -q 'BISECT'; then
  fail "PART E: a ratchet-carrying tip was BISECTED — a metric delta is not a boolean and its prefixes are not comparable"
fi
grep -q 'merge queue: 3 per-branch quality-ratchet re-measurement(s) — 1 branch(es) attributed, 0 batch(es) RATCHET-NOT-ATTRIBUTABLE' "$LOG" \
  || fail "PART E: the summary did not report one attributed branch out of three re-measurements"
[ "$(verifies "$REPO_E")" = 2 ] \
  || fail "PART E: expected 2 gate runs (the red tip + the survivors' tip), got $(verifies "$REPO_E")"
[ "$(merges "$REPO_E")" = 2 ] || fail "PART E: expected 2 --no-ff merges, got $(merges "$REPO_E")"
echo "merge-batch: PART E ok — the regressing branch blocked, its peers batched and merged"

# ══ PART F — THE RATCHET, NOT ATTRIBUTABLE: a named outcome, not a guess ═════
echo "merge-batch: PART F — a joint ratchet regression is named, not blamed on anyone"
REPO_F="$WORK/ratchet-joint"
make_quality_repo "$REPO_F" alpha bravo charlie
stagger alpha bravo charlie
no_payloads
# THE JOINT REGRESSION, and it is the whole reason this outcome exists: the SAME block
# appended to two DIFFERENT pre-existing files by two different branches. Each branch
# alone moves `duplicate_blocks` by 0 — one copy is not a duplicate. Together they
# make three duplicate blocks. Nobody did it; both did.
printf 'cat "%s/block.txt" >> src/a.sh\n' "$WORK" > "$WORK/payload/alpha.sh"
printf 'cat "%s/block.txt" >> src/b.sh\n' "$WORK" > "$WORK/payload/bravo.sh"
LOG="$WORK/f.log"
( cd "$REPO_F" && PATH="$WORK/fakebin:$PATH" POLL_SECONDS=1 CHIEF_MERGE_BATCH_WAIT=60 \
    "$CHIEF" run -p 3 --merge-batch=3 ) >"$LOG" 2>&1 || true

wlogs "$REPO_F" | grep -q 'RATCHET-NOT-ATTRIBUTABLE' \
  || fail "PART F: the joint regression did not produce the named not-attributable outcome"
wlogs "$REPO_F" | grep -q 'DISSOLVING — every branch goes back to the sha its worker finished on' \
  || fail "PART F: the batch was not dissolved to the serialized floor"
if wlogs "$REPO_F" | grep -q 'RATCHET-ATTRIBUTED'; then
  fail "PART F: a branch was blamed for a regression it does not cause on its own"
fi
grep -q 'merge queue: 3 per-branch quality-ratchet re-measurement(s) — 0 branch(es) attributed, 1 batch(es) RATCHET-NOT-ATTRIBUTABLE' "$LOG" \
  || fail "PART F: the summary did not report the not-attributable outcome"
# AND THE FALLBACK IS NOT A SHRUG. Dissolved, the three members go through the floor
# one at a time: the first of the pair merges, the second meets it ON the base and the
# ratchet's whole-tree axis blocks it there — attributably. So the regression is
# caught, by the mechanism that CAN name a culprit, and main carries one copy of the
# block: no duplication, nothing regressed.
case "$(status "$REPO_F" alpha)" in MERGED*) ;; *) fail "PART F: alpha is $(status "$REPO_F" alpha), expected MERGED (it is first and green against the base)" ;; esac
case "$(status "$REPO_F" bravo)" in
  VERIFY-FAILED*) ;;
  *) fail "PART F: bravo is $(status "$REPO_F" bravo), expected VERIFY-FAILED — the floor did not block the second branch of the joint pair" ;;
esac
[ "$(dup_on_main "$REPO_F")" = 1 ] \
  || fail "PART F: THE INVARIANT BROKE — main carries $(dup_on_main "$REPO_F") cop(ies) of the block; the joint regression landed"
# 4 gate runs: the red tip, then one per member on the floor. The three ratchet
# re-measurements are cheaper than that — they run the ratchet, not the whole hook —
# and are counted separately in the summary asserted above.
[ "$(verifies "$REPO_F")" = 4 ] \
  || fail "PART F: expected 4 gate runs (1 tip + 3 on the dissolved floor), got $(verifies "$REPO_F")"
echo "merge-batch: PART F ok — nobody blamed, batch dissolved, the floor caught it attributably"

echo "MERGE-BATCH OK"
