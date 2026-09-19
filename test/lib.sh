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
# already points $CHIEF_RUNS / $CHIEF_REPOS / $CHIEF_PREFIX at its own temp tree, so
# nothing it runs writes to ~/.chief. But a fixture run's SCHEDULER reads one number
# that belongs to no run at all: the host's one-minute LOAD AVERAGE.
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
