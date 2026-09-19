#!/usr/bin/env bash
# test/signal-cleanup.sh — AN INTERRUPTED TEST LEAVES NOTHING BEHIND.
#
# Ninety-two of the ninety-six scripts in this suite clean up with `trap … EXIT` and
# nothing else, and an interrupted verify is the normal end of a long one. test/lib.sh
# now traps INT, TERM and HUP once, at source time, for all of them: each handler
# restores the default disposition and calls `exit 128+n`, which runs the script's OWN
# EXIT trap — whatever that happens to be — and still reports the signal's status.
#
# WHAT THAT IS WORTH HAD TO BE MEASURED RATHER THAN ASSUMED, and the measurement moved
# the target. The obvious premise — "an untrapped signal kills the shell before its EXIT
# trap can run" — is FALSE for bash: on bash 3.2.57 (the system bash this suite runs
# under on macOS) an untrapped INT, TERM or HUP runs the EXIT trap on its way out, for
# a signal sent to the pid and to the process group alike. The `$WORK` tree was never
# the thing being stranded. Two things were, and both are asserted below:
#
#   THE PREFIX ROOT. $CHIEF_PREFIX is minted by test/lib.sh (chief-test-host.$$, the
#   worktree root a fixture run would otherwise take from the operator's $HOME), and no
#   test's EXIT trap has ever heard of it. It is reclaimed on a normal exit by the next
#   test to source the file; on a signal there IS no next test, and it survived — which
#   is the whole of PART B, and it is structural rather than a property of some bash.
#
#   THE STATUS. Measured on the same host: a SIGINT delivered to the pid of a script
#   blocked in a foreground child, with no trap installed, exits the shell ZERO — a
#   runner (all.sh, bystander.sh, .chief/verify.sh) reads a killed test as a PASS. With
#   the handler it is 130, every time, which is PART A's second assertion.
#
# PARTS:
#   A   three signals × the four EXIT-trap shapes that actually occur in this suite
#       (`rm -rf "$WORK"` · `rc=$?; rm -rf "$WORK"; exit "$rc"` · a `cleanup` function ·
#       `rc=$?; cleanup; exit "$rc"`), delivered TO THE GROUP, which is what a Ctrl-C
#       and a cancelled job are. Each victim gets a $TMPDIR of its own, so "nothing
#       survived" is COUNTED and not estimated on a shared /tmp, and each one makes the
#       prefix root a driver-running test would make, so both trees are in the count.
#   B   the mutation control: the same victims against a copy of lib.sh with those three
#       trap lines deleted — the pre-128 reading — must leave the prefix root behind.
#   C   the BOUND, pinned rather than discovered later: bash defers a trap handler while
#       a foreground child runs, so a signal addressed to a test's PID ALONE is acted on
#       when that child returns. It costs nothing in the case that matters (a group
#       signal reaches the child too, it dies, the handler runs at once) and the
#       alternative — this file signalling processes it did not start — is the
#       2026-08-17 incident in miniature. Asserted as a FLOOR on the elapsed time, which
#       needs no calibration against the host.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; . "$ROOT/test/lib.sh"

# ── SIGINT must be DELIVERABLE, or the INT cases assert on nothing ───────────
# A FIFTH host input, found by this very file going red inside `chief verify` while
# passing from a terminal: `A: shape 1 signalled with SIGINT exited 0, not 130`. A
# background command started by a non-interactive shell has SIGINT set to SIG_IGN,
# the disposition survives fork AND exec, and the merge gate runs this suite several
# frames below a `run_worker … &` subshell — so the victim below inherited an ignored
# SIGINT, never received the signal, slept out its nap and exited 0. Nothing in
# test/lib.sh was wrong; the harness could not stage the case, and said so by naming
# the file it was testing. chief_test_restore_int re-execs once through perl to get
# the default disposition back (test/teardown.sh needs the identical rule and calls
# the same function); when it cannot, the INT cases are the only thing skipped, and
# they are skipped OUT LOUD.
INT_OK=1
chief_test_restore_int "$0" "$@" || INT_OK=0

WORK="$(mktemp -d)"
VICTIMS=""
cleanup() { local p; for p in $VICTIMS; do kill -9 "$p" 2>/dev/null || true; done; rm -rf "$WORK"; }
trap 'rc=$?; cleanup; exit "$rc"' EXIT
fail() { echo "SIGNAL-CLEANUP FAIL: $*" >&2; exit 1; }
note() { echo "signal-cleanup: $*"; }

# What is left in a victim's private $TMPDIR, one entry per line (empty = clean).
residue() { ls -A "$1" 2>/dev/null; }

# ── the victim: this suite's preamble, one of its trap shapes, and a wait ─────
# It makes the prefix root as well as the mktemp tree, because a test that starts a
# driver has one and it is the larger of the two.
victim_src() {   # $1 = lib to source, $2 = the EXIT trap verbatim, $3 = seconds to wait
  cat <<EOS
#!/usr/bin/env bash
set -uo pipefail
ROOT="$ROOT"; . "$1"
WORK="\$(mktemp -d)"
$2
mkdir -p "\$CHIEF_PREFIX/worktrees"
printf '%s\n' "\$WORK" > "\$SIG/work"
_int=0; bash -c 'trap "exit 7" INT; kill -INT \$\$; sleep 1; exit 0' >/dev/null 2>&1 || _int=\$?
printf '%s\n' "\$_int" > "\$SIG/intrc"
: > "\$SIG/ready"
sleep $3
EOS
}

SHAPE1='trap '"'"'rm -rf "$WORK"'"'"' EXIT'
SHAPE2='trap '"'"'rc=$?; rm -rf "$WORK"; exit "$rc"'"'"' EXIT'
SHAPE3='cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT'
SHAPE4='cleanup() { rm -rf "$WORK"; }
trap '"'"'rc=$?; cleanup; exit "$rc"'"'"' EXIT'

V_RC=0; V_TMP=""; V_ELAPSED=0
run_victim() {   # $1 = label, $2 = lib, $3 = trap text, $4 = signal, $5 = pid|group, $6 = sleep
  local label="$1" lib="$2" tl="$3" sig="$4" del="$5" nap="$6" d="$WORK/$1" p pg mypg t0
  rm -rf "$d"; mkdir -p "$d/tmp" "$d/sig"
  victim_src "$lib" "$tl" "$nap" > "$d/victim.sh"
  # Its own process group AND a default SIGINT disposition, both from `set -m`: a
  # background job in a non-interactive shell has SIGINT set to SIG_IGN, which survives
  # fork and exec and cannot be trapped (test/teardown.sh's note), so without this the
  # INT cases would be asserting on a signal the victim never receives.
  set -m
  SIG="$d/sig" TMPDIR="$d/tmp" bash "$d/victim.sh" >"$d/out" 2>&1 &
  p=$!
  set +m
  VICTIMS="$VICTIMS $p"
  local i=0
  while [ ! -f "$d/sig/ready" ] && [ "$i" -lt 120 ]; do sleep 0.25; i=$((i+1)); done
  [ -f "$d/sig/ready" ] || { cat "$d/out" >&2; fail "$label: the victim never started"; }
  # The victim's own disposition, measured in the victim: "it exited 0" must never be
  # allowed to read as "the trap did not fire" when the truth is that no signal was
  # ever delivered. PART B's lib has no INT trap, but the DISPOSITION is not the trap
  # — this probe is about whether the process can receive one at all, so it holds for
  # both libs.
  if [ "$sig" = INT ] && [ "$(cat "$d/sig/intrc" 2>/dev/null)" != 7 ]; then
    fail "$label: the victim inherited an ignored SIGINT and cannot receive one — the harness could not stage this case (nothing is being claimed about test/lib.sh)"
  fi
  t0="$(date +%s)"
  if [ "$del" = group ]; then
    pg="$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')"
    mypg="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
    [ -n "$pg" ] && [ "$pg" != "$mypg" ] \
      || fail "$label: the victim shares this shell's process group (pgid '$pg' vs '$mypg') — refusing to signal"
    kill -"$sig" -"$pg" 2>/dev/null || fail "$label: could not deliver SIG$sig to process group $pg"
  else
    kill -"$sig" "$p" 2>/dev/null || fail "$label: could not deliver SIG$sig to pid $p"
  fi
  wait "$p"; V_RC=$?
  V_ELAPSED=$(( $(date +%s) - t0 ))
  V_TMP="$d/tmp"
}

# ── A. three signals × four trap shapes, delivered to the group ──────────────
for sig in INT:130 TERM:143 HUP:129; do
  name="${sig%%:*}"; want="${sig##*:}"
  if [ "$name" = INT ] && [ "$INT_OK" != 1 ]; then
    note "SIGINT is ignored on entry and perl could not restore it — SKIPPING the four INT cases (TERM and HUP cover all four shapes below)"
    continue
  fi
  n=0
  for shape in "$SHAPE1" "$SHAPE2" "$SHAPE3" "$SHAPE4"; do
    n=$((n+1))
    run_victim "a-$name-$n" "$ROOT/test/lib.sh" "$shape" "$name" group 120
    [ "$V_RC" = "$want" ] \
      || fail "A: shape $n signalled with SIG$name exited $V_RC, not $want — the status a runner reads is not the signal's"
    left="$(residue "$V_TMP")"
    [ -z "$left" ] \
      || fail "A: shape $n signalled with SIG$name left this behind in its own \$TMPDIR:
$left"
  done
  note "SIG$name: all four EXIT-trap shapes left an empty \$TMPDIR and reported $want"
done

# ── B. the mutation control ──────────────────────────────────────────────────
# Delete exactly the three lines this story added and nothing else; the victim, the
# shape, the delivery and the counting are all PART A's.
sed "/^trap '_chief_test_on_signal /d" "$ROOT/test/lib.sh" > "$WORK/lib-nosig.sh"
removed="$(grep -c "^trap '_chief_test_on_signal " "$ROOT/test/lib.sh")"
[ "$removed" = 3 ] \
  || fail "B: expected 3 signal traps in test/lib.sh, found $removed — the control is not removing what PART A relies on"
! grep -q "^trap '_chief_test_on_signal " "$WORK/lib-nosig.sh" \
  || fail "B: the mutated copy still installs a signal trap"
for name in INT TERM HUP; do
  [ "$name" = INT ] && [ "$INT_OK" != 1 ] && continue
  run_victim "b-$name" "$WORK/lib-nosig.sh" "$SHAPE1" "$name" group 120
  left="$(residue "$V_TMP")"
  # The mktemp tree IS cleaned here, by bash's own courtesy — it runs the EXIT trap on
  # its way out of a fatal signal. The prefix root is the one nothing else knows about.
  case "$left" in
    *chief-test-host.*) ;;
    *) fail "B: with the signal traps removed, SIG$name still left no prefix root behind — PART A proves nothing about them. Residue: [$left]" ;;
  esac
done
note "control: with those three lines gone the prefix root survives all three signals"

# ── C. the deferral bound, stated as a floor ─────────────────────────────────
# A signal addressed to the pid alone is handled when the current foreground command
# returns. The victim naps 3s; the assertion is that the handler still ran and still
# cleaned up, and that it did so no sooner than the child it was waiting on.
run_victim "c-term" "$ROOT/test/lib.sh" "$SHAPE1" TERM pid 3
[ "$V_RC" = 143 ] || fail "C: a pid-addressed SIGTERM exited $V_RC, not 143"
[ "$V_ELAPSED" -ge 2 ] \
  || fail "C: the handler ran in ${V_ELAPSED}s, before the 3s foreground child it should have been waiting on — the documented bound is wrong, and the comment in test/lib.sh with it"
left="$(residue "$V_TMP")"
[ -z "$left" ] || fail "C: a pid-addressed SIGTERM left this behind:
$left"
note "pid-addressed: handled after the foreground child returned (${V_ELAPSED}s), \$TMPDIR still empty, still 143"

# ── D. the cleanup itself must not be able to abort ──────────────────────────
# The repair above only helps a cleanup that RUNS TO THE END. Sixteen files here clean
# up under `set -euo pipefail`, and in that mode an AND-list whose left side fails
# returns non-zero — which inside a trap handler ENDS THE SHELL, before the `rm -rf`
# on the next line. `[ -n "$HOLDER_PID" ] && kill "$HOLDER_PID"` with the holder not
# yet started is exactly that, and it is how test/admission-refusals.sh came to be the
# one tree that survived the interrupted `test/all.sh` this story measured.
#
# So the shape is scanned for, in the two places a cleanup is written: the inline
# `trap … EXIT` body and a top-level `cleanup()`. The rule is narrow and mechanical —
# in an errexit cleanup, a conditional ends `|| true` — and what it cannot see (a
# cleanup that calls a helper, as test/host-isolation.sh's does) it says nothing
# about rather than guessing.
scan_fragile() {   # $1 = directory of test scripts → one "file: line" per finding
  local f
  for f in "$1"/*.sh; do
    grep -q '^set -e' "$f" 2>/dev/null || continue
    awk '
      /^[ \t]*#/                            { next }          # prose, not code
      /^cleanup\(\) *\{/                    { inb = 1 }
      (inb || /trap .*EXIT/) && /\[[^]]*\] *&&/ && !/\|\| *(true|:|return)/ \
                                            { printf "%s: %s\n", FILENAME, $0 }
      /^\}/                                 { inb = 0 }
      /^cleanup\(\) *\{.*\}[ \t]*$/         { inb = 0 }       # a one-line cleanup
    ' "$f"
  done
}
found="$(scan_fragile "$ROOT/test")"
[ -z "$found" ] || fail "D: a cleanup that runs under \`set -e\` can abort before its rm -rf — end the conditional with \`|| true\`:
$found"
# And the scanner is not vacuous: the pre-fix line, in a file shaped like the suite's.
mkdir -p "$WORK/scan"
{ printf '#!/usr/bin/env bash\nset -euo pipefail\nWORK="$(mktemp -d)"\nHOLDER_PID=""\n'
  printf 'trap %s EXIT\n' "'"'rc=$?; [ -n "$HOLDER_PID" ] && kill "$HOLDER_PID" 2>/dev/null; rm -rf "$WORK"; exit "$rc"'"'"
} > "$WORK/scan/fragile.sh"
[ -n "$(scan_fragile "$WORK/scan")" ] \
  || fail "D: the scanner does not flag the very line this story removed — it is checking nothing"
note "no errexit cleanup in test/ can abort before its rm -rf (and the scanner still flags the line that could)"

echo "SIGNAL-CLEANUP PASS — an interrupted test cleans up after itself, and it is lib.sh's three lines that make it"
