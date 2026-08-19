#!/usr/bin/env bash
# test/submodule-resume.sh — a SUBMODULE tasklist's per-story progress survives a
# hard kill (tasklist 96, US-1).
#
# THE FAILURE, observed 2026-08-13 in insimul: `164-asset-libraries-and-suggestion`
# had reached 2 of 3 — US-1 and US-2 committed to the submodule `babylon/packages/core`
# — and after a run restart chief reported it at 0 of 3. The code was still on the
# branch; only the COUNT was lost, and an agent handed 0 of 3 onto a branch that
# already carries two stories either wastes iterations rediscovering that or, worse,
# implements one of them a second time.
#
# THE CAUSE IS THE SPLIT. A project tasklist records each story as it lands: the agent
# commits the tracked tasks/chief/<name>.json with its pass-flag flipped, so the branch
# IS the record. A submodule tasklist has no such place — its tasklist lives in the
# PARENT and its work branch in the SUBMODULE, and the parent receives exactly one
# commit for the whole thing at the very end. The durable snapshot under
# .chief/state/snapshots/ is the only per-story record, and it used to be written only
# after the worker's agent loop returned, which a killed run never reaches.
#
# WHAT THIS PINS, end to end against a real driver and a real file:// submodule:
#
#   A. SUBMODULE, killed mid-tasklist — the fake agent commits US-1 and US-2 into the
#      submodule worktree and then HANGS inside the US-2 turn; the test SIGKILLs the
#      whole process group, so the driver dies without ever running its end-of-worker
#      snapshot write. Asserted: the branch carries 2 story commits, the snapshot on
#      disk (outside the worktree the next run rm -rf's) says 2, and the restarted run
#      hands its agent a PRD reading 2 passing with US-3 next. The hang is INSIDE the
#      turn on purpose — that is the moment a story is finished but no iteration
#      boundary has been reached, and losing it is an off-by-one straight into the
#      re-implementation hazard.
#
#   A2. THE RESUMED AGENT IS TOLD (US-2). Resuming with the right COUNT is only half
#      the guard — the agent still has to know that US-1 and US-2 are done and that
#      their code is on the branch it just checked out, or the re-implementation hazard
#      is exactly where it was. The resumed run's fake agent banks the prompt it was
#      handed on its FIRST turn; the test asserts that prompt names both finished
#      stories, does NOT name the unfinished one as done, and states outright that
#      re-implementing one is a defect. The counterpart is asserted too: the FIRST turn
#      of the fresh run (nothing done yet) gets no such section at all.
#
#   B. The TERMINAL RECORD is unmoved — the resumed run merges, and the parent still
#      gets exactly ONE tasks/chief commit, still shaped
#      `... complete @sha — bump sub + record + retire`, with the tasklist retired to
#      completed/ carrying mergedToMain. Nothing downstream that reads completed/ moves.
#
#   D. A TORN snapshot is refused, not seeded — the file is planted truncated (the
#      shape a kill mid-write leaves: non-empty, so a `-s` test accepts it, but not
#      JSON) and the run must fall back to the pristine template and complete, rather
#      than seeding garbage and reporting a tasklist with no stories at all.
#
#   C. A NON-SUBMODULE tasklist is unperturbed — the same kill/restart against a
#      project tasklist resumes at the same 2 of 3 it always did, AND does so from the
#      BRANCH's committed tasklist rather than the snapshot: the test deliberately
#      CORRUPTS the snapshot to claim 0 passing before restarting, and the run must
#      ignore it. That is the sharp form of "the common case did not change" — the
#      project arm never reads the file this fix writes more often.
#
# Fully offline; deterministic fake agent. Installs the COMMITTED state of this
# checkout (install.sh git-clones) — commit engine changes before trusting a green run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
ARM=""
cleanup() {
  # A killed group can leave a hung fake agent behind; never let the test outlive it.
  [ -f "$WORK/pgid" ] && kill -9 -"$(cat "$WORK/pgid")" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
export GIT_AUTHOR_NAME=sr GIT_AUTHOR_EMAIL=sr@test GIT_COMMITTER_NAME=sr GIT_COMMITTER_EMAIL=sr@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"     # hermetic: never touch ~/.chief
# The fake agent finishes a story per turn; don't pay for agent.sh's generous budget.
export STALL_LIMIT=2 HARD_MAX=6
# The mid-turn bank rides the liveliness heartbeat (agent.sh _beat_start). At the
# 15s default the hang below would have to run for a quarter minute to prove
# anything; 1s makes the same assertion in a test-shaped amount of time.
export LIVE_BEAT_SECONDS=1

fail() {
  echo "SUBMODULE-RESUME FAIL: $*" >&2
  for l in "$WORK/$ARM"/*.log; do [ -f "$l" ] && { echo "--- $l"; tail -40 "$l"; } >&2; done
  [ -n "$ARM" ] && for l in "$WORK/$ARM/repo/.chief/state/parallel/"*.log; do
    [ -f "$l" ] && { echo "--- worker $l"; tail -60 "$l"; } >&2
  done
  exit 1
}
command -v jq  >/dev/null || fail "jq is required"
command -v git >/dev/null || fail "git is required"

# ── install chief from this checkout ──────────────────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# ── the fake agents ───────────────────────────────────────────────────────────
# Shared body: implement the next unfinished story, flip the runtime prd, and — when
# a TRACKED tasklist exists in this worktree (a project tasklist; a submodule worktree
# has no tasks/ dir) — flip that too and commit it, which is exactly what gives a
# project tasklist the per-story durability this whole fix is adding for submodules.
mkdir -p "$WORK/fake1" "$WORK/fake2"
cat > "$WORK/fake1/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
# BANK THE PROMPT of the first turn only (both fakes do this; run_until_killed and the
# restart each clear the file first). The prompt is what US-2 is about, and stdin is
# where the claude provider receives it.
cat > "$CHIEF_TEST_PROMPTFILE.$$"
[ -f "$CHIEF_TEST_PROMPTFILE" ] || cp "$CHIEF_TEST_PROMPTFILE.$$" "$CHIEF_TEST_PROMPTFILE"
rm -f "$CHIEF_TEST_PROMPTFILE.$$"
PRD=".chief/state/prd.json"                       # cwd = the work-repo worktree
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
[ -n "$id" ] || exit 0
mkdir -p src; printf 'impl %s\n' "$id" > "src/$id.txt"
t="$(mktemp)"; jq --arg id "$id" \
  '(.userStories[]|select(.id==$id)) |= (.passes=true | .notes="green, 1 file")' "$PRD" > "$t" && mv "$t" "$PRD"
tl="$(ls tasks/chief/*.json 2>/dev/null | head -1 || true)"
if [ -n "$tl" ]; then
  t="$(mktemp)"; jq --arg id "$id" \
    '(.userStories[]|select(.id==$id)) |= (.passes=true | .notes="green, 1 file")' "$tl" > "$t" && mv "$t" "$tl"
fi
git add -A >/dev/null 2>&1 || true
git commit -q -m "feat: $id - scripted" >/dev/null 2>&1 || true
# THE KILL WINDOW. The story is finished and committed, but this turn has not
# returned — so no iteration boundary has run for it. Hanging here (rather than
# exiting) is what makes the restart below a test of the mid-turn bank.
if [ "$id" = "$CHIEF_TEST_HANG_ON" ]; then : > "$CHIEF_TEST_KILLFLAG"; sleep 600; fi
[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
# The resumed run's agent: record what it was HANDED, once, before doing anything.
cp "$WORK/fake1/claude" "$WORK/fake2/claude"
python3 - "$WORK/fake2/claude" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = 'id="$(jq -r \'first(.userStories[]|select(.passes==false)).id // empty\' "$PRD")"\n'
probe = anchor + '''if [ ! -f "$CHIEF_TEST_RESUMEFILE" ]; then
  printf '%s %s\\n' "$(jq '[.userStories[]|select(.passes==true)]|length' "$PRD")" "${id:-none}" \\
    > "$CHIEF_TEST_RESUMEFILE"
fi
'''
assert s.count(anchor) == 1
open(p, 'w').write(s.replace(anchor, probe))
PY
chmod +x "$WORK/fake1/claude" "$WORK/fake2/claude"

# ── helpers ───────────────────────────────────────────────────────────────────
# run_until_killed LOGFILE — start `chief run` in its OWN process group (set -m), wait
# for the fake agent to signal it has committed the hang story, then SIGKILL the whole
# group. A group kill is the point: killing only the agent would leave the driver alive
# to write the end-of-worker snapshot, which is the write this test must NOT get.
run_until_killed() {
  local log="$1" pgid waited=0
  rm -f "$WORK/killflag" "$CHIEF_TEST_PROMPTFILE"
  set -m
  ( PATH="$WORK/fake1:$PATH" "$CHIEF" run >"$log" 2>&1 ) &
  local bg=$!
  set +m
  pgid="$(ps -o pgid= -p "$bg" 2>/dev/null | tr -d ' ')"
  [ -n "$pgid" ] || fail "could not read the run's process group"
  echo "$pgid" > "$WORK/pgid"
  while [ ! -f "$WORK/killflag" ]; do
    waited=$((waited+1)); [ "$waited" -gt 600 ] && fail "the fake agent never reached the hang story (see $log)"
    sleep 0.5
  done
  sleep 2                       # let at least one heartbeat tick fire inside the turn
  kill -9 -"$pgid" 2>/dev/null || true
  wait "$bg" 2>/dev/null || true
  rm -f "$WORK/pgid"
}

three_stories() {   # $1 = extra tasklist fields (e.g. the "repo" line)
  cat <<JSON
{ "project":"resume-demo","branchName":"chief/resume-demo",$1"description":"resume demo",
  "iters":6,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[
    {"id":"US-1","title":"one","description":"","acceptanceCriteria":["src/US-1.txt exists"],"passes":false,"notes":""},
    {"id":"US-2","title":"two","description":"","acceptanceCriteria":["src/US-2.txt exists"],"passes":false,"notes":""},
    {"id":"US-3","title":"three","description":"","acceptanceCriteria":["src/US-3.txt exists"],"passes":false,"notes":""}] }
JSON
}

export CHIEF_TEST_HANG_ON=US-2
export CHIEF_TEST_KILLFLAG="$WORK/killflag"
export CHIEF_TEST_RESUMEFILE="$WORK/resumed"
export CHIEF_TEST_PROMPTFILE="$WORK/prompt"

# ══════════════════════════════════════════════════════════════════════════════
# ARM A — a SUBMODULE tasklist: killed at 2 of 3, restarted, must resume at 2 of 3
# ══════════════════════════════════════════════════════════════════════════════
ARM=A
mkdir -p "$WORK/A"
SUBSRC="$WORK/A/subsrc"; mkdir -p "$SUBSRC"
git -C "$SUBSRC" init -q -b main 2>/dev/null || { git -C "$SUBSRC" init -q; git -C "$SUBSRC" checkout -q -b main; }
printf 'lib\n' > "$SUBSRC/README.md"; git -C "$SUBSRC" add -A; git -C "$SUBSRC" commit -q -m "sub base"

REPO="$WORK/A/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main 2>/dev/null || { git -C "$REPO" init -q; git -C "$REPO" checkout -q -b main; }
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" -c protocol.file.allow=always submodule add "file://$SUBSRC" sub >/dev/null 2>&1 \
  || fail "submodule add failed"
git -C "$REPO" commit -q -m "add submodule sub"
cd "$REPO"
"$CHIEF" init >/dev/null || fail "chief init failed"
rm -f tasks/chief/example.json
three_stories '"repo":"sub",' > tasks/chief/resume-demo.json
cat > .chief/verify.sh <<'SH'
#!/usr/bin/env bash
set -eu
for s in US-1 US-2 US-3; do [ -f "src/$s.txt" ] || { echo "verify: missing src/$s.txt (cwd=$PWD)"; exit 1; }; done
echo "verify: all three artifacts present"
SH
chmod +x .chief/verify.sh
git add -A && git commit -q -m "resume-demo tasklist + verify hook"

run_until_killed "$WORK/A/run1.log"

# THE COUNTERPART (US-2): nothing was done when that first turn was composed, so the
# prompt must carry no prior-work section at all — the untouched case is unperturbed.
[ -f "$CHIEF_TEST_PROMPTFILE" ] || fail "A: the fresh run never handed its agent a prompt"
! LC_ALL=C grep -qF 'ALREADY DONE' "$CHIEF_TEST_PROMPTFILE" \
  || fail "A: the FIRST turn of a fresh tasklist was told work is already on the branch"

# the branch really carries two stories' worth of work
SUB="$REPO/sub"
n_commits="$(git -C "$SUB" rev-list --count main..chief/resume-demo 2>/dev/null || echo 0)"
[ "$n_commits" = "2" ] || fail "A: expected 2 story commits on the submodule branch, got $n_commits"
git -C "$SUB" show chief/resume-demo:src/US-2.txt >/dev/null 2>&1 \
  || fail "A: US-2's code is not on the submodule branch — the fixture never reached the kill window"

# THE RECORD, outside the worktree the next run destroys
SNAPFILE="$REPO/.chief/state/snapshots/resume-demo.json"
[ -f "$SNAPFILE" ] || fail "A: no durable snapshot after the kill — progress has nowhere to live"
banked="$(jq '[.userStories[]|select(.passes==true)]|length' "$SNAPFILE" 2>/dev/null || echo x)"
[ "$banked" = "2" ] || fail "A: the durable snapshot banked $banked of 3, not 2 — the killed run lost a story"

# RESTART: the resumed agent must be handed 2 passing with US-3 next
rm -f "$CHIEF_TEST_RESUMEFILE" "$CHIEF_TEST_PROMPTFILE"
PATH="$WORK/fake2:$PATH" "$CHIEF" run >"$WORK/A/run2.log" 2>&1 || { cat "$WORK/A/run2.log" >&2; fail "A: restarted run exited non-zero"; }
[ -f "$CHIEF_TEST_RESUMEFILE" ] || fail "A: the resumed run never invoked the agent"
read -r a_passing a_next < "$CHIEF_TEST_RESUMEFILE"
[ "$a_passing" = "2" ] || fail "A: resumed at $a_passing of 3, not 2 — this IS the insimul:164 regression"
[ "$a_next" = "US-3" ] || fail "A: resumed onto story $a_next, not US-3"
# The resume verdict is the WORKER's line, not the scheduler's — per-tasklist detail
# lives in .chief/state/parallel/<name>.log, and only the run summary reaches stdout.
grep -q "RESUMING chief/resume-demo (1 story left)" "$REPO/.chief/state/parallel/resume-demo.log" \
  || fail "A: the worker did not report the resume as 1 story left"

# ── US-2: the resumed agent was TOLD, it did not have to infer ────────────────
# This is insimul:164's exact shape — 2 of 3 committed in a submodule, run restarted —
# and the assertions are on strings only the ENGINE emits (the section heading and its
# defect sentence) plus markers this fixture planted (the story titles "one"/"two").
# Nothing here matches templates/agent-context.md, which quotes only the Research heading.
[ -f "$CHIEF_TEST_PROMPTFILE" ] || fail "A: the resumed run banked no prompt"
NOTICE="$WORK/A/notice.txt"
LC_ALL=C sed -n '/# ALREADY DONE/,$p' "$CHIEF_TEST_PROMPTFILE" > "$NOTICE"
[ -s "$NOTICE" ] || fail "A: the resumed prompt never told the agent what is already done"
LC_ALL=C grep -qF 'already committed on this branch' "$NOTICE" \
  || fail "A: the notice does not say the finished work is present on the checked-out branch"
for done_story in 'US-1 — one' 'US-2 — two'; do
  LC_ALL=C grep -qF "$done_story" "$NOTICE" || fail "A: the notice does not name '$done_story' as complete"
done
! LC_ALL=C grep -qF 'US-3 — three' "$NOTICE" \
  || fail "A: the notice lists the UNFINISHED story US-3 among the completed ones"
LC_ALL=C grep -qF 'RE-IMPLEMENTING ONE OF THOSE STORIES IS A DEFECT' "$NOTICE" \
  || fail "A: the notice does not state that re-implementing a completed story is a defect"
LC_ALL=C grep -qF 'Your work this turn is US-3' "$NOTICE" \
  || fail "A: the notice does not point the resumed agent at US-3"

# ── the terminal record is unmoved (criterion 3) ───────────────────────────────
git -C "$SUB" checkout -q main
for s in US-1 US-2 US-3; do
  [ -f "$SUB/src/$s.txt" ] || fail "A: $s missing from the submodule's main after merge"
done
git -C "$REPO" checkout -q main
[ -f "$REPO/tasks/chief/completed/resume-demo.json" ] || fail "A: tasklist not retired to completed/"
[ -n "$(jq -r '.mergedToMain // empty' "$REPO/tasks/chief/completed/resume-demo.json")" ] \
  || fail "A: completed record missing mergedToMain"
[ ! -f "$REPO/tasks/chief/resume-demo.json" ] || fail "A: pending tasklist not removed"
# ONE parent commit for the whole tasklist, still in its terminal shape — the setup
# commit that ADDED the tasklist is the only other one touching tasks/chief/.
tl_log="$(git -C "$REPO" log --format=%s main -- tasks/chief 2>/dev/null)"
tl_n="$(printf '%s\n' "$tl_log" | grep -c . || true)"
[ "$tl_n" = "2" ] \
  || fail "A: expected 2 commits touching tasks/chief (add + terminal), got $tl_n: $tl_log"
tl_head="$(printf '%s\n' "$tl_log" | head -1)"
case "$tl_head" in
  *"resume-demo complete @"*"bump sub + record + retire") ;;
  *) fail "A: terminal commit shape changed: '$tl_head'" ;;
esac

# ══════════════════════════════════════════════════════════════════════════════
# ARM C — a NON-SUBMODULE tasklist is unperturbed, and still resumes from the
#         BRANCH's committed tasklist rather than the snapshot this fix writes.
# ══════════════════════════════════════════════════════════════════════════════
ARM=C
mkdir -p "$WORK/C"
REPO="$WORK/C/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main 2>/dev/null || { git -C "$REPO" init -q; git -C "$REPO" checkout -q -b main; }
git -C "$REPO" commit -q --allow-empty -m init
cd "$REPO"
"$CHIEF" init >/dev/null || fail "chief init failed (C)"
rm -f tasks/chief/example.json
three_stories '' > tasks/chief/resume-demo.json
cat > .chief/verify.sh <<'SH'
#!/usr/bin/env bash
set -eu
for s in US-1 US-2 US-3; do [ -f "src/$s.txt" ] || { echo "verify: missing src/$s.txt"; exit 1; }; done
echo "verify: all three artifacts present"
SH
chmod +x .chief/verify.sh
git add -A && git commit -q -m "resume-demo tasklist + verify hook"

run_until_killed "$WORK/C/run1.log"

n_commits="$(git -C "$REPO" rev-list --count main..chief/resume-demo 2>/dev/null || echo 0)"
[ "$n_commits" = "2" ] || fail "C: expected 2 story commits on the project branch, got $n_commits"
# The branch IS the record for a project tasklist — that is what must not have moved.
tracked_passing="$(git -C "$REPO" show chief/resume-demo:tasks/chief/resume-demo.json \
  | jq '[.userStories[]|select(.passes==true)]|length')"
[ "$tracked_passing" = "2" ] || fail "C: the branch's committed tasklist says $tracked_passing of 3, not 2"

# POISON THE SNAPSHOT. If the project arm ever started reading it, this is what would
# make it lie — so a correct resume must ignore this file entirely.
SNAPFILE="$REPO/.chief/state/snapshots/resume-demo.json"
[ -f "$SNAPFILE" ] || fail "C: expected a snapshot to poison"
t="$(mktemp)"; jq '.userStories |= map(.passes=false | .notes="")' "$SNAPFILE" > "$t" && mv "$t" "$SNAPFILE"

rm -f "$CHIEF_TEST_RESUMEFILE"
PATH="$WORK/fake2:$PATH" "$CHIEF" run >"$WORK/C/run2.log" 2>&1 || { cat "$WORK/C/run2.log" >&2; fail "C: restarted run exited non-zero"; }
[ -f "$CHIEF_TEST_RESUMEFILE" ] || fail "C: the resumed run never invoked the agent"
read -r c_passing c_next < "$CHIEF_TEST_RESUMEFILE"
[ "$c_passing" = "2" ] || fail "C: resumed at $c_passing of 3, not 2 — the project arm changed behaviour"
[ "$c_next" = "US-3" ] || fail "C: resumed onto story $c_next, not US-3 (poisoned snapshot was read)"
grep -q "RESUMING chief/resume-demo (1 story left)" "$REPO/.chief/state/parallel/resume-demo.log" \
  || fail "C: the worker did not report the resume as 1 story left"

git -C "$REPO" checkout -q main
[ -f "$REPO/tasks/chief/completed/resume-demo.json" ] || fail "C: tasklist not retired to completed/"
for s in US-1 US-2 US-3; do [ -f "$REPO/src/$s.txt" ] || fail "C: $s missing from main after merge"; done

# ═════════════════════════════════════════════════════════════════════════════
# ARM D — a TORN snapshot must not poison the resume.
#
# The snapshot is host state written while a run is being killed, so the file this
# mechanism can actually present to the next run is a TRUNCATED one. That is the
# nastiest shape: it is non-empty, so a `-s` test waves it through, but it is not
# JSON — and seeding it as the runtime prd.json makes every downstream jq read
# return nothing, reporting a tasklist with NO stories at all. That resume is
# strictly worse than the 0-of-3 this tasklist set out to fix.
#
# agent.sh now writes the snapshot atomically (temp + rename), so a torn file should
# be unreachable; this arm pins the FLOOR under that — the driver seeds only what
# parses, and falls back to the pristine template otherwise. Planted directly rather
# than raced for, because a race is not a test.
# ═════════════════════════════════════════════════════════════════════════════
ARM=D
mkdir -p "$WORK/D"
SUBSRC_D="$WORK/D/subsrc"; mkdir -p "$SUBSRC_D"
git -C "$SUBSRC_D" init -q -b main 2>/dev/null || { git -C "$SUBSRC_D" init -q; git -C "$SUBSRC_D" checkout -q -b main; }
printf 'lib\n' > "$SUBSRC_D/README.md"; git -C "$SUBSRC_D" add -A; git -C "$SUBSRC_D" commit -q -m "sub base"

REPO="$WORK/D/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main 2>/dev/null || { git -C "$REPO" init -q; git -C "$REPO" checkout -q -b main; }
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" -c protocol.file.allow=always submodule add "file://$SUBSRC_D" sub >/dev/null 2>&1 \
  || fail "D: submodule add failed"
git -C "$REPO" commit -q -m "add submodule sub"
cd "$REPO"
"$CHIEF" init >/dev/null || fail "D: chief init failed"
rm -f tasks/chief/example.json
three_stories '"repo":"sub",' > tasks/chief/resume-demo.json
cat > .chief/verify.sh <<'SH'
#!/usr/bin/env bash
set -eu
for s in US-1 US-2 US-3; do [ -f "src/$s.txt" ] || { echo "verify: missing src/$s.txt"; exit 1; }; done
echo "verify: all three artifacts present"
SH
chmod +x .chief/verify.sh
git add -A && git commit -q -m "resume-demo tasklist + verify hook"

# PLANT THE TEAR: a snapshot claiming 2 of 3, cut off mid-object. Non-empty (so the
# old `-s` guard would have accepted it) and unparseable (so seeding it would lie).
mkdir -p "$REPO/.chief/state/snapshots"
SNAPFILE_D="$REPO/.chief/state/snapshots/resume-demo.json"
three_stories '"repo":"sub",' | jq '.userStories |= map(if .id=="US-3" then . else .passes=true end)' \
  | head -c 120 > "$SNAPFILE_D"
[ -s "$SNAPFILE_D" ] || fail "D: the planted snapshot is empty — it must be non-empty to test the guard"
jq -e . "$SNAPFILE_D" >/dev/null 2>&1 && fail "D: the planted snapshot still parses — it is not torn"

rm -f "$CHIEF_TEST_RESUMEFILE"
CHIEF_TEST_HANG_ON=none PATH="$WORK/fake2:$PATH" "$CHIEF" run >"$WORK/D/run1.log" 2>&1 \
  || { cat "$WORK/D/run1.log" >&2; fail "D: the run exited non-zero on a torn snapshot"; }
[ -f "$CHIEF_TEST_RESUMEFILE" ] || fail "D: the run never invoked the agent — a torn snapshot killed the tasklist"
read -r d_passing d_next < "$CHIEF_TEST_RESUMEFILE"
[ "$d_passing" = "0" ] || fail "D: agent handed $d_passing passing from a torn snapshot, not 0"
[ "$d_next" = "US-1" ] || fail "D: agent handed story $d_next, not US-1 — the torn file was seeded"

git -C "$REPO" checkout -q main
for s in US-1 US-2 US-3; do [ -f "$REPO/src/$s.txt" ] || fail "D: $s missing from main after merge"; done
[ -f "$REPO/tasks/chief/completed/resume-demo.json" ] || fail "D: tasklist not retired to completed/"

echo "SUBMODULE-RESUME PASS — submodule progress survived a SIGKILL (2/3 -> resumed at US-3),"
echo "                        a TORN snapshot fell back to the template instead of seeding garbage,"
echo "                        the terminal record kept its shape, and the project arm was unmoved"
