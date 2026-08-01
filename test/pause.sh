#!/usr/bin/env bash
# test/pause.sh — the OPERATOR pause: `chief pause` DRAINS a run, it never kills it.
#
# tasks/chief/73-operator-pause-resume. The usage-limit pause (test/ratelimit.sh,
# test/limitstate.sh, test/limitresume.sh, test/limitmonitor.sh) is an account-wide
# window Chief waits out by itself. This is the other one: a human saying "stop
# spending agent turns here", which Chief must never lift on its own. The whole
# correctness story is what a pause is allowed to interrupt —
#
#   PART A — a PRE-ARMED repo: `chief run` launches nothing, spends no agent turn,
#            exits 0 saying PAUSED, and the flag SURVIVES the driver's launch init
#            (which clears the usage-limit window and only that).
#   PART B — a pause armed MID-RUN: the iteration in flight runs to completion and
#            its commits land, no further iteration starts, the tasklist parks as
#            `paused` with branch AND worktree kept, and the rate-limit self-heal
#            budget (<name>.retries) is never touched.
#   PART C — `chief resume`: parked -> pending, the next run RESUMEs from the
#            COMMITTED passes state (branch reused, story 1 not redone) and merges.
#   PART D — the render: `chief ps` tells an operator pause apart from a usage-limit
#            one, including when BOTH are armed. Synthetic (no driver, no agent, no
#            git), so none of test/monitor.sh's timing sensitivity comes with it.
#
# Hermetic: a scripted fake `claude` on PATH, temp prefixes ($CHIEF_PREFIX included,
# so worktrees land in the temp dir), never touches the real ~/.chief. Drives
# bin/chief straight out of this checkout — unlike the install-based suites it can
# therefore test uncommitted work.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
holder=""
cleanup() {
  if [ -n "$holder" ]; then kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap 'rc=$?; cleanup; exit "$rc"' EXIT
export GIT_AUTHOR_NAME=pz GIT_AUTHOR_EMAIL=pz@test GIT_COMMITTER_NAME=pz GIT_COMMITTER_EMAIL=pz@test
export CHIEF_PREFIX="$WORK/ch" CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
CHIEF="$ROOT/bin/chief"
LOG=""
fail() { echo "PAUSE FAIL: $*" >&2; [ -n "$LOG" ] && [ -f "$LOG" ] && tail -60 "$LOG" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

REPO="$WORK/repo"
S="$REPO/.chief/state/parallel"
state()  { cat "$S/$1.state" 2>/dev/null || echo MISSING; }
status() { cat "$S/$1.status" 2>/dev/null || echo MISSING; }
calls()  { cat "$WORK/calls" 2>/dev/null || echo 0; }
retries_written() { ls "$S"/*.retries 2>/dev/null | head -1 || true; }
# NOTE: `[ … ] && fail` would exit the whole script under `set -e` on the PASSING
# branch (the && list ends non-zero), so every negative assertion below is written
# as an `if … then fail; fi`.

# ── the fake agent ────────────────────────────────────────────────────────────
# Implements ONE story per call (commit included, exactly like the real loop), then
# — when this call is $PZ_PAUSE_AT — arms the operator pause by shelling out to the
# REAL `chief pause`. That is the point of the exercise: the pause lands while an
# iteration is in flight, from outside the driver, the way an operator arms it.
# It must cd to $PZ_REPO first — its cwd is the WORKTREE, whose own .chief/ would
# otherwise be found by find_project.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null
: "${PZ_CALLS:?}" "${PZ_REPO:?}" "${PZ_CHIEF:?}"
n=$(( $(cat "$PZ_CALLS" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$PZ_CALLS"
PRD=".chief/state/prd.json"
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"; TRACKED="tasks/chief/$name.json"
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  mkdir -p out; echo "impl $id" > "out/$id.txt"
  for f in "$PRD" "$TRACKED"; do
    [ -f "$f" ] || continue
    t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id).passes)=true' "$f" > "$t" && mv "$t" "$f"
  done
  git add -A >/dev/null 2>&1 || true; git commit -q -m "feat: $id" >/dev/null 2>&1 || true
fi
if [ "$n" = "${PZ_PAUSE_AT:-0}" ]; then
  ( cd "$PZ_REPO" && "$PZ_CHIEF" pause ) || echo "fake claude: chief pause failed" >&2
fi
if [ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ]; then echo "<promise>COMPLETE</promise>"; fi
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"
export PZ_CALLS="$WORK/calls" PZ_REPO="$REPO" PZ_CHIEF="$CHIEF"

# ── a chief repo with one 2-story tasklist ────────────────────────────────────
mkdir -p "$REPO"
( cd "$REPO"
  git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
  git commit -q --allow-empty -m init
  "$CHIEF" init >/dev/null
  rm -f tasks/chief/example.json
  printf '#!/usr/bin/env bash\nset -eu\necho "verify: ok"\nexit 0\n' > .chief/verify.sh
  chmod +x .chief/verify.sh
  cat > tasks/chief/pz.json <<'JSON'
{ "project":"pz","branchName":"chief/pz","description":"operator pause",
  "iters":4,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[
    {"id":"US-1","title":"s1","description":"","acceptanceCriteria":["out/US-1.txt"],"passes":false,"notes":""},
    {"id":"US-2","title":"s2","description":"","acceptanceCriteria":["out/US-2.txt"],"passes":false,"notes":""}
  ] }
JSON
  git add -A && git commit -q -m setup )

run_chief() {   # $1 = log; rest = args to `chief run`
  local log="$1"; shift
  ( cd "$REPO" && PATH="$WORK/fakebin:$PATH" POLL_SECONDS=1 "$CHIEF" run "$@" ) >"$log" 2>&1
}

# ══ PART A — a repo paused BEFORE the run launches nothing at all ═════════════
echo "pause: PART A — a pre-armed repo runs no agent turn"
( cd "$REPO" && "$CHIEF" pause ) > "$WORK/pause1.log" 2>&1 || fail "chief pause exited non-zero"
grep -q 'PAUSED' "$WORK/pause1.log" || { cat "$WORK/pause1.log" >&2; fail "chief pause said nothing about what it armed"; }
[ -f "$S/.paused" ] || fail "chief pause did not create $S/.paused"
# Idempotent: a second pause is a no-op at exit 0, and says so.
( cd "$REPO" && "$CHIEF" pause ) > "$WORK/pause2.log" 2>&1 || fail "a second 'chief pause' did not exit 0"
grep -q 'already paused' "$WORK/pause2.log" || { cat "$WORK/pause2.log" >&2; fail "re-pausing a paused repo did not report a no-op"; }

# An armed usage-limit window is a DIFFERENT hold: the driver's launch init clears
# that one and must leave the operator flag alone.
printf '%s' "$(( $(date +%s) + 3600 ))" > "$S/.limit-pause-until"

LOG="$WORK/a.log"
run_chief "$LOG" || fail "a paused run exited non-zero (an operator pause is a decision, not a failure)"
grep -q 'OPERATOR PAUSE armed' "$LOG" || fail "the run did not report the pre-armed pause"
[ "$(calls)" = "0" ] || fail "agent invocations = $(calls) under a pre-armed pause, want 0"
[ -f "$S/.paused" ] || fail ".paused did not survive the driver's launch init"
if [ -f "$S/.limit-pause-until" ]; then fail "launch init did not clear the usage-limit window"; fi
[ -z "$(retries_written)" ] || fail "an operator pause wrote a rate-limit retry file: $(retries_written)"
[ "$(state pz)" = "pending" ] || fail "a held tasklist is '$(state pz)', want pending (never launched)"
echo "   ok  0 agent calls, exit 0, flag survived launch init, no retry budget spent"

# ══ PART B — a pause armed MID-RUN drains at the iteration boundary ═══════════
echo "pause: PART B — a pause armed mid-run drains, it does not kill"
( cd "$REPO" && "$CHIEF" resume ) >"$WORK/resume0.log" 2>&1 || fail "chief resume exited non-zero"
if [ -f "$S/.paused" ]; then fail "chief resume left the flag armed"; fi

LOG="$WORK/b.log"
export PZ_PAUSE_AT=1          # exported, not a call prefix: the FAKE AGENT reads it
run_chief "$LOG" || fail "the drained run exited non-zero (PARKED is not a failure)"
unset PZ_PAUSE_AT

[ "$(calls)" = "1" ] || fail "agent invocations = $(calls), want exactly 1 (the in-flight iteration, then nothing)"
[ "$(state pz)" = "paused" ] || fail "pz state is '$(state pz)', want paused"
case "$(status pz)" in PAUSED*) ;; *) fail "pz status is '$(status pz)', want PAUSED n/total" ;; esac
# The in-flight iteration's work SURVIVED: its commit is on the branch.
( cd "$REPO" && git rev-parse --verify chief/pz >/dev/null 2>&1 ) || fail "the branch was not kept"
( cd "$REPO" && git show chief/pz:out/US-1.txt >/dev/null 2>&1 ) \
  || fail "the in-flight iteration's commit did not land on the branch"
# …and so did the worktree (under the TEST prefix, by construction), so the resume
# path picks the branch back up with nothing rebuilt.
WT="$(ls -d "$CHIEF_PREFIX"/worktrees/*/pz 2>/dev/null | head -1 || true)"
[ -n "$WT" ] && [ -d "$WT" ] || fail "the parked tasklist's worktree was removed"
[ -f "$WT/out/US-1.txt" ] || fail "the parked worktree lost the in-flight iteration's work"
# Never mislabelled: not failed, not blocked, not EMPTY-NO-WORK, and never merged.
if grep -q 'EMPTY-NO-WORK' "$LOG"; then fail "the drain was mislabelled EMPTY-NO-WORK"; fi
if [ -f "$REPO/tasks/chief/completed/pz.json" ]; then fail "a parked tasklist was retired as completed"; fi
grep -q 'OPERATOR PAUSE — 1 tasklist(s) PARKED' "$LOG" || fail "the summary did not report the park"
grep -q 'chief resume' "$LOG" || fail "the summary did not name the resume command"
[ -z "$(retries_written)" ] || fail "the drain spent rate-limit retry budget: $(retries_written)"
# The liveliness record carries the operator phase, which is what makes the pause
# visible to `chief ps`.
LIVE="$S/pz.live.json"
grep -q '"phase": "operator-paused"' "$LIVE" || { cat "$LIVE" >&2; fail "the liveliness record lost the operator-pause phase"; }
grep -q '"state": "paused"'          "$LIVE" || { cat "$LIVE" >&2; fail "the liveliness record lost the paused state"; }
echo "   ok  1 iteration ran to completion, committed, parked with branch + worktree kept"

# ══ PART C — resume continues from the COMMITTED passes state ═════════════════
echo "pause: PART C — resume re-arms the park and continues where it stopped"
( cd "$REPO" && "$CHIEF" resume ) >"$WORK/resume1.log" 2>&1 || fail "chief resume exited non-zero"
grep -q 're-armed as pending' "$WORK/resume1.log" || { cat "$WORK/resume1.log" >&2; fail "resume did not re-arm the parked tasklist"; }
[ "$(state pz)" = "pending" ] || fail "after resume pz is '$(state pz)', want pending"
# Idempotent the other way too.
( cd "$REPO" && "$CHIEF" resume ) >"$WORK/resume2.log" 2>&1 || fail "a second 'chief resume' did not exit 0"
grep -q 'not paused' "$WORK/resume2.log" || { cat "$WORK/resume2.log" >&2; fail "resuming an unpaused repo did not report a no-op"; }

LOG="$WORK/c.log"
run_chief "$LOG" || fail "the resumed run exited non-zero"
grep -q 'RESUMING chief/pz (1 story left)' "$S/pz.log" \
  || { tail -40 "$S/pz.log" >&2; fail "the resumed run did not pick up from the committed passes state"; }
[ "$(calls)" = "2" ] || fail "agent invocations = $(calls) total, want 2 (story 1 before the pause, story 2 after) — work was redone"
[ "$(state pz)" = "done" ] || fail "pz state is '$(state pz)', want done"
( cd "$REPO" && git checkout -q main
  [ -f out/US-1.txt ] || exit 3
  [ -f out/US-2.txt ] || exit 4
  [ -n "$(jq -r '.mergedToMain // empty' tasks/chief/completed/pz.json 2>/dev/null)" ] || exit 5 ) \
  || fail "the resumed tasklist did not complete + merge (missing artifact or merge stamp)"
echo "   ok  resumed at story 2, verified, merged, retired"

# `chief resume` must never lift the ACCOUNT's window — that hold has its own
# lifetime and the run still has to wait it out.
printf '%s' "$(( $(date +%s) + 3600 ))" > "$S/.limit-pause-until"
( cd "$REPO" && "$CHIEF" pause && "$CHIEF" resume ) >"$WORK/resume3.log" 2>&1 || fail "pause+resume cycle exited non-zero"
[ -f "$S/.limit-pause-until" ] || fail "chief resume cleared the usage-limit window (the two holds are orthogonal)"
grep -q 'usage-limit window is still armed' "$WORK/resume3.log" || fail "resume did not report the remaining usage-limit hold"

# ══ PART D — the render tells the two pauses apart ═══════════════════════════
echo 'pause: PART D — chief ps distinguishes an operator pause from a usage limit'
MSTATE="$WORK/mstate"; MPAR="$MSTATE/parallel"; MRUNS="$WORK/mruns"
mkdir -p "$MPAR" "$MRUNS" "$WORK/mrepo" "$WORK/mtasks" "$WORK/mwt"
sleep 60 & holder=$!
NOW="$(date +%s)"; RESET=$(( NOW + 900 ))
ETA="$(date -r "$RESET" '+%H:%M' 2>/dev/null || date -d "@$RESET" '+%H:%M')"
echo paused       > "$MPAR/op-park.state"
echo rate-limited > "$MPAR/limit-wait.state"; printf '%s' "$RESET" > "$MPAR/limit-wait.retry-at"
echo running      > "$MPAR/work-run.state"
printf '%s' "$NOW"   > "$MPAR/.paused"              # BOTH holds armed at once
printf '%s' "$RESET" > "$MPAR/.limit-pause-until"
cat > "$MRUNS/$holder.run" <<EOF
pid=$holder
repo=$WORK/mrepo
base=main
parallel=2
tool=claude
limitmax=3
started=$NOW
state=$MSTATE
staterel=.chief/state
tasks=$WORK/mtasks
wt=$WORK/mwt
names=op-park limit-wait work-run
EOF
out="$(CHIEF_RUNS="$MRUNS" bash "$ROOT/engine/monitor.sh" once)" || fail "monitor.sh exited non-zero"
printf '%s\n' "--- chief ps (both holds armed) ---" "$out"
has() { case "$out" in *"$1"*) ;; *) printf '%s\n' "$out" >&2; fail "$2" ;; esac; }

has 'paused: operator hold'                "the parked tasklist doesn't say an operator armed it"
has 'resume: chief resume'                 "the parked row doesn't name the command that lifts it"
has 'branch + worktree kept'               "the parked row doesn't say what was kept"
has 'paused: usage limit'                  "the rate-limited row stopped saying it waits on a usage limit"
has "retry at $ETA"                        "the rate-limited row lost its retry ETA"
has 'OPERATOR PAUSE armed'                 "the run header doesn't say an operator pause holds this repo"
has 'usage-limit window until'             "the run header doesn't say a usage-limit window holds this repo"
has 'BOTH holds are armed'                 "with both holds armed the view doesn't say lifting one changes nothing"
has 'draining: work-run'                   "a worker still running under an armed pause isn't shown as draining"
# The two pauses must not be readable as each other, or as a failure.
opline="$(printf '%s\n' "$out" | grep 'op-park ' || true)"
case "$opline" in *'⏸'*) ;; *) fail "the operator-paused row is missing the pause glyph: $opline" ;; esac
case "$opline" in *'✗'*|*'⤬'*) fail "the operator-paused row uses a failure glyph: $opline" ;; esac
case "$opline" in *'usage limit'*) fail "the operator-paused row claims a usage limit: $opline" ;; esac
limline="$(printf '%s\n' "$out" | grep 'limit-wait ' || true)"
case "$limline" in *'operator'*) fail "the usage-limit row claims an operator hold: $limline" ;; esac
echo "   ok  both ⏸, different notes, and the header names both holds"

echo "PAUSE PASS — an operator pause drains at a safe checkpoint, parks with branch + worktree kept, resumes from committed state, and is legible in chief ps"
