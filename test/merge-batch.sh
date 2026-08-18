#!/usr/bin/env bash
# test/merge-batch.sh — the OPT-IN batch merge queue (engine/mergequeue.sh ·
# docs/explanation/drivers-and-safety.md).
#
# tasks/chief/92-opt-in-batch-then-bisect-merge-queue. The feature's whole claim is a
# trade: pay the verify gate ONCE for N branches instead of N times, without weakening
# anything the serialized floor guarantees. Two halves of that claim are asserted here,
# and the FIRST one is the one that matters most:
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
#
# Both halves count the SAME thing the same way: the project's verify hook increments
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
CHIEF="$ROOT/bin/chief"
LOG=""
fail() { echo "MERGE-BATCH FAIL: $*" >&2; [ -n "$LOG" ] && [ -f "$LOG" ] && tail -80 "$LOG" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

export OZ_WORK="$WORK"
NAMES="alpha bravo charlie"

mkdir -p "$WORK/fakebin"
# ── the fake agent: one story per turn, one artifact, one commit ──────────────
# A per-tasklist artifact path ON PURPOSE: two tasklists writing the same bytes to
# the same path would leave the second branch with an EMPTY diff vs a base the first
# already merged into, and the no-work guard — not the merge queue — would be what
# this measured.
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
: "${OZ_WORK:?}"
cat >/dev/null
PRD=".chief/state/prd.json"
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"; TRACKED="tasks/chief/$name.json"
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
[ -n "$id" ] || exit 0
out="out/$name/$id.txt"
mkdir -p "$(dirname "$out")"
printf 'artifact %s of %s\n' "$id" "$name" > "$out"
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
# churn and is readable from here. Serialized by $MERGE_LOCK in both parts, so the
# read-modify-write needs no lock of its own.
make_repo() {
  local repo="$1"
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
    for t in alpha bravo charlie; do
      jq -n --arg n "$t" '
        { project:"oz", branchName:("chief/" + $n), description:("merge-queue fixture " + $n),
          iters:3, dependsOn:[], touches:["domain-" + $n], warmup:[],
          userStories:[ { id:"US-1", title:("story of " + $n), description:"",
                          acceptanceCriteria:[("out/" + $n + "/US-1.txt exists")], passes:false, notes:"" } ] }' \
        > "tasks/chief/$t.json"
    done
    git add -A && git commit -q -m setup )
}

verifies() { cat "$WORK/$(basename "$1").verifies" 2>/dev/null || echo 0; }
# The queue's own narration goes to the LEADER's per-tasklist log, not to the driver's
# stdout — a worker redirects everything it prints into $STATE/parallel/<name>.log. So
# every assertion about what the queue said reads those, and the driver stdout ($LOG)
# is only asserted on for what the SUMMARY prints.
wlogs()    { cat "$1"/.chief/state/parallel/*.log 2>/dev/null || true; }
status()   { cat "$1/.chief/state/parallel/$2.status" 2>/dev/null || echo MISSING; }
merges()   { ( cd "$1" && git log main --oneline | grep -c 'Merge chief/' ) || true; }
retired()  { [ -f "$1/tasks/chief/completed/$2.json" ]; }

# ══ PART A — THE NEGATIVE CONTROL: no flag, no batching, N verifies for N ═════
echo "merge-batch: PART A — with the opt-in absent, the merge phase is the serialized floor"
REPO_A="$WORK/plain"
make_repo "$REPO_A"
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
make_repo "$REPO_B"
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
  ( cd "$REPO_B" && git show "main:out/$n/US-1.txt" >/dev/null 2>&1 ) \
    || fail "PART B: $n's artifact never reached main"
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
make_repo "$REPO_C"
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
if ( cd "$REPO_C" && git show "main:out/charlie/US-1.txt" >/dev/null 2>&1 ); then
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

echo "MERGE-BATCH OK"
