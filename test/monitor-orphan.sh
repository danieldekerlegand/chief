#!/usr/bin/env bash
# test/monitor-orphan.sh — the ABANDONED VIEW: it must end itself, and until it does
# `chief reap` must SEE it — as a VIEW, not as agent work.
#
# THE DEFECT THIS REPRODUCES. `chief monitor` outlived the terminal that started it.
# `watch` is the only looping arm and nothing could end that loop but Ctrl-C, so a
# closed window simply re-parented the watcher to init and it kept rendering into a
# terminal that no longer existed. Measured on this host 2026-08-19: NINE
# `monitor.sh watch 1` processes, every one PPID 1, from three abandoned views, the
# oldest 11.5 hours old — found only because somebody read the process list by hand.
# `chief reap` run against those nine printed "no orphaned chief processes", because
# a viewer matches none of its three agent-work keys (no --chief-run= marker, no
# inherited $CHIEF_RUN_ID, a cwd wherever the operator was standing).
#
# So this file asserts BOTH halves against a REAL watcher, plus the negatives:
#
#   1. REPRODUCTION.  An UNFIXED watcher, orphaned, is still looping an interval
#      later. Without this the rest of the file could pass on an engine that never
#      had the bug, which is the difference between reproducing a defect and
#      restating behaviour that always worked.
#   2. REAP SEES IT.  Against that still-live orphan, `reap -n` lists it under the
#      [view] key and its own headline, and NOT under any agent-work key.
#   3. REAP ENDS IT.  The real sweep kills it.
#   4. SELF-EXIT.  A CURRENT-engine watcher, orphaned the same way, is gone within
#      one refresh interval, and so is the `sleep` it was blocked in.
#   5. NO FALSE KILLS.  A watcher whose parent is ALIVE survives every one of the
#      above — it does not self-exit, it is listed by neither report, and the real
#      reap leaves it running. Its cwd is deliberately INSIDE a chief worktree,
#      which is the shape that used to be reported as `[cwd] working in …` and
#      reaped as agent work.
#
# HOW THE UNFIXED ENGINE IS OBTAINED. Not from git history — CI clones shallow, so
# `git show HEAD~2:engine/monitor.sh` is unavailable exactly where this test most
# needs to run. Instead the current monitor.sh is copied and its stop condition is
# neutered to `return 1`, which IS the pre-fix loop: no stop condition at all. The
# rewrite is asserted to have applied, so renaming the function fails the test loudly
# rather than silently turning the reproduction into a no-op.
#
# HERMETIC in state: its own $CHIEF_PREFIX / $CHIEF_RUNS / $CHIEF_REPOS, so nothing
# reads or writes the operator's real ~/.chief (pointing $CHIEF_RUNS at an empty dir
# also makes `render` fast, which matters — against a real registry a render can take
# seconds, long enough to make a correct self-exit look like a survivor).
#
# NOT hermetic in processes, and cannot be: the viewer key is host-wide BY DESIGN —
# a view belongs to no run, so there is no repo to scope it to. Two consequences,
# both deliberate. Every assertion here names the PLANTED pid rather than a count,
# because the host may carry other people's abandoned views. And the one real
# (non-dry) sweep below can end another abandoned view on this machine — that is the
# command's whole purpose, it costs a redraw, and a view whose terminal is still
# open is protected by the live-parent rule asserted in section 5.
#
# WIRED INTO TWO LISTS, NOT THREE. test/all.sh (the whole-repo run) and CI. It is
# deliberately OUT of .chief/verify.sh's CHIEF_BYSTANDER_TESTS, for the same reason
# test/monitor.sh is: it spawns real watchers and asserts on wall-clock refresh
# intervals, and the merge gate runs beneath whatever parallel load the driver is
# under. CI runs it on an idle host, which is where a timing assertion means
# something. Moving it into the gate means accepting merges that fail on load.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
PIDS=""
# `wait` after the kills reaps this shell's own wrapper jobs, so a failing run does
# not trail bash's "Killed: 9 bash -c …" job notices over the assertion that failed.
cleanup() {
  local p; for p in $PIDS; do kill -9 "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "MONITOR-ORPHAN FAIL: $*" >&2; exit 1; }
note() { echo "monitor-orphan: $*"; }

# ── hermetic state ────────────────────────────────────────────────────────────
export CHIEF_PREFIX="$WORK/ch" CHIEF_RUNS="$WORK/ch/runs" CHIEF_REPOS="$WORK/ch/repos"
WTS="$CHIEF_PREFIX/worktrees"
mkdir -p "$CHIEF_RUNS" "$WTS/zz-demo-111/tl"
: > "$CHIEF_REPOS"
cd "$WORK"

MON="$ROOT/engine/monitor.sh"
[ -f "$MON" ] || fail "engine/monitor.sh not found at $MON"

# `chief reap` IS `bash engine/reap.sh` (bin/chief:cmd_reap), so this is the command
# under test, run straight from the worktree — no install step, and therefore visible
# to an uncommitted engine edit while iterating.
#
# --scope zz- keeps the AGENT-WORK half pointed at a run-id prefix nothing on this
# host wears (a run id is `<repo>-<cksum>-<epoch>-<pid>`), which is also what clears
# the engine's refusal of an unscoped sweep read against a foreign registry. The VIEW
# half ignores --scope entirely — that is the point, and section 2 proves it.
# --no-disk keeps the sweep to processes; the disk pass is test/sweep.sh's subject.
reap() { bash "$ROOT/engine/reap.sh" "$@" 2>&1; }

# A process is alive only if it is not a ZOMBIE — `kill -0` and a bare `ps -p` both
# succeed on one. This matters twice here: the wrapper shells below are children of
# this shell, and (see spawn/orphan) a zombie parent still answers `ps -o pid=`.
alive() { ps -o pid=,stat= -p "${1:-0}" 2>/dev/null | awk '$2 !~ /^Z/ {f=1} END{exit !f}'; }
# LISTED AS A VIEW vs LISTED AS AGENT WORK — the distinction the whole of US-2 is
# about. Both grep the same report; only the key tag differs.
as_view() { LC_ALL=C grep -qE "pid +$1 +\[view\]" <<<"$2"; }
as_work() { LC_ALL=C grep -qE "pid +$1 +\[(cwd|argv|env|tree)\]" <<<"$2"; }
listed()  { as_view "$1" "$2" || as_work "$1" "$2"; }

# ── the UNFIXED engine: the current one with its stop condition removed ───────
# `return 1` from watch_should_stop is precisely the pre-fix loop — asked once per
# tick and always answering "keep going".
mkdir -p "$WORK/unfixed"
cp -R "$ROOT/engine" "$WORK/unfixed/engine"
OLD="$WORK/unfixed/engine/monitor.sh"
if LC_ALL=C grep -q '^watch_should_stop() {' "$MON"; then
  LC_ALL=C awk '
    /^watch_should_stop\(\) \{/ {
      print; print "  return 1   # CHIEF-TEST-UNFIXED — the pre-2026-08-19 loop had no stop condition"
      inf = 1; next
    }
    inf && /^\}/ { print; inf = 0; next }
    inf { next }
    { print }
  ' "$MON" > "$OLD.new"
  mv "$OLD.new" "$OLD"
  LC_ALL=C grep -q 'CHIEF-TEST-UNFIXED' "$OLD" \
    || fail "watch_should_stop is present but the rewrite did not apply — the 'unfixed' arm
would silently be a copy of the FIXED engine. Update the awk rewrite in this file."
  bash -n "$OLD" || fail "the neutered monitor.sh does not parse"
else
  # No stop condition to remove: this engine IS the unfixed one. Section 1 will
  # reproduce (correctly, on the real thing) and section 4 will fail on the defect
  # itself, which is the failure this file is for — not a harness complaint.
  note "engine/monitor.sh has no stop condition — the 'unfixed' arm IS this engine, verbatim"
fi

# ── spawning a watcher, and orphaning it ──────────────────────────────────────
# The wrapper stands in for the terminal: it starts the watcher and then just exists.
# kill -9 on it is a window closing without Ctrl-C — the measured shape, where no
# SIGHUP is ever sent because the watcher is not in a foreground process group with a
# controlling terminal to hang up.
#
# argv mirrors bin/chief exactly (`exec bash "$ENGINE/monitor.sh" watch N`), because
# reap's viewer key is that argv. The path must keep its `engine/` component.
# stdin/stdout are /dev/null on purpose: a tty on stdout would arm monitor.sh's OTHER
# stop condition (which is a different test), and a tty on stdin would make the tick
# a `read` that eats the operator's keystrokes when this suite is run by hand.
SPAWN_N=0
WATCHER=""; WRAPPER=""
spawn_watcher() {   # $1 = monitor.sh path, $2 = cwd, $3 = interval
  local mon="$1" wd="$2" iv="$3" f i
  SPAWN_N=$(( SPAWN_N + 1 )); f="$WORK/kid.$SPAWN_N"; : > "$f"
  bash -c 'cd "$2" && exec bash "$0" watch "$1" </dev/null >/dev/null 2>&1 &
           echo $! > "$3"; exec sleep 300' "$mon" "$iv" "$wd" "$f" &
  WRAPPER=$!
  PIDS="$PIDS $WRAPPER"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$f" ] && break; sleep 0.2
  done
  WATCHER="$(cat "$f" 2>/dev/null || echo)"
  case "$WATCHER" in ''|*[!0-9]*) fail "the watcher did not start (interval $iv, cwd $wd)" ;; esac
  PIDS="$PIDS $WATCHER"
  alive "$WATCHER" || fail "the watcher (pid $WATCHER) died before it could be orphaned"
}

# `wait` is not tidiness. A kill -9'd child stays a ZOMBIE until this shell reaps it,
# and `ps -o pid= -p <zombie>` SUCCEEDS — so an unwaited wrapper reads as a live
# parent, watch_should_stop answers "keep going", and section 4 fails for a reason
# that has nothing to do with the engine.
orphan() {          # $1 = wrapper pid, $2 = watcher pid
  local i
  kill -9 "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(ps -o ppid= -p "$2" 2>/dev/null | tr -d ' ')" = 1 ] && return 0
    alive "$2" || return 0        # already gone: a self-exit, which is the good case
    sleep 0.2
  done
  return 0
}

# Does PPID 1 MEAN re-parented on this host? reap declines to guess when PID 1 is not
# a recognisable init (in a container it is often the entrypoint shell, and there a
# viewer's PPID 1 is its ORIGINAL parent, alive and being read). Where it declines,
# the "reap sees it" assertions cannot hold and the DECLINE is asserted instead.
# An engine with NO viewer key at all answers 0 here too: that engine is the unfixed
# one, and the strict assertions below must RUN and fail on it rather than be skipped
# by a probe that mistook a missing function for a container.
PID1_INIT=1
bash -c '. "$1"/engine/reap.sh
         declare -f chief_pid1_is_init >/dev/null || exit 0
         chief_pid1_is_init || exit 3
         exit 0' _ "$ROOT" 2>/dev/null || PID1_INIT=0
[ "$PID1_INIT" = 1 ] || note "PID 1 is '$(ps -o comm= -p 1 2>/dev/null | tr -d ' ')', which reap\
 does not read as an init — a PPID-1 viewer here may be a view somebody is watching, so reap\
 must DECLINE rather than guess, and that is what sections 2/3 assert instead."

# ── 5a. THE CONTROL, started first so it is live through every sweep below ────
# A watcher whose terminal is still open. Its cwd is inside a chief worktree — the
# shape that was reported as `[cwd] working in demo · tl` and would have been reaped
# as agent work by a sweep that knew nothing about views.
spawn_watcher "$MON" "$WTS/zz-demo-111/tl" 1
LIVE_WATCHER="$WATCHER"; LIVE_WRAPPER="$WRAPPER"

# ── 1. REPRODUCTION — the unfixed watcher outlives its terminal ───────────────
spawn_watcher "$OLD" "$WORK" 1
OLD_WATCHER="$WATCHER"; OLD_WRAPPER="$WRAPPER"
orphan "$OLD_WRAPPER" "$OLD_WATCHER"
sleep 4                                   # four refresh intervals, not one
alive "$OLD_WATCHER" \
  || fail "the UNFIXED watcher (pid $OLD_WATCHER) exited on its own after 4 refresh intervals.
This test no longer reproduces the defect — it would be asserting behaviour that
already works. Check the awk rewrite of watch_should_stop above."
[ "$(ps -o ppid= -p "$OLD_WATCHER" 2>/dev/null | tr -d ' ')" = 1 ] \
  || fail "the unfixed orphan was not re-parented to PID 1 — this is not the measured shape"
note "reproduced: an unfixed watcher survives its terminal, PPID 1 (pid $OLD_WATCHER)"

alive "$LIVE_WATCHER" || fail "the live-parent control (pid $LIVE_WATCHER) exited while its parent was alive"

# ── 2. REAP SEES IT — as a VIEW, and not as agent work ───────────────────────
out="$(reap -n --scope zz- --no-disk)" || fail "chief reap -n exited non-zero:
$out"
case "$out" in *"dry run"*) ;; *) fail "-n did not say it was a dry run:
$out" ;; esac
alive "$OLD_WATCHER" || fail "-n signalled the orphan — a dry run must not touch anything"

if [ "$PID1_INIT" = 1 ]; then
  as_view "$OLD_WATCHER" "$out" \
    || fail "the orphaned view (pid $OLD_WATCHER, ppid 1) was not reported. This is the
2026-08-19 case exactly: nine of these were running while reap printed 'no orphaned
chief processes'.
$out"
  as_work "$OLD_WATCHER" "$out" \
    && fail "the orphaned view (pid $OLD_WATCHER) was reported as agent WORK. Ending a view
costs a redraw; ending an agent tree costs a run's worth of work. One undifferentiated
list makes the free case and the expensive case look alike.
$out"
  case "$out" in *"orphaned monitor view(s)"*) ;; *) fail "views have no headline of their own:
$out" ;; esac
  LC_ALL=C grep -q 'key: \[view\]' <<<"$out" \
    || fail "the report does not name the key a view was found on:
$out"
  # …and the clean-host wording covers BOTH kinds, so "clean" cannot mean "clean of
  # one kind" the way it did when nine views were running behind it.
  LC_ALL=C grep -q 'ORPHAN VIEW —' <<<"$out" \
    || fail "the view line does not say WHY it is judged abandoned:
$out"
else
  LC_ALL=C grep -q 'left alone — .*monitor view' <<<"$out" \
    || fail "PID 1 is not an init on this host, so a PPID-1 viewer must be DECLINED and
said so — a sweep that silently skips is indistinguishable from a clean host:
$out"
fi

# ── 5b. NO FALSE KILLS — the live-parent control is in NEITHER list ──────────
listed "$LIVE_WATCHER" "$out" \
  && fail "a watcher whose parent is ALIVE (pid $LIVE_WATCHER) was listed for reaping. Its
terminal is still open and somebody is reading it.
$out"
note "the live-parent watcher (pid $LIVE_WATCHER, cwd inside a worktree) is in neither list"

# ── 3. REAP ENDS IT ──────────────────────────────────────────────────────────
if [ "$PID1_INIT" = 1 ]; then
  out="$(reap --scope zz- --no-disk)" || fail "chief reap exited non-zero:
$out"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do alive "$OLD_WATCHER" || break; sleep 0.5; done
  alive "$OLD_WATCHER" && fail "the orphaned view (pid $OLD_WATCHER) survived the reap:
$out"
  case "$out" in *"About to reap"*) ;; *) fail "the real reap did not announce what it was about to kill:
$out" ;; esac
  alive "$LIVE_WATCHER" \
    || fail "THE REAP KILLED A LIVE VIEW (pid $LIVE_WATCHER) — its parent was alive throughout"
  listed "$LIVE_WATCHER" "$out" \
    && fail "the real reap listed the live-parent watcher (pid $LIVE_WATCHER):
$out"
  note "reaped the orphaned view; the live-parent watcher is untouched"
else
  kill -9 "$OLD_WATCHER" 2>/dev/null || true
  note "skipped the real sweep: PID 1 is not an init here, so reap correctly declines"
fi

# ── 4. SELF-EXIT — the CURRENT engine ends itself, and its sleep with it ──────
# A long interval on purpose: it leaves the watcher blocked in `sleep` at the moment
# its terminal dies, which is both the real shape and what makes the sub-assertion
# below (reap can still SEE a real, current-engine orphan before it goes) possible
# without a race that could fail.
IV=20
spawn_watcher "$MON" "$WORK" "$IV"
NEW_WATCHER="$WATCHER"; NEW_WRAPPER="$WRAPPER"
# The forked `sleep` is the tick when stdin is not a terminal, and it is half of what
# the nine left behind: nine watchers were also the machine's nine sleeps.
KIDS=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  KIDS="$(pgrep -P "$NEW_WATCHER" 2>/dev/null | tr '\n' ' ')"
  [ -n "$KIDS" ] && break
  sleep 0.3
done
orphan "$NEW_WRAPPER" "$NEW_WATCHER"

# BOTH HALVES, one real watcher: while it is still blocked in that sleep, reap must
# already see it. Guarded on still-being-alive rather than asserted blind — a watcher
# that has ALREADY self-exited is the desired behaviour, never a failure.
if [ "$PID1_INIT" = 1 ] && alive "$NEW_WATCHER"; then
  out="$(reap -n --scope zz- --no-disk)" || fail "chief reap -n exited non-zero:
$out"
  if alive "$NEW_WATCHER"; then
    as_view "$NEW_WATCHER" "$out" \
      || fail "a REAL, current-engine watcher (pid $NEW_WATCHER) that had outlived its terminal
was not seen by reap while it was still alive:
$out"
    note "reap sees a real current-engine orphan (pid $NEW_WATCHER) before it self-exits"
  fi
fi

for _ in $(seq 1 $(( (IV + 12) * 2 ))); do alive "$NEW_WATCHER" || break; sleep 0.5; done
alive "$NEW_WATCHER" && fail "the watcher (pid $NEW_WATCHER) outlived its terminal by more than
one refresh interval (${IV}s) — this is the defect: nine of these were found on
2026-08-19, PPID 1, the oldest 11.5 hours old"
note "the current engine's watcher self-exited within one refresh interval"

if [ -n "$KIDS" ]; then
  for k in $KIDS; do
    LC_ALL=C ps -o command= -p "$k" 2>/dev/null | LC_ALL=C grep -q '^sleep' \
      && fail "the watcher exited but its forked \`sleep\` (pid $k) is still running — the nine
orphans were also the machine's nine sleeps"
  done
  note "the watcher's forked sleep(s) went with it:$KIDS"
else
  note "no forked sleep was sampled (the tick may be bash's own \`read\`) — nothing to assert"
fi

# ── 5c. the control survived everything ──────────────────────────────────────
alive "$LIVE_WATCHER" \
  || fail "the live-parent watcher (pid $LIVE_WATCHER) did not survive the whole run — 0 false
kills and 0 false self-exits is the bar"
kill -0 "$LIVE_WRAPPER" 2>/dev/null || fail "the control's parent died mid-test; its survival proves nothing"
kill -9 "$LIVE_WATCHER" "$LIVE_WRAPPER" 2>/dev/null || true
wait "$LIVE_WRAPPER" 2>/dev/null || true

echo "MONITOR-ORPHAN PASS — an unfixed watcher outlives its terminal (reproduced); reap reports\
 it under its own [view] key and never as agent work, and ends it; the current engine's watcher\
 self-exits within one refresh interval and takes its forked sleep with it; a watcher whose\
 parent is alive self-exits never, is listed never, and is reaped never"
