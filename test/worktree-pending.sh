#!/usr/bin/env bash
# test/worktree-pending.sh — work already on disk is never described as no work.
#
# THE REGRESSION, verbatim (talos, 2026-08-24). Tasklist 71 ended INCOMPLETE with the
# adopted game — `lampe-games/godot-open-rts @ a628ad3`, 2,029 files — already fetched
# into `dogfood/open-rts/`, correctly placed and not gitignored. None of it was ever
# committed. `chief ps` reported `✗ failed · no progress last iter` and the run summary
# said only `left in worktree for review`, so an operator reading either one would
# reasonably conclude the tasklist was broken and re-scope it — throwing the work away.
#
# "No work produced" is a real signal about the agent. "Work produced but not
# committed" is a RECOVERABLE state that costs one `git status` to see. They rendered
# identically, and this file is the assertion that they no longer do.
#
# THREE PARTS:
#   1. THE READ — worktree_pending() against real trees, including every way it can
#      be asked about something unreadable. It is a reporting improvement and must
#      never become a new way for a run to die, so every failure is '' and exit 0.
#   2. THE RUN — the real parallel driver, INCOMPLETE, with staged AND unstaged AND
#      untracked changes standing in the worktree. Both the row and the summary block.
#   3. THE ROW — `chief ps` telling the two apart, against a synthetic registry
#      (test/limitmonitor.sh's harness: no driver, no agent, no clock sensitivity).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"

# HERMETIC IN STATE IS NOT HERMETIC IN ENV — see test/ratelimit.sh's note. This suite
# may itself be running inside a chief worktree whose driver exported a pause flag.
unset CHIEF_PAUSE_FILE
unset CHIEF_PROVIDER CHIEF_TOOL CHIEF_MODEL CHIEF_PRESET
export CHIEF_PROVIDER=claude CHIEF_TOOL=claude
holder=""
cleanup() {
  if [ -n "$holder" ]; then kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap 'rc=$?; cleanup; exit "$rc"' EXIT
export GIT_AUTHOR_NAME=wp GIT_AUTHOR_EMAIL=wp@test GIT_COMMITTER_NAME=wp GIT_COMMITTER_EMAIL=wp@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"   # hermetic: don't touch ~/.chief
fail() { echo "WORKTREE-PENDING FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

# ══ PART 1 — THE READ ═════════════════════════════════════════════════════════
# worktree_pending is a pure function of one path, which is why it lives in
# engine/lib.sh and can be driven directly.
# shellcheck source=/dev/null
. "$ROOT/engine/lib.sh"

echo "worktree-pending: the read (git status --porcelain -uall -> one phrase)"

T="$WORK/tree"; mkdir -p "$T"
git -C "$T" init -q -b main 2>/dev/null || { git -C "$T" init -q; }
git -C "$T" commit -q --allow-empty -m init

# A CLEAN tree says nothing. Silence is what "there is nothing to add" has to look
# like, because both call sites branch on the empty string.
got="$(worktree_pending "$T")"
[ -z "$got" ] || fail "a clean worktree must report nothing, got: $got"
echo "   ok  clean tree -> ''"

# NEVER A NEW WAY TO DIE. A path that does not exist, a directory that is not a git
# repo, and a worktree whose gitdir link is broken all resolve to '' and exit 0 —
# asserted under `set -e`, which is what the driver runs them under.
for bad in "$WORK/does-not-exist" "$WORK" "/dev/null"; do
  got="$(worktree_pending "$bad")"; rc=$?
  [ "$rc" = 0 ] || fail "worktree_pending '$bad' exited $rc — it must never fail a run"
  [ -z "$got" ] || fail "worktree_pending '$bad' invented a finding: $got"
done
got="$(worktree_pending)"; [ -z "$got" ] || fail "a missing argument must report nothing"
echo "   ok  missing path · non-repo · /dev/null · no argument -> '' and exit 0"

# THE 2,029-FILE SHAPE: an untracked DIRECTORY. git's default porcelain collapses one
# into a SINGLE line, which would have reported tasklist 71's whole adopted game as
# "1 uncommitted file" — the -uall in the implementation is this assertion.
mkdir -p "$T/dogfood/open-rts/scenes"
for i in 1 2 3 4 5 6 7; do echo "scene $i" > "$T/dogfood/open-rts/scenes/f$i.gd"; done
echo tracked > "$T/kept.txt"; git -C "$T" add kept.txt; git -C "$T" commit -q -m kept
echo changed >> "$T/kept.txt"                 # unstaged
echo staged  > "$T/added.txt"; git -C "$T" add added.txt
got="$(worktree_pending "$T")"
case "$got" in
  "9 uncommitted file(s) (7 untracked, 1 modified, 1 staged)"*) ;;
  *) fail "wrong counts — an untracked directory must count per FILE, got: $got" ;;
esac
case "$got" in *'dogfood/'*) ;; *) fail "the report does not name where to look, got: $got" ;; esac
echo "   ok  $got"

# The counts stay honest through a rename and a multi-byte path — LC_ALL=C, because
# BSD awk aborts on a multi-byte character in a UTF-8 locale (CLAUDE.md).
mkdir -p "$T/ém—dash"; echo u > "$T/ém—dash/x.txt"
git -C "$T" mv kept.txt renamed.txt 2>/dev/null || true
got="$(worktree_pending "$T")"
case "$got" in
  *'uncommitted file(s)'*) ;; *) fail "a rename + a multi-byte path broke the read: $got" ;;
esac
echo "   ok  survives a rename and a multi-byte path: $got"

# ══ PART 2 — THE RUN: INCOMPLETE with work standing in the worktree ═══════════
# A fake `claude` that commits US-1 on its first call and then, on every call after
# it, WRITES FILES AND COMMITS NOTHING. That is tasklist 71's shape exactly: real,
# correctly-placed output, a branch that carries some commits, and a budget that runs
# out before any of it is committed.
PREFIX="$WORK/ph"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

mkdir -p "$WORK/agentbin"
cat > "$WORK/agentbin/claude" <<'AGENT'
#!/usr/bin/env bash
set -eu
cat >/dev/null
: "${WP_COUNTER:?}"
n=$(( $(cat "$WP_COUNTER" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$WP_COUNTER"
PRD=".chief/state/prd.json"
if [ "$n" = "1" ]; then
  mkdir -p out; echo "impl US-1" > out/US-1.txt
  t="$(mktemp)"; jq '(.userStories[]|select(.id=="US-1").passes)=true' "$PRD" > "$t" && mv "$t" "$PRD"
  git add -A >/dev/null 2>&1 || true; git commit -q -m "feat: [US-1] - one" >/dev/null 2>&1 || true
  exit 0
fi
# Everything below is produced and NEVER committed — the regression, on purpose.
mkdir -p dogfood/open-rts/scenes
for i in 1 2 3 4 5; do echo "scene $i" > "dogfood/open-rts/scenes/s$i.gd"; done
echo "unstaged edit" >> out/US-1.txt
echo "staged but uncommitted" > dogfood/NOTES.md
git add dogfood/NOTES.md >/dev/null 2>&1 || true
echo "I fetched the game but did not finish US-2."
exit 0
AGENT
chmod +x "$WORK/agentbin/claude"

REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null
rm -f tasks/chief/example.json
cat > tasks/chief/wp.json <<'JSON'
{ "project":"wp","branchName":"chief/wp","description":"work stands in the worktree",
  "iters":3,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[
    {"id":"US-1","title":"one","description":"","acceptanceCriteria":[],"passes":false,"notes":""},
    {"id":"US-2","title":"two","description":"","acceptanceCriteria":[],"passes":false,"notes":""}] }
JSON
printf '#!/usr/bin/env bash\nexit 0\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "wp setup"

export WP_COUNTER="$WORK/wp-calls"
run_rc=0
PATH="$WORK/agentbin:$PATH" STALL_LIMIT=1 \
  "$CHIEF" run >"$WORK/run.log" 2>&1 || run_rc=$?
RL="$WORK/run.log"
PAR="$REPO/.chief/state/parallel"

echo "worktree-pending: the run (INCOMPLETE, with work standing in the worktree)"
st="$(cat "$PAR/wp.status" 2>/dev/null || echo NONE)"
case "$st" in INCOMPLETE*) ;; *) tail -40 "$RL" >&2; fail "status is '$st', want INCOMPLETE" ;; esac
echo "   ok  status = $st"

# THE RECORD both readers render from. One writer, so the row and the summary cannot
# disagree about what is on disk.
[ -s "$PAR/wp.pending" ] || { tail -40 "$RL" >&2; fail "no <name>.pending record was written"; }
pend="$(cat "$PAR/wp.pending")"
case "$pend" in "work pending:"*) ;; *) fail "the record does not classify this as work pending: $pend" ;; esac
case "$pend" in *'untracked'*) ;; *) fail "the record does not count the untracked files: $pend" ;; esac
case "$pend" in *'staged'*)    ;; *) fail "the record does not count the staged files: $pend" ;; esac
case "$pend" in *'dogfood/'*)  ;; *) fail "the record does not name WHERE the work is: $pend" ;; esac
case "$pend" in *'nothing is lost'*) ;; *) fail "the record does not say the work is recoverable: $pend" ;; esac
echo "   ok  $pend"

# THE SUMMARY. `left in worktree for review` used to name nothing; it must now say
# whether the worktree holds uncommitted changes and roughly how much.
WL="$PAR/wp.log"
grep -q 'holds UNCOMMITTED work' "$WL" || { tail -40 "$WL" >&2
  fail "the worker never said the INCOMPLETE worktree holds uncommitted work"; }
grep -q 'nothing is lost' "$WL" || fail "the worker log does not say the work is recoverable"
grep -q 'WORK LEFT UNCOMMITTED' "$RL" || { tail -40 "$RL" >&2
  fail "the run summary has no block naming the work left on disk"; }
grep -q 'NOTHING IS LOST' "$RL" || fail "the summary does not say the state is recoverable"
grep -q 'git -C .* status' "$RL" || fail "the summary does not say how to look at it"
echo "   ok  the summary names the work and how to see it"

# …and it is TRUE: the files really are there, uncommitted, on a branch that is kept.
git -C "$REPO" show-ref --verify --quiet refs/heads/chief/wp || fail "the branch was not kept"
[ "$(git -C "$REPO" rev-list --count "main..chief/wp")" -ge 1 ] \
  || fail "the branch should carry US-1's commit — this is INCOMPLETE, not EMPTY-NO-WORK"
echo "   ok  branch kept with US-1 committed; the rest is on disk"

# ══ PART 2b — THE OTHER TWO OUTCOMES, so the classification is not vacuous ═════
# A worktree that is genuinely CLEAN at an INCOMPLETE stop must say so rather than
# going silent, and must NOT appear in the block above.
mkdir -p "$WORK/cleanbin"
cat > "$WORK/cleanbin/claude" <<'CLEANA'
#!/usr/bin/env bash
set -eu
cat >/dev/null
: "${WP_COUNTER:?}"
n=$(( $(cat "$WP_COUNTER" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$WP_COUNTER"
PRD=".chief/state/prd.json"
if [ "$n" = "1" ]; then
  mkdir -p out; echo "impl US-1" > out/US-1.txt
  t="$(mktemp)"; jq '(.userStories[]|select(.id=="US-1").passes)=true' "$PRD" > "$t" && mv "$t" "$PRD"
  git add -A >/dev/null 2>&1 || true; git commit -q -m "feat: [US-1] - one" >/dev/null 2>&1 || true
  exit 0
fi
echo "I could not work out US-2 and wrote nothing."
exit 0
CLEANA
chmod +x "$WORK/cleanbin/claude"

git -C "$REPO" branch -D chief/wp >/dev/null 2>&1 || true
rm -f "$PAR/wp.pending"
printf '0' > "$WP_COUNTER"
PATH="$WORK/cleanbin:$PATH" STALL_LIMIT=1 \
  "$CHIEF" run >"$WORK/clean.log" 2>&1 || true
CL="$WORK/clean.log"
echo "worktree-pending: the clean INCOMPLETE (silence is not an answer)"
pend="$(cat "$PAR/wp.pending" 2>/dev/null || echo NONE)"
case "$pend" in "no uncommitted work:"*) ;; *) tail -40 "$CL" >&2
  fail "a clean INCOMPLETE worktree must SAY it is clean, got: $pend" ;; esac
grep -q 'WORK LEFT UNCOMMITTED' "$CL" \
  && fail "a clean worktree must not be reported as work left uncommitted"
grep -q 'no uncommitted changes in' "$PAR/wp.log" || { tail -40 "$PAR/wp.log" >&2
  fail "the run did not report the clean worktree either way"; }
grep -q 'no uncommitted work:' "$CL" || { tail -40 "$CL" >&2
  fail "the summary went silent about the clean worktree"; }
echo "   ok  $pend"

# ══ PART 3 — THE ROW: `chief ps` telling the two apart ════════════════════════
# Synthetic registry + on-disk state (test/limitmonitor.sh's harness): no driver, no
# agent, no clock. Two FAILED rows, identical in every way an operator can see today.
sleep 60 & holder=$!
MSTATE="$WORK/mstate"; MPAR="$MSTATE/parallel"; MRUNS="$WORK/mruns"
mkdir -p "$MPAR" "$MRUNS" "$WORK/mrepo" "$WORK/mtasks" "$WORK/mwt"
echo failed > "$MPAR/has-work.state";  echo "INCOMPLETE 1/2"  > "$MPAR/has-work.status"
echo failed > "$MPAR/no-work.state";   echo "EMPTY-NO-WORK 0/2" > "$MPAR/no-work.status"
printf 'work pending: 2029 uncommitted file(s) (2021 untracked, 5 modified, 3 staged) · dogfood/ — produced but NOT committed; nothing is lost (git -C %s/mwt/has-work status)\n' "$WORK" > "$MPAR/has-work.pending"
printf 'no work produced: nothing committed, and nothing uncommitted in the worktree either\n' > "$MPAR/no-work.pending"
cat > "$MRUNS/$holder.run" <<EOF
pid=$holder
repo=$WORK/mrepo
base=main
parallel=2
tool=claude
automerge=1
started=$(date +%s)
state=$MSTATE
staterel=.chief/state
tasks=$WORK/mtasks
wt=$WORK/mwt
names=has-work no-work
EOF
out="$(CHIEF_RUNS="$MRUNS" bash "$ROOT/engine/monitor.sh" once)" || fail "monitor.sh exited non-zero"
echo "--- chief ps (two failed rows) ---"; printf '%s\n' "$out"
case "$out" in *'work pending: 2029 uncommitted file(s)'*) ;;
  *) fail "chief ps does not show that work was produced but not committed" ;; esac
case "$out" in *'dogfood/'*) ;; *) fail "chief ps does not name where the work is" ;; esac
case "$out" in *'no work produced'*) ;;
  *) fail "chief ps does not distinguish the row that produced nothing" ;; esac
# The distinction is the whole point: the two rows must not render the same line.
hw="$(printf '%s\n' "$out" | grep -A2 'has-work ' | grep '↳' || true)"
nw="$(printf '%s\n' "$out" | grep -A2 'no-work '  | grep '↳' || true)"
[ -n "$hw" ] && [ -n "$nw" ] || fail "one of the two failed rows rendered no detail line at all"
[ "$hw" != "$nw" ] || fail "the two rows still render identically — this is the regression"
echo "   ok  the two failed rows render differently"

echo "WORKTREE-PENDING PASS — work already on disk is named, counted and never called no work"
