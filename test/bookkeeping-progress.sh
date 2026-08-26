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
# The shape, one fake agent, two tasklists:
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
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=bk GIT_AUTHOR_EMAIL=bk@test GIT_COMMITTER_NAME=bk GIT_COMMITTER_EMAIL=bk@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos" CHIEF_WORKTREE_ROOT="$WORK/wt"  # hermetic
fail() { echo "BOOKKEEPING FAIL: $*" >&2
         for l in bk-spin bk-both; do
           [ -f "$WORK/repo/.chief/state/parallel/$l.log" ] || continue
           echo "--- $l.log ---" >&2; tail -60 "$WORK/repo/.chief/state/parallel/$l.log" >&2
         done
         [ -f "$WORK/run.log" ] && tail -30 "$WORK/run.log" >&2
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
turn=$(( $(cat "$W/turns-$name" 2>/dev/null || echo 0) + 1 )); echo "$turn" > "$W/turns-$name"

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
  echo "re-checked; the story is not complete"
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
grep -q "Iteration 1: progress (0/1 passing)" "$BOTHLOG" \
  || fail "an iteration that changed the product but flipped no story was not scored as progress"
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

echo "BOOKKEEPING PASS — $ITERS turns of state-only commits scored as stalls and stopped at the budget (pre-change: 20), reported as BOOKKEEPING ONLY, nothing merged; the work+notes pairing ran $both turns to COMPLETE with its notes intact on main"
