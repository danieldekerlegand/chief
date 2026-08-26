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
# The shape, one fake agent, one tasklist:
#   bk-spin  every turn re-stamps `notes` in the RUNTIME prd.json, appends to
#            progress.txt, force-adds both (chief init gitignores them, exactly as
#            formant's were before they were tracked) and commits with a plausible
#            subject. No story ever flips; nothing outside .chief/state/ is ever
#            touched; it never emits the completion token.
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
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=bk GIT_AUTHOR_EMAIL=bk@test GIT_COMMITTER_NAME=bk GIT_COMMITTER_EMAIL=bk@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos" CHIEF_WORKTREE_ROOT="$WORK/wt"  # hermetic
fail() { echo "BOOKKEEPING FAIL: $*" >&2
         [ -f "$WORK/repo/.chief/state/parallel/bk-spin.log" ] && tail -60 "$WORK/repo/.chief/state/parallel/bk-spin.log" >&2
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
# THE RE-CHECK STAMP, and nothing else. `notes` only — `passes` is never touched,
# because the story is blocked on something this agent cannot do.
t="$(mktemp)"
jq --arg n "turn $turn: re-checked; still blocked on the hardware measurement. Further iterations can only add churn." \
   '.userStories |= map(if .id=="US-1" then .notes=$n else . end)' "$PRD" > "$t" && mv "$t" "$PRD"
printf 'turn %s: re-checked, still blocked.\n' "$turn" >> .chief/state/progress.txt
# Force-added: `chief init` gitignores .chief/state/. formant's were tracked, which is
# how a state-only commit gets made at all — the point is that it IS one.
git add -f .chief/state/prd.json .chief/state/progress.txt >/dev/null 2>&1 || true
# A PLAUSIBLE SUBJECT over a bookkeeping diff: the rule under test reads the diff.
git commit -q -m "feat: US-1 - record the re-check and the blocker" >/dev/null 2>&1 || true
echo "re-checked; the story is not complete"
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
    iters:$it,dependsOn:[],touches:["bk-spin"],warmup:[],
    userStories:[{id:"US-1",title:"ship the flip",description:"",
      acceptanceCriteria:["the hardware measurement is taken"],passes:false,notes:""}]}' \
  > tasks/chief/bk-spin.json
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
touched="$(git -C "$REPO" diff --name-only main "$BR")"
[ -n "$touched" ] || fail "the spinner committed nothing at all — the fixture is not exercising the path"
outside="$(printf '%s\n' "$touched" | grep -v '^\.chief/state/' || true)"
[ -z "$outside" ] || fail "the fixture touched more than bookkeeping: $outside"
# Captured, never piped into `grep -q`: under `pipefail` an early-exiting grep SIGPIPEs
# the `git log` behind it, and the assertion fails on the length of the history rather
# than its content — which is exactly the variable this test exists to change.
subjects="$(git -C "$REPO" log --format=%s "main..$BR")"
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

# ── 3. nothing merged, nothing marked passing ────────────────────────────────
case "$(status bk-spin)" in INCOMPLETE*) ;; *) fail "expected INCOMPLETE, got: '$(status bk-spin)'" ;; esac
[ ! -f "$REPO/tasks/chief/completed/bk-spin.json" ] || fail "the stalled tasklist was retired"
[ "$(jq -r '[.userStories[]|select(.passes==true)]|length' "$REPO/.chief/state/snapshots/bk-spin.json" 2>/dev/null || echo 0)" = "0" ] \
  || fail "a story was marked passing by a run that only wrote notes"

echo "BOOKKEEPING PASS — $ITERS turns of state-only commits scored as stalls and stopped at the budget (pre-change: 20), reported as BOOKKEEPING ONLY, nothing merged"
