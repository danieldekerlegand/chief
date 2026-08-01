#!/usr/bin/env bash
# test/reapenv.sh — the INHERITED run marker (key 3) may not widen the blast radius.
#
# Key 3 reads $CHIEF_RUN_ID back out of a candidate's environment. That is the only
# key a process cannot escape — and for exactly the same reason, the only key that can
# reach somewhere it has no business reaching: an exported variable is inherited by
# every descendant forever, including a terminal an operator opened out of an agent's
# environment, and including anything still carrying the marker of a run that is very
# much alive. So the key is gated three ways, and each gate is pinned here:
#
#   (a) the id must NAME A RUN — `<repo>-<cksum>-<epoch>-<pid>`, all three numeric;
#   (b) the run it names must be DEAD — a live run's marker is stale bookkeeping,
#       never a licence to kill;
#   (c) the carrier must not be somebody's interactive SHELL.
#
# Each gate only ever REMOVES an env-keyed candidate, so a positive control runs
# alongside every negative one: without a process the env key DOES match, "it was not
# listed" would prove only that the key never fired.
#
# Hermetic: temp $CHIEF_PREFIX/$CHIEF_RUNS/$CHIEF_REPOS, fake worktrees, decoys that
# are all `sleep`, and only DRY RUNS — this test signals nothing at all. It never
# touches the real ~/.chief.
#
# Where the platform will not show another process's environment (macOS: `ps -E` is
# accepted and prints none), key 3 is inert by construction. The end-to-end half is
# then SKIPPED loudly rather than failed; the unit half of the gates still runs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
PIDS=""
cleanup() { local p; for p in $PIDS; do kill -9 "$p" 2>/dev/null || true; done; rm -rf "$WORK"; }
trap cleanup EXIT
fail() { echo "REAPENV FAIL: $*" >&2; exit 1; }

# ── install chief from this checkout, into a private prefix ───────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
export CHIEF_PREFIX="$PREFIX" CHIEF_RUNS="$PREFIX/runs" CHIEF_REPOS="$PREFIX/repos"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"
WTS="$PREFIX/worktrees"
mkdir -p "$WTS/envrepo-4242/tl-x" "$CHIEF_RUNS" "$WORK/elsewhere"
: > "$CHIEF_REPOS"
cd "$WORK"

# $CHIEF_RUN_ID is deliberately left ALONE. When this suite runs under chief itself on
# a host where key 3 is live, that id is what makes the sweep skip the real run's tree
# (chief_pids_env_marked never emits our own id) — unsetting it would point a host-wide
# scan at the very run executing the test. Each decoy sets or clears its own marker.

alive()  { ps -o pid=,stat= -p "$1" 2>/dev/null | awk '$2 !~ /^Z/ {f=1} END{exit !f}'; }
listed() { grep -q "pid $1 " <<<"$2"; }

# ── the gates, as units ───────────────────────────────────────────────────────
# shellcheck source=engine/reap.sh
. "$PREFIX/src/engine/reap.sh"

# (a) well-formedness. The id has to parse as something this engine could have minted:
# a CHIEF_RUN_ID somebody exported by hand is not evidence of a run.
for good in "chief-1234-1700000000-4242" "my_repo-9-1-2"; do
  chief_run_id_wellformed "$good" || fail "well-formed run id '$good' was rejected"
done
for bad in "" "garbage" "no-such-thing" "a-b-c-d" "chief-1234-1700-x" "chief-x-1700-42" \
           "chief-1234-1700-1" "chief-1234-1700-"; do
  if chief_run_id_wellformed "$bad"; then fail "malformed run id '$bad' was accepted as naming a run"; fi
done

# (b) liveness. Registered: a run file CLAIMING the id, whose pid is alive.
sleep 300 & live_drv=$!; PIDS="$PIDS $live_drv"; disown "$live_drv" 2>/dev/null || true
LIVE_ID="livrepo-5151-1700000000-$live_drv"
printf 'pid=%s\nrunid=%s\nrepo=%s\nnames=tl-x\n' "$live_drv" "$LIVE_ID" "$WORK/repo-live" \
  > "$CHIEF_RUNS/$live_drv.run"
chief_run_id_live "$LIVE_ID" || fail "a registered run whose driver is alive was not seen as live"
# The whole id is compared, epoch included — that is what tells two runs of one repo
# apart, and what stops a recycled pid from passing as a live run.
if chief_run_id_live "livrepo-5151-1699999999-$live_drv"; then
  fail "a DIFFERENT run id sharing the driver pid was mistaken for the live run"
fi
# Unregistered but alive: `$$` inside `bash -c` survives the exec, so the id names the
# very pid that ends up wearing it — a driver that lost its run file.
bash -c 'exec -a "bash /e/driver.sh --chief-run=unregrepo-777-1700000000-$$" sleep 300' &
unreg_drv=$!; PIDS="$PIDS $unreg_drv"; disown "$unreg_drv" 2>/dev/null || true
sleep 0.5
UNREG_ID="unregrepo-777-1700000000-$unreg_drv"
[ "$(chief_pid_tag "$unreg_drv")" = "$UNREG_ID" ] || fail "could not stage an unregistered live driver (pid $unreg_drv)"
chief_run_id_live "$UNREG_ID" || fail "a live driver with no run file was treated as a dead run"
DEAD_ID="envrepo-4242-1700000000-999999"
if chief_run_id_live "$DEAD_ID"; then fail "an id naming no live process was reported live"; fi

# (c) the interactive shell. A shell with no SCRIPT OPERAND is one somebody is typing
# into; every shell the engine runs carries an operand and cannot be spelled without.
mkfifo "$WORK/stdin.fifo"
( export CHIEF_RUN_ID="$DEAD_ID"; cd "$WORK/elsewhere" || exit 1
  exec bash --norc --noprofile -i ) < "$WORK/stdin.fifo" >/dev/null 2>&1 &
env_shell=$!; PIDS="$PIDS $env_shell"; disown "$env_shell" 2>/dev/null || true
exec 8> "$WORK/stdin.fifo"                 # hold it open so the shell keeps waiting
sleep 0.5
alive "$env_shell" || fail "could not stage an interactive shell decoy"
chief_is_interactive_shell "$env_shell" || fail "an interactive shell (pid $env_shell, argv '$(chief_pid_cmd "$env_shell")') was not recognised as one"
if chief_is_interactive_shell "$unreg_drv"; then fail "a driver frame ('bash …/driver.sh --chief-run=…') was mistaken for an interactive shell"; fi
if chief_is_interactive_shell "$live_drv";  then fail "a bare 'sleep' was mistaken for an interactive shell"; fi

# ── decoys for the end-to-end sweep ───────────────────────────────────────────
SPAWNED=""
spawn_env() {   # $1 = run id ('' = none)  $2 = cwd  $3 = argv0
  ( if [ -n "$1" ]; then export CHIEF_RUN_ID="$1"; else unset CHIEF_RUN_ID; fi
    cd "$2" || exit 1
    exec -a "$3" sleep 300 ) &
  SPAWNED=$!
  PIDS="$PIDS $SPAWNED"
  disown "$SPAWNED" 2>/dev/null || true
}

# THE POSITIVE CONTROL: chdir'd clean out of the worktree, argv says nothing, marker of
# a run that is gone. Neither key 1 nor key 2 can see it.
spawn_env "$DEAD_ID"  "$WORK/elsewhere" sleep;   env_orphan="$SPAWNED"
# Same process, marker of a run that is LIVE and registered — gate (b).
spawn_env "$LIVE_ID"  "$WORK/elsewhere" sleep;   env_live="$SPAWNED"
# Same process, a CHIEF_RUN_ID that names no run at all — gate (a).
spawn_env "not-a-chief-run" "$WORK/elsewhere" sleep; env_bogus="$SPAWNED"
# Same process, no marker — proves the env key is what matched, not a wider pattern.
spawn_env ""          "$WORK/elsewhere" sleep;   env_none="$SPAWNED"
# Key 1's own finding, untouched by any of this — and the [cwd] line in the report.
spawn_env ""          "$WTS/envrepo-4242/tl-x" sleep; wt_orphan="$SPAWNED"
sleep 0.5

# ── the dry run: every match is labelled with the KEY that made it ────────────
out="$("$CHIEF" reap -n 2>&1)" || fail "chief reap -n exited non-zero: $out"
case "$out" in *"dry run"*) ;; *) fail "-n did not say it was a dry run:
$out" ;; esac
alive "$env_orphan" || fail "-n signalled a candidate — a dry run must not touch anything"
case "$out" in *"keys: [cwd]"*) ;; *) fail "the report has no key legend, so an operator cannot read the tags:
$out" ;; esac
listed "$wt_orphan" "$out" || fail "key 1's own orphan (pid $wt_orphan) was not found — the gates must not touch cwd matches:
$out"
case "$out" in *"[cwd]  working in envrepo · tl-x"*) ;; *) fail "the cwd match is not labelled [cwd]:
$out" ;; esac

if [ -z "$(chief_env_key_mode)" ]; then
  echo "REAPENV SKIP (end-to-end) — this platform will not show another process's" \
       "environment, so key 3 is inert here and cannot be exercised. The gates were" \
       "still checked as units above; CI runs the full half on Linux."
else
  listed "$env_orphan" "$out" || fail "the escaped-cwd orphan carrying a dead run's marker (pid $env_orphan) was not found by the env key:
$out"
  case "$out" in *"[env]  inherited run marker · run $DEAD_ID"*) ;; *) fail "the env match is not labelled [env] with the run it came from:
$out" ;; esac
  if listed "$env_shell" "$out"; then fail "an operator's interactive shell that inherited the marker (pid $env_shell) was listed for reaping:
$out"; fi
  if listed "$env_live"  "$out"; then fail "a process carrying a LIVE registered run's marker (pid $env_live) was listed for reaping:
$out"; fi
  if listed "$env_bogus" "$out"; then fail "a process carrying a CHIEF_RUN_ID that names no run (pid $env_bogus) was listed for reaping:
$out"; fi
  if listed "$env_none"  "$out"; then fail "a process with NO marker (pid $env_none) was listed — the env key matched something wider than itself:
$out"; fi
fi

# ── the protected set is still taken twice, around the scan ───────────────────
# Gate (b) protects a live run's tree from INSIDE the candidate scan — i.e. BETWEEN
# the two snapshots 75 takes. It has to ADD to them, never stand in for either: the
# pair is what closes the race where a live run spawns a fresh agent turn mid-scan.
# The count below pins the pair (it does not simulate the race); the run below it is
# the behavioural half — protection survives a full scan, orphans still come out.
n="$(awk '/^chief_find_orphans\(\)/ {f=1} f && /chief_protected_pids/ {c++} f && /^}/ {exit} END{print c+0}' \
      "$PREFIX/src/engine/reap.sh")"
[ "$n" = "2" ] || fail "chief_find_orphans calls chief_protected_pids $n time(s); the before/after pair 75 established must stay"

chief_protected_reset
chief_find_orphans "$WTS" "$CHIEF_RUN_MARKER" || fail "chief_find_orphans errored"
case " $CHIEF_PROTECTED " in *" $live_drv "*) ;; *) fail "the live registered run's driver (pid $live_drv) is not in the protected set after a full scan" ;; esac
case " $CHIEF_ORPHANS "   in *" $wt_orphan "*) ;; *) fail "the cwd-keyed orphan (pid $wt_orphan) was lost: '$CHIEF_ORPHANS'" ;; esac
case " $CHIEF_ORPHANS "   in *" $env_live "*) fail "a process carrying a live run's marker (pid $env_live) survived into CHIEF_ORPHANS" ;; esac
case " $CHIEF_ORPHANS "   in *" $env_shell "*) fail "an operator's interactive shell (pid $env_shell) survived into CHIEF_ORPHANS" ;; esac

# ── the gates AS WIRED, on every platform ─────────────────────────────────────
# The section above can only assert the negatives where key 3 is inert, and a negative
# with no positive control proves nothing. So stand in for the ONE thing macOS cannot
# do — read another process's environment — and leave every gate beneath it real. The
# decoys are the same live processes; only the platform read is scripted.
chief_pids_env_marked() {   # $1 = run id prefix (every id here shares the empty one)
  printf '%s %s\n' "$env_orphan" "$DEAD_ID"
  printf '%s %s\n' "$env_live"   "$LIVE_ID"
  printf '%s %s\n' "$env_bogus"  "not-a-chief-run"
  printf '%s %s\n' "$env_shell"  "$DEAD_ID"
}
chief_protected_reset
chief_find_orphans "$WTS" "$CHIEF_RUN_MARKER" || fail "chief_find_orphans errored with a scripted environment read"
case " $CHIEF_ORPHANS " in *" $env_orphan "*) ;; *) fail "the escaped-cwd orphan carrying a DEAD run's marker (pid $env_orphan) was not reached by the env key: '$CHIEF_ORPHANS'" ;; esac
case "$CHIEF_ORPHAN_INFO" in *"[env]  inherited run marker · run $DEAD_ID"*) ;; *) fail "the env match is not labelled [env] with the run it came from:
$CHIEF_ORPHAN_INFO" ;; esac
case " $CHIEF_ORPHANS " in *" $env_live "*)  fail "(b) a process carrying a LIVE registered run's marker (pid $env_live) was going to be reaped" ;; esac
case " $CHIEF_ORPHANS " in *" $env_bogus "*) fail "(a) a process carrying a CHIEF_RUN_ID that names no run (pid $env_bogus) was going to be reaped" ;; esac
case " $CHIEF_ORPHANS " in *" $env_shell "*) fail "(c) an operator's interactive shell that inherited the marker (pid $env_shell) was going to be reaped" ;; esac
case " $CHIEF_ORPHANS " in *" $env_none "*)  fail "a process with NO marker (pid $env_none) was matched — the env key reached wider than itself" ;; esac
case " $CHIEF_ORPHANS " in *" $wt_orphan "*) ;; *) fail "key 1's orphan (pid $wt_orphan) was lost once the env key fired — the keys must be a union" ;; esac

echo "REAPENV PASS — the inherited marker reaps only what it names: a live run's marker, an unparseable one and an operator's shell are all spared; cwd matches and the before/after protected set are untouched"
