#!/usr/bin/env bash
# test/bookkeeping-progress.sh — a commit whose entire diff is chief's own state is
# NOT progress, and cannot buy another iteration.
#
# The run this replays, measured in `formant` on 2026-08-24: tasklist
# `56-neural-synth-ship-flip` was blocked on a measurement only a human could take.
# The agent understood that and said so on every turn — its closing note reads
# "further iterations on this tasklist can only add churn". It was nevertheless
# re-driven eleven times against a five-iteration budget, because each turn stamped a
# note into `.chief/state/prd.json` + `.chief/state/progress.txt` and committed it.
# HEAD moved, the stall counter reset, and the budget extended. Five consecutive
# commits whose entire content was a re-check stamp, and 1h32m of them.
#
# The shape, one fake agent, three tasklists:
#   bk-spin  every turn re-stamps `notes` in the RUNTIME prd.json, appends to
#            progress.txt, force-adds both (chief init gitignores them, exactly as
#            formant's were before they were tracked) and commits with a plausible
#            subject. No story ever flips; nothing outside .chief/state/ is ever
#            touched; it never emits the completion token.
#   bk-both  THE CASE THE NAIVE FIX BREAKS: every turn does REAL work *and* stamps the
#            same two state files in the same commit. It flips no story until the last
#            turn, so the ONLY thing that can score its early iterations as progress is
#            the non-bookkeeping path in the diff — which is precisely the arm under
#            test. "Ignore any commit touching .chief/state/" would score this exactly
#            as it scores bk-spin, and would stall a tasklist that is working.
#
# THE SECOND SHAPE, and the one neither fixture above can reach — a branch that is
# FINISHED. Measured on 2026-09-12 in another repository (named nowhere here, and its
# figures are the run's own): a tasklist whose every story passed had its merge-phase
# verify fail post-rebase for a reason it had not caused, was re-engaged with the
# `## ⚠️ PRIOR VERIFICATION FAILED` block, and then ran 18 iterations against a budget
# of 10. Every header read `3/3 passing`. Each turn committed one more tracked markdown
# note diagnosing an environmental failure it could not fix, and each was scored
# `progress — <that file> changed (outside .chief/state/)` — because with every story
# already passing, no story CAN flip, so the product diff was the only scoring arm left
# and a note satisfied it every single time.
#
# Both fixtures above miss it BY CONSTRUCTION: bk-spin's diff is entirely bookkeeping
# and this one's is not, and bk-both is scored by the arm that is right to keep scoring
# it — a story of its is still false. The distinguishing fact is the one in the header:
# there is no story left for a diff to complete, so the diff is not evidence of progress
# toward completion, and it stops resetting the stall counter.
#
#   bk-allpass  a THIRD tasklist in its OWN repo, because the shape needs a verify hook
#               that FAILS (the two above share a repo whose hook passes, and must keep
#               it). Turn 1 does real work, flips the story and claims completion; the
#               gate says no; every turn after that commits one tracked markdown file
#               outside .chief/state/ and never claims completion again.
#
# What is asserted:
#   1. IT STOPS — at the stall threshold, in exactly $iters turns. Pre-change, HEAD
#      moved every turn, so it ran to HARD_MAX (>= 20) instead. That gap IS the test.
#   2. THE VERDICT IS ON THE DIFF, NOT THE MESSAGE — the fixture's commit subjects read
#      `feat: US-1 - ...`, the same words a real implementing turn writes. The score is
#      still no-progress, which is the discipline the false-complete guard already
#      applies to a claim of completion.
#   3. IT IS SAID OUT LOUD, and distinguishably — an iteration that committed
#      bookkeeping reads BOOKKEEPING ONLY, not the bare "no progress" of a turn that
#      committed nothing, or an operator reading `git log` beside it thinks chief lost
#      the commit.
#   4. NOTHING WAS MERGED and no story was marked passing on the way out.
#   5. THE PAIRING STILL SCORES AS PROGRESS — bk-both's first iteration reads
#      `progress (0/1 passing)`, never BOOKKEEPING ONLY, and the tasklist runs PAST its
#      2-iteration budget to completion on the strength of the real change alone.
#   6. THE BOOKKEEPING IS STILL THERE — the merged tree carries both the product file
#      and the agent's notes/progress stamps. This story removed their power to extend a
#      budget, not their existence.
#   7. THE OPERATOR CAN SEE IT WITHOUT READING THE LOG — `progress (0/2 passing)` is
#      not printable anywhere; the run SUMMARY says this tasklist STOPPED ADVANCING,
#      names WHICH stall it was, keeps it apart from a failed gate and from an
#      unreachable provider, and quotes the agent's own closing words underneath.
#   8. A FINISHED BRANCH CANNOT BUY ITERATIONS PAST ITS BUDGET WITH A DIFF — bk-allpass
#      stops in exactly 7 turns (3 + 2 + 2 across its three attempts) instead of running
#      to the hard ceiling on every one of them, says ALL STORIES PASS rather than either
#      of the other two verdicts, and REPRODUCES FIRST: the same fixture against a copy
#      of the engine with that one condition restored to its pre-change form takes 18.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=bk GIT_AUTHOR_EMAIL=bk@test GIT_COMMITTER_NAME=bk GIT_COMMITTER_EMAIL=bk@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos" CHIEF_WORKTREE_ROOT="$WORK/wt"  # hermetic
fail() { echo "BOOKKEEPING FAIL: $*" >&2
         for l in "$WORK"/repo*/.chief/state/parallel/*.log; do
           [ -f "$l" ] || continue
           echo "--- ${l#"$WORK/"} ---" >&2; tail -60 "$l" >&2
         done
         for r in "$WORK"/run*.log; do
           [ -f "$r" ] || continue
           echo "--- ${r#"$WORK/"} ---" >&2; tail -30 "$r" >&2
         done
         exit 1; }
command -v jq >/dev/null || fail "jq required"

# ── install chief from this checkout (HEAD — commit before trusting a green run) ──
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# ── fake `claude` — the bookkeeping spinner ───────────────────────────────────
# Its turn counter lives OUTSIDE the worktree, which the driver rebuilds per run.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
W="@WORK@"
cat > /dev/null                                  # the prompt; unread here
PRD=".chief/state/prd.json"                      # cwd = the worktree
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
# $BKTAG namespaces the counter: bk-allpass below runs the SAME tasklist name twice
# under one $WORK — once against this engine, once against a neutered copy of it —
# and a shared counter would silently add the two runs together.
C="$W/turns-${BKTAG:-}$name"
turn=$(( $(cat "$C" 2>/dev/null || echo 0) + 1 )); echo "$turn" > "$C"

# THE STAMP BOTH FIXTURES WRITE: a note on the story and a line in the progress log.
# Identical in each — the only difference between them is whether anything ELSE moved.
stamp() {
  t="$(mktemp)"
  jq --arg n "turn $turn: $1" '.userStories |= map(if .id=="US-1" then .notes=$n else . end)' \
     "$PRD" > "$t" && mv "$t" "$PRD"
  printf 'turn %s: %s\n' "$turn" "$1" >> .chief/state/progress.txt
  # Force-added: `chief init` gitignores .chief/state/. formant's were tracked, which is
  # how a state-only commit gets made at all — the point is that it IS one.
  git add -f .chief/state/prd.json .chief/state/progress.txt >/dev/null 2>&1 || true
}

case "$name" in
bk-spin)
  # THE RE-CHECK STAMP, AND NOTHING ELSE. `notes` only — `passes` is never touched,
  # because the story is blocked on something this agent cannot do.
  stamp "re-checked; still blocked on the hardware measurement. Further iterations can only add churn."
  # A PLAUSIBLE SUBJECT over a bookkeeping diff: the rule under test reads the diff.
  git commit -q -m "feat: US-1 - record the re-check and the blocker" >/dev/null 2>&1 || true
  # Formant's closing note, near-verbatim. Nothing in chief MATCHES on it (see the
  # stall arm in engine/agent.sh) — it is here because the run summary QUOTES the
  # agent's last words, and this is the sentence that was buried at iteration 10.
  echo "re-checked; still blocked on the hardware measurement. Further iterations on this tasklist can only add churn; re-parking it would be the honest call."
  ;;
bk-both)
  # REAL WORK AND THE STAMP, IN ONE COMMIT — the normal shape of a working iteration.
  mkdir -p src; printf 'step %s\n' "$turn" > "src/step-$turn.txt"
  stamp "implemented step $turn and recorded it."
  # The story flips only on the LAST turn, so turns 1..2 can be scored as progress by
  # NOTHING except the src/ path in the diff. That is the arm this fixture exists for.
  if [ "$turn" -ge 3 ]; then
    for f in "$PRD" "tasks/chief/$name.json"; do
      [ -f "$f" ] || continue
      t="$(mktemp)"; jq '(.userStories[]|select(.id=="US-1").passes)=true' "$f" > "$t" && mv "$t" "$f"
    done
    git add -f "$PRD" >/dev/null 2>&1 || true
  fi
  git add -A >/dev/null 2>&1 || true
  git commit -q -m "feat: US-1 - step $turn, and a note about it" >/dev/null 2>&1 || true
  [ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
  echo "step $turn done"
  ;;
bk-allpass)
  # THE FINISHED BRANCH. Two behaviours, selected by the state the turn BEGINS in —
  # which is the same fact the scoring arm under test reads, and the reason this
  # fixture needs no turn-number special cases.
  if [ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" != "0" ]; then
    # (a) A REAL implementing turn: product, the flip, an observed value in `notes`,
    # and a claim of completion. The gate then says no — which is where the incident
    # starts, not where it ends.
    mkdir -p src; printf 'the product\n' > src/product.txt
    for f in "$PRD" "tasks/chief/$name.json"; do
      [ -f "$f" ] || continue
      t="$(mktemp)"
      jq '(.userStories[]|select(.id=="US-1")) |= (.passes=true | .notes="built it; suite green, 0 failed")' \
         "$f" > "$t" && mv "$t" "$f"
    done
    git add -A -f >/dev/null 2>&1 || true
    git commit -q -m "feat: US-1 - build the product" >/dev/null 2>&1 || true
    echo "<promise>COMPLETE</promise>"
    exit 0
  fi
  # (b) EVERY TURN AFTER: one more tracked markdown file, outside .chief/state/,
  # recording one more diagnosis of a gate failure this branch did not cause. Real
  # product by every test chief has — a NEW tracked path, a moved HEAD, a plausible
  # subject — and it completes nothing, because there is nothing left to complete.
  # It never claims completion again, so the agent boundary's verify never re-runs
  # and no recorded verdict ever changes: the stall counter is the only thing left.
  mkdir -p notes
  printf 'turn %s: the gate died inside the allocator again. Not caused by this branch.\n' "$turn" \
    > "notes/diagnosis-$turn.md"
  git add -A -f >/dev/null 2>&1 || true
  git commit -q -m "docs: US-1 - diagnose the failing gate (turn $turn)" >/dev/null 2>&1 || true
  echo "turn $turn: the gate failure is environmental — the OS killed the test binary. I cannot fix it from here."
  ;;
esac
exit 0
FAKE
sed -i.bak "s#@WORK@#$WORK#" "$WORK/fakebin/claude" && rm -f "$WORK/fakebin/claude.bak"
chmod +x "$WORK/fakebin/claude"

# ── scaffold a repo with one tasklist and a verify hook that would PASS ───────
REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null
rm -f tasks/chief/example.json
ITERS=2   # HARD_MAX is max(3*iters,20) = 20, so a spinner has 18 turns of room to run
jq -n --argjson it "$ITERS" \
  '{project:"bk",branchName:"chief/bk-spin",description:"a tasklist that cannot advance",
    iters:$it,dependsOn:[],touches:[".chief/state"],warmup:[],
    userStories:[{id:"US-1",title:"ship the flip",description:"",
      acceptanceCriteria:["the hardware measurement is taken"],passes:false,notes:""}]}' \
  > tasks/chief/bk-spin.json
# The pairing case, same budget: real work AND a state stamp every turn. It must run
# PAST $ITERS, because nothing about it is a stall. Both tasklists write the same two
# state files, which is exactly what a `touches` domain is for — they share one, so the
# scheduler serializes them and the run does not report an under-tagged overlap it is
# right about. The domain they share is `.chief/state` itself, which also puts both
# tasklists in the position US-2's third criterion asks about: declaring the state
# directory in `touches` must not silently exempt (or silently reclassify) anything.
jq -n --argjson it "$ITERS" \
  '{project:"bk",branchName:"chief/bk-both",description:"a tasklist that works and takes notes",
    iters:$it,dependsOn:[],touches:[".chief/state"],warmup:[],
    userStories:[{id:"US-1",title:"do the work",description:"",
      acceptanceCriteria:["src/ carries the steps"],passes:false,notes:""}]}' \
  > tasks/chief/bk-both.json
printf '#!/usr/bin/env bash\nset -eu\necho "verify: (would pass)"\nexit 0\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "bk setup"

PATH="$WORK/fakebin:$PATH" "$CHIEF" run >"$WORK/run.log" 2>&1 || true   # a stall exits non-zero
LOG="$REPO/.chief/state/parallel/bk-spin.log"
status() { cat "$REPO/.chief/state/parallel/$1.status" 2>/dev/null || echo MISSING; }
[ -f "$LOG" ] || fail "no worker log at $LOG"

# ── 0. the fixture really did commit state and ONLY state ────────────────────
# If this fails the rest proves nothing: the test would be stopping a run that never
# made the commits it is supposed to be scoring.
spun="$(cat "$WORK/turns-bk-spin" 2>/dev/null || echo 0)"
[ "$spun" -ge 1 ] || fail "the fake agent never ran"
BR="$(git -C "$REPO" rev-parse --verify chief/bk-spin 2>/dev/null || echo '')"
[ -n "$BR" ] || fail "the work branch was never created"
# Against the MERGE BASE, not `main`: bk-both merges into main during this same run, so
# `git diff main $BR` would report its files as deletions and this assertion would fail
# on another tasklist's work.
base="$(git -C "$REPO" merge-base main "$BR")"
touched="$(git -C "$REPO" diff --name-only "$base" "$BR")"
[ -n "$touched" ] || fail "the spinner committed nothing at all — the fixture is not exercising the path"
outside="$(printf '%s\n' "$touched" | grep -v '^\.chief/state/' || true)"
[ -z "$outside" ] || fail "the fixture touched more than bookkeeping: $outside"
# Captured, never piped into `grep -q`: under `pipefail` an early-exiting grep SIGPIPEs
# the `git log` behind it, and the assertion fails on the length of the history rather
# than its content — which is exactly the variable this test exists to change.
subjects="$(git -C "$REPO" log --format=%s "$base..$BR")"
case "$subjects" in *"feat: US-1"*) ;; *) fail "the fixture's commits do not carry an implementation-shaped subject" ;; esac

# ── 1. THE ASSERTION: it stops at the budget instead of extending forever ────
[ "$spun" = "$ITERS" ] \
  || fail "the spinner took $spun turns against a $ITERS-iter budget (hard cap 20) — a state-only commit is still extending the budget"

# ── 2. …scored as a stall, and named as bookkeeping ──────────────────────────
grep -q 'no progress' "$LOG" || fail "a bookkeeping-only iteration was never scored as no progress"
grep -q 'BOOKKEEPING ONLY' "$LOG" \
  || fail "the log does not distinguish a bookkeeping commit from an iteration that committed nothing"
grep -q "stall $ITERS/" "$LOG" || fail "the stall counter never reached the limit"
! grep -q "Iteration $ITERS: progress" "$LOG" \
  || fail "an iteration whose whole diff was .chief/state/ was reported as progress"
grep -q 'stalled .* without completing' "$LOG" || fail "the run does not report why it stopped"
# …and the tasklist DECLARED `.chief/state` in its touches, which changes the verdict
# not at all — but is said out loud rather than left to be discovered, because an author
# who wrote that declaration believed the directory was in scope.
grep -q 'does NOT exempt it' "$LOG" \
  || fail "a tasklist that lists the state dir in \`touches\` was reclassified as bookkeeping SILENTLY"

# ── 3. nothing merged, nothing marked passing ────────────────────────────────
case "$(status bk-spin)" in INCOMPLETE*) ;; *) fail "expected INCOMPLETE, got: '$(status bk-spin)'" ;; esac
[ ! -f "$REPO/tasks/chief/completed/bk-spin.json" ] || fail "the stalled tasklist was retired"
[ "$(jq -r '[.userStories[]|select(.passes==true)]|length' "$REPO/.chief/state/snapshots/bk-spin.json" 2>/dev/null || echo 0)" = "0" ] \
  || fail "a story was marked passing by a run that only wrote notes"

# ── 4. THE PAIRING: real work + a state stamp in one commit is still progress ─
# The case the naive fix ("ignore any commit that touches .chief/state/") breaks. Its
# early turns flip no story, so if the diff rule did not look PAST the bookkeeping paths
# this tasklist would score exactly like bk-spin and stall at $ITERS with work landing.
BOTHLOG="$REPO/.chief/state/parallel/bk-both.log"
[ -f "$BOTHLOG" ] || fail "no worker log at $BOTHLOG — the pairing case never ran"
both="$(cat "$WORK/turns-bk-both" 2>/dev/null || echo 0)"
[ "$both" -gt "$ITERS" ] \
  || fail "the pairing case took $both turns against a $ITERS-iter budget — a commit carrying REAL work was scored as bookkeeping because it also wrote notes"
prog1="$(grep -m1 'Iteration 1: progress' "$BOTHLOG" || true)"
[ -n "$prog1" ] \
  || fail "an iteration that changed the product but flipped no story was not scored as progress"
case "$prog1" in *"(0/1 passing)"*) ;; *) fail "the progress line lost its passing count: $prog1" ;; esac
# US-3: the line NAMES what advanced. Iteration 1 flipped no story, so the only thing
# it can name is the path outside the state dir — which is the whole point.
case "$prog1" in *"src/step-1.txt"*) ;;
  *) fail "the progress line does not say WHAT advanced: $prog1" ;; esac
! grep -q 'BOOKKEEPING ONLY' "$BOTHLOG" \
  || fail "a commit containing work outside ${CHIEF_STATE_DIR:-.chief/state}/ was reported as bookkeeping"
! grep -q 'no progress' "$BOTHLOG" || fail "a working iteration was scored as a stall"
case "$(status bk-both)" in MERGED*) ;; *) fail "expected MERGED for the pairing case, got: '$(status bk-both)'" ;; esac

# ── 5. …and the bookkeeping it wrote is STILL THERE, merged ──────────────────
# This story removed the power of a state write to extend a budget, not its existence:
# notes and progress records are how the next iteration and a human reader learn what
# was tried, and a fix that dropped them would be a different bug.
merged="$(git -C "$REPO" show "main:.chief/state/progress.txt" 2>/dev/null || echo '')"
case "$merged" in *"implemented step 1 and recorded it."*) ;;
  *) fail "the agent's progress record did not survive to main — bookkeeping must stay SUPPORTED, just not budget-extending" ;; esac
git -C "$REPO" show "main:src/step-1.txt" >/dev/null 2>&1 || fail "the pairing case's real work never merged"
[ -f "$REPO/tasks/chief/completed/bk-both.json" ] || fail "the completed tasklist was not retired"
notes="$(jq -r '.userStories[0].notes // empty' "$REPO/tasks/chief/completed/bk-both.json" 2>/dev/null || echo '')"
[ -n "$notes" ] || fail "the retired record carries no notes — the state write was stripped somewhere"

# ── 6. THE OPERATOR CAN SEE THE DIFFERENCE WITHOUT READING THE LOG ──────────
# 6a. `progress (0/2 passing). Continuing...` must not be PRINTABLE. Stated over both
# logs and the run log at once, because the sentence is a template and a single
# surviving call site reproduces the whole misread.
bad=""
for f in "$LOG" "$BOTHLOG" "$WORK/run.log"; do
  [ -f "$f" ] || continue
  hit="$(LC_ALL=C grep -n ': progress ([0-9]' "$f" || true)"
  [ -n "$hit" ] && bad="$bad
$f: $hit"
done
[ -z "$bad" ] || fail "the nameless progress line is still printable — it asserts progress and a count and names nothing:$bad"

# 6b. A tasklist stopped by the stall counter says WHY, in the RUN SUMMARY, and
# distinguishably from a failed gate and from an unreachable provider.
sum="$(cat "$WORK/run.log")"
case "$sum" in *"STOPPED ADVANCING"*) ;;
  *) fail "the run summary does not separate a tasklist that stopped advancing from any other failure" ;; esac
case "$sum" in *"Not a failed gate, and not an unreachable provider"*) ;;
  *) fail "the summary does not distinguish this stop from VERIFY-FAILED and PROVIDER-UNAVAILABLE" ;; esac
# The REASON, not just the category: which of the two stalls this was.
case "$sum" in *"bookkeeping, not progress"*) ;;
  *) fail "the run summary does not name the bookkeeping stall as the cause" ;; esac
# …and the INCOMPLETE headline carries it too, so a reader of the worker log gets the
# same answer as a reader of the summary.
head_line="$(grep -h 'INCOMPLETE' "$REPO/.chief/state/parallel/bk-spin.log" "$WORK/run.log" 2>/dev/null | head -1 || true)"
case "$head_line" in *stalled:*) ;;
  *) fail "the INCOMPLETE headline still reports a nameless budget exhaustion: $head_line" ;; esac
# The tasklist that MERGED is not in the block — the report is about this stop, not
# about every tasklist in the run. Asserted on the record the block is built FROM,
# not on the rendered text: `bk-both` appears in the summary for legitimate reasons.
[ ! -e "$REPO/.chief/state/parallel/bk-both.stalled" ] \
  || fail "a merged tasklist was recorded as having stopped advancing"
[ -s "$REPO/.chief/state/parallel/bk-spin.stalled" ] \
  || fail "the stalled tasklist left no reason record for the summary to render"

# 6c. The agent's own last words are SURFACED, not buried at iteration 10 of a log.
# Chief matches nothing in them — the fixture's sentence could be any prose — it quotes
# the final turn's output verbatim beneath the reason.
case "$sum" in *"re-parking it would be the honest call"*) ;;
  *) fail "the agent's closing words — the run's clearest signal that it should stop — are still only in the log" ;; esac

# ══════════════════════════════════════════════════════════════════════════════
# THE FINISHED BRANCH — a diff cannot buy iterations past the budget
# ══════════════════════════════════════════════════════════════════════════════
# Its own repo, because the hook must FAIL: everything above depends on a hook that
# passes, and a re-engagement is what puts an all-passing branch back in front of the
# agent in the first place. Same fake `claude`, third arm.
#
# HARD_MAX is pinned rather than left at its default max(3*iters,20)=20. The claim
# being made is "stops at the budget instead of running to the ceiling", and both
# halves must be measured against the SAME ceiling for the comparison to mean
# anything; 6 makes the neutered half of this file cost ~1 minute instead of ~4.
APITERS=2
APCAP=6
AP_EXPECT=7                  # 3 + 2 + 2 turns across the three attempts RETRY_MAX allows
AP_PRE_EXPECT=$(( 3 * APCAP ))   # pre-change: every attempt runs to the ceiling instead

# Scaffolds the fixture repo. Called twice — once for this engine, once for a copy of
# it with the arm under test neutered — because a run leaves its branch, its state and
# its registry entry behind, and reusing a repo would measure the second run against
# the first one's leftovers rather than against the same starting point.
ap_scaffold() {
  local dir="$1" ch="$2"
  mkdir -p "$dir"; ( cd "$dir" || exit 1
    git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
    git commit -q --allow-empty -m init
    "$ch" init >/dev/null
    rm -f tasks/chief/example.json
    jq -n --argjson it "$APITERS" \
      '{project:"bk",branchName:"chief/bk-allpass",
        description:"a branch that finishes and then sits behind a gate it did not break",
        iters:$it,dependsOn:[],touches:["src"],warmup:[],
        userStories:[{id:"US-1",title:"build the product",description:"",
          acceptanceCriteria:["src/ carries the product"],passes:false,notes:""}]}' \
      > tasks/chief/bk-allpass.json
    # The gate that says no for a reason the branch did not cause. Deterministic here;
    # in the field it was one test binary killed by the OS under host memory pressure.
    printf '#!/usr/bin/env bash\nset -eu\necho "verify: the test binary was killed by the OS (SIGTRAP inside the allocator)"\nexit 1\n' \
      > .chief/verify.sh
    chmod +x .chief/verify.sh
    git add -A && git commit -q -m "allpass setup" )
}

# ── A. this engine: it stops at the budget ───────────────────────────────────
APREPO="$WORK/repo-ap"
ap_scaffold "$APREPO" "$CHIEF" || fail "could not scaffold the all-pass fixture"
( cd "$APREPO" && PATH="$WORK/fakebin:$PATH" BKTAG="ap-" HARD_MAX="$APCAP" \
    "$CHIEF" run >"$WORK/run-ap.log" 2>&1 ) || true    # a stall exits non-zero
APLOG="$APREPO/.chief/state/parallel/bk-allpass.log"
[ -f "$APLOG" ] || fail "no worker log at $APLOG — the all-pass fixture never ran"
ap="$(cat "$WORK/turns-ap-bk-allpass" 2>/dev/null || echo 0)"

# 8a. THE FIXTURE IS THE SHAPE IT CLAIMS TO BE. Without these four, a green run below
# proves only that something stopped — not that it stopped the thing this file is about.
grep -q 'FAILED verify last run — re-engaging' "$APLOG" \
  || fail "the branch was never re-engaged after a failed gate — this is not the shape under test"
APBR="$(git -C "$APREPO" rev-parse --verify chief/bk-allpass 2>/dev/null || echo '')"
[ -n "$APBR" ] || fail "the all-pass work branch was never created"
apbase="$(git -C "$APREPO" merge-base main "$APBR")"
aptouched="$(git -C "$APREPO" diff --name-only "$apbase" "$APBR")"
case "$aptouched" in *notes/diagnosis-*) ;;
  *) fail "the spinning turns committed no tracked file outside .chief/state/ — the fixture is not exercising the arm: $aptouched" ;; esac
# …and it really was ALL-PASSING while it spun, which is the distinguishing fact. Read
# off the header chief itself prints, not off the fixture's own bookkeeping.
grep -q 'Chief Iteration 2 .*1/1 passing' "$APLOG" \
  || fail "the iteration after the flip did not begin with every story passing"

# 8b. THE ASSERTION: an exact turn count, at the budget, and the ceiling never reached.
[ "$ap" = "$AP_EXPECT" ] \
  || fail "the all-pass branch took $ap turns, expected $AP_EXPECT ($APITERS-iter budget, ceiling $APCAP, 3 attempts) — a diff is still extending the budget of a branch with no story left to complete"
! grep -q 'hard iteration ceiling' "$APLOG" \
  || fail "the all-pass branch ran all the way to the hard ceiling ($APCAP) instead of stopping at its $APITERS-iter budget"

# 8c. SAID OUT LOUD, and as none of the other two verdicts. Its diff is real product, so
# BOOKKEEPING ONLY would be false; it committed on every turn, so the bare `no progress`
# would read to an operator with `git log` open as chief having lost the commit.
grep -q 'ALL STORIES PASS' "$APLOG" \
  || fail "the log does not name the state — a finished branch whose diff did not count reads like any other stall"
grep -q 'the diff does not extend the budget' "$APLOG" \
  || fail "the line does not say what the diff did NOT buy"
! grep -q 'BOOKKEEPING ONLY' "$APLOG" \
  || fail "an iteration that committed a tracked file outside .chief/state/ was reported as bookkeeping"
! LC_ALL=C grep -qE 'Iteration [0-9]+: no progress \(stall' "$APLOG" \
  || fail "an iteration that committed real product was scored with the bare no-progress line"

# 8d. THE GIVE-UP ARM NAMES WHICH STALL THIS WAS — the record the driver and the summary
# read, not a different sentence assembled for the log.
grep -q 'stalled: the branch is all-passing and its diffs did not count' "$APLOG" \
  || fail "the give-up arm does not report that the branch was all-passing and its diffs did not count"

# 8e. NOTHING MERGED. The gate is still red, and a stop is not a pass.
case "$(cat "$APREPO/.chief/state/parallel/bk-allpass.status" 2>/dev/null || echo MISSING)" in
  VERIFY-FAILED*) ;;
  *) fail "expected VERIFY-FAILED for the all-pass fixture, got: '$(cat "$APREPO/.chief/state/parallel/bk-allpass.status" 2>/dev/null || echo MISSING)'" ;;
esac
[ ! -f "$APREPO/tasks/chief/completed/bk-allpass.json" ] || fail "a branch behind a red gate was retired"
git -C "$APREPO" show "main:src/product.txt" >/dev/null 2>&1 \
  && fail "the all-pass branch merged despite a failing gate"

# ── B. IT REPRODUCES FIRST ───────────────────────────────────────────────────
# The same fixture against the arm as it stood BEFORE this change, so 8b cannot pass by
# restating behaviour that always worked. The pre-change form is restored in a COPY of
# the installed engine — not recovered with `git show HEAD~N` (CI clones shallow), and
# not pinned with CHIEF_VERSION either: install.sh clones `file://$ROOT` and a
# `--branch <sha>` that fails falls back to cloning the checkout's own branch, so a
# "pre-fix" install that way silently measures THIS code.
PRE_PREFIX="$WORK/ch-pre"; PRE_BIN="$WORK/bin-pre"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PRE_PREFIX" CHIEF_BINDIR="$PRE_BIN" sh "$ROOT/install.sh" >/dev/null \
  || fail "the pre-change install failed"
PRECHIEF="$PRE_BIN/chief"
PREAGENT="$PRE_PREFIX/src/engine/agent.sh"
# Through ENVIRON, never `awk -v`, which escape-processes its value. Exactly one line
# must match: a zero here means the condition was refactored and this half is measuring
# the fixed engine while claiming to measure the old one, so it is a hard failure.
NEUTERED_LINE='  if [ "$now_pass" -gt "$prev_pass" ] || [ "$prod" = 1 ]; then'
export NEUTERED_LINE
LC_ALL=C awk '
  index($0, "[ \"$prod\" = 1 ] && [ \"$allpass\" = 0 ]") { print ENVIRON["NEUTERED_LINE"]; n++; next }
  { print }
  END { if (n != 1) exit 3 }
' "$PREAGENT" > "$PREAGENT.pre" \
  || fail "could not neuter the scoring arm in the installed copy — the condition this test pins no longer exists in engine/agent.sh"
mv "$PREAGENT.pre" "$PREAGENT"; chmod +x "$PREAGENT"

PREREPO="$WORK/repo-pre"
ap_scaffold "$PREREPO" "$PRECHIEF" || fail "could not scaffold the pre-change fixture"
( cd "$PREREPO" && PATH="$WORK/fakebin:$PATH" BKTAG="pre-" HARD_MAX="$APCAP" \
    "$PRECHIEF" run >"$WORK/run-pre.log" 2>&1 ) || true
PRELOG="$PREREPO/.chief/state/parallel/bk-allpass.log"
[ -f "$PRELOG" ] || fail "no worker log at $PRELOG — the pre-change fixture never ran"
pre="$(cat "$WORK/turns-pre-bk-allpass" 2>/dev/null || echo 0)"

[ "$pre" = "$AP_PRE_EXPECT" ] \
  || fail "the pre-change engine took $pre turns on this fixture, expected $AP_PRE_EXPECT — the neutered arm does not reproduce the incident, so the $AP_EXPECT above is not evidence of a fix"
grep -q 'hard iteration ceiling' "$PRELOG" \
  || fail "the pre-change engine did not run to the ceiling — the fixture does not reproduce"
! grep -q 'ALL STORIES PASS' "$PRELOG" \
  || fail "the neutered engine still printed the new verdict — the neuter did not take"
[ "$pre" -gt "$ap" ] || fail "pre-change ($pre) did not exceed post-change ($ap) — nothing was demonstrated"

echo "BOOKKEEPING PASS — $ITERS turns of state-only commits scored as stalls and stopped at the budget (pre-change: 20), reported as BOOKKEEPING ONLY, nothing merged; the work+notes pairing ran $both turns to COMPLETE with its notes intact on main"
echo "ALL-PASS PASS — a re-engaged branch with every story passing stopped in $ap turns against a $APITERS-iter budget, scored ALL STORIES PASS, nothing merged; the same fixture on the pre-change arm took $pre (ceiling $APCAP, three attempts)"
