#!/usr/bin/env bash
# test/reapscope.sh — the orphan reaper finds the ENGINE, and nothing else.
#
# Two halves of one bug (engine/reap.sh, `chief reap`):
#
#   FINDING. The sweep this replaces was `pgrep -f "$WT_ROOT"`. But driver.sh,
#   agent.sh and `claude --dangerously-skip-permissions --print` carry no worktree
#   path on their command line — only their transient children do — so it reaped the
#   leaves and left the engine above them alive and spending. Every orphan below has
#   a deliberately boring argv (`sleep`), exactly like the real processes: if the
#   reaper can still find them, it is not matching argv paths.
#
#   SCOPING. A sweep that kills too much is worse than one that kills too little. So
#   this also pins what must SURVIVE: a registered live run (and its children), a
#   driver holding its repo's driver.lock but missing from the registry, a developer's
#   own `claude` session running elsewhere, and another repo's run when the sweep is
#   scoped to one repo. That scoping is asserted here, not argued in a comment.
#
# Hermetic: temp $CHIEF_PREFIX/$CHIEF_RUNS/$CHIEF_REPOS, fake worktrees, decoy
# processes that are all `sleep`. Never signals anything outside its own temp tree,
# and never touches the real ~/.chief.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
PIDS=""
cleanup() { local p; for p in $PIDS; do kill -9 "$p" 2>/dev/null || true; done; rm -rf "$WORK"; }
trap cleanup EXIT
fail() { echo "REAPSCOPE FAIL: $*" >&2; exit 1; }

# ── install chief from this checkout, into a private prefix ───────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
export CHIEF_PREFIX="$PREFIX" CHIEF_RUNS="$PREFIX/runs" CHIEF_REPOS="$PREFIX/repos"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"
WTS="$PREFIX/worktrees"                       # every repo's worktrees live here
mkdir -p "$WTS/alpha-111/tl-a" "$WTS/beta-222/tl-b" "$CHIEF_RUNS" "$WORK/elsewhere"
cd "$WORK"

# A process is alive only if it is not a ZOMBIE: `kill -0` (and a bare `ps -p`)
# succeed on one, and every decoy here is a child of this shell, so a TERMed decoy
# would look alive forever and every "was it reaped?" assertion would misfire.
alive()  { ps -o pid=,stat= -p "$1" 2>/dev/null | awk '$2 !~ /^Z/ {f=1} END{exit !f}'; }
listed() { grep -q "pid $1 " <<<"$2"; }

# ── decoys ────────────────────────────────────────────────────────────────────
# spawn CWD ARGV0 -> $SPAWNED = pid of a `sleep` with that cwd and that argv.
SPAWNED=""
spawn() {
  ( cd "$1" && exec -a "$2" sleep 300 ) &
  SPAWNED=$!
  PIDS="$PIDS $SPAWNED"
  disown "$SPAWNED" 2>/dev/null || true    # the point is to be reaped — don't report it as a killed job
}

# (1) ORPHAN, cwd marker: an agent tree working inside a chief worktree whose argv
#     names no path at all — the exact layer the old pgrep sweep could not see.
spawn "$WTS/alpha-111/tl-a" sleep;                                        orphan_cwd="$SPAWNED"
# (2) ORPHAN, argv marker: a driver, whose own cwd is wherever the operator stood,
#     identified only by the run marker driver.sh stamps on itself.
spawn "$WORK/elsewhere" "bash /e/driver.sh --chief-run=alpha-111-1700-4242"; orphan_drv="$SPAWNED"
# (3) another repo's orphan — must not be touched by an alpha-scoped sweep.
spawn "$WTS/beta-222/tl-b" sleep;                                         orphan_beta="$SPAWNED"
spawn "$WORK/elsewhere" "bash /e/driver.sh --chief-run=beta-222-1700-4243"; orphan_beta_drv="$SPAWNED"
# (4) a developer's OWN claude session, running somewhere else entirely.
spawn "$WORK/elsewhere" "claude --dangerously-skip-permissions --print";   dev_claude="$SPAWNED"
# (5) a REGISTERED live run: a driver outside the worktrees whose child works inside
#     one — the child must be protected through parentage, not by where it sits.
bash -c '( cd "$1" && exec sleep 300 ) & echo $! > "$2"; wait' _ "$WTS/beta-222/tl-b" "$WORK/child.pid" &
live_drv=$!; PIDS="$PIDS $live_drv"; disown "$live_drv" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$WORK/child.pid" ] && break; sleep 0.2; done
live_child="$(cat "$WORK/child.pid" 2>/dev/null || echo)"
[ -n "$live_child" ] || fail "could not start the live run's child process"
PIDS="$PIDS $live_child"
printf 'pid=%s\nrepo=%s\nnames=tl-b\n' "$live_drv" "$WORK/repo-beta" > "$CHIEF_RUNS/$live_drv.run"
# (6) a driver that is ALIVE but UNREGISTERED, still holding its repo's driver.lock.
#     Losing the run file is a bookkeeping bug (chief ps under-reports it), never a
#     licence to kill the work — this one must survive on the lock alone.
locked_repo="$WORK/repo-locked"; mkdir -p "$locked_repo/.chief/state/driver.lock"
printf 'CHIEF_TOOL=claude\n' > "$locked_repo/.chief/config"
spawn "$WTS/alpha-111/tl-a" "bash /e/driver.sh --chief-run=alpha-111-1700-4244"; locked_drv="$SPAWNED"
echo "$locked_drv" > "$locked_repo/.chief/state/driver.lock/pid"
printf '%s\n' "$locked_repo" > "$CHIEF_REPOS"
sleep 0.5

# ── 1. host-wide dry run: found the engine, spared everything else ─────────────
out="$("$CHIEF" reap -n 2>&1)" || fail "chief reap -n exited non-zero: $out"
listed "$orphan_cwd"  "$out" || fail "the cwd-marked orphan (pid $orphan_cwd, argv 'sleep') was not found:
$out"
listed "$orphan_drv"  "$out" || fail "the argv-marked orphan driver (pid $orphan_drv) was not found:
$out"
listed "$orphan_beta" "$out" || fail "the other repo's orphan (pid $orphan_beta) was not found host-wide:
$out"
if listed "$dev_claude" "$out"; then fail "a developer's own claude session (pid $dev_claude) was listed for reaping:
$out"; fi
if listed "$live_drv"   "$out"; then fail "a REGISTERED live run's driver (pid $live_drv) was listed for reaping:
$out"; fi
if listed "$live_child" "$out"; then fail "a live run's child (pid $live_child) was listed — descendants must be protected:
$out"; fi
if listed "$locked_drv" "$out"; then fail "a live driver holding its repo's driver.lock (pid $locked_drv) was listed:
$out"; fi
case "$out" in *"alpha · tl-a"*) ;; *) fail "the report does not name the run an orphan belonged to (repo · tasklist):
$out" ;; esac
case "$out" in *"dry run"*)      ;; *) fail "-n did not say it was a dry run:
$out" ;; esac
alive "$orphan_cwd" || fail "-n signalled the orphan — a dry run must not touch anything"

# ── 2. repo-scoped sweep (the driver's startup path) can't reach another repo ──
# shellcheck source=engine/reap.sh
. "$PREFIX/src/engine/reap.sh"
chief_find_orphans "$WTS/alpha-111" "--chief-run=alpha-111-" || fail "chief_find_orphans errored"
found=" $CHIEF_ORPHANS "
case "$found" in *" $orphan_cwd "*)      ;; *) fail "alpha-scoped sweep missed alpha's own orphan ($orphan_cwd): '$CHIEF_ORPHANS'" ;; esac
case "$found" in *" $orphan_drv "*)      ;; *) fail "alpha-scoped sweep missed alpha's marked driver ($orphan_drv): '$CHIEF_ORPHANS'" ;; esac
case "$found" in *" $orphan_beta "*)     fail "alpha-scoped sweep reached INTO another repo's worktree ($orphan_beta)" ;; esac
case "$found" in *" $orphan_beta_drv "*) fail "alpha-scoped sweep matched another repo's run marker ($orphan_beta_drv)" ;; esac
case "$found" in *" $locked_drv "*)      fail "alpha-scoped sweep targeted a lock-holding live driver ($locked_drv)" ;; esac

# ── 3. the real reap: orphans die, the protected set lives ────────────────────
out="$("$CHIEF" reap 2>&1)" || fail "chief reap exited non-zero: $out"
for _ in 1 2 3 4 5 6 7 8 9 10; do alive "$orphan_cwd" || break; sleep 0.3; done
if alive "$orphan_cwd";  then fail "the cwd-marked orphan (pid $orphan_cwd) survived the reap:
$out"; fi
if alive "$orphan_drv";  then fail "the argv-marked orphan driver (pid $orphan_drv) survived the reap:
$out"; fi
if alive "$orphan_beta"; then fail "the other repo's orphan (pid $orphan_beta) survived a host-wide reap:
$out"; fi
alive "$dev_claude" || fail "a developer's own claude session was KILLED by the sweep:
$out"
alive "$live_drv"   || fail "a registered live run's driver was KILLED by the sweep:
$out"
alive "$live_child" || fail "a registered live run's child was KILLED by the sweep:
$out"
alive "$locked_drv" || fail "a lock-holding live driver was KILLED by the sweep:
$out"
case "$out" in *TERM*|*KILL*) ;; *) fail "the reap did not report how it signalled:
$out" ;; esac

# ── 4. a clean host reports clean ─────────────────────────────────────────────
kill -9 "$locked_drv" 2>/dev/null || true
rm -f "$locked_repo/.chief/state/driver.lock/pid"
out="$("$CHIEF" reap -n 2>&1)" || fail "chief reap -n exited non-zero on a clean host: $out"
case "$out" in *"no orphaned chief processes"*) ;; *) fail "expected a clean sweep after the reap, got:
$out" ;; esac

echo "REAPSCOPE PASS — orphans found by cwd + run marker (never by argv paths); live runs, lock-holding drivers and a developer's own claude untouched; repo scoping holds"
