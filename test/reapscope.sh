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
# Hermetic in STATE and in PROCESSES, which are two different things. A temp
# $CHIEF_PREFIX/$CHIEF_RUNS/$CHIEF_REPOS bounds where this test READS; it does not
# bound `pgrep -f --chief-run=`, which is every chief process on the box. This test
# used to sweep host-wide out of that temp registry, so a developer's live run in a
# sibling repo was checked against a registry that had never heard of it and read as
# an orphan — three real runs were killed that way (2026-08-17). So every sweep here
# is SCOPED to `$RS`, a run-id prefix only these fixtures wear, and the last section
# pins that the unscoped invocation is now refused outright.
#
# Decoy processes are all `sleep`. Nothing outside this test's own temp tree is ever
# signalled, and the real ~/.chief is never touched.
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
# THE FIXTURE NAMESPACE. Every run id below starts with this, and every sweep is
# scoped to it, so no `pgrep` in this file can reach a real run: a run id is
# `<repo>-<cksum>-<epoch>-<pid>` and no repo on this host is named `reapscope-*`.
RS="reapscope-"
mkdir -p "$WTS/${RS}alpha-111/tl-a" "$WTS/${RS}beta-222/tl-b" "$CHIEF_RUNS" "$WORK/elsewhere"
cd "$WORK"

# A process is alive only if it is not a ZOMBIE: `kill -0` (and a bare `ps -p`)
# succeed on one, and every decoy here is a child of this shell, so a TERMed decoy
# would look alive forever and every "was it reaped?" assertion would misfire.
alive()  { ps -o pid=,stat= -p "$1" 2>/dev/null | awk '$2 !~ /^Z/ {f=1} END{exit !f}'; }
# LISTED FOR REAPING, specifically: a report line carrying one of the key tags
# ([cwd]/[argv]/[env]/[tree]). The sweep also prints a "left alone" block naming pids
# it declined to touch, and a bare "pid N" grep cannot tell the two apart — which is
# the distinction decoy (7) below exists to pin.
listed() { grep -qE "pid $1 +\\[" <<<"$2"; }
spared() { grep -qE "pid $1 +unresolvable" <<<"$2"; }

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
spawn "$WTS/${RS}alpha-111/tl-a" sleep;                                   orphan_cwd="$SPAWNED"
# (2) ORPHAN, argv marker: a driver, whose own cwd is wherever the operator stood,
#     identified only by the run marker driver.sh stamps on itself.
spawn "$WORK/elsewhere" "bash /e/driver.sh --chief-run=${RS}alpha-111-1700-4242"; orphan_drv="$SPAWNED"
# (3) another repo's orphan — must not be touched by an alpha-scoped sweep.
spawn "$WTS/${RS}beta-222/tl-b" sleep;                                    orphan_beta="$SPAWNED"
spawn "$WORK/elsewhere" "bash /e/driver.sh --chief-run=${RS}beta-222-1700-4243"; orphan_beta_drv="$SPAWNED"
# (4) a developer's OWN claude session, running somewhere else entirely.
spawn "$WORK/elsewhere" "claude --dangerously-skip-permissions --print";   dev_claude="$SPAWNED"
# (5) a REGISTERED live run: a driver outside the worktrees whose child works inside
#     one — the child must be protected through parentage, not by where it sits.
bash -c '( cd "$1" && exec sleep 300 ) & echo $! > "$2"; wait' _ "$WTS/${RS}beta-222/tl-b" "$WORK/child.pid" &
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
spawn "$WTS/${RS}alpha-111/tl-a" "bash /e/driver.sh --chief-run=${RS}alpha-111-1700-4244"; locked_drv="$SPAWNED"
echo "$locked_drv" > "$locked_repo/.chief/state/driver.lock/pid"
printf '%s\n' "$locked_repo" > "$CHIEF_REPOS"
# (7) THE BYSTANDER. A chief driver of some OTHER install: a well-formed run marker
#     whose repo this prefix has never heard of — no run file claiming the id, no
#     entry in $CHIEF_REPOS, no worktree dir under $WTS. Exactly the shape of a live
#     run in a sibling repo seen by a sweep with a hermetic $CHIEF_RUNS, which is the
#     configuration that killed three real runs. Its ABSENCE from this registry is
#     evidence the registry is the wrong one, never evidence the run is dead, so it
#     must be REPORTED and LEFT ALONE rather than reaped.
spawn "$WORK/elsewhere" "bash /e/driver.sh --chief-run=${RS}gamma-999888777-1700-4245";  foreign_drv="$SPAWNED"
sleep 0.5

# ── 1. dry run across every fixture repo: found the engine, spared everything ──
# Scoped to $RS, which spans all three fixture repos (alpha, beta, gamma) and nothing
# else on the host — the cross-repo reach the assertions below need, without the
# cross-INSTALL reach that made this test dangerous.
out="$("$CHIEF" reap -n --scope "$RS" 2>&1)" || fail "chief reap -n exited non-zero: $out"
listed "$orphan_cwd"  "$out" || fail "the cwd-marked orphan (pid $orphan_cwd, argv 'sleep') was not found:
$out"
listed "$orphan_drv"  "$out" || fail "the argv-marked orphan driver (pid $orphan_drv) was not found:
$out"
listed "$orphan_beta" "$out" || fail "the other repo's orphan (pid $orphan_beta) was not found by a sweep spanning both repos:
$out"
if listed "$dev_claude" "$out"; then fail "a developer's own claude session (pid $dev_claude) was listed for reaping:
$out"; fi
if listed "$live_drv"   "$out"; then fail "a REGISTERED live run's driver (pid $live_drv) was listed for reaping:
$out"; fi
if listed "$live_child" "$out"; then fail "a live run's child (pid $live_child) was listed — descendants must be protected:
$out"; fi
if listed "$locked_drv" "$out"; then fail "a live driver holding its repo's driver.lock (pid $locked_drv) was listed:
$out"; fi
if listed "$foreign_drv" "$out"; then fail "a driver of ANOTHER install (pid $foreign_drv) was listed for reaping — an unreadable registry is not evidence of orphanhood:
$out"; fi
spared "$foreign_drv" "$out" || fail "the unresolvable driver (pid $foreign_drv) was neither reaped nor REPORTED — a sweep that silently declines is indistinguishable from a clean host:
$out"
case "$out" in *"${RS}alpha · tl-a"*) ;; *) fail "the report does not name the run an orphan belonged to (repo · tasklist):
$out" ;; esac
case "$out" in *"dry run"*)      ;; *) fail "-n did not say it was a dry run:
$out" ;; esac
alive "$orphan_cwd" || fail "-n signalled the orphan — a dry run must not touch anything"

# ── 2. repo-scoped sweep (the driver's startup path) can't reach another repo ──
# shellcheck source=engine/reap.sh
. "$PREFIX/src/engine/reap.sh"
chief_find_orphans "$WTS/${RS}alpha-111" "--chief-run=${RS}alpha-111-" || fail "chief_find_orphans errored"
found=" $CHIEF_ORPHANS "
case "$found" in *" $orphan_cwd "*)      ;; *) fail "alpha-scoped sweep missed alpha's own orphan ($orphan_cwd): '$CHIEF_ORPHANS'" ;; esac
case "$found" in *" $orphan_drv "*)      ;; *) fail "alpha-scoped sweep missed alpha's marked driver ($orphan_drv): '$CHIEF_ORPHANS'" ;; esac
case "$found" in *" $orphan_beta "*)     fail "alpha-scoped sweep reached INTO another repo's worktree ($orphan_beta)" ;; esac
case "$found" in *" $orphan_beta_drv "*) fail "alpha-scoped sweep matched another repo's run marker ($orphan_beta_drv)" ;; esac
case "$found" in *" $locked_drv "*)      fail "alpha-scoped sweep targeted a lock-holding live driver ($locked_drv)" ;; esac

# ── 3. the real reap: orphans die, the protected set lives ────────────────────
out="$("$CHIEF" reap --scope "$RS" 2>&1)" || fail "chief reap exited non-zero: $out"
for _ in 1 2 3 4 5 6 7 8 9 10; do alive "$orphan_cwd" || break; sleep 0.3; done
if alive "$orphan_cwd";  then fail "the cwd-marked orphan (pid $orphan_cwd) survived the reap:
$out"; fi
if alive "$orphan_drv";  then fail "the argv-marked orphan driver (pid $orphan_drv) survived the reap:
$out"; fi
if alive "$orphan_beta"; then fail "the other repo's orphan (pid $orphan_beta) survived a sweep spanning both repos:
$out"; fi
alive "$dev_claude" || fail "a developer's own claude session was KILLED by the sweep:
$out"
alive "$live_drv"   || fail "a registered live run's driver was KILLED by the sweep:
$out"
alive "$live_child" || fail "a registered live run's child was KILLED by the sweep:
$out"
alive "$locked_drv" || fail "a lock-holding live driver was KILLED by the sweep:
$out"
alive "$foreign_drv" || fail "a driver belonging to ANOTHER install was KILLED by the sweep — this is the 2026-08-17 incident:
$out"
case "$out" in *TERM*|*KILL*) ;; *) fail "the reap did not report how it signalled:
$out" ;; esac

# ── 4. a clean host reports clean ─────────────────────────────────────────────
kill -9 "$locked_drv" 2>/dev/null || true
rm -f "$locked_repo/.chief/state/driver.lock/pid"
out="$("$CHIEF" reap -n --scope "$RS" 2>&1)" || fail "chief reap -n exited non-zero on a clean host: $out"
case "$out" in *"no orphaned chief processes"*) ;; *) fail "expected a clean sweep after the reap, got:
$out" ;; esac

# ── 5. the guard: an UNSCOPED sweep out of this registry is refused ───────────
# Everything above is scoped by hand, and a convention nobody enforces is a defect
# waiting for its next author. The engine refuses the combination outright: a
# host-wide (empty run-id prefix) sweep read against a $CHIEF_RUNS that is not this
# host's own. That is precisely this test's configuration, so the refusal is provable
# from right here — and it is what makes the 2026-08-17 incident unrepeatable rather
# than merely unrepeated.
set +e
out="$("$CHIEF" reap -n 2>&1)"; rc=$?
set -e
[ "$rc" -ne 0 ] || fail "an UNSCOPED 'chief reap -n' from a hermetic \$CHIEF_RUNS was allowed to run (exit $rc) — the guard is not wired:
$out"
case "$out" in *REFUS*) ;; *) fail "the refusal does not say it refused:
$out" ;; esac
case "$out" in *"$CHIEF_RUNS"*) ;; *) fail "the refusal does not name the registry the sweep would have used ($CHIEF_RUNS):
$out" ;; esac
case "$out" in *--scope*) ;; *) fail "the refusal does not tell the caller how to scope the sweep:
$out" ;; esac
# And it refuses BEFORE looking: nothing was signalled on the way out.
alive "$foreign_drv" || fail "the refused sweep signalled something anyway (pid $foreign_drv)"

echo "REAPSCOPE PASS — orphans found by cwd + run marker (never by argv paths); live runs, lock-holding drivers and a developer's own claude untouched; repo scoping holds; an unscoped sweep out of a foreign registry is refused"
