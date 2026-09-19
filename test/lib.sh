#!/usr/bin/env bash
# test/lib.sh — WHAT EVERY TEST IN THIS SUITE OWES THE HOST IT RUNS ON.
#
# Sourced by every test/*.sh immediately after $ROOT is resolved, and it acts at
# SOURCE TIME rather than exposing a function a test has to remember to call. The
# defect this file exists for is a test reading a host input NOBODY THOUGHT ABOUT,
# and a rule you have to opt into is precisely the rule such a test does not opt
# into. Fifty-three of the ninety-six scripts here start a real `chief run`; two of
# them pinned the capacity inputs they depend on, and the other fifty-one had never
# been asked whether they depended on any.
#
# HERMETIC IN STATE IS NOT HERMETIC IN THE HOST — the third register of a sentence
# this suite has now written twice (test/bystander.sh: hermetic in state is not
# hermetic in PROCESSES; test/suspectlimit.sh: nor in ENV). Every fixture here
# points $CHIEF_RUNS / $CHIEF_REPOS / $CHIEF_PREFIX at its own temp tree, so nothing
# it runs writes to ~/.chief BY THAT ROUTE. But a fixture run's SCHEDULER reads one
# number that belongs to no run at all — the host's one-minute LOAD AVERAGE — and
# the caller hands it a fistful of absolute paths into a LIVE RUN'S state besides.
#
# FIVE HOST INPUTS, in the order they were found, each with its own section below:
# the load average · the worktree root · the litter an interrupted run leaves · the
# per-run pointers in the environment, which is the only one of the five that is a
# WRITE · and the SIGNAL DISPOSITION the caller hands down, which is the one that
# decides whether the litter rule can fire at all. The WRITE is first in the file,
# because it is the general rule the others are exceptions to; the disposition is
# last, because it is the only one that is opt-in and it says why.
#
# MEASURED 2026-09-18, on an operator host with three other chief runs live across
# 14 physical cores. In one verify, tests 1-33 of the 78-test behavioural block took
# twelve minutes; `test/suspectlimit.sh` then took SIX HOURS. Its fixture's own log
# says why:
#
#     ⏸ machine budget hold — machine load: load average 17.04 over 14 core(s)
#
# The fixture's `chief run -p 4` launched two of its four tasklists and held the
# other two until the load average of a machine it does not own, cannot influence
# and cannot finish the work of fell back under the ceiling. Nothing was broken:
# every part of that is the scheduler doing exactly what an operator wants it to do
# on a real host. It is simply not a question a fixture may be made to wait on —
# and the cost of it being asked is not a slow test, it is a SIX-HOUR verify whose
# eventual red (`test/suspectlimit.sh KILLED the bystander driver`) named a file
# that had already printed PASS.

# ── the run that CALLED us is not a fixture's to write into ───────────────────
# The fourth host input, and the only one that is a WRITE. The three below are
# things a fixture READS off the machine; this one is a set of absolute paths
# INTO A LIVE RUN'S STATE that the caller hands us in the environment, and every
# test here that drives engine/agent.sh directly picks them up.
#
# The suite's most common caller is `chief verify`, which runs inside an agent
# turn, and the driver exports its own per-run pointers into that turn (driver.sh
# run_worker + the agent invocation block). Thirty-six CHIEF_* variables arrive,
# and five of them are loaded:
#
#   CHIEF_LIVE_FILE        the run's liveliness record        — WRITTEN by agent.sh
#   CHIEF_EVENTS_FILE      the run's NDJSON event stream      — APPENDED by agent.sh
#   CHIEF_PRD_SNAPSHOT     the durable per-story record       — OVERWRITTEN by _prd_promote
#   CHIEF_VERIFY_CACHE_STATE  the run's verdict cache         — RECORDED into
#   CHIEF_ITER_HOOK        `driver.sh --integrate-base <the real branch> …` — EXECUTED
#
# MEASURED 2026-09-19, from inside this repo's own run of tasklist 128, by pointing
# each of those at a canary and running three unmodified tests (ratelimit ·
# provider-unavailable · provider). All three PASSED, and between them they:
#
#   · rewrote the live record to `phase=stalled · total=1 · stall=2/2 · noturn=3/3`
#     — a one-story fixture's shape, stamped over a four-story run that `chief ps`
#     was at that moment showing in an agent turn. That is the observation this
#     rule exists for, reproduced on demand;
#   · appended 55 event lines carrying the REAL run's runId, repo and tasklist
#     name, so `tasklist.provider-unavailable … HTTP 401 (authentication_error) —
#     permanent refusal (the credential is wrong, revoked …)` is in this repo's own
#     stream, attributed to work that never made the request. An event stream is a
#     PUBLISHED interface (chief-cloud, embedding hosts); a subscriber cannot tell
#     a fixture's 401 from its own;
#   · replaced .chief/state/snapshots/128-….json with `{"branchName":
#     "chief/provider","userStories":[{"id":"US-1","passes":false}]}`. For a
#     `repo:<sub>` tasklist that file is the ONLY record of which stories passed,
#     and the driver seeds the next run's worktree from it;
#   · RAN the iteration hook — a real `driver.sh --integrate-base` against the real
#     branch, worktree and repo. It was a no-op only because the branch happened to
#     be current with its base.
#
# It runs the other way too, and that half is louder: agent.sh SEEDS from
# $CHIEF_PRD_SNAPSHOT, so a fixture inherits the caller's PRD. Two tests sharing
# one inherited snapshot contaminated each other in the measurement above.
#
# A DENYLIST IS THE WRONG SHAPE HERE. This file exists for host inputs nobody
# thought about, and the driver's export set GROWS: of the 28 names it hands an agent
# turn today, eleven were added in the last five weeks (CHIEF_UNVERIFIED_FILE 08-20 ·
# five CHIEF_VERIFY_* 08-22 · CHIEF_PRD_SNAPSHOT and CHIEF_RESEARCH_FILE 08-26 ·
# CHIEF_MACHINE_BUDGET_LOG 09-04), and three of those eleven are among the five loaded
# ones above. So the rule is the other way round: EVERY CHIEF_* in the environment
# goes, and what stays is NAMED. A new driver export is covered on the day it is
# written, by nobody.
#
# WHAT STAYS, and why each one is addressed to the SUITE rather than to a run:
#   CHIEF_TEST_*          the suite's own namespace (CHIEF_TEST_PREFIX below,
#                         CHIEF_TEST_MODE, CHIEF_TEST_BASE_REPO, …). No driver
#                         exports one; every use is a person or a fixture
#                         addressing a test by name.
#   CHIEF_BYSTANDER_TESTS the list .chief/verify.sh hands test/bystander.sh. Scrub
#                         it and the merge gate's behavioural block runs EMPTY —
#                         silently, and reporting PASS.
#   CHIEF_VERIFY_TESTS    the same block's on/off switch.
#   CHIEF_MACHINE_* ·     the capacity knobs, which are NUMBERS. They are how the
#   CHIEF_LOAD_AVERAGE    five capacity tests and this file's own PART A/B inject a
#                         reading, and PART C asserts that an explicit request
#                         survives this file; keeping the whole family is what makes
#                         that promise true of all of it. With ONE exception, and it
#                         is the exception that proves the rule was written by hand:
#                         CHIEF_MACHINE_BUDGET_LOG is not a number, it is the live
#                         run's hold log under its state root, exported beside
#                         CHIEF_LIVE_FILE and appended to by the very same budget
#                         code. A family match is a guess about names; this one is
#                         named, because it was measured surviving.
#
# Not `env -i` and not a wrapper: this must hold for a test run straight from a
# shell, which is how every one of them is run while it is being written.
_chief_test_v=
for _chief_test_v in $(env 2>/dev/null | LC_ALL=C sed -n 's/^\(CHIEF_[A-Z0-9_]*\)=.*/\1/p'); do
  case "$_chief_test_v" in
    CHIEF_TEST_*|CHIEF_BYSTANDER_TESTS|CHIEF_VERIFY_TESTS) continue ;;
    CHIEF_MACHINE_BUDGET_LOG) ;;                 # a PATH wearing the capacity prefix
    CHIEF_MACHINE_*|CHIEF_LOAD_AVERAGE) continue ;;
  esac
  unset "$_chief_test_v"
done
unset _chief_test_v

# ── the host's load is not a fixture's input ──────────────────────────────────
# `off` and not a higher ceiling: a number is a bet about the host, and this suite
# runs on a two-core CI runner, a laptop and a loaded fourteen-core workstation
# alike, so any number is wrong somewhere. Turning the rule off is the honest
# statement — a fixture run has no foreign load to defer to, because every gate and
# every agent turn in its registry is one it started itself.
#
# It does NOT touch CHIEF_MACHINE_BUDGET or CHIEF_MACHINE_GATE_BUDGET. Those two
# count chief's OWN records, and a fixture's registry is its own temp tree, so they
# hold only against work the fixture itself launched and they clear when it
# finishes. The load line is the only one of the three that sees a machine.
#
# AN EXPLICIT REQUEST WINS, which is what makes this safe to apply to all 96: the
# tests whose SUBJECT is capacity admission (load-admission · concurrency-monitor ·
# machine-budget · gate-budget · concurrency) pin their own inputs, and so may an
# operator from the shell. `${VAR:-}` fills the silence and nothing else. Note the
# engine captures the request at SOURCE time (engine/concurrency.sh's
# CHIEF_MACHINE_LOAD_LIMIT_REQUESTED), so a test that pins it must do so before it
# sources that file — which is why this line runs at $ROOT, above every test's own
# setup rather than beside it.
export CHIEF_MACHINE_LOAD_LIMIT="${CHIEF_MACHINE_LOAD_LIMIT:-off}"

# ── the host's worktree tree is not a fixture's to enumerate ──────────────────
# The second host input, found the same day and by the same fixture. Every test
# here points $CHIEF_RUNS and $CHIEF_REPOS at its own temp tree — those two are
# spelled out in 70-odd files — but the WORKTREE root is resolved from a THIRD
# knob nobody thought to pin, and its default is the operator's real home:
#
#     CHIEF_WORKTREE_ROOT  ->  $CHIEF_PREFIX/worktrees  ->  $HOME/.chief/worktrees
#
# Twenty-seven of the ninety-six scripts set neither end of that chain, so their
# fixture runs resolved the last arm. The visible half is the STARTUP SWEEP, which
# walks $(chief_worktree_root)/* before the scheduler starts and reports a verdict
# per entry: a hermetic fixture was enumerating the operator's live worktrees and
# printing `LEFT ALONE, a live run is behind it` about work in other repositories.
# It left them alone — the liveness predicate is correct, and test/reapscope.sh
# asserts it in full — but "the sweep that destroys a worktree decided correctly"
# is not a property a fixture should be staking anything on, and the 2026-08-17
# incident is what it looks like when that decision goes the other way.
#
# The invisible half is simply litter: `git worktree add` creates
# $HOME/.chief/worktrees/<basename>-<cksum of the repo path>, the repo is a fresh
# mktemp per test run, so the cksum is new EVERY TIME and nothing ever reclaims it.
# MEASURED 2026-09-19 on the incident host: 136 directories, of which the great
# majority are empty husks named after fixture repos (`cli-*` from
# test/provider-conformance.sh, `proj-*` from test/status-deps.sh, `repo-*` from
# some sixty others), the newest of them minutes old.
#
# IT IS THE PREFIX THAT IS PINNED HERE, NOT THE WORKTREE ROOT, and the difference
# matters. $CHIEF_WORKTREE_ROOT is the LAST word on where worktrees go, so exporting
# it at source time would overrule every test that pins the tree itself a few lines
# later — and a dozen do: test/pause.sh, test/plan-review.sh and test/overlap-zones.sh
# find the driver's worktree at `$CHIEF_PREFIX/worktrees/*/<name>`, and the four reap
# fixtures (reapscope · reapenv · reap-escaped · bystander) BUILD the tree the sweep
# under test is supposed to walk. Pinning the PREFIX instead fills only the silence:
# a test that names either knob still wins outright, and a test that names neither
# gets a root of its own instead of the operator's.
#
# It is not created here. engine/paths.sh resolves paths and never makes them
# (driver.sh mkdirs the tree it needs, with a writability diagnosis attached), so a
# test that starts no driver leaves nothing behind at all — and one that does leaves
# a single directory, in $TMPDIR, keyed by its own pid.
# One base, used by both the export and the sweep: $TMPDIR carries a trailing slash
# on macOS and a glob built from the raw value would not match the exported path.
_chief_test_tmp="${TMPDIR:-/tmp}"; _chief_test_tmp="${_chief_test_tmp%/}"

# Reclaimed by the NEXT test to source this file rather than by an EXIT trap of our
# own, because that one trap is the thing this suite cannot rely on: all 96 scripts
# install their own `trap … EXIT` a line or two below, which replaces anything set
# here. (The signal section at the foot of this file DOES delete it, because there
# we know we are leaving and the disposition is ours; this sweep is the belt to that
# brace, and the only cover for the two exits nobody gets a word in — a normal one,
# where the script's own EXIT trap has already displaced ours, and a SIGKILL.)
# Four guards, each for a reason: the name must carry a decimal pid, the entry must
# be a real directory and not a symlink pointed somewhere else, it must be OURS —
# $TMPDIR is shared on Linux — and the pid must be gone. A pid that has been reused
# by an unrelated live process reads as alive and the directory is left; leaving one
# husk is the failure to prefer.
_chief_test_sweep_stale() {
  local d pid
  for d in "$_chief_test_tmp"/chief-test-host.*; do
    [ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || continue
    pid="${d##*.}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    # $$ can only be a husk left by a dead predecessor that held this pid before us.
    if [ "$pid" = "$$" ] || ! kill -0 "$pid" 2>/dev/null; then rm -rf -- "$d"; fi
  done
}
_chief_test_sweep_stale

# AND HERE THE SILENCE IS NOT SILENT, which is why this one line does not wear the
# `${CHIEF_PREFIX:-}` shape every other default in this file wears. The suite's most
# common caller is chief itself: `chief verify` runs it from inside a worktree, and
# the driver exports its own resolved state into every agent turn and every hook —
#
#     CHIEF_PREFIX=/Users/<op>/.chief   CHIEF_RUNS=…/.chief/runs   CHIEF_REPOS=…/.chief/repos
#
# — so a fixture asking "did anyone request a prefix?" is answered YES, with the
# host's, by the very run whose worktrees it then enumerates. An ambient value that
# IS the defect cannot also be the channel for overriding the fix, so the override
# gets a name of its own. $CHIEF_TEST_PREFIX is a request a person types; $CHIEF_PREFIX
# is something that happens to a test, and it is overruled. (A test that wants its own
# prefix does what seventy of them already do and assigns one AFTER this file is
# sourced — later assignment wins outright, and nothing here touches that.)
_chief_test_own_root="$_chief_test_tmp/chief-test-host.$$"
export CHIEF_PREFIX="${CHIEF_TEST_PREFIX:-$_chief_test_own_root}"
# Only the one we minted is ours to delete on the way out; a prefix a person asked
# for is theirs, and the sweep above already refuses anything not pid-keyed.
[ "$CHIEF_PREFIX" = "$_chief_test_own_root" ] || _chief_test_own_root=""

# ── a signal is an exit, and an exit is what all 96 traps already handle ──────────
# An interrupted verify is the normal end of a long one — Ctrl-C, a closed terminal,
# a cancelled CI job — and ninety-two of the ninety-six scripts here clean up with
# `trap … EXIT` and nothing else.
#
# THE OBVIOUS PREMISE IS FALSE, AND MEASURING IT MOVED THE TARGET. "An untrapped
# signal kills the shell before its EXIT trap can run" is true of some shells and
# not of bash: on bash 3.2.57, the system bash this suite runs under on macOS, an
# untrapped INT, TERM or HUP runs the EXIT trap on its way out — pid-addressed and
# group-addressed alike, and whether the shell is in a builtin or blocked in a
# foreground child (test/signal-cleanup.sh reproduces all of it). So `$WORK` was
# never what an interrupted run stranded. Two other things were:
#
#   THE PREFIX ROOT ABOVE. No test's EXIT trap has heard of it — it is this file's,
#   reclaimed by the NEXT test to source this file, and on a signal there is no next
#   test. That one is structural: it holds on every bash, because nothing else in
#   the process knows the directory exists.
#
#   THE STATUS. A SIGINT addressed to the pid of a script blocked in a foreground
#   child, with nothing trapped, exits the shell ZERO on this bash — so all.sh,
#   bystander.sh and .chief/verify.sh all read a killed test as a PASS, which is the
#   worse of the two failures by some distance.
#
# THE REPAIR IS NOT NINETY-SIX MORE TRAP LINES. Three signals × ninety-six files,
# each with its own cleanup body to keep in step, is the shape this file exists to
# refuse — and US-1 already measured what a suite-wide insert costs: the quality
# ratchet's duplication window is six normalized lines and the copy-pasted preamble
# is five, so one more shared line tips eleven file-pairs over it at once.
#
# Instead, one rule, stated once: A SIGNAL BECOMES AN EXIT. bash runs the EXIT trap
# when a handler calls `exit`, and `$?` at the EXIT trap's entry is the status that
# `exit` was given — so `trap 'rm -rf "$WORK"' EXIT` and
# `trap 'rc=$?; cleanup; exit "$rc"' EXIT` both keep doing precisely what they
# already do, the temp tree goes, and the shell reports 143 to whoever asked.
# Nothing in the ninety-six changes, which is also why this cannot fall out of step
# with them: there is no second copy of the cleanup here, only the arrival.
#
# It survives their traps for the same reason US-1's export survives their setup:
# `trap … EXIT` replaces the handler for EXIT and for nothing else.
#
# `trap - "$sig"` FIRST, so the disposition is back to the default before any of the
# cleanup runs: a second Ctrl-C has to be able to end a cleanup that is itself stuck
# (test/teardown.sh's fixtures wedge on purpose), and an operator pressing it twice
# means it.
#
# THE BOUND, stated rather than discovered later: bash defers a trap handler while a
# FOREGROUND child is running, so a signal addressed to a test's pid ALONE is acted
# on when the current command returns, not at once. It costs nothing in the case
# that matters — a Ctrl-C and a `kill` on the process group reach the child too, and
# the child is what is slow — and the alternative (this file signalling processes
# it did not start) is the 2026-08-17 incident in miniature.
_chief_test_on_signal() {
  trap - "$1"
  [ -n "$_chief_test_own_root" ] && rm -rf -- "$_chief_test_own_root"
  exit "$2"          # → the script's own EXIT trap, whatever it happens to be
}
trap '_chief_test_on_signal INT 130'  INT
trap '_chief_test_on_signal TERM 143' TERM
trap '_chief_test_on_signal HUP 129'  HUP

# ── and a signal you cannot RECEIVE is a fifth host input ─────────────────────
# The three traps above are worth exactly what the signal reaching this process is
# worth, and for SIGINT that is a property of the CALLER, not of this file. A
# background command started by a non-interactive shell has SIGINT set to SIG_IGN;
# the disposition survives fork AND exec, and bash can neither trap nor reset a
# signal ignored on entry. chief's own driver says so at engine/driver.sh's
# STOP_SIGNALS block, because it is why its teardown is stopped with TERM — and the
# suite's most common caller is several frames below one of those `run_worker … &`
# subshells, so every test in the merge gate's behavioural block runs with SIGINT
# ignored while the same file from a terminal runs with it deliverable.
#
# MEASURED 2026-09-19: test/signal-cleanup.sh PART A passed standalone and failed
# inside `chief verify` with `shape 1 signalled with SIGINT exited 0, not 130` —
# the victim never received the signal, so the trap it was asserting on could not
# fire. That reads as a defect in the three lines above and is nothing of the kind:
# it is the 2026-09-18 false-accusation shape one register down, a red naming a
# file that is behaving correctly.
#
# Only a process that resets the disposition ITSELF can undo it, which bash will
# not do, so the re-exec goes through perl. It is OPT-IN — the two tests whose
# SUBJECT is signals call it — and deliberately not applied to all 96 at source
# time: `exec` replaces the process, and the reap fixtures assert on argv and on
# process identity. Same pid across both execs, so $CHIEF_PREFIX above is unchanged
# and the husk clause keyed on `$$` in the sweep is the one that covers the rest.
#
# chief_test_restore_int "$0" "$@" — returns 0 when SIGINT is deliverable to this
# process and everything it starts (re-execing once to make it so), 1 when it could
# not be restored, so the caller can say which case it is staging rather than
# asserting on a signal nobody received.
chief_test_restore_int() {
  local rc=0
  bash -c 'trap "exit 7" INT; kill -INT $$; sleep 1; exit 0' >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 7 ]; then return 0; fi
  if [ "${CHIEF_TEST_INT_RESTORED:-0}" = 1 ]; then return 1; fi
  command -v perl >/dev/null 2>&1 || return 1
  export CHIEF_TEST_INT_RESTORED=1
  exec perl -e '$SIG{INT} = "DEFAULT"; exec { $ARGV[0] } @ARGV or die "exec: $!\n"' -- bash "$@"
}
