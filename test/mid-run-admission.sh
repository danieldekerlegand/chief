#!/usr/bin/env bash
# test/mid-run-admission.sh — AN ADMITTED TASKLIST IS INDISTINGUISHABLE FROM ONE NAMED
# AT LAUNCH, through the real driver (engine/admit.sh · engine/driver.sh ·
# docs/reference/mid-run-admission.md).
#
# tasks/chief/127-a-live-run-accepts-new-work US-2. `chief offer` recording a request
# is one claim; a run that then SCHEDULES, MERGES and ACCOUNTS FOR the newcomer exactly
# as it does for a launch name is a different one, and only the second is the feature —
# an operator killed a live run on 2026-09-16 precisely because appending a name was not
# something the tool could do.
#
#   PART A  THE ADMISSION, END TO END. A run starts with `alpha beta`; `gamma` is
#           offered from inside alpha's FIRST agent turn — a worker genuinely
#           mid-iteration, not a quiet driver between waves — and the test asserts:
#             · the LAUNCH TREATMENT: stale per-run files planted for gamma before the
#               run (a `.stalled` flag, a spent `.attempts` budget, a `.why` from
#               another day, a `.log` with a marker in it) are cleared, exactly as the
#               launch loop clears them for a name given on the command line;
#             · NO WAVE JUMPED: beta, which was waiting when gamma arrived, merges
#               first;
#             · THE ACCOUNTING: gamma in the end-of-run summary, in the headless JSON
#               summary, in the run's registry entry and in `chief ps` — the last two
#               read WHILE the run is live, because that is the only time they exist;
#             · IN-FLIGHT WORK UNTOUCHED: alpha's branch, worktree and iteration
#               counter, sampled by the worker itself either side of the admission.
#   PART B  THE CONTROL. The same fixture with the offer never made ends with two
#           tasklists, gamma unrun and still in tasks/chief/. Without it PART A would
#           pass just as well against a driver that ran every tasklist it could find —
#           which is the auto-scan this feature refuses to be.
#
# Hermetic: a scripted fake `claude` on PATH, temp prefixes ($CHIEF_PREFIX included),
# never touches the real ~/.chief. Drives bin/chief straight out of this checkout, so it
# tests uncommitted work.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rc=$?; rm -rf "$WORK"; exit "$rc"' EXIT
export GIT_AUTHOR_NAME=mra GIT_AUTHOR_EMAIL=mra@test GIT_COMMITTER_NAME=mra GIT_COMMITTER_EMAIL=mra@test
export CHIEF_PREFIX="$WORK/ch" CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
# Both would add a hold to a branch below, and "gamma merged" would then be asserting
# something else entirely.
unset CHIEF_ZONES CHIEF_DIFF_BUDGET CHIEF_DIFF_BUDGET_LINES CHIEF_DIFF_BUDGET_FILES 2>/dev/null || true
CHIEF="$ROOT/bin/chief"
LOG=""
fail() { echo "MID-RUN-ADMISSION FAIL: $*" >&2; [ -n "$LOG" ] && [ -f "$LOG" ] && tail -80 "$LOG" >&2; exit 1; }
command -v jq  >/dev/null || fail "jq is required"
command -v git >/dev/null || fail "git is required"

export MRA_WORK="$WORK" MRA_CHIEF="$CHIEF" MRA_RUNS="$CHIEF_RUNS"

# ── the fake agent ────────────────────────────────────────────────────────────
# Ordinary for every tasklist but alpha, whose FIRST turn is where the offer is made:
# the worker is then demonstrably mid-iteration (this process IS the agent turn), which
# is the timing claim the feature makes and the one a test driving `chief offer` from
# the outside cannot pin down.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
: "${MRA_WORK:?}" "${MRA_CHIEF:?}" "${MRA_REPO:?}"
cat >/dev/null                                  # drain the prompt on stdin
PRD=".chief/state/prd.json"                     # cwd = the worktree (set by the driver)
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
TRACKED="tasks/chief/$name.json"
ST="$MRA_REPO/.chief/state/parallel"

# The three facts an admission may not touch, read from where an OPERATOR would read
# them: the worktree this turn is running in, the branch checked out there, and the
# driver's own liveliness record for this tasklist (engine/live.sh writes it line-wise,
# so it is read line-wise — a compact re-dump reads back empty for every field).
snap() {
  { echo "branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    echo "wt=$PWD"
    echo "iter=$(sed -n 's/^  "iter": *\([0-9][0-9]*\).*$/\1/p' "$ST/$name.live.json" 2>/dev/null | head -1)"
  } > "$1"
}

if [ "$name" = alpha ] && [ "${MRA_OFFER:-1}" = 1 ] && [ ! -f "$MRA_WORK/offered" ]; then
  : > "$MRA_WORK/offered"
  snap "$MRA_WORK/inflight.before"
  # From the PROJECT, never from the worktree: `chief offer` resolves its project from
  # the cwd upward, and a worktree resolves to a state root the driver never reads.
  ( cd "$MRA_REPO" && "$MRA_CHIEF" offer gamma ) > "$MRA_WORK/offer.log" 2>&1 \
    || echo "offer exited $?" >> "$MRA_WORK/offer.log"
  i=0
  while [ ! -f "$ST/gamma.state" ] && [ "$i" -lt 60 ]; do sleep 1; i=$(( i + 1 )); done
  # THE TWO SURFACES AN OPERATOR WATCHES A RUN WITH, read while the run is live —
  # afterwards the registry entry is gone and there is nothing left to ask.
  cat "$MRA_RUNS"/*.run > "$MRA_WORK/runfile.mid" 2>/dev/null || true
  ( cd "$MRA_REPO" && "$MRA_CHIEF" ps ) > "$MRA_WORK/ps.mid" 2>&1 || true
  snap "$MRA_WORK/inflight.after"
fi

id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  mkdir -p out; printf 'impl %s of %s\n' "$id" "$name" > "out/$name.$id.txt"
  for f in "$PRD" "$TRACKED"; do
    [ -f "$f" ] || continue
    t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id)|.passes)=true
      | (.userStories[]|select(.id==$id)|.notes)="artifact written; verify green"' "$f" > "$t" && mv "$t" "$f"
  done
  git add -A >/dev/null 2>&1 || true
  git commit -q -m "feat: [$id] - story $id of $name" >/dev/null 2>&1 || true
fi
[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── the fixture, built by a function so PART B gets the SAME one ──────────────
repo_of()  { printf '%s/repo.%s' "$WORK" "$1"; }
state_of() { cat "$(repo_of "$1")/.chief/state/parallel/$2.state" 2>/dev/null || echo MISSING; }
on_main()  { ( cd "$(repo_of "$1")" && git show "main:$2" >/dev/null 2>&1 ); }

fixture() {   # $1 = arm name
  local arm="$1" repo t stories
  repo="$(repo_of "$arm")"
  mkdir -p "$repo"
  ( cd "$repo"
    git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
    git commit -q --allow-empty -m init
    "$CHIEF" init >/dev/null
    rm -f tasks/chief/example.json
    printf '#!/usr/bin/env bash\nset -eu\necho "verify: ok"\nexit 0\n' > .chief/verify.sh
    chmod +x .chief/verify.sh
    for t in alpha beta gamma; do
      # alpha gets TWO stories so its first turn is not also its last: the offer is made
      # in turn 1 and the worker goes on to take another, which is what makes "the
      # iteration counter did not move" a statement about the admission.
      stories=1; [ "$t" = alpha ] && stories=2
      jq -n --arg n "$t" --argjson k "$stories" '
        { project:"mra", branchName:("chief/" + $n), description:("admission fixture " + $n),
          iters:4, dependsOn:[], touches:["domain-" + $n], warmup:[],
          userStories:[ range(1; $k + 1) | { id:("US-" + (tostring)), title:("story of " + $n),
                          description:"", acceptanceCriteria:[("the " + $n + " artifact is written")],
                          passes:false, notes:"" } ] }' > "tasks/chief/$t.json"
    done
    git add -A && git commit -q -m setup ) >/dev/null
}

run_arm() {   # $1 = arm, $2 = log; rest = `chief run` args
  local arm="$1" log="$2"; shift 2
  ( cd "$(repo_of "$arm")" && MRA_REPO="$(repo_of "$arm")" PATH="$WORK/fakebin:$PATH" \
      POLL_SECONDS=1 "$CHIEF" run "$@" ) >"$log" 2>&1
}

# ══ PART A — the offer, mid-turn, through the real driver ════════════════════
echo "mid-run-admission: PART A — a third tasklist offered from inside a live agent turn joins, runs, merges and is accounted for"
fixture adm
A="$(repo_of adm)"

# STALE PER-RUN FILES, planted before the run. This is the discriminator for the launch
# treatment: a newcomer merely appended to $NAMES inherits every one of them, and the
# run then reads a retry budget that is already spent and prints a reason for a block
# that never happened in it.
mkdir -p "$A/.chief/state/parallel"
: > "$A/.chief/state/parallel/gamma.stalled"
printf '3' > "$A/.chief/state/parallel/gamma.attempts"
printf 'needs "ghost", which FAILED in a run that ended yesterday\n' > "$A/.chief/state/parallel/gamma.why"
printf 'STALE-LEFTOVER from a previous run\n' > "$A/.chief/state/parallel/gamma.log"

LOG="$WORK/a.log"
run_arm adm "$LOG" --headless alpha beta || { rc=$?; fail "A: the run exited $rc (a run that admitted and merged everything must exit 0)"; }

# --- it joined, it ran, it merged --------------------------------------------
[ -s "$WORK/offer.log" ] || fail "A: the fake agent never ran chief offer — the fixture did not exercise the feature"
grep -q '✓ gamma' "$WORK/offer.log" || { cat "$WORK/offer.log" >&2; fail "A: chief offer refused gamma at the keyboard"; }
grep -q '＋ ADMITTED gamma' "$LOG" || fail "A: the run never announced admitting gamma"
[ "$(state_of adm gamma)" = "done" ] || fail "A: gamma state is '$(state_of adm gamma)', want done"
on_main adm "out/gamma.US-1.txt" || fail "A: gamma's work is not on main — an admitted tasklist that does not merge is not indistinguishable from a launch name"
[ -f "$A/tasks/chief/completed/gamma.json" ] || fail "A: gamma was not retired to completed/"

# --- the LAUNCH TREATMENT: the stale per-run files are gone -------------------
for leftover in gamma.stalled gamma.why gamma.attempts; do
  [ -e "$A/.chief/state/parallel/$leftover" ] \
    && fail "A: $leftover survived admission — the newcomer inherited another run's state instead of the launch treatment"
done
if grep -q 'STALE-LEFTOVER' "$A/.chief/state/parallel/gamma.log"; then
  fail "A: gamma's worker log still carries the previous run's line — it was not truncated at admission"
fi
if grep -q 'ghost' "$LOG"; then fail "A: the run summary printed a stale .why — the newcomer kept a reason from a run it was not in"; fi
echo "   ok  launch treatment: state initialised and four stale per-run files cleared, exactly as a launch name gets"

# --- NO WAVE JUMPED ----------------------------------------------------------
# beta was pending when gamma arrived; it merges first. Read off main's own first-parent
# history, which is the order the merges actually happened in.
order="$( cd "$A" && git log --first-parent --reverse --format=%s main | sed -n 's/^Merge chief\/\([a-z]*\).*/\1/p' | tr '\n' ' ' )"
case "$order" in
  "alpha beta gamma "*) ;;
  *) fail "A: merge order was '$order', want 'alpha beta gamma' — a newcomer may not jump work already waiting" ;;
esac
echo "   ok  no wave jumped: merge order $order"

# --- THE ACCOUNTING, in all four places --------------------------------------
grep -q '^   - gamma  *done' "$LOG" || { grep -n 'gamma' "$LOG" >&2; fail "A: gamma has no row in the end-of-run summary"; }
grep -q '^chief: outcome=merged' "$LOG" || fail "A: headless outcome is not merged"
grep -q '^chief: exit=0' "$LOG" || fail "A: headless exit is not 0"
summary="$(sed -n 's/^chief: summary=//p' "$LOG" | tail -1)"
[ -n "$summary" ] || fail "A: no headless JSON summary line"
[ "$(printf '%s' "$summary" | jq -r '[.tasklists[].name] | sort | join(",")')" = "alpha,beta,gamma" ] \
  || fail "A: the headless summary names $(printf '%s' "$summary" | jq -c '[.tasklists[].name]'), want all three"
[ "$(printf '%s' "$summary" | jq -r '.tasklists[] | select(.name=="gamma") | .outcome')" = "merged" ] \
  || fail "A: the headless summary does not report gamma as merged"
# The registry entry and `chief ps`, both read WHILE the run was live. Every row those
# two commands draw comes from the run file's `names=` field: a tasklist admitted into
# $NAMES but absent there is running and merging invisibly.
case "$(sed -n 's/^names=//p' "$WORK/runfile.mid" | tail -1)" in
  *gamma*) ;;
  *) cat "$WORK/runfile.mid" >&2; fail "A: the run's registry entry never listed gamma — chief ps and chief monitor draw every row from that field" ;;
esac
grep -q 'gamma' "$WORK/ps.mid" || { cat "$WORK/ps.mid" >&2; fail "A: chief ps showed no gamma row while the run was live"; }
echo "   ok  accounted for in the summary, the headless JSON, the registry entry and chief ps"

# --- IN-FLIGHT WORK UNTOUCHED ------------------------------------------------
[ -s "$WORK/inflight.before" ] && [ -s "$WORK/inflight.after" ] \
  || fail "A: the worker did not sample itself either side of the admission"
# Not vacuous: an empty `iter` on both sides would compare equal and prove nothing.
it="$(sed -n 's/^iter=//p' "$WORK/inflight.before")"
case "$it" in ''|*[!0-9]*) cat "$WORK/inflight.before" >&2; fail "A: the in-flight sample carries no iteration counter ('$it') — the comparison below would be vacuous" ;; esac
[ "$it" -ge 1 ] || fail "A: in-flight iteration counter is $it"
case "$(sed -n 's/^branch=//p' "$WORK/inflight.before")" in chief/alpha) ;; *) fail "A: the in-flight worker was not on chief/alpha" ;; esac
if ! diff -u "$WORK/inflight.before" "$WORK/inflight.after" >"$WORK/inflight.diff" 2>&1; then
  cat "$WORK/inflight.diff" >&2
  fail "A: admitting a tasklist changed the in-flight worker's branch, worktree or iteration counter"
fi
echo "   ok  in-flight worker untouched: branch, worktree and iteration counter identical across the admission"

# ══ PART B — the control: no offer, and the run ends with two ════════════════
echo "mid-run-admission: PART B — the same fixture with the offer never made ends with two tasklists"
fixture ctl
B="$(repo_of ctl)"
LOG="$WORK/b.log"
( cd "$B" && MRA_REPO="$B" MRA_OFFER=0 PATH="$WORK/fakebin:$PATH" POLL_SECONDS=1 \
    "$CHIEF" run --headless alpha beta ) >"$LOG" 2>&1 || fail "B: the control run exited non-zero"
summary="$(sed -n 's/^chief: summary=//p' "$LOG" | tail -1)"
[ "$(printf '%s' "$summary" | jq -r '[.tasklists[].name] | sort | join(",")')" = "alpha,beta" ] \
  || fail "B: the control run's set was $(printf '%s' "$summary" | jq -c '[.tasklists[].name]'), want alpha and beta only"
[ -f "$B/tasks/chief/gamma.json" ] || fail "B: gamma left tasks/chief/ without ever being offered"
[ -f "$B/tasks/chief/completed/gamma.json" ] && fail "B: gamma was retired without ever being offered — the run absorbed work nobody handed it"
if on_main ctl "out/gamma.US-1.txt"; then fail "B: gamma's work reached main without an offer — this is the silent auto-scan the feature refuses to be"; fi
[ "$(state_of ctl gamma)" = "MISSING" ] || fail "B: gamma has a scheduler state of '$(state_of ctl gamma)' in a run it was never in"
echo "   ok  control: two tasklists in, two out; gamma untouched in tasks/chief/"

echo "MID-RUN-ADMISSION PASS — offered mid-turn, admitted at the wave boundary with the full launch treatment, merged last, accounted for everywhere; in-flight work untouched; and nothing joins without an offer"
