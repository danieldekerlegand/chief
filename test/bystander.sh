#!/usr/bin/env bash
# test/bystander.sh — running the test suite must not kill a run the suite did not start.
#
# THE INCIDENT (2026-08-17). Starting `chief:98` in this repo destroyed live runs in
# cuneiform, vita and rosetta. Nothing malicious and nothing exotic: `.chief/verify.sh`
# runs a behavioural block, two of those tests called `chief reap` with an empty run-id
# prefix, and process discovery (`pgrep -u <uid> -f --chief-run=`) is HOST-WIDE however
# hermetic the caller's `$CHIEF_PREFIX` is. Each sibling repo's healthy driver was
# looked up in a temp registry that had never heard of it, read as an orphan, killed.
#
# US-1 made an unreadable registry stop meaning "dead"; US-2 made the unscoped sweep
# refuse to run at all. Both are asserted by unit-shaped tests inside the reaper. This
# is the END-TO-END one, and it is the only test here whose subject is the SUITE:
#
#     stand up a run that belongs to somebody else — its own driver argv, its own
#     $CHIEF_RUNS, its own worktree root, all outside every prefix the suite mints —
#     run the behavioural block, and assert it is still breathing.
#
# It checks the decoy after EVERY test rather than once at the end, so a future
# regression names the file that did it instead of the block that contained it.
#
# Then the other direction, because a reaper that refuses everything has traded one
# failure for another: a genuine orphan — registry readable, run file present, its
# driver pid demonstrably gone — is still reaped in the same sweep that spares the
# decoy. Sparing and reaping are one decision and are pinned as one.
#
# $CHIEF_BYSTANDER_TESTS overrides the block (space-separated test names, no .sh).
# The default is the sweep-capable subset, which is what a developer or CI wants;
# .chief/verify.sh passes its FULL behavioural block, which is where the incident
# happened and the configuration this reproduces.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; . "$ROOT/test/lib.sh"
WORK="$(mktemp -d)"
DECOYS=""
cleanup() { local p; for p in $DECOYS; do kill -9 "$p" 2>/dev/null || true; done; rm -rf "$WORK"; }
trap cleanup EXIT
fail() { echo "BYSTANDER FAIL: $*" >&2; exit 1; }
note() { echo "bystander: $*"; }

# Alive means NOT A ZOMBIE. Every decoy is a child of this shell and nothing waits on
# it, so a TERMed decoy would answer `kill -0` forever and the whole test would pass by
# failing to notice the kill it exists to catch.
alive() { ps -o pid=,stat= -p "${1:-0}" 2>/dev/null | awk '$2 !~ /^Z/ {f=1} END{exit !f}'; }
gone()  { local p="${1:-0}" i; for i in 1 2 3 4 5 6 7 8 9 10; do alive "$p" || return 0; sleep 0.3; done; return 1; }

# WHAT A DEAD DECOY LOOKS LIKE, in facts rather than in the accusation alone. The
# accusation is severe — it blocks a merge and sends the reader into the engine — so it
# has to carry enough for a reader to check it against the host: how far into the block
# we are (the decoys are bounded by this shell, not by a clock, so elapsed time is
# context and never a cause), and what the process table says now. A fully reaped pid
# prints nothing at all, which reads as a broken `ps` unless it is said out loud.
T0="$(date +%s)"
decoy_forensics() {
  local ps_line; ps_line="$(ps -o pid=,stat=,command= -p "${1:-0}" 2>/dev/null | sed 's/^ *//')"
  [ -n "$ps_line" ] || ps_line="no such process — it was reaped, not merely signalled"
  printf '%ss into the block; ps now: %s' "$(( $(date +%s) - T0 ))" "$ps_line"
}

# The fixture namespace: every run id this file mints starts with it, and the one real
# sweep it runs is scoped to it. No repo on this host is named `bystander-*`.
NS="bystander-"

# ── the bystander: a chief run belonging to ANOTHER install ───────────────────
# Its prefix, registry and worktree root all live under $DECOY, which no test in the
# block has heard of — the sibling-repo relationship, reproduced. It is deliberately
# reachable by process discovery (a well-formed `--chief-run=` marker on argv, an
# inherited $CHIEF_RUN_ID) and deliberately unresolvable by any registry lookup, which
# is exactly the shape the sweep got wrong.
DECOY="$WORK/decoy"
mkdir -p "$DECOY/runs" "$DECOY/repo" "$DECOY/worktrees"
CKD="$(printf '%s' "$DECOY/repo" | cksum | awk '{print $1}')"
mkdir -p "$DECOY/worktrees/${NS}sibling-$CKD/tl-x"

# THE DECOY'S LIFETIME IS ITS PARENT'S, NEVER A CLOCK — and that is not tidiness, it
# is the difference between this file reporting a defect and inventing one. Both decoys
# used to `sleep 3600`, which is a wall-clock ceiling on the WHOLE BLOCK, chosen rather
# than measured; and when the block outruns it the decoy simply EXITS, which `alive`
# cannot tell apart from the kill it exists to catch. Measured on 2026-09-18:
# `.chief/verify.sh`'s 78-test block on a host at load 27/14 cores reached test 34 six
# hours in, the decoys had expired somewhere inside it, and the run failed with
# "test/suspectlimit.sh KILLED the bystander driver" — naming a file that had just
# printed SUSPECTLIMIT PASS and whose own fixtures are scoped nowhere near the decoy.
# A test that accuses an innocent file is worse than no test: it blocks a merge and
# sends the reader into an engine that is behaving correctly.
#
# So a decoy waits on the PID OF THE SHELL THAT STARTED IT — `chief monitor watch`'s own
# rule, one register down (engine/monitor.sh: a looping process must not outlive the
# thing that asked for it). It cannot expire early however slow the host is, and it
# cannot leak, because the moment this shell is gone it has nothing left to wait for.
cat > "$DECOY/keepalive.sh" <<'EOS'
#!/usr/bin/env bash
# Stay alive exactly as long as pid $1 does. No clock, so nothing to outrun.
while kill -0 "$1" 2>/dev/null; do sleep 2; done
EOS

cat > "$DECOY/driver.sh" <<'EOS'
#!/usr/bin/env bash
# A stand-in for engine/driver.sh doing the one thing that matters here: stamping its
# OWN pid into the run marker it wears on argv (the real driver re-execs to place it),
# and registering itself in ITS OWN $CHIEF_RUNS — which is not the suite's, which is
# the entire point. argv is then as boring as the real thing, and it still wears the
# marker: `exec -a` renames the process whatever it goes on to run.
id="$1-$$"
printf 'runid=%s\npid=%s\nrepo=%s\nnames=tl-x\nstatus=running\n' "$id" "$$" "$2" > "$3/$$.run"
printf '%s\n' "$id" > "$4"
exec -a "bash $0 --chief-run=$id" bash "$5" "$6"
EOS

( cd "$DECOY/repo" && exec bash "$DECOY/driver.sh" "${NS}sibling-$CKD-1700" "$DECOY/repo" "$DECOY/runs" "$WORK/decoy.id" "$DECOY/keepalive.sh" "$$" ) &
decoy_drv=$!; DECOYS="$DECOYS $decoy_drv"; disown "$decoy_drv" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$WORK/decoy.id" ] && break; sleep 0.2; done
decoy_id="$(cat "$WORK/decoy.id" 2>/dev/null || echo)"
[ -n "$decoy_id" ] || fail "the decoy driver never stamped its run id"
[ -s "$DECOY/runs/$decoy_drv.run" ] || fail "the decoy driver never registered in its own \$CHIEF_RUNS"

# Its agent tree: cwd inside the decoy's worktree root, a boring argv, and the run id
# inherited through the environment — keys 1 and 3, both pointed somewhere the suite
# cannot resolve either.
( cd "$DECOY/worktrees/${NS}sibling-$CKD/tl-x" && export CHIEF_RUN_ID="$decoy_id" && exec -a sleep bash "$DECOY/keepalive.sh" "$$" ) &
decoy_agent=$!; DECOYS="$DECOYS $decoy_agent"; disown "$decoy_agent" 2>/dev/null || true
sleep 0.5
alive "$decoy_drv"   || fail "the decoy driver did not start"
alive "$decoy_agent" || fail "the decoy agent did not start"
note "decoy run up — driver pid $decoy_drv, agent pid $decoy_agent, run $decoy_id"
note "  its registry is $DECOY/runs, which no test below can read"

# ── 1. run the behavioural block over it ──────────────────────────────────────
TESTS=""
for t in ${CHIEF_BYSTANDER_TESTS:-smoke teardown reapscope reapenv}; do
  [ "$t" = "bystander" ] && continue          # never recurse into this file
  TESTS="$TESTS $t"
done
[ -n "$TESTS" ] && [ "$TESTS" != " " ] || fail "no tests to run (\$CHIEF_BYSTANDER_TESTS is empty) — a guard that runs nothing proves nothing"
total=0; for t in $TESTS; do total=$((total+1)); done
n=0
for t in $TESTS; do
  n=$((n+1))
  # A named test that does not exist would silently shrink the block, which is the
  # coverage loss this whole tasklist is about noticing.
  [ -f "$ROOT/test/$t.sh" ] || fail "test/$t.sh does not exist, but the block names it"
  note "[$n/$total] test/$t.sh"
  # Streamed, not captured: when this runs as .chief/verify.sh's behavioural block a
  # failure here BLOCKS a merge, and the full output is what makes that debuggable.
  bash "$ROOT/test/$t.sh" 2>&1 | sed "s/^/  $t| /"
  [ "${PIPESTATUS[0]}" = 0 ] || fail "test/$t.sh failed (its output is above)"
  alive "$decoy_drv" || fail "test/$t.sh KILLED the bystander driver (pid $decoy_drv, run $decoy_id).
This is the 2026-08-17 incident: a run in another repo, registered in a registry the
suite cannot read, destroyed by a sweep that read that absence as death.
It did not time out: the decoy lives exactly as long as this shell does ($(decoy_forensics "$decoy_drv"))."
  alive "$decoy_agent" || fail "test/$t.sh KILLED the bystander's agent process (pid $decoy_agent, run $decoy_id).
Its cwd and its inherited \$CHIEF_RUN_ID both belong to an install the suite cannot see.
It did not time out: the decoy lives exactly as long as this shell does ($(decoy_forensics "$decoy_agent"))."
done
note "the whole block ran; the bystander is still alive"

# ── 2. and a REAL orphan is still reaped ──────────────────────────────────────
# A sweep that spares everything is not a fix. This one is registered in a registry
# the sweep CAN read, and that registry says its driver is gone — the one configuration
# in which absence of life is actually evidence of death.
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"
RUNS="$PREFIX/runs"; REPOS="$PREFIX/repos"; WTS="$PREFIX/worktrees"
mkdir -p "$RUNS" "$WTS" "$WORK/repo-orphan"
CKO="$(printf '%s' "$WORK/repo-orphan" | cksum | awk '{print $1}')"
mkdir -p "$WTS/${NS}alpha-$CKO/tl-a"

( exec sleep 0 ) & dead=$!; wait "$dead" 2>/dev/null
alive "$dead" && fail "could not obtain a dead pid to stand in for a departed driver"
oid="${NS}alpha-$CKO-1700-$dead"
printf 'runid=%s\npid=%s\nrepo=%s\nnames=tl-a\nstatus=running\n' "$oid" "$dead" "$WORK/repo-orphan" > "$RUNS/$dead.run"
( cd "$WTS/${NS}alpha-$CKO/tl-a" && exec -a "bash /e/agent.sh --chief-run=$oid" sleep 3600 ) &
orphan=$!; DECOYS="$DECOYS $orphan"; disown "$orphan" 2>/dev/null || true
sleep 0.5
alive "$orphan" || fail "the orphan fixture did not start"

out="$(CHIEF_PREFIX="$PREFIX" CHIEF_RUNS="$RUNS" CHIEF_REPOS="$REPOS" "$CHIEF" reap --scope "$NS" 2>&1)" \
  || fail "chief reap exited non-zero: $out"
gone "$orphan" || fail "a REAL orphan (pid $orphan, run $oid — its run file says driver pid $dead, which is dead) survived the sweep.
A reaper that spares everything has traded one failure for another:
$out"
alive "$decoy_drv" || fail "the real sweep killed the bystander driver (pid $decoy_drv) — the scope covered it, the registry could not resolve it, and it was reaped anyway:
$out"
alive "$decoy_agent" || fail "the real sweep killed the bystander's agent (pid $decoy_agent):
$out"
grep -qE "pid $decoy_drv +unresolvable" <<<"$out" \
  || fail "the sweep neither reaped nor REPORTED the bystander (pid $decoy_drv) — an operator has to be able to tell a clean sweep from a blind one, and a silent decline reads as a clean host:
$out"
case "$out" in *TERM*|*KILL*) ;; *) fail "the reap did not say how it signalled the orphan:
$out" ;; esac
note "one sweep, both directions: orphan $orphan reaped, bystander $decoy_drv left alone"

# ── 3. leave nothing behind ───────────────────────────────────────────────────
# The other half of this bug: `/var/folders/**/tmp.*/bin/chief run sr-clean` was still
# running from an earlier suite when the incident was investigated. A test that leaks a
# `sleep 3600` is a test that will one day be the thing something else has to reap.
kill -9 $DECOYS 2>/dev/null || true
for p in $DECOYS; do wait "$p" 2>/dev/null; done
for p in $DECOYS; do gone "$p" || fail "the test leaked a process (pid $p) it started"; done
DECOYS=""

echo "BYSTANDER PASS — a run belonging to another install survived the behavioural block ($total test(s)) and a real sweep; a genuine orphan in a readable registry was still reaped; no fixture leaked"
