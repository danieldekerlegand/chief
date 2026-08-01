#!/usr/bin/env bash
# test/teardown.sh — the field failure, end to end: an interrupt must REAP before it
# FORGETS.
#
# WHAT WAS OBSERVED. A Ctrl-C'd run left a driver alive with PPID 1, still driving a
# `claude` agent for ~45 minutes, while `chief ps` reported no active runs at all.
# driver.sh trapped `EXIT` only, and that trap removed `driver.lock` and the
# `<pid>.run` file and nothing else — so the interrupt deleted the BOOKKEEPING while
# the worker tree kept spending account quota, unsupervised and invisible.
#
# THE THREE HALVES OF THAT ONE BUG, one part each — driven against a REAL run of the
# real engine (a scripted fake `claude` whose turn never ends), never a mock:
#
#   1. TEARDOWN ORDER. A genuine process-group SIGINT mid-iteration must reap the
#      whole tree — driver, `agent.sh` frame, the tool, and the tool's own child —
#      and release the records only afterwards. The ordering is asserted DIRECTLY, by
#      a sampler polling both facts throughout the teardown: the records may outlive
#      the processes, never the reverse. A refactor that restores the inversion fails
#      here instead of silently regressing.
#   2. THE REAPER'S MATCHING GAP. `SIGKILL` the driver (no teardown at all) and the
#      surviving tree carries NO worktree path in argv — the test proves that with
#      the old sweep's own pattern, `pgrep -f "$WT_ROOT"`, which matches none of it —
#      yet `chief reap` still identifies it, names the run it belonged to, and stops
#      it.
#   3. THE REGISTRY'S INVERSE. Delete a live run's records (the exact state the old
#      teardown produced) and `chief ps` must report an UNREGISTERED driver — repo,
#      tasklist in flight, pid to kill — rather than "no active runs"; and a second
#      `chief run` on that repo must refuse.
#
# Hermetic like test/{ratelimit,reapscope}.sh: chief installed from this checkout
# into a temp $CHIEF_PREFIX with its own $CHIEF_RUNS/$CHIEF_REPOS, a fake `claude` on
# PATH, no network. It signals only its own runs — the one real reap it performs is
# SCOPED to this test's worktree root and run-marker prefix, so it can never reach a
# developer's (or another test's) live chief work.
#
# NOTE: install.sh git-clones, so the COMMITTED tree is what runs. Commit engine
# changes before trusting a green result.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── SIGINT must be DELIVERABLE, or part 1 proves nothing ─────────────────────
# The same SIG_IGN rule this test exists to pin down applies to the TEST ITSELF.
# A background command started by a non-interactive shell has SIGINT set to
# SIG_IGN; that disposition survives fork AND exec, and bash cannot trap or reset
# a signal ignored on entry. So when this file runs from inside chief's own verify
# hook — which the merge gate does, several frames below a `run_worker … &`
# subshell — every process it starts inherits the ignore, INCLUDING the driver
# under test, whose `trap … INT` is then silently a no-op. Part 1's Ctrl-C would be
# delivered to nobody and the driver would "survive" it: a harness artefact
# indistinguishable from the very bug being tested (it is exactly how this test
# first failed under `.chief/verify.sh` while passing from a terminal).
# Only a process that resets the disposition itself can undo it, which bash will
# not do — so re-exec once through perl, which can, and carry on with SIG_DFL.
int_catchable() {   # can a child of this shell CATCH SIGINT, or was it ignored on entry?
  local rc=0
  bash -c 'trap "exit 7" INT; kill -INT $$; sleep 1; exit 0' >/dev/null 2>&1 || rc=$?
  [ "$rc" = 7 ]
}
INT_SIGNAL=INT; INT_TO_GROUP=1
if ! int_catchable; then
  if [ "${TD_INT_RESTORED:-0}" != 1 ] && command -v perl >/dev/null 2>&1; then
    export TD_INT_RESTORED=1
    exec perl -e '$SIG{INT} = "DEFAULT"; exec { $ARGV[0] } @ARGV or die "exec: $!\n"' \
      -- bash "$0" "$@"
  fi
  # No perl (or the re-exec did not take): say so loudly and stop the run with the
  # other signal it is stopped by — TERM, sent to the DRIVER, exactly as `kill <pid>`
  # or a service manager does. Not to the group: a group-wide TERM reaches the
  # worker subshells and `agent.sh` frames directly and tears the tree down from
  # underneath the driver, which is a different scenario from the Ctrl-C this part
  # pins (there, the group's SIGINT is ignored by the very processes that must die,
  # so the driver's own ordered reap is the only thing that ends them). Every
  # assertion below is unchanged; only the signal and its target differ, and the
  # report names which one it delivered.
  INT_SIGNAL=TERM; INT_TO_GROUP=0
  echo "teardown: NOTE — SIGINT is ignored on entry and could not be restored;" >&2
  echo "                part 1 stops the run with SIGTERM to the driver instead." >&2
fi

WORK="$(mktemp -d)"
PIDS=""            # every process this test starts, for a guaranteed cleanup
SAMPLER=""
LASTLOG=""

cleanup() {
  local p f
  if [ -n "$SAMPLER" ]; then kill -9 "$SAMPLER" 2>/dev/null || true; fi
  # Kill the trees first (a driver would otherwise re-spawn nothing, but its agent
  # frames outlive it), then the pids we started ourselves.
  for f in "$WORK"/sig/*.pid; do
    [ -e "$f" ] || continue
    p="$(cat "$f" 2>/dev/null || echo)"
    [ -n "$p" ] && kill -9 "$p" 2>/dev/null || true
  done
  for p in $PIDS; do kill -9 "$p" 2>/dev/null || true; done
  rm -rf "$WORK"
  return 0
}
trap 'rc=$?; cleanup; exit "$rc"' EXIT

fail() {
  echo "TEARDOWN FAIL: $*" >&2
  [ -n "$LASTLOG" ] && [ -f "$LASTLOG" ] && { echo "--- $LASTLOG (tail) ---" >&2; tail -40 "$LASTLOG" >&2; }
  exit 1
}
command -v jq  >/dev/null || fail "jq is required"
command -v git >/dev/null || fail "git is required"

export GIT_AUTHOR_NAME=td GIT_AUTHOR_EMAIL=td@test GIT_COMMITTER_NAME=td GIT_COMMITTER_EMAIL=td@test

# ── helpers ───────────────────────────────────────────────────────────────────
# A ZOMBIE is not alive: `kill -0` (and a bare `ps -p`) succeed on one, so every
# "did it die?" assertion below would misfire on a TERMed-but-unwaited process.
alive()  { ps -o pid=,stat= -p "${1:-0}" 2>/dev/null | awk '$2 !~ /^Z/ {f=1} END{exit !f}'; }
cmd_of() { ps -o command= -p "${1:-0}" 2>/dev/null | head -1; }

waitfile() {   # FILE SECONDS
  local f="$1" n="${2:-60}" i=0
  while [ "$i" -lt "$n" ]; do
    [ -e "$f" ] && return 0
    sleep 1; i=$(( i + 1 ))
  done
  return 1
}
waitdead() {   # PID SECONDS
  local p="$1" n="${2:-30}" i=0
  while [ "$i" -lt "$n" ]; do
    alive "$p" || return 0
    sleep 1; i=$(( i + 1 ))
  done
  return 1
}

# ── install chief from THIS checkout, into a private prefix ───────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"; SIG="$WORK/sig"
export CHIEF_PREFIX="$PREFIX" CHIEF_RUNS="$PREFIX/runs" CHIEF_REPOS="$PREFIX/repos"
mkdir -p "$SIG"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# ── the fake agent: a WEDGED turn that never ends ────────────────────────────
# Two properties, both load-bearing:
#   · nothing it leaves behind carries a worktree path in argv (its child is an
#     `exec -a sleep`) — exactly like `driver.sh`, `agent.sh` and
#     `claude --dangerously-skip-permissions --print`, which is what the old sweep
#     could not see (part 2);
#   · it IGNORES SIGTERM, like a tool wedged inside a long call. A polite reap alone
#     can therefore never end this turn: the teardown must escalate to KILL after its
#     bounded grace, and that grace is the window in which the ordering sampler gets
#     to watch the records sit there while the tree is provably still alive (part 1).
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null 2>/dev/null || true              # drain the prompt
PRD=".chief/state/prd.json"                     # cwd = the worktree (set by the driver)
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
d="${TD_SIG:?}"
( exec -a sleep sleep 900 ) >/dev/null 2>&1 &   # a grandchild that holds no pipe open
echo "$!" > "$d/$name.child.pid"
echo "$$" > "$d/$name.claude.pid"
: > "$d/$name.turn"                             # "I am mid-iteration" — the test waits on this
trap '' TERM                                    # wedged: only a hard kill ends this turn
while :; do sleep 1; done
FAKE
chmod +x "$WORK/fakebin/claude"

# ── a repo with three tasklists (one real run per part) ──────────────────────
REPO="$WORK/tdrepo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null || fail "chief init failed"
rm -f tasks/chief/example.json
for n in td-a td-b td-c; do
  cat > "tasks/chief/$n.json" <<JSON
{ "project":"$n","branchName":"chief/$n","description":"an agent turn that never ends",
  "iters":3,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[{"id":"US-1","title":"never finishes","description":"","acceptanceCriteria":[],"passes":false,"notes":""}] }
JSON
done
printf '#!/usr/bin/env bash\nexit 0\n' > .chief/verify.sh   # never reached: no turn ever completes
chmod +x .chief/verify.sh
git add -A && git commit -q -m "teardown: fixtures"

# ── starting a run the way a TERMINAL does ───────────────────────────────────
# `set -m` matters: without job control a background job's SIGINT is set to SIG_IGN
# and cannot be trapped or reset, so a plain `run & ; kill -INT` would prove nothing.
# With monitor mode the job also gets its OWN process group, which is what lets the
# test deliver a genuine Ctrl-C — kill -INT -<pgid>, to the whole group, exactly as a
# tty does. (That the driver's own background subshells then IGNORE that INT, and
# must be reaped with TERM/KILL, is the mechanism behind the observed orphan.)
GRACE=4            # CHIEF_TEARDOWN_GRACE: TERM → KILL, short enough for a test
RUN_SHIM=""; RUN_PGID=""; RUN_DRV=""; RUN_FILE=""; DRV_REPO=""; DRV_WT=""; DRV_MARKER=""
start_run() {   # $1 = tasklist name, $2 = log path
  local name="$1" log="$2" mypg f
  LASTLOG="$log"
  rm -f "$SIG/$name.turn" "$SIG/$name.claude.pid" "$SIG/$name.child.pid"
  rm -f "$CHIEF_RUNS"/*.run 2>/dev/null || true
  set -m
  TD_SIG="$SIG" PATH="$WORK/fakebin:$PATH" CHIEF_TEARDOWN_GRACE="$GRACE" \
    "$CHIEF" run "$name" >"$log" 2>&1 &
  RUN_SHIM=$!
  set +m
  PIDS="$PIDS $RUN_SHIM"
  disown "$RUN_SHIM" 2>/dev/null || true
  RUN_PGID="$(ps -o pgid= -p "$RUN_SHIM" 2>/dev/null | tr -d ' ')"
  mypg="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
  # A safety interlock, not a nicety: if job control did NOT give the run its own
  # group, `kill -INT -$RUN_PGID` would signal THIS test's group instead.
  [ -n "$RUN_PGID" ] && [ "$RUN_PGID" != "$mypg" ] \
    || fail "the run shares this shell's process group (pgid '$RUN_PGID' vs '$mypg') — refusing to signal"
  waitfile "$SIG/$name.turn" 120 || fail "$name never reached an agent turn"
  # The driver registers itself before the agent turn, so its run file exists by now.
  RUN_FILE=""
  for f in "$CHIEF_RUNS"/*.run; do [ -e "$f" ] && RUN_FILE="$f"; done
  [ -n "$RUN_FILE" ] || fail "the live run registered no <pid>.run file in $CHIEF_RUNS"
  RUN_DRV="$(sed -n 's/^pid=//p'    "$RUN_FILE" | head -1)"
  DRV_REPO="$(sed -n 's/^repo=//p'  "$RUN_FILE" | head -1)"
  DRV_WT="$(sed -n 's/^wt=//p'      "$RUN_FILE" | head -1)"
  DRV_MARKER="$(sed -n 's/^marker=//p' "$RUN_FILE" | head -1)"
  PIDS="$PIDS $RUN_DRV"
  alive "$RUN_DRV" || fail "the registered driver pid $RUN_DRV is not running"
  [ "$RUN_FILE" = "$CHIEF_RUNS/$RUN_DRV.run" ] || fail "run file $RUN_FILE does not name its driver pid $RUN_DRV"
  return 0
}

# The ENGINE layer of a live run: its agent.sh frame and the worker subshell (a fork
# of the driver, so it carries driver.sh's argv), plus the tool and the tool's own
# child by pid. Transient children (a `sleep` in the poll loop, `jq`, `tee`) are left
# out on purpose — they die of their own accord and would blur every assertion.
tree_engine_pids() {   # $1 = tasklist name -> pids to watch
  local name="$1" p out="" c
  chief_scan_descendants "$RUN_DRV"
  for p in $CHIEF_DESCENDANTS; do
    c="$(cmd_of "$p")"
    case "$c" in *agent.sh*|*driver.sh*) out="$out $p" ;; esac
  done
  out="$out $(cat "$SIG/$name.claude.pid" 2>/dev/null || echo) $(cat "$SIG/$name.child.pid" 2>/dev/null || echo)"
  printf '%s' "${out# }"
}
assert_engine_tree() {   # $1 = pids — the fixture really is reproducing the field case
  local p have_agent=0 have_worker=0
  for p in $1; do
    case "$(cmd_of "$p")" in
      *agent.sh*)  have_agent=1 ;;
      *driver.sh*) have_worker=1 ;;
    esac
  done
  [ "$have_agent"  = 1 ] || fail "no engine/agent.sh frame below the driver — the fixture is not mid-iteration"
  [ "$have_worker" = 1 ] || fail "no driver.sh worker subshell below the driver — the fixture is not mid-iteration"
  for p in $1; do alive "$p" || fail "watched pid $p ($(cmd_of "$p")) is already dead before the signal"; done
  return 0
}

# shellcheck source=engine/lib.sh
. "$PREFIX/src/engine/lib.sh"     # chief_scan_descendants — parentage, not argv

# ══ PART 1 — a Ctrl-C mid-iteration reaps the tree, THEN releases the records ══
echo "teardown: part 1 — interrupt mid-iteration (reap first, forget second)"
start_run td-a "$WORK/a.log"
drv="$RUN_DRV"; pg="$RUN_PGID"; runfile="$RUN_FILE"
lock="$DRV_REPO/.chief/state/driver.lock"
[ -e "$runfile" ] || fail "no run file for the live run"
[ -d "$lock" ]    || fail "no driver.lock for the live run"

watch="$(tree_engine_pids td-a)"
assert_engine_tree "$watch"

# THE ORDERING ASSERTION. Poll both facts through the whole teardown: if the records
# ever vanish while any engine process is still alive, that IS the field bug, and it
# is recorded as a violation. `samples` is the canary — a sampler watching the wrong
# paths would report neither, and an empty samples file fails the test.
: > "$WORK/violations"; : > "$WORK/samples"
(
  while :; do
    live=""
    for p in $watch; do if alive "$p"; then live="$p"; break; fi; done
    if [ -n "$live" ]; then
      if [ -e "$runfile" ] && [ -d "$lock" ]; then
        echo x >> "$WORK/samples"
      else
        printf 'run file %s / driver.lock %s while pid %s was STILL ALIVE: %s\n' \
          "$([ -e "$runfile" ] && echo present || echo GONE)" \
          "$([ -d "$lock" ] && echo present || echo GONE)" \
          "$live" "$(cmd_of "$live")" >> "$WORK/violations"
      fi
    fi
    sleep 0.05
  done
) & SAMPLER=$!
PIDS="$PIDS $SAMPLER"
disown "$SAMPLER" 2>/dev/null || true    # it is killed on purpose — no "Killed" job notice

if [ "$INT_TO_GROUP" = 1 ]; then
  kill -"$INT_SIGNAL" -"$pg" || fail "could not deliver SIG$INT_SIGNAL to the run's process group ($pg)"
  sent="SIG$INT_SIGNAL to group $pg"
else
  kill -"$INT_SIGNAL" "$drv" || fail "could not deliver SIG$INT_SIGNAL to the driver ($drv)"
  sent="SIG$INT_SIGNAL to driver $drv"
fi

waitdead "$drv" 90 || fail "the driver survived a Ctrl-C ($sent; pid $drv: $(cmd_of "$drv"))"
for p in $watch; do
  waitdead "$p" 30 || fail "a worker-tree process survived the interrupt — pid $p: $(cmd_of "$p")"
done
kill -9 "$SAMPLER" 2>/dev/null || true; SAMPLER=""

if [ -s "$WORK/violations" ]; then
  echo "--- ordering violations ---" >&2; head -5 "$WORK/violations" >&2
  fail "RECORDS WERE RELEASED WHILE THE TREE WAS STILL RUNNING — the exact inversion that produced the field orphan"
fi
# The canary: a sampler watching the wrong paths would report no violations either,
# so its silence only counts if it demonstrably watched a live tree WITH its records
# for the length of the escalation.
samples="$(wc -l < "$WORK/samples" | tr -d ' ')"
[ "${samples:-0}" -ge 5 ] \
  || fail "the ordering sampler only caught $samples sample(s) of 'tree alive + records present' — too few to prove the ordering held"
[ ! -e "$runfile" ] || fail "the run file survived a completed teardown ($runfile)"
[ ! -d "$lock" ]    || fail "driver.lock survived a completed teardown ($lock)"
grep -q "reaping the worker tree" "$WORK/a.log" \
  || fail "the teardown never reported reaping the worker tree (a silent teardown is indistinguishable from the bug)"
# Bounded escalation: the wedged tool ignores TERM, so the grace must expire into a
# hard kill rather than letting the interrupt hang forever.
grep -q "hard-killing survivors" "$WORK/a.log" \
  || fail "a TERM-ignoring agent was not hard-killed after the ${GRACE}s grace — the teardown is not bounded"
echo "   ok  $sent: tree reaped (agent.sh · tool · its child, TERM→KILL) then records released — $samples ordered samples, 0 violations"

# ══ PART 2 — the reaper's matching gap, on real processes ════════════════════
# No teardown at all this time: SIGKILL cannot be trapped, so the driver dies and
# leaves exactly the tree the startup sweep was supposed to find and never could.
echo "teardown: part 2 — a SIGKILLed driver leaves a tree that argv cannot find"
start_run td-b "$WORK/b.log"
drv="$RUN_DRV"; runfile="$RUN_FILE"
orphans="$(tree_engine_pids td-b)"
assert_engine_tree "$orphans"
cl="$(cat "$SIG/td-b.claude.pid")"; ch="$(cat "$SIG/td-b.child.pid")"

kill -9 "$drv"
waitdead "$drv" 20 || fail "the driver survived SIGKILL"
sleep 1
for p in $orphans; do alive "$p" || fail "pid $p died with its driver — the fixture must ORPHAN the tree, not end it"; done

# The gap itself: the old sweep was `pgrep -f "$WT_ROOT" | xargs kill -9`.
old="$(pgrep -u "$(id -u)" -f -- "$DRV_WT" 2>/dev/null || true)"
for p in $orphans; do
  case " $(printf '%s' "$old" | tr '\n' ' ') " in
    *" $p "*) fail "pgrep -f \$WT_ROOT matched pid $p ($(cmd_of "$p")) — the fixture no longer reproduces the matching gap" ;;
  esac
done

# And the registry cannot see it either: the run file names a DEAD pid, so it is
# pruned and `chief ps` says nothing is running while the agent still spends. That is
# why the reap must be reachable without starting a new run on this repo.
ps_out="$("$CHIEF" ps 2>&1 || true)"
case "$ps_out" in
  *"0 active run(s)"*|*"no active runs"*) ;;
  *) fail "expected the pruned registry to report no active runs beside the orphan tree, got:
$ps_out" ;;
esac
for p in $orphans; do
  case "$ps_out" in *"$p"*) fail "chief ps named orphan pid $p — the fixture is no longer invisible to the registry:
$ps_out" ;; esac
done

# `chief reap -n` — the on-demand path, from anywhere, signalling nothing.
reap_out="$("$CHIEF" reap -n 2>&1)" || fail "chief reap -n exited non-zero: $reap_out"
for p in $orphans; do
  case "$reap_out" in
    *"pid $p "*) ;;
    *) fail "chief reap did not find orphan pid $p ($(cmd_of "$p")):
$reap_out" ;;
  esac
done
case "$reap_out" in *"tdrepo · td-b"*) ;; *) fail "the reap report does not name the run its orphans belonged to:
$reap_out" ;; esac
alive "$cl" || fail "a DRY reap signalled the tool process"
alive "$ch" || fail "a DRY reap signalled the tool's child"

# The real reap, deliberately SCOPED to this test's own worktree root and run-marker
# prefix (the driver's startup-sweep call). A host-wide `chief reap` here would be
# correct code with an unacceptable blast radius for a test: this prefix's registry
# knows none of the developer's live runs, so they would not be in the protected set.
: > "$WORK/reap.log"
# shellcheck source=engine/reap.sh
. "$PREFIX/src/engine/reap.sh"
chief_reap_orphans "$DRV_WT" "$DRV_MARKER" "the SIGKILLed td-b run" 3 2>>"$WORK/reap.log" || true
for p in $orphans; do
  waitdead "$p" 15 || fail "orphan pid $p ($(cmd_of "$p")) survived the reap:
$(cat "$WORK/reap.log")"
done
grep -q "TERM" "$WORK/reap.log" || fail "the reap did not report how it signalled:
$(cat "$WORK/reap.log")"
rm -f "$runfile"                        # the dead run's stale record (monitor prunes it on sight)
echo "   ok  orphaned agent.sh + tool + child: invisible to the old argv sweep, found and stopped by the reaper"

# ══ PART 3 — the registry's inverse: alive, unregistered, and reported ═══════
echo "teardown: part 3 — a LIVE driver with no run file is reported, not hidden"
start_run td-c "$WORK/c.log"
# The stale-lock steal (part 2's SIGKILLed driver still owns driver.lock) must keep
# working exactly as it always has — the process-level check added beside it must not
# have replaced it.
grep -q "clearing a stale driver lock" "$WORK/c.log" \
  || fail "the stale driver.lock from the SIGKILLed run was not auto-cleared (the classic path regressed)"

drv="$RUN_DRV"; runfile="$RUN_FILE"
watch="$(tree_engine_pids td-c)"
assert_engine_tree "$watch"

# Reproduce the state the old teardown left behind: records gone, run still running.
rm -f "$runfile"
rm -rf "$DRV_REPO/.chief/state/driver.lock"
ps_out="$("$CHIEF" ps 2>&1 || true)"
case "$ps_out" in
  *"no active runs"*) fail "chief ps reported NO ACTIVE RUNS while pid $drv was mid-iteration — the field bug, verbatim:
$ps_out" ;;
esac
case "$ps_out" in *unregistered*) ;; *) fail "an unregistered live driver is not reported as such:
$ps_out" ;; esac
case "$ps_out" in *"$drv"*)       ;; *) fail "the report does not name the pid to kill:
$ps_out" ;; esac
case "$ps_out" in *"$DRV_REPO"*)  ;; *) fail "the report does not identify the driver's repo:
$ps_out" ;; esac
case "$ps_out" in *td-c*)         ;; *) fail "the report does not say what work is in flight:
$ps_out" ;; esac

# With the lock gone, only the PROCESS check stands between this run and a second
# driver racing it over the same branches, worktrees and merges.
if TD_SIG="$SIG" PATH="$WORK/fakebin:$PATH" "$CHIEF" run td-a >"$WORK/second.log" 2>&1; then
  fail "a SECOND driver started on a repo whose driver is alive but unregistered:
$(cat "$WORK/second.log")"
fi
LASTLOG="$WORK/second.log"
grep -q "already RUNNING" "$WORK/second.log" || fail "the refusal does not say a driver is already running"
grep -q "$drv" "$WORK/second.log"            || fail "the refusal does not name the pid to kill"
[ ! -d "$DRV_REPO/.chief/state/driver.lock" ] || fail "the refused run left a driver.lock behind"
LASTLOG="$WORK/c.log"

# Stopping it with TERM (what `kill <pid>` and a service manager send) must reap the
# same way SIGINT did — the records are already gone here, so this pins the TREE half.
kill -TERM "$drv"
waitdead "$drv" 90 || fail "the driver survived SIGTERM (pid $drv: $(cmd_of "$drv"))"
for p in $watch; do
  waitdead "$p" 30 || fail "a worker-tree process survived SIGTERM — pid $p: $(cmd_of "$p")"
done
grep -q "reaping the worker tree" "$WORK/c.log" || fail "SIGTERM did not reap the worker tree"

# Nothing from this test may be left running on the host.
ps_out="$("$CHIEF" ps 2>&1 || true)"
case "$ps_out" in *"no active runs"*) ;; *) fail "after every teardown, chief ps still reports a run:
$ps_out" ;; esac
chief_find_orphans "$DRV_WT" "$DRV_MARKER"
[ -z "$CHIEF_ORPHANS" ] || fail "this test left chief work running: $CHIEF_ORPHANS"
echo "   ok  unregistered driver named with its repo + in-flight tasklist; a second driver refused; SIGTERM reaped the tree"

echo "TEARDOWN PASS — Ctrl-C reaps the tree before releasing the records (never the reverse); a SIGKILLed run's boring-argv tree is still found and stopped; a live driver with no run file is reported, not hidden"
