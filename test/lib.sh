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
