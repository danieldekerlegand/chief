#!/usr/bin/env bash
# test/reap-escaped.sh — THE ORPHAN THAT LEFT THE WORKTREE, on the platform this
# fleet actually runs on.
#
# engine/reap.sh has three keys, and its own notes say key 3 — the inherited
# $CHIEF_RUN_ID, read back out of a candidate's ENVIRONMENT — "exists for the process
# that escapes BOTH of the others: chdir'd out of the worktree AND wearing an argv
# that says nothing". On macOS that key is DARK: `ps -E` is accepted under SIP and
# prints no environment, so chief_env_key_mode reports nothing and the key degrades
# to zero. The shape key 3 exists for therefore has no key at all here — and
# test/reapenv.sh SKIPS its end-to-end half on exactly this platform, which is how
# the gap stayed invisible.
#
# THE FIELD RECORD, 2026-09-11, macOS 26.5. Four runs were cut off around 00:58
# (four runs across two downstream repositories); every driver pid was dead and every state
# file still said `running`. A manual sweep found `UnrealEditor-Cmd -unattended` on a
# temporary `engine-version-probe-<uuid>.uproject`, spawned by a downstream tasklist's
# run: PPID 1, process-group leader dead, cwd in `/Users/Shared/Epic Games/UE_5.8/…`,
# argv carrying no `--chief-run=` marker, 78 minutes old, 99% CPU rising to 199%, and
# it IGNORED SIGTERM. That is the residual shape, in the field, burning two cores.
#
# So this file builds that process and asserts the one thing an operator needs:
# `chief reap` NAMES it and STOPS it. The fixture is faithful to the record in the
# four ways that matter — it leaves the worktree, it execs a boring argv, it ignores
# TERM, and it is re-parented to PID 1 when its parent is SIGKILLed (the run's driver
# dying, with its run file left behind still saying `running`).
#
# IT IS NOT SKIPPED ANYWHERE. A skip is how this shape stayed invisible, and the
# platform is not a reason to stop asserting — it is the thing being asserted about.
# Both platform answers are PRINTED rather than inferred: the three keys are asked
# individually, by name, before the sweep is run, so the log says which key saw the
# process on this host and which did not. Where the environment is readable (Linux)
# key 3 is expected to carry it; where it is not (macOS) nothing in the engine can,
# until a key that does not read environments is added.
#
# NOT YET IN THE THREE GATE LISTS (.chief/verify.sh's CHIEF_BYSTANDER_TESTS,
# test/all.sh's BASH_SUITE, .github/workflows/ci.yml). It lands RED on purpose — it
# is the observation that the hole is real, made before the key that closes it exists
# — and a red file in the merge gate would block the very branch that fixes it. The
# story that adds the key adds this file to all three in the same commit; until then
# it is run by hand (`bash test/reap-escaped.sh`) and its failure is the deliverable.
#
# Hermetic in STATE and in PROCESSES, on test/reapenv.sh's terms: a temp
# $CHIEF_PREFIX/$CHIEF_RUNS/$CHIEF_REPOS bounds what is READ, and every sweep is
# SCOPED to `$RE`, a run-id prefix only these fixtures wear, because process
# discovery is host-wide however private the registry is. The only process this test
# signals is one it started itself.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
PIDS=""
cleanup() { local p; for p in $PIDS; do kill -9 "$p" 2>/dev/null || true; done; rm -rf "$WORK"; }
trap cleanup EXIT
fail() { echo "REAPESC FAIL: $*" >&2; exit 1; }
note() { echo "reapesc: $*"; }

# ── install chief from this checkout, into a private prefix ───────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
export CHIEF_PREFIX="$PREFIX" CHIEF_RUNS="$PREFIX/runs" CHIEF_REPOS="$PREFIX/repos"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"
WTS="$PREFIX/worktrees"

# THE FIXTURE NAMESPACE. A run id is `<repo>-<cksum>-<epoch>-<pid>`, and no repo on
# this host is named `reapesc-*`, so a sweep scoped to $RE cannot reach a real run
# however the platform enumerates processes. The cksum is also the key the worktree
# dir is named with, which is read (3) of chief_run_id_resolvable — without a
# worktree dir wearing it, this install could not account for the run and would
# correctly refuse to judge it.
RE="reapesc-"
CK=4242
IDBASE="${RE}escrepo-$CK-1700000000"
WT="$WTS/${RE}escrepo-$CK/tl-x"
SIG="$WORK/sig"
mkdir -p "$WT" "$CHIEF_RUNS" "$WORK/elsewhere" "$SIG"
: > "$CHIEF_REPOS"
cd "$WORK"

# On macOS /var is a symlink to /private/var, so a cwd read back out of the process
# table is the RESOLVED path while $WTS is not. engine/reap.sh canonicalises the
# scope dir before it compares (chief_reap_canon); a test that compares the literal
# strings instead would report "it escaped the worktree" for every process in it.
alive()  { ps -o pid=,stat= -p "$1" 2>/dev/null | awk '$2 !~ /^Z/ {f=1} END{exit !f}'; }
listed() { grep -q "pid $1 " <<<"$2"; }
ppid_of() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }
canon() { ( cd "${1:-}" 2>/dev/null && pwd -P ) 2>/dev/null; }
cwd_of() {   # the same two reads engine/reap.sh uses, in the same order
  if [ -e "/proc/$1/cwd" ]; then readlink "/proc/$1/cwd" 2>/dev/null; return 0; fi
  lsof -p "$1" -a -d cwd -F n 2>/dev/null | sed -n 's/^n//p' | head -1
}
waitfile() {  # $1 = path  $2 = seconds
  local n=0
  while [ ! -e "$1" ]; do
    n=$(( n + 1 )); [ "$n" -gt "${2:-60}" ] && return 1
    sleep 1
  done
  return 0
}

# ── the run's process tree, with one descendant that walks out of it ──────────
#
# A stand-in for driver.sh + agent.sh, not the real engine: what is under test is
# the SWEEP, and a real run would take a minute to reach an agent turn to produce
# the same three facts (a registered run, a tree, a descendant that leaves it).
# `$$` survives `exec`, so the frame that ends up wearing the marker is the very pid
# the run id names — the same idiom test/reapenv.sh stages its live driver with.
cat > "$WORK/fakedriver.sh" <<'EOS'
#!/usr/bin/env bash
set -u
SIG="$1"; WT="$2"; ELSEWHERE="$3"; IDBASE="$4"; ARGV0="$5"
export CHIEF_RUN_ID="$IDBASE-$$"          # exported to the whole tree, as the driver does
cd "$WT" || exit 1                        # where the driver puts the agent
printf '%s' "$$"             > "$SIG/driver.pid"
printf '%s' "$CHIEF_RUN_ID"  > "$SIG/runid"
# A sibling that STAYS — an ordinary tool step, still cwd'd in the worktree. It is
# this test's positive control: key 1 finds it, so "the escapee was not listed" can
# never be read as "the sweep found nothing / never ran".
( exec -a sleep sleep 900 ) </dev/null >/dev/null 2>&1 &
printf '%s' "$!" > "$SIG/stay.pid"
# THE ESCAPEE. Leaves the worktree, takes an argv that says nothing about chief, and
# ignores TERM — the field shape, all three at once. It keeps only what it inherited.
( cd "$ELSEWHERE" || exit 1
  exec -a "$ARGV0" bash -c 'trap "" TERM; while :; do sleep 1; done'
) </dev/null >/dev/null 2>&1 &
printf '%s' "$!" > "$SIG/escape.pid"
: > "$SIG/up"
while :; do sleep 1; done
EOS

# Faithful to the record: a game engine on a temp project file, nothing chief-shaped.
ARGV0="UnrealEditor-Cmd -unattended /var/tmp/engine-version-probe-0f3c.uproject"
bash -c 'exec -a "bash /engine/driver.sh --chief-run='"$IDBASE"'-$$" bash "$0" "$@"' \
  "$WORK/fakedriver.sh" "$SIG" "$WT" "$WORK/elsewhere" "$IDBASE" "$ARGV0" &
shim=$!
PIDS="$PIDS $shim"
disown "$shim" 2>/dev/null || true
waitfile "$SIG/up" 30 || fail "the fixture run never started (no $SIG/up)"
DRV="$(cat "$SIG/driver.pid")"
ESC="$(cat "$SIG/escape.pid")"
STAY="$(cat "$SIG/stay.pid")"
RID="$(cat "$SIG/runid")"
PIDS="$PIDS $DRV $ESC $STAY"
[ "$DRV" = "$shim" ] || fail "the exec'd driver frame ($DRV) is not the pid the run id names ($shim)"
[ "$RID" = "$IDBASE-$DRV" ] || fail "run id '$RID' does not end in the driver pid $DRV"
alive "$DRV" || fail "the fixture driver (pid $DRV) is not running"
alive "$ESC" || fail "the escapee (pid $ESC) is not running"
alive "$STAY" || fail "the control process that stayed in the worktree (pid $STAY) is not running"

# Registered, exactly as the four cut-off runs were — and the run file is left behind
# saying `running` after the driver dies, which is the field record's other half.
printf 'pid=%s\nrunid=%s\nrepo=%s\nnames=tl-x\nstate=running\n' \
  "$DRV" "$RID" "$WORK/escrepo" > "$CHIEF_RUNS/$DRV.run"

# ── the fixture IS the shape, before anything is swept ────────────────────────
WTS_P="$(canon "$WTS")"
[ -n "$WTS_P" ] || fail "could not canonicalise the worktree root $WTS"
esc_cwd="$(cwd_of "$ESC")"
case "$esc_cwd" in
  "$WTS"/*|"$WTS_P"/*) fail "the escapee's cwd ($esc_cwd) is still inside the worktree root — it has not escaped key 1" ;;
  '') fail "could not read the escapee's cwd at all, so this test cannot claim it left the worktree" ;;
esac
esc_argv="$(ps -o command= -p "$ESC" 2>/dev/null | head -1)"
case "$esc_argv" in
  *--chief-run=*) fail "the escapee's argv carries the spawn marker, so it has not escaped key 2: $esc_argv" ;;
esac
note "the escapee (pid $ESC) is cwd'd at $esc_cwd, argv '$(printf '%s' "$esc_argv" | cut -c1-60)…'"
stay_cwd="$(cwd_of "$STAY")"
case "$stay_cwd" in
  "$WTS"/*|"$WTS_P"/*) ;;
  *) fail "the control process (pid $STAY) is cwd'd at '$stay_cwd', not inside the worktree root — it cannot stand in for key 1" ;;
esac

# shellcheck source=engine/reap.sh
. "$PREFIX/src/engine/reap.sh"
ENVMODE="$(chief_env_key_mode)"
note "this platform's environment read: ${ENVMODE:-NONE (key 3 is inert here)}"

# WHILE THE RUN IS LIVE the escapee is still connected — a descendant of a
# registered driver, and protected as one. That window is the only moment anything
# can record the relationship; after the driver dies there is no PPID edge back to
# chief from anywhere, which is why the descendant walk cannot reach it below.
chief_protected_reset
chief_protected_pids
case " $CHIEF_PROTECTED " in
  *" $ESC "*) ;;
  *) fail "the escapee (pid $ESC) is not protected while its registered run is LIVE — the fixture is not a descendant of the run at all" ;;
esac
note "while the run is live, pid $ESC is protected as a descendant of driver $DRV"

# ── the run dies the way the four cut-off runs did ────────────────────────────
kill -9 "$DRV" 2>/dev/null || true
n=0
while [ "$(ppid_of "$ESC")" != "1" ]; do
  n=$(( n + 1 )); [ "$n" -gt 20 ] && fail "the escapee (pid $ESC) was never re-parented to PID 1 (ppid is now '$(ppid_of "$ESC")')"
  sleep 1
done
alive "$ESC" || fail "the escapee did not survive its parent — the fixture proves nothing"
alive "$STAY" || fail "the control process (pid $STAY) did not survive its parent either"
[ -e "$CHIEF_RUNS/$DRV.run" ] || fail "the stale run file vanished; the field record is a run file that still says running"
note "driver $DRV is gone; pid $ESC survives on PPID 1 with the run file still saying running"

# ── WHICH KEY CAN SEE IT? Asked one at a time, and printed either way ─────────
k1="$(chief_pids_cwd_under "$WTS" | awk -v p="$ESC" '$1==p {print "yes"}')"
k2="$(chief_pids_tagged "$CHIEF_RUN_MARKER$RE" | awk -v p="$ESC" '$1==p {print "yes"}')"
k3="$(chief_pids_env_marked "$RE" | awk -v p="$ESC" '$1==p {print "yes"}')"
note "key 1 (cwd inside a chief worktree): ${k1:-no}"
note "key 2 (--chief-run= on argv):        ${k2:-no}"
note "key 3 (inherited \$CHIEF_RUN_ID):     ${k3:-no}   [env read: ${ENVMODE:-none}]"
[ -z "$k1" ] || fail "key 1 matched the escapee, so this fixture is not the residual shape"
[ -z "$k2" ] || fail "key 2 matched the escapee, so this fixture is not the residual shape"
c1="$(chief_pids_cwd_under "$WTS" | awk -v p="$STAY" '$1==p {print "yes"}')"
note "key 1 on the control that STAYED in the worktree: ${c1:-no}"
[ -n "$c1" ] || fail "key 1 cannot see the control process (pid $STAY) either, so nothing below would distinguish a missing key from a broken fixture"

# ── THE ASSERTION: reap names it, and stops it ────────────────────────────────
out="$("$CHIEF" reap --grace 1 --no-disk --scope "$RE" 2>&1)" || true
listed "$STAY" "$out" || fail "the sweep did not even name the control process (pid $STAY), whose cwd is
  inside the worktree root — so this run proves nothing about the escapee:
$out"
if ! listed "$ESC" "$out"; then
  fail "chief reap did not NAME the escaped orphan (pid $ESC, $ARGV0).
  It left the worktree, it wears an argv with no marker, and the run it belonged to
  is dead with its run file still saying running. On this host the environment read
  is '${ENVMODE:-none}', so key 3 reported: ${k3:-no}. Keys 1 and 2 cannot see this
  shape by construction. A key that does not read process environments is needed.
  The sweep said:
$out"
fi
if alive "$ESC"; then
  fail "chief reap named pid $ESC but it is still running — it ignores SIGTERM, as the
  field process did, so the escalation to KILL has to reach it:
$out"
fi
case "$out" in
  *"ledger"*|*"[cwd]"*|*"[argv]"*|*"[env]"*|*"[tree]"*) ;;
  *) fail "the orphan was reaped with no key named as the evidence for it:
$out" ;;
esac

note "reap found and stopped the escaped orphan; the sweep said:"
printf '%s\n' "$out" | sed 's/^/  | /'
echo "REAPESC PASS — an orphan that left the worktree, took a boring argv and ignored TERM is still found and stopped (env read: ${ENVMODE:-none})"
