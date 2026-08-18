#!/usr/bin/env bash
#
# run-parallel.sh — run independent Chief tasklists CONCURRENTLY, each in its own
# git worktree, with a dependency- and conflict-aware scheduler and a SERIALIZED
# rebase → verify → merge phase. The sibling of run-all.sh (sequential).
#
# Runs on STOCK macOS bash 3.2 (no associative arrays, no `wait -n`) — same as
# run-all.sh / chief.sh. State is tracked on the filesystem; finished workers are
# reaped by a poll loop. Nothing to install.
#
# WHY worktrees: run-all.sh refuses two drivers on one working tree because they
# share .git/HEAD and corrupt each other. A worktree gives each tasklist its own
# HEAD/index/working tree + its own gitignored scripts/chief/{prd.json,progress.txt},
# so N agent loops run in true isolation. The only shared resource is `main`, which
# is touched only in the serialized merge phase (one tasklist integrates at a time).
#
# SAFETY MODEL (see also the scheduler fields on each tasklist JSON):
#   • dependsOn[]  — hard "must be merged first" edges. A tasklist waits until all
#                    its deps are recorded merged in tasks/chief/completed/.
#   • touches[]    — conflict domains. Two tasklists sharing a domain are never
#                    co-scheduled (an OPTIMIZATION to avoid wasted rebase churn).
#   • warmup[]     — optional shell commands run in the worktree BEFORE the agent
#                    loop, to provision gitignored build deps (a fresh worktree has
#                    none: no node_modules/.venv). Isolated per worktree.
#   • The real safety floor is the merge phase: before merging, each branch is
#     REBASED onto the latest main and RE-VERIFIED (verify_branch). File overlap
#     surfaces as a rebase conflict; semantic staleness surfaces as a verify
#     failure. Interference degrades to a caught failure — never a silent merge.
#     Over-tagging touches only costs parallelism; under-tagging only costs a
#     wasted rebase. There is no correctness knob to get wrong.
#   • No AI auto-conflict-resolution: a rebase/merge conflict STOPS that tasklist
#     and leaves its branch for a human.
#
# SCHEDULER STATES (per tasklist, in $STATE/<name>.state):
#   pending · running · done · failed · blocked · rate-limited · paused ·
#   awaiting-review · awaiting-approval
# FOUR of these are NON-TERMINAL, and none of them is a failure:
#   · 'rate-limited' — the worker's agent loop exited 2, i.e. it stopped on a Claude
#     usage/session limit (see engine/agent.sh's exit-code contract). Nothing is
#     wrong with that branch — it is merely blocked until the limit window resets —
#     so it is NOT recorded as 'failed'. The scheduler WAITS OUT the window and
#     re-dispatches it itself (see USAGE-LIMIT SELF-HEAL below) — no operator
#     action, branch reused.
#   · 'paused' — an OPERATOR pause was armed (see OPERATOR PAUSE below) and the
#     worker drained at a safe checkpoint. Its branch and worktree are kept, so the
#     next run RESUMEs it from its committed passes state. Chief never lifts this
#     one by itself: it stays 'paused' until a human runs `chief resume`.
#   · 'awaiting-review' — the worker's agent loop exited 5: plan review is enabled
#     for that tasklist, it has a well-formed plan, and no human has approved it
#     (docs/plan-review.md). Deliberately the SAME park as an operator pause, in a
#     distinct state so `chief ps` can say which of the two is holding the work:
#     branch, worktree, plan and annotations all kept, the scheduler carries on with
#     the siblings, and the next run resumes reading the verdict off disk instead of
#     re-asking. Chief never manufactures the missing approval — an unreachable
#     reviewer is not a yes.
#   · 'awaiting-approval' — the MERGE POLICY LAYER held the branch: it changed a
#     domain declared an OVERLAP ZONE with policy `review` (engine/zones.sh,
#     docs/reference/overlap-zones.md), or a story blew the per-story DIFF-SIZE
#     BUDGET under CHIEF_DIFF_BUDGET=block (engine/budget.sh,
#     docs/reference/diff-budget.md). One state, one approval, for both.
#     The merge floor ALREADY RAN: it is rebased onto the latest base and its verify
#     came back green, and it is held anyway, because the risk the layer exists for —
#     two parallel branches whose designs disagree — is invisible to every automated
#     gate. `chief approve <name>` records the human YES; the next run reads it off
#     disk and merges. This is the one park where the branch's worktree is already
#     gone (the merge phase removes it before checking out): the BRANCH is what is
#     kept, rebased and green, and a resumed run rebuilds the rest.
# dep_broken() treats NONE of them as broken: the dependents of a tasklist that is
# only waiting stay 'pending' (schedulable) instead of cascading to 'blocked'.
#
# OPERATOR PAUSE (the human lever, deliberately NOT the usage-limit one):
#   • $STATE/.paused is armed by `chief pause` and cleared by `chief resume`. While
#     it exists the scheduler launches NOTHING and running workers drain at their
#     safe checkpoints — the point is to stop spending AGENT TURNS in this repo so
#     the account's quota can go elsewhere.
#   • It is strictly orthogonal to the usage-limit window ($STATE/.limit-pause-until):
#     that is an account-wide wall Chief waits out and re-dispatches after, ALL BY
#     ITSELF; this is a human decision Chief must never revoke on its own. Arming or
#     clearing one never reads or writes the other, and with both armed the run stays
#     held until BOTH are lifted. Launch-time init clears the limit window (a stale
#     ETA from a previous run is meaningless) but NEVER the operator pause — a repo
#     paused before `chief run` is still paused when the run starts.
#   • DRAIN, don't kill. The pause is checked at exactly ONE point inside a running
#     worker: agent.sh's ITERATION BOUNDARY (it exits $AGENT_RC_PAUSED there). So the
#     turn in flight always finishes and its commits land, and there is deliberately
#     NO checkpoint between commit and merge, mid-rebase or mid-verify — a pause can
#     never leave a work repo mid-rebase or a branch committed-but-unrecorded. A
#     drained tasklist parks in state 'paused' with its branch AND worktree kept.
#   • It withholds AGENT TURNS, not the completion of finished work: a tasklist whose
#     agent loop is already done (a resumed all-pass branch, or a drain that found
#     every story passing) still runs verify+merge under the pause. Parking those
#     would strand finished branches and block their dependents for an unbounded time.
#   • Because it is unbounded in time, an operator pause ENDS the run once everything
#     has drained (releasing driver.lock) rather than idling on it.
#
# USAGE-LIMIT SELF-HEAL (the whole-run recovery):
#   • The worker persists the reset ETA agent.sh parsed out of the real limit
#     message into $STATE/<name>.retry-at (epoch). One parser, so worker and
#     scheduler agree on when the window reopens.
#   • Because ONE account means ONE limit window, a limit arms a GLOBAL pause
#     ($STATE/.limit-pause-until = the latest known reset). While it is armed the
#     scheduler launches NOTHING: with PARALLEL>1 that is the difference between
#     backing off once and throwing every remaining worker into the same wall.
#     Workers already running are left alone — agent.sh has its own sleep/resume.
#   • When the window passes, every paused tasklist is re-armed 'pending' and
#     re-dispatched. run_worker's normal RESUME path reuses the existing
#     chief/<name> branch and its committed passes state (nothing is rebuilt).
#   • Bounded: RATE_LIMIT_REDISPATCH_MAX re-dispatches per tasklist per run. When
#     the cap is spent the run ENDS, reporting the pause distinctly from a failure
#     — it never hangs silently waiting for capacity that isn't coming.
#
# Usage:
#   PARALLEL=3 ./scripts/chief/run-parallel.sh                 # all pending, up to 3 at once
#   PARALLEL=2 ./scripts/chief/run-parallel.sh a b c           # only these, still dep/conflict-aware
#   DRY_RUN=1 ./scripts/chief/run-parallel.sh                  # print the schedule waves; spawn nothing
#   AUTO_MERGE_MAIN=0 ./scripts/chief/run-parallel.sh          # complete branches but don't merge
#
# Env vars (shared with run-all.sh unless noted):
#   PARALLEL=N            max tasklists running at once (default 2). NEW.
#   CHIEF_PROVIDER=claude|devin|opencode|amp  AI provider (default claude). amp is a first-class
#                         dispatch case of its own, NOT an alias — it just has no model selector.
#   CHIEF_MODEL=<model>                  optional provider-specific model override
#   AUTO_MERGE_MAIN=1     verify+merge each completed branch (default 1)
#   NO_VERIFY=0           skip the pre-merge verification gate (not advised)
#   STRICT_VERIFY=0       fail on any verify failure incl. ones pre-existing on main
#   DRY_RUN=0             print the schedule and exit without git/agents. Honoured when set
#                         in the environment of `chief run` too, not only via -n/--dry-run.
#   POLL_SECONDS=5        how often the scheduler checks for finished workers. NEW.
#   FORCE=0               skip the STARTUP precondition (on-base + clean tree). That gate
#                         protects the AGENT's fork point, not the merge — the merge phase
#                         parks the work repo's uncommitted work itself. See the gate below.
#   RESET=0               force a fresh branch from base, discarding a prior run's
#                         partial progress (default: RESUME an existing branch). NEW.
#   RATE_LIMIT_REDISPATCH_MAX=3        re-dispatches per tasklist after a usage-limit
#                         pause, per run. 0 disables the self-heal (old behavior:
#                         the run ends with the tasklist paused). NEW.
#   RATE_LIMIT_REDISPATCH_WAIT=3600    fallback backoff when the worker recorded no
#                         reset ETA (agent.sh normally does). NEW.
#   RATE_LIMIT_REDISPATCH_MAX_WAIT=21600  ceiling on any single wait (6h), so a
#                         bogus far-future reset can't park the run for days. NEW.
#   (the per-worker knobs — RATE_LIMIT_RETRY/WAIT/MAX_WAITS/PATTERN — are agent.sh's)
#   WT_ROOT=<dir>         where THIS repo's worktrees live. Default is OUTSIDE the
#                         repo ($CHIEF_WORKTREE_ROOT/<repo>-<hash>) so a `--print`
#                         agent can't resolve its root to the outer tree.
#   CHIEF_PREFIX=<dir>    host-wide state root (runs/repos/worktrees). Default
#                         ~/.chief, with container fallbacks — engine/paths.sh.
#   CHIEF_WORKTREE_ROOT=<dir>  the worktree tree ALL repos share. Default
#                         $CHIEF_PREFIX/worktrees; set it to keep worktrees off a
#                         container's ephemeral prefix.
#
set -uo pipefail

ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Host-wide state paths (prefix / runs / repos / worktree root). Sourced HERE, well
# before the first path is spelled, because the old inline `${CHIEF_PREFIX:-$HOME/.chief}`
# aborted the driver outright under `set -u` when $HOME was unset — the shape a
# container hands you. engine/paths.sh has the resolution order and the fallbacks.
# shellcheck source=engine/paths.sh
. "$ENGINE/paths.sh"
: "${CHIEF_PROJECT:?CHIEF_PROJECT must be set — run this via 'chief run', not directly}"
REPO="$CHIEF_PROJECT"
# ---------------------------------------------------------------------------
# RUN MARKER — the durable identity of this run's process tree.
#
# Nothing in `bash driver.sh` / `bash agent.sh` / `claude --print` says which repo
# (or which run) it belongs to, which is why the old orphan sweep — pgrep for the
# worktree path — could only ever find their transient children. So the driver
# stamps itself: a run id encoding the repo, and an argv marker carrying it.
#
#   CHIEF_RUN_ID = <repo>-<cksum>-<epoch>-<pid>
#     · <repo>-<cksum> is exactly the key $WT_ROOT is built from, so a sweep can
#       scope to ONE repo's runs by prefix,
#     · the trailing <pid> makes the id self-identifying: an id inherited through
#       the environment by a NESTED chief run (the test suite does this) does not
#       end in that shell's pid, so the nested driver mints its own instead of
#       impersonating its parent.
#
# The exec is how the marker reaches argv where `ps`/`pgrep` can see it — exec
# REPLACES this shell, so the pid, the environment and the redirections all carry
# over unchanged; only the command line grows. It happens before any state is
# touched, and CHIEF_RUN_ID (now ending in our pid) makes it strictly once.
case "${CHIEF_RUN_ID:-}" in
  *-"$$") ;;
  *)
    # `--integrate-base` (the internal subcommand below) is a SHORT helper re-entry
    # from a running worker's agent hook, not a run of its own: it must never mint a
    # run id or stamp argv, or a reap sweep would momentarily see a phantom run for
    # this repo. It inherits the real driver's marker and exits long before the run
    # registry is written.
    if [ "${1:-}" = "--integrate-base" ]; then
      CHIEF_RUN_ID="${CHIEF_RUN_ID:-integrate-0-0-$$}"
    else
      CHIEF_RUN_ID="$(printf '%s' "$(basename "$REPO")" | tr -cs 'A-Za-z0-9' '_')-$(printf '%s' "$REPO" | cksum | cut -d' ' -f1)-$(date +%s)-$$"
      export CHIEF_RUN_ID
      exec bash "$ENGINE/driver.sh" "--chief-run=$CHIEF_RUN_ID" "$@"
    fi
    ;;
esac
case "${1:-}" in --chief-run=*) shift ;; esac   # ours; not a tasklist name
# The prefix that matches every run marker for THIS repo and no other's.
CHIEF_RUN_MARKER_REPO="--chief-run=${CHIEF_RUN_ID%-*-*}-"
TASKS_REL="${CHIEF_TASKS_DIR:-tasks/chief}"
SRC="$REPO/$TASKS_REL"
TASKS_DIR="$SRC"
COMPLETED="$SRC/completed"
STATE_REL="${CHIEF_STATE_DIR:-.chief/state}"
STATE_ROOT="$REPO/$STATE_REL"
SNAP="$STATE_ROOT/snapshots"
SNAP_REL="$STATE_REL/snapshots"            # repo-relative — short enough for a .status line
# The RESEARCH PHASE's durable store (engine/research.sh): one document per tasklist,
# OUTSIDE the worktree on purpose — the worktree is deleted and rebuilt on every run,
# so a document kept only there would be regenerated by each resumed run instead of
# produced once. It is also the human-edit surface: a person can open
# .chief/state/research/<name>.md between iterations, correct the map, and the next
# story consumes the correction (correcting research is cheaper than correcting the
# code it would otherwise produce).
RESEARCH_DIR="$STATE_ROOT/research"
RESEARCH_REL="$STATE_REL/research"         # repo-relative — for .status lines and messages
# Worktrees live OUTSIDE the repo (under the host-wide chief prefix), keyed per
# project. A worktree nested *inside* $REPO makes a `--print` agent resolve its
# project root to the OUTER working tree and read/edit THAT instead of the
# worktree — so it produces no committed work and the branch merges empty. Keeping
# the worktree tree out of $REPO is what makes agent isolation actually hold.
# WT_ROOT names THIS repo's worktree dir; $CHIEF_WORKTREE_ROOT relocates the tree
# ALL repos share (chief_worktree_root). The per-repo key is <basename>-<cksum of the
# absolute path>: inside a container the repo's bind-mount path differs from the
# host's, so the same repo keys differently there — which is what keeps a container
# run's worktrees from colliding with the host's.
WT_ROOT="${WT_ROOT:-$(chief_worktree_root)/$(basename "$REPO")-$(printf '%s' "$REPO" | cksum | cut -d' ' -f1)}"
STATE="$STATE_ROOT/parallel"
MERGE_LOCK="$STATE_ROOT/merge.lock"
WT_LOCK="$STATE_ROOT/wt.lock"              # serialize concurrent `git worktree add`
IDX_LOCK="$STATE_ROOT/index.lock"           # serialize PARENT-repo index mutations
DRIVER_LOCK="$STATE_ROOT/driver.lock"      # one driver per repo
# GLOBAL run registry — one small file per active driver, keyed by pid, in a
# host-wide dir (default ~/.chief/runs). It lets `chief ps`/`chief monitor` see
# every live run across ALL repos, not just this one. Written after the driver
# lock is held; removed on exit. `chief monitor` prunes files whose pid is dead.
CHIEF_RUNS="$(chief_runs_dir)"
RUN_FILE="$CHIEF_RUNS/$$.run"
# Known-repos registry (bin/chief exports it; defaulted here so the driver also
# works standalone). Resolves the "<repo>:" half of a qualified cross-repo dep.
CHIEF_REPOS="$(chief_repos_dir)"
BASE_BRANCH="${CHIEF_BASE_BRANCH:-main}"
VERIFY_HOOK=""; [ -n "${CHIEF_VERIFY:-}" ] && VERIFY_HOOK="$REPO/$CHIEF_VERIFY"
mkdir -p "$COMPLETED" "$SNAP" "$WT_ROOT" "$STATE" "$RESEARCH_DIR"
rm -f "$STATE/sweep.bytes" 2>/dev/null || true   # this run's disk-reclaim tally (sweep_worktree)

PROVIDER="${CHIEF_PROVIDER:-${CHIEF_TOOL:-${TOOL:-claude}}}"
MODEL="${CHIEF_MODEL:-}"
TOOL="$PROVIDER"                         # compatibility name used in status output
PARALLEL="${PARALLEL:-1}"                   # default sequential; -p N for concurrency
AUTO_MERGE_MAIN="${CHIEF_AUTO_MERGE:-${AUTO_MERGE_MAIN:-1}}"
NO_VERIFY="${NO_VERIFY:-0}"
# MERGE QUEUE (engine/mergequeue.sh) — OPT-IN, and off unless someone asked for it.
# 1 = the serialized floor, which is what every merge phase below still is by default;
# N > 1 batches up to N merge-ready branches, stacks them and verifies the tip ONCE.
# `chief run --merge-batch[=N]` sets it for one run; CHIEF_MERGE_BATCH in .chief/config
# sets it per repo. MERGE_BATCH_WAIT bounds how long a batch leader waits for peers.
MERGE_BATCH="${CHIEF_MERGE_BATCH:-${MERGE_BATCH:-1}}"
MERGE_BATCH_WAIT="${CHIEF_MERGE_BATCH_WAIT:-${MERGE_BATCH_WAIT:-120}}"
# How many branches ONE red batch may isolate by bisection before chief stops paying
# for the search and dissolves to the serialized floor instead. 0 = never bisect (a
# red tip dissolves immediately), which is the right setting for a gate known to be
# flaky, since bisect is only sound on a deterministic one.
MERGE_BATCH_BISECT="${CHIEF_MERGE_BATCH_BISECT:-${MERGE_BATCH_BISECT:-2}}"
STRICT_VERIFY="${STRICT_VERIFY:-0}"
# DRY_RUN — accepted from the environment as well as from `chief run -n` (the CLI
# forwards the flag and otherwise leaves an inherited value ALONE). Normalized to
# 1/0 here, on the CHIEF_HEADLESS precedent below: the single test downstream is
# `= "1"`, so an unrecognized truthy spelling (DRY_RUN=true) would silently mean
# "not a dry run" — and this is the one toggle whose failure mode is launching real
# agents at a repo when someone asked for a simulation.
case "${DRY_RUN:-0}" in 1|true|yes|on) DRY_RUN=1 ;; *) DRY_RUN=0 ;; esac
POLL_SECONDS="${POLL_SECONDS:-5}"
FORCE="${FORCE:-0}"
# HEADLESS — programmatic invocation (docs/guides/headless-invocation.md). Set by
# `chief run --headless` or CHIEF_HEADLESS=1 in the environment/.chief/config, and
# NEVER inferred from `[ -t 1 ]`: a host that pipes a normal run through `tee` must
# see exactly what it sees on a terminal, so the contract is switched on explicitly
# or not at all. It only ADDS machine-readable lines — every human line the driver
# already prints still prints, so `chief logs`, the per-tasklist logs and the final
# summary are unchanged and a host can tee the stream to a person as well.
case "${CHIEF_HEADLESS:-0}" in 1|true|yes|on) HEADLESS=1 ;; *) HEADLESS=0 ;; esac
# Announce the run's identity on stable, greppable, one-per-line `chief: key=value`
# records. The id is the marker minted above — the same string that appears in
# $CHIEF_RUNS/<pid>.run as `runid=` and on every process in this run's tree — so a
# parent can correlate its child's stdout with the registry and the state dir
# without parsing a table. Silent unless headless.
headless_announce() {
  [ "$HEADLESS" = "1" ] || return 0
  printf 'chief: run-id=%s\n' "$CHIEF_RUN_ID"
  # Only announce the registry entry once it actually exists: the early no-runnable
  # exit and a dry run never write one, and a path that resolves to nothing is worse
  # than no line at all for a host that would go read it.
  [ -f "$RUN_FILE" ] && printf 'chief: run-file=%s\n' "$RUN_FILE"
  # The NDJSON event log for this run (docs/reference/events.md). Announced on the same
  # convention so a host can subscribe without knowing $CHIEF_RUNS' layout.
  [ -n "${CHIEF_EVENTS_FILE:-}" ] && printf 'chief: events=%s\n' "$CHIEF_EVENTS_FILE"
  printf 'chief: state=%s\n' "$STATE_ROOT"
}

# HEADLESS EXIT-CODE CONTRACT (the table lives in docs/guides/headless-invocation.md and is
# pinned by test/headless.sh). A host must be able to tell what happened WITHOUT
# reading the summary block, so a headless run exits with a code that names the
# outcome instead of the historical 0/1.
#
# The codes apply to HEADLESS runs only. An interactive `chief run` keeps the exits
# it has always had (0 success or "nothing ran, operator pause"; 1 everything blocked
# on a dependency), because scripts and CI jobs already depend on those and a new
# table must not silently redefine them for callers who never asked for it.
HL_RC_OK=0          # every requested tasklist reached a merged/complete terminal state
HL_RC_CONFIG=2      # invocation/config error — the run never started
HL_RC_NOWORK=3      # nothing ran: nothing runnable, or every tasklist blocked on a dep
HL_RC_VERIFY=4      # >=1 tasklist ended VERIFY-FAILED
HL_RC_CONFLICT=5    # >=1 tasklist ended REBASE-CONFLICT / MERGE-CONFLICT
HL_RC_FAILED=6      # >=1 tasklist failed for another reason (stall, incomplete, no-work guard)
HL_RC_PAUSED=7      # work was withheld: an operator pause and/or a usage-limit window
# Pick an exit code for the mode we are in. $1 = the headless code, $2 = the code a
# NON-headless run has always exited with at this point. Every `exit` on a path the
# contract names goes through here, so the two behaviours can never drift apart.
hl_rc() { if [ "$HEADLESS" = "1" ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

# The terminal state of ONE tasklist, in the vocabulary the contract publishes. This
# is PURE TRANSLATION of state the driver already computed — the <name>.status line
# its worker wrote and the scheduler state reap() mapped it to (both of which the
# human summary prints verbatim). Nothing here decides anything, so there is exactly
# one state machine in the driver, not a second one for machines.
# $1 = tasklist name, $2 = its .status line (may be empty).
tasklist_outcome() {
  case "$2" in
    MERGED*)                          printf 'merged' ;;
    COMPLETE-UNMERGED*)               printf 'complete-unmerged' ;;   # --no-merge / AUTO_MERGE_MAIN=0
    VERIFY-FAILED*)                   printf 'verify-failed' ;;
    REBASE-CONFLICT*|MERGE-CONFLICT*) printf 'conflict' ;;
    REBASE-REFUSED*)                  printf 'rebase-refused' ;;
    RATE-LIMITED*)                    printf 'rate-limited' ;;
    PAUSED*)                          printf 'paused' ;;
    EMPTY-NO-WORK*)                   printf 'no-work' ;;
    PLAN-INVALID*)                    printf 'plan-invalid' ;;
    RESEARCH-FAILED*)                 printf 'research-failed' ;;
    AWAITING-REVIEW*)                 printf 'awaiting-review' ;;
    AWAITING-APPROVAL*)               printf 'awaiting-approval' ;;
    BAD-REPO*)                        printf 'bad-repo' ;;
    # No status line (or one no worker writes): fall back to the scheduler state,
    # which is what distinguishes "blocked on a dep" from "never launched" from
    # "failed for a reason with no status" (INCOMPLETE/WORKTREE-FAILED land here).
    *) case "$(get_state "$1")" in
         blocked)      printf 'blocked' ;;
         pending)      printf 'not-launched' ;;
         done)         printf 'merged' ;;
         rate-limited) printf 'rate-limited' ;;
         paused)          printf 'paused' ;;
         awaiting-review) printf 'awaiting-review' ;;
         awaiting-approval) printf 'awaiting-approval' ;;
         *)               printf 'failed' ;;
       esac ;;
  esac
}

# Machine-readable END-OF-RUN summary: the outcome half of the headless contract.
# One line, one JSON object, on the same `chief: <key>=<value>` convention as the
# run-id announcement — so a host reads the entire outcome with
#   sed -n 's/^chief: summary=//p'
# and never scrapes the human block printed above it. Built with jq (already a hard
# requirement) so names and status lines are escaped correctly.
# $1 = the run outcome, $2 = the exit code that goes with it.
headless_summary() {
  [ "$HEADLESS" = "1" ] || return 0
  local outcome="$1" code="$2" n st f
  f="$STATE/.summary.jsonl"; : > "$f" 2>/dev/null || return 0
  for n in $NAMES; do
    st="$(cat "$STATE/$n.status" 2>/dev/null || echo)"
    jq -nc --arg name "$n" --arg state "$(get_state "$n")" --arg status "$st" \
           --arg outcome "$(tasklist_outcome "$n" "$st")" --arg log "$STATE/$n.log" \
           --argjson attempts "$(attempts_used "$n")" \
      '{name:$name,state:$state,status:$status,outcome:$outcome,attempts:$attempts,log:$log}' >> "$f"
  done
  printf 'chief: outcome=%s\n' "$outcome"
  printf 'chief: exit=%s\n'    "$code"
  # `account` names WHICH account the run spent, never its credentials: the operator's
  # label and the env-file PATH, both null on an undesignated run. A pooler (chief-cloud
  # 91) reconciles its assignment against this without ever seeing a secret.
  printf 'chief: summary=%s\n' \
    "$(jq -nc --arg runId "$CHIEF_RUN_ID" --arg repo "$REPO" --arg base "$BASE_BRANCH" \
              --arg state "$STATE_ROOT" --arg outcome "$outcome" --argjson exit "$code" \
              --arg acctLabel "$ACCOUNT_LABEL" --arg acctEnv "$ACCOUNT_ENV_FILE" \
              --slurpfile tasklists "$f" \
       '{runId:$runId,repo:$repo,base:$base,state:$state,outcome:$outcome,exit:$exit,ok:($exit==0),
         account:{label:(if $acctLabel=="" then null else $acctLabel end),
                  envFile:(if $acctEnv=="" then null else $acctEnv end)},
         tasklists:$tasklists}')"
  rm -f "$f" 2>/dev/null || true
}
# engine/agent.sh's exit-code contract: 0 = COMPLETE, 1 = genuine failure (stall or
# hard cap), 2 = stopped on a Claude usage/session limit and won't retry, 3 = drained
# at an iteration boundary because an OPERATOR PAUSE is armed, 4 = a plan-review
# tasklist whose PLAN turn produced no well-formed plan, 5 = one whose plan is
# well-formed but UNAPPROVED with no reviewer reachable, 6 = the up-front RESEARCH
# PHASE could not produce a valid document. Keep in sync with the header of agent.sh
# — the whole limit-vs-failure distinction rides on these codes, and 3 and 5 must
# never be read as failed tasklists.
#
# 6 IS A FAILURE, but a differently-shaped one: it is the ONLY code that guarantees
# nothing was implemented, so it must not be reported as a stall (1) or, worse, fall
# through to the no-work guard and read as a false-complete. See run_worker.
AGENT_RC_LIMIT=2
AGENT_RC_PAUSED=3
AGENT_RC_PLAN=4
AGENT_RC_REVIEW=5
AGENT_RC_RESEARCH=6
AGENT_RC_UNVERIFIED=7
# Driver-level usage-limit self-heal (see SCHEDULER STATES above). Deliberately a
# separate family from agent.sh's RATE_LIMIT_* per-worker knobs: those govern how
# long ONE agent loop sleeps mid-story, these govern how many times the SCHEDULER
# re-launches a tasklist that gave up.
# RETRY ON FAILURE — bounded, and deliberately not universal.
#
# A tasklist that fails is left to rot until an operator notices, and it decays while it
# waits: every sibling that merges in the meantime puts it further behind its base. Seen in
# production 2026-08-10 — 124-items-equipment-economy failed a flaky 5s test timeout, sat
# for ~7 hours while 8 tasklists merged, and turned from "re-run it" into a 23-commit
# rebase with real conflicts. The failure was transient; the cost of not retrying was not.
#
# RETRY_MAX is total ATTEMPTS per tasklist per run (not retries on top of the first), so 3
# means it may run three times. 1 or 0 disables it. A re-armed tasklist goes back to
# 'pending' and run_worker's normal RESUME path reuses its branch and committed passes
# state — nothing is rebuilt, and integrate_base rebases it onto whatever landed meanwhile,
# which is precisely the decay this exists to stop.
RETRY_MAX="${RETRY_MAX:-3}"
RATE_LIMIT_REDISPATCH_MAX="${RATE_LIMIT_REDISPATCH_MAX:-3}"
RATE_LIMIT_REDISPATCH_WAIT="${RATE_LIMIT_REDISPATCH_WAIT:-3600}"
RATE_LIMIT_REDISPATCH_MAX_WAIT="${RATE_LIMIT_REDISPATCH_MAX_WAIT:-21600}"
LIMIT_PAUSE_FILE="$STATE/.limit-pause-until"
# The OPERATOR pause flag (see OPERATOR PAUSE in the header). A sibling of the file
# above in location only: that one holds a deadline Chief waits out by itself, this
# one holds a human decision and is lifted only by `chief resume`. Its content is the
# epoch it was armed at — informational, for the monitor; PRESENCE is what gates.
OPERATOR_PAUSE_FILE="$STATE/.paused"

source "$ENGINE/lib.sh"
# The SCOPE rule on acceptance criteria (engine/criteria.sh) — shared verbatim with
# `chief gen` and `chief lint`, so authoring time and run time cannot disagree about
# what "outside this worktree" means.
source "$ENGINE/criteria.sh"
# The BAR rule on acceptance criteria (engine/measure.sh): a story claiming a
# checkable bar must record the value it observed, or it is `unverified`, not passed.
source "$ENGINE/measure.sh"
# The per-story DIFF-SIZE BUDGET (engine/budget.sh): larger diffs carry higher
# conflict probability, so change size is the lever. Sourced BEFORE zones.sh, whose
# merge gate calls it — the two are one policy layer with one approval, not two
# checkpoints. Warn-only by default: it reports, and the merge continues.
source "$ENGINE/budget.sh"
# The OVERLAP ZONE REGISTRY (engine/zones.sh): the per-repo declaration of domains
# where a green gate is not sufficient authority to merge. A policy layer ABOVE the
# merge floor — it runs after the rebase and after a green verify, never instead of
# them — and asks nothing at all of a repo that declares no zones and stays in budget.
source "$ENGINE/zones.sh"
ZONES_CONF="$(zones_file "$REPO")"
# The OPT-IN BATCH MERGE QUEUE (engine/mergequeue.sh). Sourced after zones.sh because
# its eligibility rule consults the zone registry: a branch that needs a human's yes
# is never merged on the strength of a shared batch tip. Sourcing it is free — with
# MERGE_BATCH=1 (the default) nothing below ever calls into it, and the merge phase
# is the serialized floor it has always been.
source "$ENGINE/mergequeue.sh"
# git as a CONTAINER hands it to us (engine/gitenv.sh): a bind-mounted repo owned by
# another uid, and an image with no committer identity. Sourced before anything runs
# git on $REPO; its exports are inherited by every child — agent.sh, the verify hook,
# and the agent's own commits.
# shellcheck source=engine/gitenv.sh
source "$ENGINE/gitenv.sh"
# Orphan identification + the bounded, reporting reap (engine/reap.sh). Shared with
# `chief reap`, which is the same sweep on a path that does NOT need a new run.
source "$ENGINE/reap.sh"
# The DISK half of the same idea (engine/sweep.sh): reap.sh collects orphaned
# PROCESSES, this collects the build directories they left behind. Shared with
# `chief reap` for the same reason.
source "$ENGINE/sweep.sh"
# Per-tasklist LIVELINESS record (engine/live.sh): phase + heartbeat next to the
# coarse <name>.state, so `chief ps` can tell a working run from a hung one.
source "$ENGINE/live.sh"
live_of() { printf '%s' "$STATE/$1.live.json"; }   # the record for tasklist $1
# Machine-readable EVENT STREAM (engine/events.sh): an append-only NDJSON projection
# of the transitions written just below — subscribed to by chief-cloud and embedding
# hosts. $CHIEF_EVENTS_FILE is EXPORTED so the agent loop (a child process) appends
# its story events to the SAME log; empty makes every emit a no-op.
source "$ENGINE/events.sh"
CHIEF_EVENTS_FILE="$(events_file_for "$CHIEF_RUNS" "$CHIEF_RUN_ID")"
CHIEF_EVENT_REPO="$REPO"
export CHIEF_EVENTS_FILE CHIEF_EVENT_REPO

command -v jq >/dev/null || { echo "ERROR: jq is required."; exit "$(hl_rc "$HL_RC_CONFIG" 1)"; }

# ACCOUNT DESIGNATION (docs/reference/account-credentials.md) — the optional credential env
# FILE this run's provider turns execute under. The driver only PLUMBS the path
# through to engine/agent.sh, which applies it around the provider invocation and
# nowhere else; git, the verify hook and the iteration hook keep running under
# chief's own environment. Validated here, before a single worktree or agent turn,
# so a bad designation is a config error at launch instead of a run that quietly
# spends the inherited account's quota. bin/chief already resolved a relative path
# against the invoking cwd — the driver and its workers run elsewhere, so a path
# that is still relative here cannot be trusted to mean the same thing.
ACCOUNT_ENV_FILE="${CHIEF_ACCOUNT_ENV_FILE:-}"
if [ -n "$ACCOUNT_ENV_FILE" ]; then
  case "$ACCOUNT_ENV_FILE" in /*) ;; *) ACCOUNT_ENV_FILE="$PWD/$ACCOUNT_ENV_FILE" ;; esac
  if [ ! -f "$ACCOUNT_ENV_FILE" ] || [ ! -r "$ACCOUNT_ENV_FILE" ]; then
    echo "ERROR: --account-env: no readable credential env file at $ACCOUNT_ENV_FILE" >&2
    exit "$(hl_rc "$HL_RC_CONFIG" 1)"
  fi
fi
# THE PUBLIC HALF of the designation: the label this run's account is REPORTED under.
# Chief publishes WHICH account a run uses (registry entry, run.started event, verbose
# trace) and never WHAT it is — the label and the env-file PATH are reportable, the
# file's values are not, and no chief-written surface ever reads a value out of the
# file except the provider subshell in engine/agent.sh. Defaulted from the file's
# basename so a designated run is always identifiable, and re-derived here (not just
# in bin/chief) so a direct driver invocation reports the same thing.
ACCOUNT_LABEL="${CHIEF_ACCOUNT_LABEL:-}"
if [ -z "$ACCOUNT_LABEL" ] && [ -n "$ACCOUNT_ENV_FILE" ]; then
  ACCOUNT_LABEL="$(basename "$ACCOUNT_ENV_FILE")"; ACCOUNT_LABEL="${ACCOUNT_LABEL%.env}"
fi
# Operator-supplied text on its way into a key=value registry line and into JSON.
# An `if`, not `[ … ] && …`: the no-label path is the common one, and a top-level
# AND-list would leave it as a non-zero $? for whatever reads it next.
if [ -n "$ACCOUNT_LABEL" ]; then
  ACCOUNT_LABEL="$(printf '%s' "$ACCOUNT_LABEL" | tr -d '"\\$`' | tr '\n\r\t' '   ' | cut -c1-60)"
fi
# Keep the designation OUT of the ambient environment from here on: the driver hands
# it to engine/agent.sh explicitly (see run_worker), and nothing else in a run has
# any business consulting it. Un-exporting it means the verify hook, the warmup
# commands and the iteration hook see exactly the environment they would see on an
# undesignated run.
export -n CHIEF_ACCOUNT_ENV_FILE 2>/dev/null || true
export -n CHIEF_ACCOUNT_LABEL 2>/dev/null || true

# The state tree must be WRITABLE, not merely nameable — a distinction that only
# bites in a container, where the prefix can land on a read-only mount or a path this
# uid does not own, and where a bind-mounted repo can itself be read-only. Every
# symptom of that appears much later and somewhere unhelpful: `git worktree add`
# failing with a permission error from deep inside git, or a run whose registry entry
# silently never appears. So it is checked once, here, with the knobs named.
for _d in "$WT_ROOT" "$STATE"; do
  mkdir -p "$_d" 2>/dev/null || true
  { [ -d "$_d" ] && [ -w "$_d" ]; } && continue
  echo "ERROR: chief cannot write its state directory: $_d" >&2
  case "$_d" in
    "$REPO"/*) echo "       This lives inside the repo — mount/checkout $REPO writable." >&2 ;;
    *)         echo "       Set CHIEF_PREFIX (all host-wide state) or CHIEF_WORKTREE_ROOT" >&2
               echo "       (worktrees only) to a writable path — in a container, a volume or a tmpfs." >&2 ;;
  esac
  exit "$(hl_rc "$HL_RC_CONFIG" 1)"
done
unset _d

# git must OPERATE on this repo and be able to sign a commit, checked here for the
# same reason the writability guard above is: both hold for free on a laptop, both
# fail inside a container, and both otherwise surface an hour later as a git error
# with no mention of chief. See engine/gitenv.sh for what each knob does.
# NOT in a command substitution, however tempting: this call's whole product is
# EXPORTS ($GIT_CONFIG_*, $GIT_*_NAME/EMAIL) and a subshell would drop every one of
# them while still printing a reassuring note. Its notes go to stderr with a plain
# redirection, which keeps them in this shell.
chief_git_env_setup "$REPO" "$WT_ROOT" >&2 || exit "$(hl_rc "$HL_RC_CONFIG" 1)"

# ---------------------------------------------------------------------------
# Small helpers (bash 3.2 — no associative arrays)
# ---------------------------------------------------------------------------
in_set() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }   # is $1 a word in list $2?

# TEARDOWN SYMMETRY — chief created the worktree, so chief collects what accumulated
# inside it. Called immediately BEFORE every worktree removal, because removal here
# is best-effort at every site (`wt_git remove --force … 2>/dev/null || true`) and a
# removal that loses is exactly how a finished run leaves gigabytes standing. The
# verdict on each directory is engine/sweep.sh's business, not this function's; this
# only supplies the two paths that bound it and totals the bytes for the run summary.
# $1 = worktree, $2 = tasklist name (the label on the report lines).
sweep_worktree() {
  [ -d "$1" ] || return 0
  chief_sweep_worktree "$WT_ROOT" "$1" "$2" || true
  [ "${CHIEF_SWEEP_BYTES:-0}" -gt 0 ] && echo "$CHIEF_SWEEP_BYTES" >> "$STATE/sweep.bytes" 2>/dev/null
  return 0
}

# git worktree add / remove are NOT safe to run concurrently on one repo: they
# take the same ref lock and a race yields a spurious failure. Serialize them
# behind a short-held mkdir lock so PARALLEL>1 workers don't collide. (The agent
# loops themselves still run fully concurrently — only this git op is serialized.)
wt_git() {
  # Operates on the current worker's work-repo (a submodule for `repo:<sub>`
  # tasklists, else the project). $work_repo is a run_worker local, visible here
  # by bash dynamic scope; falls back to $REPO for any non-worker caller.
  local waited=0
  while ! mkdir "$WT_LOCK" 2>/dev/null; do sleep 1; waited=$(( waited + 1 )); [ "$waited" -gt 120 ] && break; done
  git -C "${work_repo:-$REPO}" worktree "$@"; local rc=$?
  rmdir "$WT_LOCK" 2>/dev/null || true
  return $rc
}

# Real product work on a branch = tracked files changed vs base, EXCLUDING chief's
# own bookkeeping — the tasklist JSON the agent flips pass-flags in. An agent that
# marked its stories "passed" but wrote no code changes ONLY that one JSON; if it
# counted as work, the no-work guard below would be defeated and an empty-of-code
# branch would merge (the false-complete class). $1=branch, $2=tasklist name.
branch_has_real_work() {
  # $work_repo/$work_base are run_worker locals (dynamic scope) — for a submodule
  # tasklist the diff is taken in the submodule against its own base. The tasklist
  # JSON lives only in the project, so excluding it is a no-op for submodule
  # branches (harmless) and closes the false-complete loophole for project ones.
  git -C "${work_repo:-$REPO}" diff --name-only "${work_base:-$BASE_BRANCH}...$1" \
    -- . ":(exclude)$TASKS_REL/$2.json" 2>/dev/null | head -1
}

# EVIDENCE GATE — a story CHIEF promotes must say how it was done.
#
# The COMPLETE path trusts an agent that committed real work and marks every story
# it left stale-false as passed (verify, not the pass-flags, is the merge bar). That
# trust is what lets a story report green against a criterion nobody read: a silent
# promotion is indistinguishable from finished work in the record. The cheapest
# signal separating them is already in the data — a story that did its work has
# something to say about HOW, and force-passed stories carry an EMPTY `notes`.
#
# So the promotion becomes conditional, and ONLY on the stories chief promotes
# itself. A story the agent explicitly marked passing is left alone: the point is to
# stop silent promotion, not to add ceremony to work that reported itself honestly.
# A stale-false story WITH evidence in `notes` is promoted as before; one WITHOUT is
# left false and reported here, so the branch fails instead of merging.
#
# $1 = the runtime prd.json. Promotes in place, and prints one block per unevidenced
# story — its id, title and the criteria it would have claimed — on stdout. Empty
# output means every promotion carried evidence and the branch may proceed.
evidence_gate() {
  local prd="$1" t
  # The report first: it must describe the stories as the agent left them, before
  # the promotion below rewrites any pass-flag.
  jq -r '
    def unpassed: (.passes != true);
    def evidenced: (((.notes // "") | tostring) | test("\\S"));
    def clip: if (. | length) > 200 then .[0:197] + "..." else . end;
    .userStories[] | select(unpassed and (evidenced | not))
    | "   ✗ \(.id) — \(.title // "(untitled)")\n"
      + ( [ (.acceptanceCriteria // [])[] | "       claimed: \"" + (tostring | clip) + "\"" ]
          | if length == 0 then ["       (no acceptance criteria recorded)"] else . end
          | join("\n") )
  ' "$prd" 2>/dev/null
  t="$(mktemp)"
  jq '
    def evidenced: (((.notes // "") | tostring) | test("\\S"));
    .userStories |= map(if (.passes != true) and evidenced then .passes = true else . end)
  ' "$prd" > "$t" 2>/dev/null && mv "$t" "$prd" || rm -f "$t"
}

# Fail the tasklist on evidence_gate's report: status, event, and the report itself.
# NOT the INCOMPLETE arm, which is where these stories would otherwise land (they are
# still false): that failure means the iteration budget ran out and an operator fixes
# it by raising `iters`, while this one is fixed by reading what was claimed. So the
# report is printed verbatim — the operator needs WHAT the story claimed, not a count
# that did not match. $1 = the report. $name/$branch/$live/$total/$remaining/$STATE
# are run_worker's, by dynamic scope.
unverified_stop() {
  local n; n="$(_int "$(printf '%s\n' "$1" | grep -c '✗' 2>/dev/null || true)")"
  live_set "$live" phase=unverified
  event_emit tasklist.unverified name="$name" state=failed \
    detail="$n stor$([ "$n" = 1 ] && echo y || echo ies) reported COMPLETE with no evidence in notes"
  echo "UNVERIFIED $(( $(_int "$total") - $(_int "$remaining") ))/$total" > "$STATE/$name.status"
  echo "!! $name UNVERIFIED — the agent reported COMPLETE, but $n stor$([ "$n" = 1 ] && echo y was || echo ies were) left unmarked with an EMPTY notes:"
  printf '%s\n' "$1"
  echo "   Not merging. A story chief passes on the agent's behalf must record in 'notes' HOW it met these — branch $branch is kept in its worktree."
}

# The passes-state to seed the runtime prd.json from (and to count remaining
# stories on a resume). For a project tasklist it's the branch's committed tasklist
# (survives across resumes in-repo). A submodule branch carries no tasklist JSON, so
# fall back to the last snapshot, then the pristine template. $name/$branch/$sub/
# $work_repo/$TASKS_REL/$SNAP/$SRC are visible by dynamic scope.
prd_state_source() {
  if [ -z "${sub:-}" ]; then
    git -C "${work_repo:-$REPO}" show "$branch:$TASKS_REL/$name.json" 2>/dev/null
  elif [ -f "$SNAP/$name.json" ]; then
    cat "$SNAP/$name.json"
  else
    cat "$SRC/$name.json"
  fi
}

# plan_sync SRC DEST — copy the PLAN ARTIFACTS (docs/plan-review.md) one way.
#
# Called twice per worker, in both directions. A worktree's .chief/state/ is
# gitignored and a fresh worktree starts empty, so a plan a previous run paid for —
# and that a human may already have reviewed — would be re-asked for every time the
# worktree was rebuilt. Snapshots outlive worktrees; that is the same reason
# prd.json is mirrored there. Silent and free when plan review is off: the source
# directory simply does not exist. Never fatal — a plan is re-derivable, and losing
# a run over a bookkeeping copy is not a trade worth making.
plan_sync() {
  [ -n "$(ls "$1/"*.json 2>/dev/null)" ] || return 0
  mkdir -p "$2" 2>/dev/null && cp "$1/"*.json "$2/" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# BASE INTEGRATION — keep a branch fresh, and move conflict resolution EARLIER
# (into the agent phase) instead of leaving it all to the merge phase.
#
# WHY: the merge phase rebases onto the LATEST base and re-verifies — that is the
# safety floor and it does not change. But by the time a branch reaches it, it may
# be a whole run's worth of sibling merges behind, and a conflict THERE ends the
# tasklist ("left for manual merge") with its dependents blocked. The drift is the
# fixable part: a branch picked up from a prior run starts this run exactly as far
# behind as it stopped, and never catches up on its own.
#
# There are TWO moments where that drift is visible and fixable, and both funnel
# through the one integrate_base() below:
#   · PICKUP        — run_worker's RESUME arm, before the agent loop starts.
#   · ITERATION     — between the agent's iterations (agent.sh's CHIEF_ITER_HOOK,
#     BOUNDARY        which re-enters this script as `--integrate-base`), because
#                     the serialized merge phase keeps advancing base while this
#                     worker runs. That bounds divergence to ONE iteration's worth
#                     of sibling merges instead of a whole run's.
#
# So integrate here, while an agent with full task context is still available:
#   · not behind          -> nothing at all (one rev-list; the common path is free)
#   · behind, clean       -> `git rebase <base>` in the worktree; one log line
#   · behind, conflicting -> ABORT the rebase (the branch is left exactly as it
#                            was — clean, attached, un-rebased) and write an
#                            INTEGRATE-BASE note the agent is told to act on
#                            FIRST, before any user story.
# Nothing here fails a tasklist, and nothing here resolves a conflict by itself.
#
# The note asks for a REBASE, not a merge, on purpose: the merge phase rebases the
# branch too, and a rebase DROPS merge commits and replays the original commits —
# so a resolution recorded in a merge commit is discarded and the very same
# conflict comes back at merge time. Resolving during a rebase bakes the fix into
# the branch's own commits, which is what makes the later rebase trivial.
#
# $1 name · $2 branch · $3 worktree · $4 work repo · $5 base branch
# Returns 0 when the branch is current or was cleanly rebased, 1 when a conflict
# was noted for the agent. Logs to stdout (callers run inside the worker's log).
INTEGRATE_NOTE_REL="$STATE_REL/INTEGRATE-BASE.md"
# The base tip this branch was last integrated against. Written on every attempt
# (by either call site) and read by the iteration-boundary throttle, so a boundary
# where base has not moved costs one rev-parse and nothing else.
INTEGRATED_SHA_REL="$STATE_REL/.integrated-base"
integrate_base() {
  local name="$1" branch="$2" wt="$3" repo="$4" base="$5"
  local note="$wt/$INTEGRATE_NOTE_REL" behind base_sha base_tip conflicted
  mkdir -p "$wt/$STATE_REL" 2>/dev/null || true
  rm -f "$note" 2>/dev/null || true                 # a stale note must never re-instruct
  base_tip="$(git -C "$repo" rev-parse --verify --quiet "$base" 2>/dev/null)"
  [ -n "$base_tip" ] || return 0
  # Record the tip BEFORE acting: this base has now been handled — cleanly, or by
  # handing the agent a note — and re-attempting it every boundary until base moves
  # again would just rewrite the same note.
  printf '%s' "$base_tip" > "$wt/$INTEGRATED_SHA_REL" 2>/dev/null || true
  behind="$(git -C "$repo" rev-list --count "$branch..$base" 2>/dev/null)"
  case "$behind" in ''|*[!0-9]*) return 0 ;; 0) return 0 ;; esac   # current: no git ops at all
  base_sha="$(git -C "$repo" rev-parse --short "$base" 2>/dev/null)"
  if git -C "$wt" rebase "$base" >/dev/null 2>&1; then
    echo ">> $name: rebased $branch onto $base @$base_sha ($behind commit(s) behind)"
    return 0
  fi
  # Conflicted (or could not start). Take the unmerged paths from the stopped
  # rebase — the real answer — before putting the branch back exactly as it was.
  conflicted="$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)"
  git -C "$wt" rebase --abort 2>/dev/null || true
  if [ -z "$conflicted" ]; then                     # fall back to a merge preview (git >= 2.38)
    conflicted="$(git -C "$repo" merge-tree --write-tree --name-only "$branch" "$base" 2>/dev/null \
                    | awk 'NR==1{next} /^$/{exit} {print}')"
  fi
  {
    echo "# BASE INTEGRATION REQUIRED — do this FIRST, before any user story"
    echo
    echo "\`$branch\` is **$behind commit(s) behind** its base \`$base\` (@$base_sha) and"
    echo "chief's automatic rebase onto that base CONFLICTS. The rebase was aborted, so"
    echo "your branch is exactly as it was and nothing is lost — but it cannot merge"
    echo "until the base is integrated, and every commit that lands on \`$base\` while"
    echo "this is unresolved makes it worse."
    echo
    echo "**Your first task this iteration is to integrate the base yourself:**"
    echo
    echo "1. \`git rebase $base\` in this worktree."
    echo "2. At each stop, resolve the conflicts keeping BOTH sides' intent — the"
    echo "   \`$base\` side is already-merged work, so never discard it, and never"
    echo "   discard your own — then \`git add <files>\` and \`git rebase --continue\`."
    echo "   \`git rebase --abort\` returns you to exactly this state if you need it."
    echo "3. Re-run the project's quality gates and make them green."
    echo
    echo "Rebase, not \`git merge $base\`: chief rebases this branch again at merge time,"
    echo "and a rebase drops merge commits and replays the originals — a resolution"
    echo "recorded in a merge commit would be thrown away and this conflict would come"
    echo "straight back. Resolving inside the rebase puts the fix in your own commits."
    echo
    echo "Then continue the normal loop: pick the highest-priority story with"
    echo "\`passes:false\` and implement it. The integration is NOT a user story — do not"
    echo "flip any story's \`passes\` for it, and do not report completion until the"
    echo "stories themselves are really done."
    echo
    echo "## Conflicting paths"
    if [ -n "$conflicted" ]; then
      printf '%s\n' "$conflicted" | sed 's/^/- /'
    else
      echo "- (git could not preview them — \`git rebase $base\` will show them)"
    fi
    echo
    echo "base: $base @$base_sha · behind: $behind commit(s) · branch: $branch"
  } > "$note" 2>/dev/null || true
  echo "!! $name: $branch is $behind commit(s) behind $base and does NOT rebase cleanly — wrote $INTEGRATE_NOTE_REL for the agent to integrate $base first (conflicts: $(printf '%s' "$conflicted" | tr '\n' ' '))"
  return 1
}

# The note reaches the agent the same way a persisted verify failure does: through
# the progress.txt it re-reads at the top of every iteration. (The note itself stays
# on disk next to prd.json — gitignored, like the rest of the runtime state — so the
# agent can go back to it while it works.) $1 = worktree.
inject_integrate_note() {
  local wt="$1" note="$1/$INTEGRATE_NOTE_REL" prog="$1/$STATE_REL/progress.txt"
  [ -f "$note" ] || return 0
  { echo; echo "## ⚠️ $(head -1 "$note" | sed 's/^# //')"
    tail -n +2 "$note"
    echo "(full note: $INTEGRATE_NOTE_REL)"
  } >> "$prog" 2>/dev/null || true
}

# Is the worktree mid-operation, or carrying uncommitted tracked work? Then this is
# NOT a safe moment to rebase it: `git rebase` would refuse, and integrate_base would
# read that refusal as a conflict and write a note about one that doesn't exist.
# Skipping costs nothing — the branch is re-checked at the next boundary, and the
# merge phase is still the floor. (Untracked files are ignored: they never block a
# rebase, and a build artifact must not freeze integration for the whole run.)
wt_busy() {
  ( cd "$1" 2>/dev/null || exit 1
    for d in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
      [ -e "$(git rev-parse --git-path "$d" 2>/dev/null)" ] && exit 0
    done
    [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ] && exit 0
    exit 1 )
}

# ---------------------------------------------------------------------------
# ` M <submodule>` IS NOT UNCOMMITTED WORK — it is a stale working tree
# ---------------------------------------------------------------------------
# `git status --porcelain -uno` answers "is this tree dirty", and in a repo with
# submodules that one answer conflates two unrelated conditions. Git does NOT update a
# submodule's working tree on checkout, so the instant a branch whose GITLINK differs
# from the current one is checked out, status reports ` M <sub>`. Nothing is dirty
# there: the tree is STALE, and no commit and no stash can clear it (`git stash` has
# nothing in the superproject to save). If that branch's whole PURPOSE is to advance
# the pin, the change it exists to make is the thing that blocks it — on every run,
# forever. Measured in chief-cloud on 2026-08-17 (76-runner-0-8-alignment, a one-line
# pin bump): clean on main, ` M chief` the moment the branch is checked out, clean
# again after `git submodule update --init`. It read REBASE-REFUSED three consecutive
# runs, blocked the tasklist behind it, and was hand-merged in the end.
#
# So: classify the dirt and make the tree HONEST, rather than loosening the check.
# `--ignore-submodules=dirty` is the wrong tool and would not even work here — it hides
# changes INSIDE a submodule's working tree (the case that MUST keep blocking) and it
# does not hide a gitlink mismatch (the case that must not).
#
# dirt_classify REPO — one `<class> <path>` line per uncommitted TRACKED entry:
#   gitlink   a submodule whose working tree sits at a different commit than the ref
#             pins, carrying no work of its own — `git submodule update` is the only fix
#   subdirty  a submodule with uncommitted work INSIDE it — a real block, and the
#             superproject cannot commit or stash it either
#   file      ordinary uncommitted tracked work in this repo
# Empty output means the tree is clean. Untracked files are out of scope throughout
# (they never block a checkout, a rebase or a merge).
dirt_classify() {
  local repo="$1" dirty subs line p
  dirty="$(git -C "$repo" -c core.quotePath=false status --porcelain --untracked-files=no 2>/dev/null)"
  [ -n "$dirty" ] || return 0
  # The gitlink paths, in ONE git call and only when there could be any: a repo with a
  # thousand modified files must not pay a `git ls-files` per file to be told what a
  # repo with no `.gitmodules` cannot have.
  subs=""
  [ -f "$repo/.gitmodules" ] && subs="$(git -C "$repo" -c core.quotePath=false ls-files --stage 2>/dev/null \
    | LC_ALL=C awk '$1=="160000"{i=index($0,"\t"); print substr($0,i+1)}')"
  printf '%s\n' "$dirty" | while IFS= read -r line; do
    p="${line#???}"          # XY + space
    p="${p##* -> }"          # a rename names the destination
    # Membership without a subprocess per path (bash 3.2 has no associative arrays):
    # a path exotic enough that git still quotes it will not match, and falls to
    # `file` — which blocks, the safe direction.
    case "
$subs
" in
      *"
$p
"*)
        # `-e $repo/$p/.git` first: for a submodule that is not checked out at all, a
        # `git -C` into it walks UP and reports the SUPERPROJECT's status — which is
        # never empty here, so every uninitialized one would misread as dirty inside.
        if [ -e "$repo/$p/.git" ] && [ -n "$(git -C "$repo/$p" status --porcelain --untracked-files=no 2>/dev/null)" ]
        then echo "subdirty $p"; else echo "gitlink $p"; fi ;;
      *) echo "file $p" ;;
    esac
  done
}

# dirt_paths CLASSIFIED CLASS — the paths of one class from a dirt_classify block, on
# one line, at most three of them (a refusal cause is a sentence, not an inventory).
dirt_paths() {
  printf '%s\n' "$1" | LC_ALL=C awk -v c="$2" '$1==c{sub(/^[^ ]+ /,""); n++; if (n<=3) p=(p?p", ":"")$0}
    END{ if (n>3) p=p", +"(n-3)" more"; if (n) print p }'
}

# submodules_sync REPO [LABEL] — make the submodule working trees honestly match the
# gitlinks of whatever is checked out RIGHT NOW. A no-op (one `git status`) for the
# overwhelmingly common case of a repo with no submodules, or none of them stale.
#
# SCOPED to the stale paths on purpose, rather than a bare `git submodule update --init
# --recursive`. run_worker already declines to init a project worktree's submodules for
# the same reason (a meta-repo's submodules are the sibling projects, and checking out
# gigabytes nobody asked for is not chief's call) — the operator's own checkout deserves
# at least that restraint. A submodule carrying work of its own is deliberately NOT
# synced: `git submodule update` does not always refuse to check out over local changes
# (it only refuses when the checkout would overwrite them), and chief must never be the
# reason a human's edit moved. It stays `subdirty`, and it goes on blocking the merge.
submodules_sync() {
  local repo="$1" label="${2:-chief}" paths
  paths="$(dirt_classify "$repo" | LC_ALL=C awk '$1=="gitlink"{sub(/^[^ ]+ /,"");print}')"
  [ -n "$paths" ] || return 0
  # shellcheck disable=SC2086  # one pathspec per line, deliberately split
  if git -C "$repo" submodule update --init --recursive -- $paths >/dev/null 2>&1; then
    echo ">> $label: synced submodule working tree(s) to the checked-out gitlink: $(printf '%s' "$paths" | tr '\n' ' ')"
  else
    echo "!! $label: could NOT sync submodule(s) to the checked-out gitlink: $(printf '%s' "$paths" | tr '\n' ' ')"
    echo "!! $label: the repo will read as dirty and the merge will refuse — run \`git -C $repo submodule update --init --recursive\` by hand"
  fi
  return 0
}

# work_checkout REPO REF [LABEL] — the ONLY way the merge path checks the work repo out
# onto anything. Checkout, then sync: git leaves submodule working trees behind on every
# ref move, and the very next thing every caller does is ask whether the tree is clean.
# Returns the checkout's own status (git's chatter is suppressed exactly as it was at
# each call site; the sync's is not — a submodule that moved under the operator says so).
work_checkout() {
  local repo="$1" ref="$2" label="${3:-chief}" rc=0
  git -C "$repo" checkout "$ref" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] && submodules_sync "$repo" "$label"
  return "$rc"
}

# Why would `git rebase` REFUSE to even start? A non-zero rebase exit is NOT by
# itself a content collision: git also declines outright when the tree carries
# uncommitted tracked changes, when a previous rebase/merge/cherry-pick was left in
# progress, or when it will not operate on the repo at all (dubious ownership,
# permissions). Every one of those leaves ZERO unmerged paths, so `--diff-filter=U`
# reports nothing and the failure used to be labelled a conflict "with git reported
# none" — the exact field symptom this exists to kill (three branches strictly AHEAD
# of main, where a rebase is a no-op, all parked as REBASE-CONFLICT).
#
# wt_busy() above answers the same question as a yes/no for the integration path;
# this one NAMES the cause for a human, and is the merge phase's pre-flight.
#
# $1 = repo (or worktree) path. Echoes ONE line naming the cause, or nothing at all
# when no refusal cause is detectable — an empty answer means "go ahead and rebase".
rebase_refusal_cause() {
  ( cd "$1" 2>/dev/null || { echo "the work repo path does not exist or is unreadable"; exit 0; }
    git rev-parse --git-dir >/dev/null 2>&1 \
      || { echo "git will not operate on this repo (not a repository, dubious ownership, or permissions) — run \`git status\` in it"; exit 0; }
    for d in rebase-merge rebase-apply; do
      [ -e "$(git rev-parse --git-path "$d" 2>/dev/null)" ] || continue
      echo "a previous rebase was left in progress ($d) — \`git rebase --abort\` clears it"; exit 0
    done
    for d in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
      [ -e "$(git rev-parse --git-path "$d" 2>/dev/null)" ] || continue
      echo "a previous merge/cherry-pick/revert was left in progress ($d) — finish or abort it"; exit 0
    done
    # Uncommitted tracked work — but WHICH kind. A stale submodule gitlink is reported
    # by `git status` in the same shape as an operator's half-finished edit, and "commit
    # or stash them" is advice that cannot be followed for it (see dirt_classify). Name
    # the classes separately, or the report sends a human after the wrong fix.
    cls="$(dirt_classify .)"
    [ -n "$cls" ] || exit 0
    gl="$(dirt_paths "$cls" gitlink)"; sd="$(dirt_paths "$cls" subdirty)"; fl="$(dirt_paths "$cls" file)"
    msg=""
    [ -n "$gl" ] && msg="submodule working tree(s) at a different commit than the ref pins ($gl) — this is NOT uncommitted work and neither a commit nor a stash clears it: \`git submodule update --init --recursive\`"
    [ -n "$sd" ] && msg="${msg:+$msg; also }uncommitted work INSIDE submodule(s) ($sd) — commit or stash it in the submodule itself"
    [ -n "$fl" ] && msg="${msg:+$msg; also }uncommitted tracked changes ($fl) — commit or stash them"
    echo "the work repo has $msg"
    exit 0 )
}

# ---------------------------------------------------------------------------
# THE OPERATOR'S UNCOMMITTED WORK — parked for the merge, and always given back
# ---------------------------------------------------------------------------
# The merge phase does its rebase → verify → merge IN THE WORK REPO, i.e. in the
# operator's own checkout. That made a clean working tree an unwritten PRECONDITION
# of merging: one uncommitted line anywhere in the repo — a file the branch never
# touches — and `rebase_refusal_cause` above declines, the tasklist is parked
# REBASE-REFUSED, and its dependents block. `chief run` checks the tree ONCE at
# startup and nothing re-checks it, so an operator editing their own repo while a run
# is in flight (a reasonable way to work) walks straight into it. Observed twice in
# one afternoon: two tasklists that had finished every story, each failing to merge
# over a single modified tracked file.
#
# So the merge phase stops requiring it, by PARKING the work for the duration of the
# critical section and restoring it on the way out. Three ways to do that were on the
# table; this is (b), and here is why not the other two:
#
#   (a) `git rebase --autostash` — one flag, and WRONG. Autostash pops the moment the
#       rebase ends, so the operator's changes are back in the tree for the re-verify
#       and the `--no-ff` merge that follow. The gate would then be measuring the
#       branch PLUS someone's half-finished edit, and a green result would not mean
#       what it says. It also covers exactly one of the three git commands here: the
#       `git checkout <branch>` before it and the merge after it are still exposed.
#
#   (c) rebase + verify + merge in a DEDICATED worktree, never checking the operator's
#       checkout out onto the branch at all — the structural fix, and rejected on two
#       counts. First, verify: `run_verify` runs the project's hook with cwd = the work
#       repo, and every real project's gate leans on untracked, unclonable state there
#       (node_modules, target/, .env, a warm build cache). A fresh worktree per merge
#       either fails the gate or pays a cold build for it, every merge. Second, the
#       merge itself has to land ON the base branch, which the operator's checkout
#       holds; a linked worktree cannot check out that same branch, so it would have to
#       merge detached and move `refs/heads/<base>` by hand — leaving the operator's
#       working tree silently BEHIND its own HEAD. That trades a loud, recoverable
#       refusal for a quiet corruption of the thing this story exists to protect.
#
# (b) keeps the merge exactly where it is, keeps verify honest (it runs against the
# branch and nothing else), and confines the new risk to one question: is the work
# always given back? That question has a bounded answer, below.
#
# THE SAFETY CONTRACT. The parked work is never held anywhere but git's own stash, so
# it survives a SIGKILL, a lost terminal and a reboot. `merge_stash_pop` runs from the
# subshell's `trap … EXIT`, so it fires on the happy path AND on every failure and
# abort arm; the sha is also written into `$STATE/<name>.critical`, which teardown
# reads on a signal and the next run's preflight sweeps for. And a replay that cannot
# apply cleanly DROPS NOTHING — the stash entry stays, and it is named.
CHIEF_STASH_TAG="chief: parked operator work for the merge of"

# merge_stash_push REPO NAME — park the repo's uncommitted TRACKED changes and echo
# the stash commit sha. Echoes NOTHING when there was nothing to park (the common
# path: one `git status`). UNTRACKED files are deliberately left alone — they never
# block a checkout of a tracked path, and sweeping a build tree into a stash is a far
# bigger surprise than the problem it would solve. Stdout is the sha and only the sha;
# the caller logs.
merge_stash_push() {
  local repo="$1" name="$2" sha before
  [ -n "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ] || return 0
  # What refs/stash pointed at BEFORE, because a dirty tree does not guarantee a new
  # entry: `git stash push` saves nothing for a submodule that is merely dirty INSIDE
  # (there is no superproject change to record) and still exits 0. Reading refs/stash
  # blind would then hand back the operator's OWN, older stash entry — and drop it.
  before="$(git -C "$repo" rev-parse --verify --quiet refs/stash 2>/dev/null || echo)"
  git -C "$repo" stash push --quiet --message "$CHIEF_STASH_TAG ${name:-a tasklist}" >/dev/null 2>&1 || return 0
  sha="$(git -C "$repo" rev-parse --verify --quiet refs/stash 2>/dev/null || echo)"
  [ -n "$sha" ] && [ "$sha" != "$before" ] && printf '%s' "$sha"
  return 0
}

# merge_stash_pop REPO SHA NAME — give it back. A no-op when SHA is empty (nothing was
# parked) or when the object is already gone (a previous pop won the race), so it is
# safe to call from a trap that may fire more than once.
#
# Applied by SHA, never by `stash@{0}`: the index is a stack, and an operator who
# stashed something themselves while the merge ran would otherwise get the wrong entry
# back. `--index` first so a staged change comes back staged; a plain apply is only
# retried when the failed attempt left the tree untouched, so a conflicted apply is
# never stacked on top of itself.
#
# Returns 1 — with the stash INTACT — when the work cannot be replayed. Nothing here
# ever drops an entry it did not successfully apply.
merge_stash_pop() {
  local repo="$1" sha="$2" name="$3" rc=0 entry
  [ -n "$sha" ] || return 0
  git -C "$repo" cat-file -e "${sha}^{commit}" 2>/dev/null || return 0
  git -C "$repo" stash apply --index "$sha" >/dev/null 2>&1 || rc=$?
  if [ "$rc" != 0 ] && [ -z "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    rc=0; git -C "$repo" stash apply "$sha" >/dev/null 2>&1 || rc=$?
  fi
  if [ "$rc" = 0 ]; then
    # Drop the ENTRY that names this sha, found by walking the reflog — dropping
    # `stash@{0}` blind would discard whatever happens to be on top instead.
    entry="$(git -C "$repo" stash list --format='%gd %H' 2>/dev/null | awk -v s="$sha" '$2==s{print $1; exit}')"
    [ -n "$entry" ] && git -C "$repo" stash drop --quiet "$entry" >/dev/null 2>&1
    echo ">> ${name:-chief}: restored the uncommitted changes chief parked for the merge"
    return 0
  fi
  echo "!! ${name:-chief}: chief parked this repo's uncommitted changes for the merge and CANNOT replay them cleanly."
  echo "!! ${name:-chief}: NOTHING WAS DROPPED — the work is intact in the stash. To get it back:"
  echo "     git -C $repo stash list        # '$CHIEF_STASH_TAG ${name:-a tasklist}'"
  echo "     git -C $repo stash apply $sha"
  return 1
}

# merge_critical_enter REPO NAME BASE — everything that has to happen, in order, at the
# top of a merge critical section, for the serialized floor and the batch queue alike.
# Sets $MERGE_STASH (the parked sha, empty when there was nothing to park) rather than
# echoing it: the sync and the park both have things to say to the operator's log, and a
# command substitution would swallow them.
#
#   mark   — first, so a kill in the next microsecond still names the repo and the base
#   sync   — HONEST TREE BEFORE PARKING: a submodule left stale by an earlier merge is
#            not the operator's work and must not land in their stash, which would carry
#            the gitlink off and still leave the tree reading dirty (see dirt_classify)
#   park   — the operator's uncommitted work. A clean work repo is no longer a
#            precondition of merging: it is a state the merge phase CREATES and undoes
#   mark   — again, now with the sha, which is what lets teardown and the next run's
#            preflight sweep give the work back when this section's own trap never ran
merge_critical_enter() {
  local repo="$1" name="$2" base="$3" label="${4:-$2}"
  merge_critical_mark "$repo" "$name" "$base"
  submodules_sync "$repo" "$label"
  MERGE_STASH="$(merge_stash_push "$repo" "$name")"
  merge_critical_mark "$repo" "$name" "$base" "$MERGE_STASH" "$label"
}

# merge_critical_mark REPO NAME BASE [STASH_SHA] [LABEL] — (re)write the marker that
# says "this repo is mid-merge", and announce a park. Called TWICE around
# merge_stash_push: once before it (so a kill in that window still names the repo and
# the base to restore) and once after with the sha, which is what lets teardown — and
# the next run's preflight sweep — give the operator's work back when neither the
# subshell's trap nor the signal handler ever ran.
#
# It lives here rather than inline because the serialized merge phase and the batch
# merge queue enter that section identically: a batch must not invent a second way for
# the work repo to be dirty, or a second set of files to restore it from.
merge_critical_mark() {
  local repo="$1" name="$2" base="$3" sha="${4:-}" label="${5:-$2}"
  { echo "name=$name"; echo "repo=$repo"; echo "base=$base"
    [ -n "$sha" ] && echo "stash=$sha"
  } > "$STATE/$name.critical" 2>/dev/null || true
  [ -n "$sha" ] || return 0
  rm -f "$STATE/$name.stash" 2>/dev/null || true      # a prior run's unreplayable entry
  echo ">> $label: the work repo had uncommitted tracked changes — PARKED in the stash @$(printf '%s' "$sha" | cut -c1-7) for the merge, and restored on the way out (they are not lost if this run dies: git stash list)"
}

# ITERATION-BOUNDARY integration — the throttled wrapper around integrate_base().
# Called once between agent iterations (never during one). Same args as
# integrate_base; always returns 0 — nothing here may end an iteration or a
# tasklist, it only keeps the branch close to base and, on a conflict, tells the
# agent about it.
integrate_boundary() {
  local name="$1" branch="$2" wt="$3" repo="$4" base="$5" tip last short
  tip="$(git -C "$repo" rev-parse --verify --quiet "$base" 2>/dev/null)"
  [ -n "$tip" ] || return 0
  last="$(cat "$wt/$INTEGRATED_SHA_REL" 2>/dev/null)"
  [ "$tip" = "$last" ] && return 0                  # base hasn't moved: nothing to do
  short="$(printf '%s' "$tip" | cut -c1-7)"
  if wt_busy "$wt"; then
    echo ">> $name: $base advanced to @$short but the worktree is mid-operation or has uncommitted changes — deferring integration to the next iteration boundary"
    return 0
  fi
  echo ">> $name: $base advanced to @$short since the last integration — re-integrating $branch"
  integrate_base "$name" "$branch" "$wt" "$repo" "$base" || inject_integrate_note "$wt"
  return 0
}

# ---------------------------------------------------------------------------
# CONFLICT FORENSICS — what the merge phase knew and used to throw away
# ---------------------------------------------------------------------------
# Integration (above) removes most of the drift, but the merge phase's rebase is
# still the floor and it can still stop: an agent that never got to its
# INTEGRATE-BASE instruction inside its iteration budget arrives at the merge
# phase with the same conflict. The engine deliberately does NOT auto-resolve it
# — a human (or the next run's agent) does. What it CAN do is hand them the
# answer instead of the question.
#
# Everything needed is on disk at the moment of the failure and gone a second
# later (the abort discards the index): the unmerged paths, and — for each of
# them — which commits landed on base since this branch forked. Chief's own
# auto-merge commits ("Merge <branch> (chief, auto-verified)") are called out by
# sibling tasklist name, because a just-merged sibling is the overwhelmingly
# likely collider: in the incident this work came from, all three conflicts
# traced to one sibling.
#
# `git log -- <path>` alone would NOT show those merge commits (history
# simplification prunes a merge that is TREESAME to a parent), which is why the
# attribution runs with --full-history: the sibling's own commits AND the chief
# merge that brought them in.
#
# $1 name · $2 branch · $3 work repo · $4 base branch · $5 merge-base sha
# $6 phase label · $7 report path. Writes the report; never fails the caller.
conflict_report() {
  local name="$1" branch="$2" repo="$3" base="$4" mb="$5" phase="$6" out="$7"
  local files f line sib sibs="" base_tip branch_tip
  # The unmerged paths, taken from the STOPPED operation — the accurate answer,
  # available only before the abort.
  files="$(git -C "$repo" diff --name-only --diff-filter=U 2>/dev/null)"
  base_tip="$(git -C "$repo" rev-parse --short "$base" 2>/dev/null)"
  branch_tip="$(git -C "$repo" rev-parse --short "$branch" 2>/dev/null)"
  mb="$(git -C "$repo" rev-parse --short "$mb" 2>/dev/null || printf '%s' "$mb")"
  mkdir -p "$SNAP" 2>/dev/null || true
  {
    echo "# $phase — $name"
    echo
    echo "The merge phase stopped and nothing was merged. \`$branch\` is exactly as the"
    echo "agent left it (the conflicting operation was aborted), and \`$base\` never moved."
    echo
    echo "- branch: \`$branch\` @$branch_tip"
    echo "- base: \`$base\` @$base_tip"
    echo "- merge-base: @$mb"
    echo
    echo "## Conflicted files"
    if [ -n "$files" ]; then printf '%s\n' "$files" | sed 's/^/- /'; else echo "- (git reported none — see the worker log)"; fi
    echo
    echo "## What landed on \`$base\` under them"
    echo
    echo "Commits on \`$base\` since @$mb that touched each conflicted file, newest first."
    if [ -z "$files" ]; then
      echo
      echo "(no conflicted paths to attribute)"
    fi
    printf '%s\n' "$files" | while IFS= read -r f; do
      [ -n "$f" ] || continue
      echo
      echo "### $f"
      git -C "$repo" log --full-history --format='%h %s' "$mb..$base" -- "$f" 2>/dev/null | while IFS= read -r line; do
        case "$line" in
          *"(chief, auto-verified)"*)
            sib="$(printf '%s' "$line" | sed -e 's/ (chief, auto-verified).*$//' -e 's/^[0-9a-f]* Merge //' -e 's|.*/||')"
            echo "- \`$line\` ← **chief auto-merge of sibling tasklist \`$sib\`**" ;;
          *) echo "- \`$line\`" ;;
        esac
      done
      [ -n "$(git -C "$repo" log --oneline --full-history "$mb..$base" -- "$f" 2>/dev/null)" ] \
        || echo "- (nothing on \`$base\` touched it — the conflict is inside this branch's own replay)"
    done
    # The colliders, collapsed to one list: this is the line a human reads first.
    sibs="$(printf '%s\n' "$files" | while IFS= read -r f; do
              [ -n "$f" ] || continue
              git -C "$repo" log --full-history --format='%s' "$mb..$base" -- "$f" 2>/dev/null \
                | sed -n 's/^Merge \(.*\) (chief, auto-verified).*$/\1/p' | sed 's|.*/||'
            done | sort -u | grep -v '^$')"
    echo
    echo "## Likely collider"
    if [ -n "$sibs" ]; then
      echo
      echo "Sibling tasklist(s) chief merged into \`$base\` ahead of this branch, touching the"
      echo "same files:"
      printf '%s\n' "$sibs" | sed 's/^/- `/;s/$/`/'
      echo
      echo "If this branch and that sibling share no \`touches\` domain, they were free to run"
      echo "concurrently over the same files — add a shared domain (or a \`dependsOn\` edge) so"
      echo "the scheduler serializes them next time."
    else
      echo
      echo "No chief auto-merge on \`$base\` touched these files — the collision is with"
      echo "hand-landed work on \`$base\`, or inside this branch's own history."
    fi
    echo
    echo "## Resolve it"
    echo
    echo '```sh'
    echo "cd $repo"
    echo "git checkout $branch"
    echo "git rebase $base        # resolve, git add <files>, git rebase --continue"
    echo "# then re-run the tasklist: chief run $name"
    echo '```'
    echo
    echo "Resolve inside the rebase, not with \`git merge $base\`: chief rebases this branch"
    echo "again at merge time and a rebase replays the original commits, so a resolution"
    echo "recorded in a merge commit is discarded and the conflict returns."
  } > "$out" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# REFUSAL FORENSICS — the other arm of the same failure
# ---------------------------------------------------------------------------
# A refused rebase and a conflicted one land a human in the same place (nothing
# merged, branch parked) for opposite reasons, and the move out is opposite too: a
# conflict is resolved INSIDE a rebase, a refusal is cleared BEFORE one can start.
# Handing over conflict_report()'s runbook for a dirty work repo sends someone
# hunting a collision that never happened — "## Conflicted files: (git reported
# none)" is the field symptom this whole tasklist exists to kill. So the refusal
# arm writes its OWN note: git's reason, the repo's state at that instant (which
# the abort does not throw away, unlike the conflict index — but the operator is
# not there to see it), and the one command that clears it.
#
# $1 name · $2 branch · $3 work repo · $4 base branch · $5 cause · $6 report path.
# Writes the report; never fails the caller.
refusal_report() {
  local name="$1" branch="$2" repo="$3" base="$4" cause="$5" out="$6"
  local base_tip branch_tip dirty
  base_tip="$(git -C "$repo" rev-parse --short "$base" 2>/dev/null)"
  branch_tip="$(git -C "$repo" rev-parse --short "$branch" 2>/dev/null)"
  dirty="$(git -C "$repo" status --short 2>/dev/null | head -20)"
  mkdir -p "$SNAP" 2>/dev/null || true
  {
    echo "# REBASE-REFUSED — $name"
    echo
    echo "**This is not a merge conflict.** \`git rebase\` never got far enough to produce"
    echo "one: it left ZERO unmerged paths (\`git diff --diff-filter=U\` was empty at the"
    echo "moment of the failure), which is exactly what separates this from"
    echo "\`REBASE-CONFLICT\`. There are no conflicted files to open and nothing to resolve."
    echo
    echo "Nothing was merged and nothing was rewritten — \`$branch\` is exactly as the agent"
    echo "left it and \`$base\` never moved. The work repo needs one fix, then a re-run."
    echo
    echo "- branch: \`$branch\` @$branch_tip"
    echo "- base: \`$base\` @$base_tip"
    echo "- work repo: \`$repo\`"
    echo
    echo "## Why git refused"
    echo
    echo "$cause"
    echo
    echo "## The work repo at that moment"
    echo
    if [ -n "$dirty" ]; then
      echo '```'
      printf '%s\n' "$dirty"
      echo '```'
    else
      echo "\`git status --short\` was clean — the refusal is state or configuration, not"
      echo "uncommitted work (see the cause above)."
    fi
    echo
    echo "## Fix it"
    echo
    echo '```sh'
    echo "cd $repo"
    # Cause-specific first move. The cause string is either rebase_refusal_cause()'s
    # own wording or git's verbatim message, so match on the tokens common to both.
    case "$cause" in
      *rebase-merge*|*rebase-apply*|*"rebase in progress"*|*"rebase --abort"*)
        echo "git rebase --abort       # clear the rebase left in progress" ;;
      *CHERRY_PICK_HEAD*|*"cherry-pick in progress"*)
        echo "git cherry-pick --abort  # clear the cherry-pick left in progress" ;;
      *REVERT_HEAD*|*"revert in progress"*)
        echo "git revert --abort       # clear the revert left in progress" ;;
      *MERGE_HEAD*|*"merge in progress"*|*"You have not concluded your merge"*)
        echo "git merge --abort        # clear the merge left in progress" ;;
      *uncommitted*|*unstaged*|*"local changes"*|*"staged changes"*|*"would be overwritten"*)
        echo "git status               # whose work is this?"
        echo "git stash -u             # or commit it — do not discard someone's work blind" ;;
      *ownership*|*"not a repository"*|*permission*|*safe.directory*)
        echo "git status               # confirm git will operate on this path at all"
        echo "git config --global --add safe.directory $repo   # if it is dubious ownership" ;;
      *)
        echo "git status               # the refusal above is git's own wording" ;;
    esac
    echo "#"
    echo "# then this must start AND finish clean before chief will merge:"
    echo "git rebase $base"
    echo "# and the tasklist picks back up with: chief run $name"
    echo '```'
    echo
    echo "Chief does not retry this on its own. A refusal is an **environment** fault, not"
    echo "something an agent can write code to fix — re-running the agent would only be"
    echo "refused again. Once the rebase above runs clean, \`chief run $name\` picks the"
    echo "branch back up at the merge phase with the stories it already finished intact."
  } > "$out" 2>/dev/null || true
}

# INTERNAL SUBCOMMAND — `driver.sh --integrate-base <name> <branch> <wt> <repo> <base>`.
# agent.sh runs this between iterations (see run_worker's CHIEF_ITER_HOOK). It is a
# re-entry rather than an exported function so the pickup path and the boundary path
# execute the SAME code from the SAME file, with no environment smuggling.
if [ "${1:-}" = "--integrate-base" ]; then
  shift
  [ "$#" = 5 ] || { echo "!! --integrate-base needs <name> <branch> <worktree> <work-repo> <base>" >&2; exit 2; }
  integrate_boundary "$@"
  exit 0
fi

iters_of()   { jq -r '.iters // 5' "$SRC/$1.json" 2>/dev/null || echo 5; }
deps_of()    { jq -r '(.dependsOn // [])[]' "$SRC/$1.json" 2>/dev/null; }
touches_of() { jq -r '(.touches // [])[]' "$SRC/$1.json" 2>/dev/null; }

# --- cross-repo deps --------------------------------------------------------
# A dep may be QUALIFIED as "<repo>:<tasklist>" to depend on work that lands in a
# different repo — e.g. "pinakes:10-koine-align". Bare names stay repo-local.
# <repo> is either a path (absolute, ~/…, or relative to this repo) or the plain
# name of a repo in the known-repos registry ($CHIEF_REPOS, appended by `chief
# init`/`chief run`). Only the merged RECORD is read across the boundary; chief
# never schedules, branches, or merges in another repo.
dep_repo() { case "$1" in *:*) printf '%s' "${1%%:*}" ;; esac; }   # empty when unqualified
dep_task() { printf '%s' "${1##*:}"; }

resolve_repo() {   # repo spec -> absolute path, or nothing when it can't be resolved
  local spec="$1" cand hits
  case "$spec" in
    "~/"*) cand="${HOME:-}/${spec#\~/}"; [ -n "${HOME:-}" ] || cand="" ;;
    /*)    cand="$spec" ;;
    */*)   cand="$REPO/$spec" ;;                      # relative to this repo
    *)     cand="" ;;
  esac
  if [ -n "$cand" ]; then
    [ -d "$cand/.chief" ] && (cd "$cand" 2>/dev/null && pwd)
    return 0
  fi
  [ -f "$CHIEF_REPOS" ] || return 0                   # bare name -> the registry
  hits="$(while read -r p; do
            [ -n "$p" ] && [ "$(basename "$p")" = "$spec" ] && [ -d "$p/.chief" ] && printf '%s\n' "$p"
          done < "$CHIEF_REPOS" | sort -u)"
  [ "$(printf '%s' "$hits" | grep -c .)" = "1" ] && printf '%s' "$hits"   # ambiguous = unresolved
  return 0
}

repo_tasks_rel() {   # another repo's CHIEF_TASKS_DIR (parsed, NOT sourced — it's foreign config)
  local v; v="$(sed -n 's/^[[:space:]]*CHIEF_TASKS_DIR=\([^ #]*\).*/\1/p' "$1/.chief/config" 2>/dev/null | tail -1)"
  printf '%s' "${v:-tasks/chief}"
}

dep_record() {   # dep -> the completed-record path that would satisfy it ('' if unresolvable)
  local d="$1" rr
  rr="$(dep_repo "$d")"
  [ -z "$rr" ] && { printf '%s' "$COMPLETED/$d.json"; return 0; }
  rr="$(resolve_repo "$rr")"
  [ -n "$rr" ] || return 0
  printf '%s' "$rr/$(repo_tasks_rel "$rr")/completed/$(dep_task "$d").json"
}

is_recorded_done() {   # merged record exists? (in this repo, or the dep's own repo)
  local f; f="$(dep_record "$1")"
  [ -n "$f" ] && [ -f "$f" ] && [ -n "$(jq -r '.mergedToMain // empty' "$f" 2>/dev/null)" ]
}

# Per-tasklist scheduler state lives in files so no associative array is needed.
# Every lifecycle transition also lands in the liveliness record (and stamps its
# heartbeat), so the two views can never drift apart.
set_state() {
  printf '%s' "$2" > "$STATE/$1.state"; live_set "$(live_of "$1")" name="$1" state="$2"
  # Event stream: the two coarse transitions a subscriber cannot derive from a
  # worker's own outcome event — a tasklist STARTING, and one the scheduler ruled
  # unstartable. The rest (done/failed/rate-limited/paused/awaiting-review) are reap()'s translation
  # of a <name>.status the worker already emitted an event for, so re-emitting them
  # here would double-report one transition under two names.
  case "$2" in
    running) event_emit tasklist.launched name="$1" state=running ;;
    blocked) event_emit tasklist.blocked  name="$1" state=blocked ;;
  esac
}
get_state() { cat "$STATE/$1.state" 2>/dev/null || printf 'pending'; }
dep_key() {   # scheduler key for a dep: one qualified with THIS repo is just a local dep,
              # so it can still be satisfied by a tasklist finishing in this run.
  local d="$1" rr; rr="$(dep_repo "$d")"
  [ -n "$rr" ] && rr="$(resolve_repo "$rr")" && [ "$rr" = "$REPO" ] && { dep_task "$d"; return 0; }
  printf '%s' "$d"
}

# ---------------------------------------------------------------------------
# Build the program: pending tasklists (or the names passed as args)
# ---------------------------------------------------------------------------
REQUESTED=""
if [ "$#" -gt 0 ]; then
  REQUESTED="$*"                          # explicit names run even if parked
else
  for f in "$SRC"/*.json; do              # auto-discovery skips "parked":true (e.g. rust-engine-*)
    [ -e "$f" ] || continue
    [ "$(jq -r '.parked // false' "$f" 2>/dev/null)" = "true" ] && continue
    REQUESTED="$REQUESTED $(basename "$f" .json)"
  done
fi

NAMES=""                                  # space-separated list of tasklists we schedule
for n in $REQUESTED; do
  if is_recorded_done "$n"; then continue; fi
  if [ ! -f "$SRC/$n.json" ]; then echo "  skip $n (no tasks/chief/$n.json and no merged record)"; continue; fi
  NAMES="$NAMES $n"
done
NAMES="$(printf '%s' "$NAMES" | xargs)"   # trim
if [ -z "$NAMES" ]; then
  # Nothing to schedule. Distinguish a fresh repo (only the parked example, or
  # no tasklists at all) from one where every real tasklist is already done —
  # and never silently run/merge a scaffolded example just to have something.
  if ls "$SRC"/*.json >/dev/null 2>&1; then
    echo "No runnable tasklists in $TASKS_REL/ — every one is complete or parked."
    echo "To get started, add a tasklist JSON (copy the parked example.json and drop its \"parked\" flag), then: chief run"
  else
    echo "No tasklists in $TASKS_REL/ yet."
    echo "Create one to get started (tasklist format: docs/reference/tasklist-schema.md), then: chief run"
  fi
  # A host still gets the full contract on the emptiest possible run: the id (so the
  # invocation is correlatable at all) and a summary with an empty tasklist array.
  # No registry file exists yet on this path, so headless_announce prints no
  # run-file — the same shape a dry run has. NOWORK is exactly what "no runnable
  # tasklist" means, and it is a NON-ZERO a host can act on; an interactive run
  # keeps its historical exit 0, because for a person this is not an error.
  headless_announce
  headless_summary no-work "$HL_RC_NOWORK"
  exit "$(hl_rc "$HL_RC_NOWORK" 0)"
fi

# A dep is satisfied if recorded-done on disk OR marked done this run.
deps_satisfied() {
  local d
  for d in $(deps_of "$1"); do
    is_recorded_done "$d" && continue
    [ "$(get_state "$(dep_key "$d")")" = "done" ] && continue
    return 1
  done
  return 0
}
dep_broken() {   # a dep failed/blocked -> this tasklist can never run
  # 'rate-limited', 'paused', 'awaiting-review' and 'awaiting-approval' are
  # deliberately absent: a dep waiting out a usage limit, parked by an operator
  # pause, waiting on a human's plan verdict, or held by the merge policy layer for a
  # human's approval is not broken — it is unfinished work with its branch intact that the next
  # run resumes. Its dependents must therefore stay pending (schedulable on resume)
  # rather than cascade to 'blocked'.
  local d
  for d in $(deps_of "$1"); do
    case "$(get_state "$(dep_key "$d")")" in failed|blocked) return 0 ;; esac
  done
  return 1
}
# Why is an unsatisfied dep unsatisfied? Prints 'scheduled' when the dep is part of
# THIS run and may still finish; otherwise a human reason it can never resolve here.
# Without this, an unresolvable dep just leaves the dependent sitting at 'pending'
# with no explanation — the run looks like a no-op instead of a blocked program.
dep_why() {
  local d="$1" rr rp rec
  rr="$(dep_repo "$d")"
  if [ -n "$rr" ]; then                                     # qualified "<repo>:<tasklist>"
    rp="$(resolve_repo "$rr")"
    if [ -z "$rp" ]; then
      echo "repo \"$rr\" could not be resolved — it is not a path, and no uniquely-named repo matches it in $CHIEF_REPOS (run 'chief init' or 'chief run' in that repo once to register it, or qualify with a path: \"../$rr:$(dep_task "$d")\")"; return
    fi
    [ "$rp" = "$REPO" ] && { in_set "$(dep_task "$d")" "$NAMES" && { echo scheduled; return; }; }
    rec="$(dep_record "$d")"
    if [ ! -f "$rec" ]; then
      if [ ! -f "$rp/$(repo_tasks_rel "$rp")/$(dep_task "$d").json" ]; then
        echo "$rp has no tasklist \"$(dep_task "$d")\" — neither $(repo_tasks_rel "$rp")/$(dep_task "$d").json nor a completed record exists there (misspelled? the name is the filename minus .json)"; return
      fi
      echo "not merged in $rp yet — $rec does not exist. Chief reads that record across repos but never runs another repo: complete it there ('cd $rp && chief run')"; return
    fi
    echo "its record $rec has no \"mergedToMain\" — the merge did not finish in $rp"; return
  fi
  if [ -f "$COMPLETED/$d.json" ]; then
    echo "its record $TASKS_REL/completed/$d.json has no \"mergedToMain\" — the merge did not finish"; return
  fi
  in_set "$d" "$NAMES" && { echo scheduled; return; }
  if [ ! -f "$SRC/$d.json" ]; then
    echo "no $TASKS_REL/$d.json and no $TASKS_REL/completed/$d.json in this repo — a bare dep is resolved against THIS repo (if it lives elsewhere, qualify it: \"<repo>:$d\"; if that is a branch name, drop the \"chief/\" prefix)"; return
  fi
  [ "$(jq -r '.parked // false' "$SRC/$d.json" 2>/dev/null)" = "true" ] \
    && { echo "$TASKS_REL/$d.json is parked, so it is never scheduled"; return; }
  echo "$TASKS_REL/$d.json was not selected for this run — name it too, or run 'chief run' with no names"
}
running_names() { local n; for n in $NAMES; do [ "$(get_state "$n")" = "running" ] && printf '%s ' "$n"; done; }
n_running()     { set -- $(running_names); echo "$#"; }
running_touches() { local n; for n in $(running_names); do touches_of "$n"; done | sort -u; }
touch_free() {    # no running tasklist shares a conflict domain with $1
  local t rt; rt="$(running_touches)"
  for t in $(touches_of "$1"); do printf '%s\n' "$rt" | grep -qxF "$t" && return 1; done
  return 0
}

# ---------------------------------------------------------------------------
# UNDER-TAGGED `touches` AUDIT — reporting only, never scheduling.
#
# `touches` is an optimization, and it fails asymmetrically. Over-tagging costs
# parallelism and is obvious in the wave plan; UNDER-tagging — two tasklists that
# edit the same file while sharing no domain — is invisible. It costs a wasted
# rebase, or a whole burnt tasklist when that rebase conflicts, and nothing ever
# names the mis-tagged pair: the human is left inferring it from a conflict.
#
# A run already knows both halves of the answer, so record them and cross them:
#   $STATE/.cosched     — "a b" per line: a and b were running at the same time.
#                         Recorded at LAUNCH — everything already running is a
#                         co-scheduled peer of the tasklist being launched, which
#                         is exactly the "ever concurrent" relation.
#   $STATE/<n>.touches  — the domains it declared, captured at launch because a
#                         merged tasklist is RETIRED to completed/ and touches_of()
#                         would then read a file that no longer exists.
#   $STATE/<n>.files    — its changed-file set vs its merge-base, captured after
#                         the agent phase so a branch that later conflicts, or ends
#                         INCOMPLETE, is audited too.
# A file overlap between a co-scheduled pair that shares NO domain is the finding.
# It changes no scheduling, no merge behavior and no status value — the run was
# still safe (the merge phase rebases and re-verifies); the audit only makes the
# cost attributable.
# ---------------------------------------------------------------------------
audit_launch() {   # $1 is about to start: record its domains + who it runs beside
  local n="$1" r
  touches_of "$n" > "$STATE/$n.touches" 2>/dev/null || : > "$STATE/$n.touches"
  for r in $(running_names); do
    [ "$r" = "$n" ] && continue
    printf '%s %s\n' "$r" "$n" >> "$STATE/.cosched" 2>/dev/null || true
  done
}

audit_record_files() {   # $1=name $2=branch — what this branch actually changed
  # The same diff (and the same bookkeeping exclusion) as branch_has_real_work,
  # kept as a LIST. Paths from a `repo:<sub>` tasklist are prefixed with the
  # submodule so two different repos' src/lib.rs can never read as an overlap.
  # Sorted because the audit intersects with comm(1).
  local pre=""; [ -n "${sub:-}" ] && pre="$sub/"
  git -C "${work_repo:-$REPO}" diff --name-only "${work_base:-$BASE_BRANCH}...$2" \
      -- . ":(exclude)$TASKS_REL/$1.json" 2>/dev/null \
    | sed "s|^|$pre|" | sort -u > "$STATE/$1.files" 2>/dev/null || true
}

audit_findings() {   # one WARNING block per under-tagged pair ($1: only this name)
  local only="${1:-}" a b t ta tb shared overlap
  [ -s "$STATE/.cosched" ] || return 0
  sort -u "$STATE/.cosched" | while read -r a b; do
    [ -n "$a" ] && [ -n "$b" ] || continue
    if [ -n "$only" ]; then
      [ "$a" = "$only" ] || [ "$b" = "$only" ] || continue
    fi
    # A pair is only auditable once BOTH sides recorded what they changed.
    { [ -s "$STATE/$a.files" ] && [ -s "$STATE/$b.files" ]; } || continue
    ta="$(tr '\n' ' ' < "$STATE/$a.touches" 2>/dev/null)"
    tb="$(tr '\n' ' ' < "$STATE/$b.touches" 2>/dev/null)"
    shared=""
    for t in $ta; do in_set "$t" "$tb" && { shared=1; break; }; done
    [ -n "$shared" ] && continue          # correctly serialized-by-domain: silent
    overlap="$(comm -12 "$STATE/$a.files" "$STATE/$b.files" 2>/dev/null)"
    [ -n "$overlap" ] || continue
    echo "   ⚠ WARNING — under-tagged touches: $a + $b ran concurrently and both changed:"
    printf '%s\n' "$overlap" | sed 's|^|        · |'
    echo "        $a touches: [${ta% }]"
    echo "        $b touches: [${tb% }]"
    echo "        Fix: give them a shared touches domain (or a dependsOn edge) so the"
    echo "        scheduler stops co-scheduling them — docs/explanation/drivers-and-safety.md."
  done
}

# ---------------------------------------------------------------------------
# DRY_RUN — simulate the schedule waves (no git, no agents). Validates the
# dependency + conflict + concurrency logic before a real, hours-long run.
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = "1" ]; then
  # A dry run spawns nothing and writes no registry file, so the id it announces is
  # this process's alone — correlate on stdout, not on $CHIEF_RUNS.
  [ "$HEADLESS" = "1" ] && printf 'chief: run-id=%s\nchief: dry-run=1\n' "$CHIEF_RUN_ID"
  echo "DRY RUN — provider=$PROVIDER${MODEL:+ model=$MODEL} — PARALLEL=$PARALLEL — pending:$NAMES" | sed 's/  */ /g'
  # The gate is checked inline: op_paused() is defined with the scheduler helpers,
  # far below this early-exit block.
  [ -f "$OPERATOR_PAUSE_FILE" ] && echo "  ⏸ an OPERATOR PAUSE is armed — a real run would launch NONE of this until 'chief resume'."
  echo "(each tasklist assumed to finish in its own wave; deps satisfied when done, touches free when not co-running)"
  DONE=""; wave=0
  while :; do
    wave_names=""; wtouch=""; progressed=1
    while [ -n "$progressed" ]; do
      progressed=""
      set -- $wave_names; [ "$#" -ge "$PARALLEL" ] && break
      for n in $NAMES; do
        in_set "$n" "$DONE" && continue
        in_set "$n" "$wave_names" && continue
        ok=1; for d in $(deps_of "$n"); do
          is_recorded_done "$d" && continue; in_set "$(dep_key "$d")" "$DONE" && continue; ok=""; break; done
        [ -z "$ok" ] && continue
        cf=1; for t in $(touches_of "$n"); do in_set "$t" "$wtouch" && { cf=""; break; }; done
        [ -z "$cf" ] && continue
        wave_names="$wave_names $n"
        for t in $(touches_of "$n"); do wtouch="$wtouch $t"; done
        progressed=1
        set -- $wave_names; [ "$#" -ge "$PARALLEL" ] && break
      done
    done
    [ -z "$wave_names" ] && break
    wave=$(( wave + 1 ))
    set -- $wave_names
    printf '  wave %d (%d/%d):%s\n' "$wave" "$#" "$PARALLEL" "$wave_names"
    DONE="$DONE $wave_names"
  done
  for n in $NAMES; do
    in_set "$n" "$DONE" && continue
    echo "  !! UNSCHEDULABLE: $n"
    shown=""
    for d in $(deps_of "$n"); do
      is_recorded_done "$d" && continue
      in_set "$(dep_key "$d")" "$DONE" && continue
      r="$(dep_why "$d")"
      [ "$r" = "scheduled" ] && r="it is also unschedulable (a dependency cycle, or its own deps can't complete)"
      echo "       needs \"$d\": $r"; shown=1
    done
    [ -z "$shown" ] && echo "       (a dependency cycle among the scheduled tasklists)"
  done
  echo "DRY RUN complete — $wave wave(s)."
  exit 0
fi

# ---------------------------------------------------------------------------
# Preconditions (real run) — mirror run-all.sh: single driver, clean tree, on main.
# ---------------------------------------------------------------------------
# ONE DRIVER PER REPO — enforced against the PROCESS TABLE, not only the lock file.
#
# driver.lock is a file, and the failure this tasklist exists for is precisely a
# driver that outlives its records: a teardown that released the lock before reaping
# the tree (the inversion US-1 fixed), an `rm -rf .chief/state`, a registry lost
# under a running driver. In that state `mkdir "$DRIVER_LOCK"` SUCCEEDS and a second
# scheduler starts on top of the first — two drivers racing one repo's branches,
# worktrees, index and merges, which is the one thing this lock exists to prevent.
#
# Scope: this repo's own run-marker prefix, which no other repo's run can carry, so
# a concurrent run elsewhere is untouched. A driver that IS the current lock owner is
# skipped here and reported by the lock branch below in its own words, so the classic
# "lock held / stale lock stolen" paths behave exactly as they always have.
if [ "${CHIEF_ALLOW_SECOND_DRIVER:-0}" != "1" ]; then
  lockpid="$(cat "$DRIVER_LOCK/pid" 2>/dev/null || echo)"
  ghosts=""
  while read -r dpid dtag; do
    [ -n "$dpid" ] || continue
    [ "$dpid" = "$lockpid" ] && continue
    ghosts="$ghosts $dpid"
    ghost_tags="${ghost_tags:-}$dpid $dtag
"
  done <<EOF
$(chief_driver_pids "$CHIEF_RUN_MARKER_REPO")
EOF
  if [ -n "$ghosts" ]; then
    echo "ERROR: a Chief driver for this repo is already RUNNING but the lock does not name it —" >&2
    echo "       refusing to start a second driver on $REPO." >&2
    printf '%s\n' "${ghost_tags:-}" | while read -r dpid dtag; do
      [ -n "$dpid" ] || continue
      if [ -n "$(chief_run_file_for_pid "$dpid")" ]; then reg="registered"; else reg="UNREGISTERED — invisible to 'chief ps' until now"; fi
      echo "       · pid $dpid  ($reg)  run $dtag" >&2
      echo "         $(chief_pid_cmd "$dpid")" >&2
      work="$(chief_driver_inflight "$REPO")"
      # shellcheck disable=SC2086
      set -- $work
      while [ "$#" -ge 2 ]; do echo "         in flight: $1 — $2" >&2; shift 2; done
    done
    echo "       Two drivers on one repo race its branches, worktrees and merges." >&2
    echo "       Watch it:  chief ps      ·  stop it:  kill$ghosts      ·  then:  chief reap" >&2
    exit "$(hl_rc "$HL_RC_CONFIG" 1)"
  fi
fi
# Single-driver lock that AUTO-CLEARS a stale one (owner pid dead) — so a re-run
# after a crash/Ctrl-C doesn't need manual `rmdir`. The lock dir carries the pid.
if mkdir "$DRIVER_LOCK" 2>/dev/null; then
  echo $$ > "$DRIVER_LOCK/pid"
  chief_ns_token > "$DRIVER_LOCK/ns"
else
  opid="$(cat "$DRIVER_LOCK/pid" 2>/dev/null || echo)"
  # "Stale" here means "that pid is dead", and a pid from ANOTHER PID namespace is
  # not a pid we can ask about: `kill -0` would answer about whatever local process
  # happens to wear that number, and the likely answer — nothing — clears a lock that
  # a driver in a sibling container is holding right now. Two drivers on one repo is
  # the failure this lock exists to prevent, so an unanswerable question stops the run
  # instead of being guessed at. (Same repo, same container: the token matches and
  # this branch never fires.)
  if chief_ns_foreign "$(chief_lock_ns "$DRIVER_LOCK")"; then
    echo "ERROR: this repo's driver.lock was taken in a DIFFERENT PID namespace" >&2
    echo "       (lock: $(chief_lock_ns "$DRIVER_LOCK"), here: $(chief_ns_token)) by pid ${opid:-unknown}." >&2
    echo "       Another container is driving $REPO, or one exited without releasing it." >&2
    echo "       Chief will not guess: from here that pid number means a different process." >&2
    echo "       Stop that run, or — if you know it is gone — rm -rf $DRIVER_LOCK" >&2
    exit "$(hl_rc "$HL_RC_CONFIG" 1)"
  fi
  if [ -n "$opid" ] && kill -0 "$opid" 2>/dev/null; then
    echo "ERROR: another Chief driver is active (pid $opid, lock: $DRIVER_LOCK). Never run two on one repo." >&2
    exit "$(hl_rc "$HL_RC_CONFIG" 1)"
  fi
  echo "  (clearing a stale driver lock from a dead run — owner pid ${opid:-unknown})" >&2
  rm -rf "$DRIVER_LOCK"
  if mkdir "$DRIVER_LOCK"; then echo $$ > "$DRIVER_LOCK/pid"; chief_ns_token > "$DRIVER_LOCK/ns"; fi
fi
# ---------------------------------------------------------------------------
# TEARDOWN — reap before you forget.
#
# THE INVARIANT, in one sentence: Chief must never remove the record of a run that
# is still running. The EXIT trap this replaces did exactly that inversion — it
# dropped driver.lock and the <pid>.run file and nothing else — so a Ctrl-C deleted
# the bookkeeping while the worker subshells, engine/agent.sh and `claude --print`
# below it kept going: an unsupervised, unbounded agent spending account quota that
# `chief ps` then reported as "no active runs".
#
# Ordering here is therefore load-bearing:
#   1. let an in-flight rebase/verify/merge reach a safe point (bounded),
#   2. REAP the worker tree — polite TERM, then a hard KILL after a grace period,
#   3. repair any repo the interrupt caught mid-operation (no manual git surgery),
#   4. and ONLY THEN release driver.lock / the merge+worktree locks / the run file —
#      refusing to release at all if anything below us somehow survived.
#
# Why TERM and not INT: a background command started by a NON-INTERACTIVE shell has
# SIGINT set to SIG_IGN, and an ignored-on-entry signal cannot be trapped or reset.
# Every `run_worker … &` subshell — and agent.sh and `claude` beneath it — inherits
# that, so a Ctrl-C delivered to the process group is *ignored by exactly the
# processes that need to die*. That is the mechanism behind the observed orphan.
STOP_SIGNALS=0                 # how many INT/TERM/HUP have arrived
STOP_REASON=""                 # the first one's name
IN_SCHEDULER=0                 # 1 while the poll loop owns the shell (see on_stop)
TEARDOWN_DONE=0                # teardown is idempotent — EXIT fires after a signal too
TEARDOWN_GRACE="${CHIEF_TEARDOWN_GRACE:-10}"                    # TERM -> KILL, seconds
TEARDOWN_CRITICAL_GRACE="${CHIEF_TEARDOWN_CRITICAL_GRACE:-120}"  # let a merge finish

# A worker marks $STATE/<name>.critical while it is inside the rebase → verify →
# merge sequence, i.e. while the WORK REPO is mid-git-operation. Killing there is
# what leaves a repo needing manual surgery, so teardown waits it out first.
stop_critical() { ls "$STATE"/*.critical 2>/dev/null; }

stop_wait_critical() {
  local waited=0
  [ "$STOP_SIGNALS" -gt 0 ] || return 0
  [ -n "$(stop_critical)" ] || return 0
  echo "  ⏳ a rebase/verify/merge is in flight — waiting up to ${TEARDOWN_CRITICAL_GRACE}s for it to finish (interrupt again to skip):" >&2
  stop_critical | sed 's|.*/|       · |; s|\.critical$||' >&2
  while [ -n "$(stop_critical)" ] && [ "$waited" -lt "$TEARDOWN_CRITICAL_GRACE" ] && [ "$STOP_SIGNALS" -lt 2 ]; do
    sleep 1; waited=$(( waited + 1 ))
  done
  return 0
}

# Everything the reap has ever aimed at, so a process that escapes the tree mid-reap
# (a `claude` reparented to init when its agent.sh frame dies first) stays accounted
# for — by both the escalation below and the release check further down.
STOP_TARGETS=""

# Escalating and BOUNDED: polite first so an agent can flush, hard after the grace,
# so a wedged `claude` can never make the interrupt hang forever. A SECOND interrupt
# collapses the grace period to nothing (STOP_SIGNALS is bumped by on_stop, which
# bash can only dispatch because this runs OUTSIDE the trap — see on_stop).
stop_reap_tree() {
  local waited=0 p why
  chief_scan_descendants "$$" "$STOP_TARGETS"
  [ -n "$CHIEF_DESCENDANTS" ] || return 0
  STOP_TARGETS="$CHIEF_DESCENDANTS"
  echo "  ⏹ reaping the worker tree below this driver (TERM): $STOP_TARGETS" >&2
  for p in $STOP_TARGETS; do kill -TERM "$p" 2>/dev/null || true; done
  while [ "$waited" -lt "$TEARDOWN_GRACE" ] && [ "$STOP_SIGNALS" -lt 2 ]; do
    chief_scan_descendants "$$" "$STOP_TARGETS"
    [ -n "$CHIEF_DESCENDANTS" ] || return 0
    sleep 1; waited=$(( waited + 1 ))
  done
  chief_scan_descendants "$$" "$STOP_TARGETS"
  [ -n "$CHIEF_DESCENDANTS" ] || return 0
  if [ "$STOP_SIGNALS" -ge 2 ]; then why="a second interrupt"; else why="the ${TEARDOWN_GRACE}s grace"; fi
  echo "  ⏹ hard-killing survivors after $why (KILL): $CHIEF_DESCENDANTS" >&2
  for p in $CHIEF_DESCENDANTS; do kill -9 "$p" 2>/dev/null || true; done
  sleep 1
  return 0
}

# Never hand back a repo that needs `git rebase --abort` typed by hand. Any work the
# interrupt caught uncommitted is parked as a wip commit ON THE FEATURE BRANCH first
# (never discarded), mirroring the preflight AUTO-RECOVER path above.
stop_repair_repo() {
  local r="$1" b="$2" cur
  [ -n "$r" ] || return 0
  git -C "$r" rev-parse --git-dir >/dev/null 2>&1 || return 0
  git -C "$r" rebase --abort 2>/dev/null || true
  git -C "$r" merge  --abort 2>/dev/null || true
  cur="$(git -C "$r" rev-parse --abbrev-ref HEAD 2>/dev/null || echo)"
  case "$cur" in
    chief/*) ;;
    *) return 0 ;;
  esac
  if [ -n "$(git -C "$r" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    git -C "$r" add -A 2>/dev/null || true
    git -C "$r" commit -q -m "wip(chief): interrupted mid-merge on $cur" 2>/dev/null || true
  fi
  if git -C "$r" checkout "$b" >/dev/null 2>&1; then
    echo "  ⏹ restored $(basename "$r") to '$b' (the interrupt caught it on '$cur')" >&2
  else
    echo "  !! could not restore '$b' in $r — still on '$cur'; resolve it by hand." >&2
  fi
  return 0
}

# The stash restore is done HERE rather than inside stop_repair_repo(), because that
# function returns early once the repo is already back on its base — which is exactly
# the state a critical section that finished its merge but was killed before its trap
# ran leaves behind, and it is still owed the operator's work.
stop_repair_repos() {
  local f r b st n
  for f in "$STATE"/*.critical; do
    [ -e "$f" ] || continue
    r="$(sed -n 's/^repo=//p' "$f" 2>/dev/null | head -1)"
    b="$(sed -n 's/^base=//p' "$f" 2>/dev/null | head -1)"
    st="$(sed -n 's/^stash=//p' "$f" 2>/dev/null | head -1)"
    n="$(sed -n 's/^name=//p' "$f" 2>/dev/null | head -1)"
    stop_repair_repo "$r" "${b:-$BASE_BRANCH}"
    [ -n "$st" ] && [ -n "$r" ] && { merge_stash_pop "$r" "$st" "$n" >&2 || echo "$r|$st" > "$STATE/$n.stash"; }
    rm -f "$f" 2>/dev/null || true
  done
  stop_repair_repo "$REPO" "$BASE_BRANCH"
  return 0
}

# The LAST step, and only once the tree is provably gone. If anything outlived both
# TERM and KILL we keep the records instead: an orphan that is still spending is far
# less dangerous when it is still visible to `chief ps`.
stop_release_records() {
  chief_scan_descendants "$$" "$STOP_TARGETS"
  if [ -n "$CHIEF_DESCENDANTS" ]; then
    echo "  !! REFUSING to release the run records — these survived TERM and KILL: $CHIEF_DESCENDANTS" >&2
    echo "     Keeping $DRIVER_LOCK and $RUN_FILE so the run stays visible to 'chief ps'." >&2
    echo "     Chief never removes the record of a run that is still running." >&2
    return 1
  fi
  rm -rf "$DRIVER_LOCK" 2>/dev/null || true
  rmdir "$MERGE_LOCK" "$WT_LOCK" 2>/dev/null || true
  rm -f "$RUN_FILE" 2>/dev/null || true
  return 0
}

teardown() {
  [ "$TEARDOWN_DONE" = 1 ] && return 0
  TEARDOWN_DONE=1
  if [ "$STOP_SIGNALS" -gt 0 ]; then
    echo >&2
    echo "  ⏹ ${STOP_REASON:-signal} — stopping. Reaping the agent tree FIRST, then releasing the run records." >&2
    echo "     (interrupt again to skip the grace periods and hard-kill immediately)" >&2
    # Close the event stream on the interrupt path too, BEFORE the records are
    # released — otherwise a subscriber's last line is whatever the run happened to
    # be doing and it can never tell "killed" from "still going". Gated on the run
    # file because teardown also runs for a Ctrl-C during preflight, where no
    # `run.started` was ever emitted to pair with it. The normal path emits its own
    # `run.finished` from the summary, so this arm is signals-only — never both.
    [ -f "$RUN_FILE" ] && event_emit run.finished state=interrupted detail="${STOP_REASON:-signal}"
  fi
  stop_wait_critical
  stop_reap_tree
  [ "$STOP_SIGNALS" -gt 0 ] && stop_repair_repos
  stop_release_records
  return 0
}

# $1 = signal name, $2 = the exit code that signal implies.
#
# THIS HANDLER IS DELIBERATELY THREE ASSIGNMENTS LONG, because of two bash rules
# that together decide whether a SECOND interrupt can be seen at all:
#
#   1. While bash is waiting for a foreground command, a trapped signal does not
#      run its trap until that command COMPLETES — and repeats arriving in the
#      meantime are COALESCED into one pending trap. Two signals inside one
#      `sleep $POLL_SECONDS` are therefore indistinguishable from one. That is why
#      every wait in this driver is sliced into 1s steps by stop_sleep(), which
#      bounds the coalescing window to about a second.
#   2. Bash will not dispatch a repeat of the same signal while its handler is
#      still executing. Every instruction in here is thus a window in which a
#      second Ctrl-C is silently dropped.
#
# So all the announcing and all the work happen in teardown(), which runs OUTSIDE
# the trap: from the scheduler loop we only RECORD the request and let stop_check
# run teardown at the next command boundary, where a second signal dispatches
# normally, bumps STOP_SIGNALS to 2, and collapses the grace periods that the wait
# loops above check.
#
# Outside the loop (preflight, summary) there is no worker tree to wait on, so the
# bounded waits are no-ops and running teardown inline is both safe and the only way
# to stop promptly.
on_stop() {
  STOP_SIGNALS=$(( STOP_SIGNALS + 1 ))
  [ -z "$STOP_REASON" ] && STOP_REASON="$1"
  [ "$IN_SCHEDULER" = 1 ] && return 0
  teardown
  exit "$2"
}
# monitor.sh has trapped INT/TERM since it existed; the driver — the process that
# actually owns child processes — trapped nothing but EXIT until now.
trap 'on_stop INT 130'  INT
trap 'on_stop TERM 143' TERM
trap 'on_stop HUP 129'  HUP
trap 'teardown' EXIT

# Honour a recorded interrupt at a safe point in the scheduler loop.
stop_check() {
  [ "$STOP_SIGNALS" -gt 0 ] || return 0
  teardown
  case "$STOP_REASON" in INT) exit 130 ;; HUP) exit 129 ;; *) exit 143 ;; esac
}

# Every scheduler wait goes through here. Sleeping in 1s slices (rather than one
# long `sleep`) is what keeps an interrupt honoured within about a second instead of
# up to $POLL_SECONDS — and, per rule 1 in on_stop's comment, it is also what stops
# two separate interrupts from being coalesced into one pending trap.
stop_sleep() {
  local n="$1" i=0
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  while [ "$i" -lt "$n" ]; do sleep 1; stop_check; i=$(( i + 1 )); done
  return 0
}

rmdir "$MERGE_LOCK" "$WT_LOCK" 2>/dev/null || true  # clear stale merge/worktree locks from a killed run
# Stale mid-merge markers from a killed run. Before they go, HARVEST any operator work
# a previous merge phase parked in the stash and never got to give back — a SIGKILL,
# a closed terminal or a reboot skips the trap that restores it. The work is not lost
# either way (a stash entry outlives the process that made it), but a run that took it
# owes it back, and an operator should not have to know it was taken. Restored below,
# AFTER the preflight cleanliness gate — putting it back first would fail the gate on
# the strength of the run that borrowed it.
STALE_STASHES=""
for f in "$STATE"/*.critical; do
  [ -e "$f" ] || continue
  cs="$(sed -n 's/^stash=//p' "$f" 2>/dev/null | head -1)"
  cr="$(sed -n 's/^repo=//p'  "$f" 2>/dev/null | head -1)"
  cn="$(sed -n 's/^name=//p'  "$f" 2>/dev/null | head -1)"
  [ -n "$cs" ] && [ -n "$cr" ] && STALE_STASHES="$STALE_STASHES $cr|$cs|${cn:-a previous run}"
done
rm -f "$STATE"/*.critical 2>/dev/null || true       # stale mid-merge markers from a killed run
rm -f "$STATE"/*.state "$STATE"/*.pid "$STATE"/*.live.json 2>/dev/null || true   # fresh scheduler state
# Register this run in the global registry so `chief ps`/`chief monitor` can find
# it from any cwd. Absolute paths only — the monitor reads them without parsing a
# project config. `names` is the schedule (already trimmed of completed/parked).
mkdir -p "$CHIEF_RUNS" 2>/dev/null || true
{
  echo "pid=$$"
  echo "ns=$(chief_ns_token)"                  # which PID namespace `pid`/`pgid` are numbered in
  echo "repo=$REPO"
  echo "base=$BASE_BRANCH"
  echo "parallel=$PARALLEL"
  echo "provider=$PROVIDER"
  echo "model=$MODEL"
  echo "tool=$TOOL"
  echo "automerge=$AUTO_MERGE_MAIN"
  echo "limitmax=$RATE_LIMIT_REDISPATCH_MAX"   # monitor.sh renders "re-dispatch n/max"
  echo "retrymax=$RETRY_MAX"                     # monitor.sh renders "attempt n/max"
  echo "started=$(date +%s)"
  echo "state=$STATE_ROOT"
  echo "staterel=$STATE_REL"
  echo "tasks=$SRC"
  echo "wt=$WT_ROOT"
  # ACCOUNT DESIGNATION, reported not exposed (docs/reference/account-credentials.md): the
  # env-file PATH and the label, so `chief ps`/`chief monitor` and any registry reader
  # can say WHICH account this run spends. Both are empty on an undesignated run.
  # The file's VALUES are read only inside agent.sh's provider subshell and are never
  # written here, to a live record, to a log, or to anything under .chief/state.
  echo "account=$ACCOUNT_ENV_FILE"
  echo "accountlabel=$ACCOUNT_LABEL"
  echo "events=$CHIEF_EVENTS_FILE"             # this run's NDJSON event log (docs/reference/events.md)
  echo "runid=$CHIEF_RUN_ID"                   # the marker stamped on this run's tree
  echo "marker=$CHIEF_RUN_MARKER_REPO"         #   (and the prefix that matches this repo)
  echo "pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
  echo "names=$NAMES"
} > "$RUN_FILE" 2>/dev/null || true
# The run file now exists, so the id a headless host reads here is immediately
# resolvable in the registry. Emitted BEFORE the scheduler loop (and before the
# orphan sweep below, which can spend seconds) so the parent can start correlating
# at once instead of after the first tasklist launches.
headless_announce
# The event stream opens here, on the same transition: the registry entry exists, so
# a host that reads `run.started` can immediately resolve the run it names. Older logs
# are pruned first — they outlive their run by design, so nothing else bounds them.
events_prune "$CHIEF_RUNS" "${CHIEF_EVENTS_KEEP_DAYS:-14}"
event_emit run.started state=running \
  detail="base=$BASE_BRANCH parallel=$PARALLEL provider=$PROVIDER automerge=$AUTO_MERGE_MAIN${ACCOUNT_LABEL:+ account=$ACCOUNT_LABEL} names:$NAMES"
# Reap ORPHANED agent loops left by a prior crashed run on THIS repo. We hold the
# driver lock, so nothing legitimate is using them.
#
# The sweep this replaces was `pgrep -f "$WT_ROOT"`, which found only the transient
# grandchildren (a pytest, a build) — driver.sh, agent.sh and `claude --print` carry
# no worktree path in argv at all, so the engine layer survived the reap and kept
# spawning. Identification is now by cwd (every process in an agent tree runs INSIDE
# $WT_ROOT/<tasklist>) and by the run marker on argv, which is what catches a driver
# whose own cwd is wherever the operator was standing. Scoped to this repo's worktree
# root and this repo's marker prefix, and every live registered run — ours included —
# is protected, so a concurrent run in another repo cannot be touched.
chief_reap_orphans "$WT_ROOT" "$CHIEF_RUN_MARKER_REPO" \
  "a previous run on $(basename "$REPO")" "${CHIEF_REAP_GRACE:-5}" || true
git -C "$REPO" worktree prune 2>/dev/null || true   # drop stale worktree metadata (branches kept)

# THE STARTUP PRECONDITION — what it protects, and what it does NOT.
#
# It protects the AGENT'S FORK POINT. Every worktree is created from the base branch's
# TIP (`wt_git add <wt> -b <branch> "$work_base"`), never from this working tree, so
# anything uncommitted here is invisible to every tasklist in the run: the agent plans
# and builds against a base the operator has already moved on from, and can duplicate
# or contradict the change sitting in their editor. "On the base branch" is the same
# property from the other side — it is where worktrees fork from, where merges land,
# and the branch the merge phase restores to this checkout on its way out.
#
# It does NOT protect the MERGE, and never did: it is checked ONCE, here, and nothing
# re-checks it, so an operator who typed one line five minutes into a run walked
# straight past it and the merge failed anyway (the field case behind tasklist 93).
# That gap is closed at the merge phase itself, which parks the work repo's
# uncommitted tracked changes in git's own stash for the length of its critical
# section and gives them back on the way out (merge_stash_push/merge_stash_pop).
# Editing this repo DURING a run is safe for the merge.
#
# So it stays a BLOCK rather than a warning, but on the narrower ground: a run forked
# from a base the operator has already moved past is work built against the wrong
# tree, and no later step can repair that — whereas the merge-time exposure the gate
# used to be justified by is now handled where it actually happens. FORCE=1 skips it,
# and is the right call when the uncommitted work is somewhere no tasklist in this run
# will look. Nothing here runs at all for a clean checkout on the base branch.
if [ "$FORCE" != "1" ]; then
  cur="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  # AUTO-RECOVER: a run killed mid-merge leaves the BASE working tree checked out on
  # a chief/* feature branch (possibly mid-rebase), which would hard-block every
  # future run. Abort any in-progress rebase/merge, stash the stray work onto the
  # branch (so it's not lost), and restore the base branch. AUTO_RECOVER=0 disables.
  if [ "$cur" != "$BASE_BRANCH" ]; then
    case "$cur:${AUTO_RECOVER:-1}" in
      chief/*:1)
        echo "  (auto-recover: base repo stranded on '$cur' from a crashed run — restoring '$BASE_BRANCH')" >&2
        git -C "$REPO" rebase --abort  2>/dev/null || true
        git -C "$REPO" merge  --abort  2>/dev/null || true
        if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]; then
          git -C "$REPO" add -A 2>/dev/null || true
          git -C "$REPO" commit -q -m "wip(chief): recovered from an interrupted run on $cur" 2>/dev/null || true
        fi
        git -C "$REPO" checkout "$BASE_BRANCH" >/dev/null 2>&1 || { echo "ERROR: could not restore '$BASE_BRANCH' from '$cur' — resolve by hand." >&2; exit "$(hl_rc "$HL_RC_CONFIG" 1)"; }
        cur="$BASE_BRANCH" ;;
      *) echo "ERROR: not on '$BASE_BRANCH' (on '$cur') — every worktree in this run forks from '$BASE_BRANCH' and every merge lands there, so a run started from here builds against a base you are not looking at." >&2
         echo "       git checkout $BASE_BRANCH   (or FORCE=1 to run anyway)" >&2
         exit "$(hl_rc "$HL_RC_CONFIG" 1)" ;;
    esac
  fi
  # A submodule whose working tree an earlier merge left behind reads exactly like
  # uncommitted work here, and neither a commit nor a stash nor FORCE=1-then-fix can
  # clear it — so make the tree honest before judging it (dirt_classify above).
  submodules_sync "$REPO" >&2
  if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]; then
    echo "ERROR: uncommitted tracked changes on '$BASE_BRANCH' — commit or stash them (or FORCE=1)." >&2
    echo "       This guards what the AGENT forks from, not the merge: every worktree is created" >&2
    echo "       from the '$BASE_BRANCH' tip, so work you have not committed is invisible to every" >&2
    echo "       tasklist in this run — the agent builds against a base you have moved past." >&2
    echo "       The merge is safe either way: it parks this repo's uncommitted changes for its" >&2
    echo "       critical section and gives them back, so editing this repo DURING a run is fine." >&2
    echo "       FORCE=1 is the right call when the uncommitted work is somewhere no tasklist" >&2
    echo "       in this run will look." >&2
    git -C "$REPO" status --short | head
    dirt_classify "$REPO" | grep -q '^subdirty ' && \
      echo "       A ' M <submodule>' line above is uncommitted work INSIDE that submodule — commit or stash it THERE; the superproject cannot." >&2
    exit "$(hl_rc "$HL_RC_CONFIG" 1)"
  fi
fi

# GIVE BACK what a killed run borrowed (harvested from the stale .critical markers
# above). This is the last of the three restore paths — the subshell's own EXIT trap
# covers a normal exit, teardown covers a signal, and this covers the case where
# neither ran at all. It is deliberately AFTER the gate: the tree the gate judged is
# the one the previous run left, not the one it was about to be handed back.
for e in $STALE_STASHES; do
  sr="${e%%|*}"; rest="${e#*|}"; ss="${rest%%|*}"; sn="${rest#*|}"
  git -C "$sr" cat-file -e "${ss}^{commit}" 2>/dev/null || continue
  echo "  (a previous run was killed mid-merge holding this repo's uncommitted changes in the stash — restoring them)" >&2
  merge_stash_pop "$sr" "$ss" "$sn" >&2 || true
done

# worker_park OUTCOME DETAIL MESSAGE — record a worker that stopped with its branch
# intact, and say so four ways at once.
#
# Five arms of run_worker end this way (an operator pause, an unformable plan, an
# unapproved one, a research phase that could not draw the map, and a branch held at
# an overlap zone), and each of them used to spell out the same five lines. They are
# the same transition, so they are
# one function: the four surfaces a stop has to
# reach — the liveliness record `chief ps` renders, the event a subscriber sees, the
# <name>.status line reap() maps to a scheduler state, and the human log — are
# written together or not at all. A future arm that writes only three of them is the
# bug this exists to make impossible.
#
# $live/$name/$total/$remaining/$STATE are the caller's, by dynamic scope (the same
# idiom as prd_state_source above). Returns 0; the caller still owns its `return`,
# because a helper cannot return out of run_worker for it.
worker_park() {
  local phase status ev state story
  story="$(live_get "$live" story)"
  case "$1" in
    # The operator pause is the only one that clears the story: a human stopped the
    # tasklist between stories, so naming one would imply a turn that never started.
    paused)          phase=operator-paused; status=PAUSED;          ev=tasklist.paused;          state=paused;          story="" ;;
    plan-invalid)    phase=plan-invalid;    status=PLAN-INVALID;    ev=tasklist.plan-invalid;    state=failed ;;
    # Research runs BEFORE the first story, so like the operator pause it names no
    # story — there was never a turn to name. It is a failure (nothing was built),
    # but an actionable one: the fix is usually to write the document by hand.
    research-failed) phase=research-failed; status=RESEARCH-FAILED; ev=tasklist.research-failed; state=failed; story="" ;;
    awaiting-review) phase=awaiting-review; status=AWAITING-REVIEW; ev=tasklist.awaiting-review; state=awaiting-review ;;
    # The one arm that fires INSIDE the merge phase, after the floor came back
    # green (engine/zones.sh). Its worktree is already gone — the merge phase
    # removes it to free the branch — so unlike its four siblings what is kept is
    # the BRANCH, rebased onto the latest base and verified.
    awaiting-approval) phase=awaiting-approval; status=AWAITING-APPROVAL; ev=tasklist.awaiting-approval; state=awaiting-approval ;;
    *) return 0 ;;
  esac
  live_set "$live" phase="$phase" story="$story"
  event_emit "$ev" name="$name" story="$story" state="$state" detail="$2"
  echo "$status $(( $(_int "$total") - $(_int "$remaining") ))/$total" > "$STATE/$name.status"
  echo "$3"
  return 0
}

# mark_reengage REASON — the pickup path is RE-ENGAGING a branch, and says so.
#
# Three ways a run picks up a branch that already claims to be finished: its verify
# failed post-rebase (the `persisted for re-engagement` path below), its pass-flags
# were a misfire with no commits behind them, or it will not rebase onto the base. All
# three send the agent back in, and none of them is a fresh start — but the display had
# no word for it, so the row read as whatever the PREVIOUS attempt left behind while
# the pickup rebuilt the worktree and re-integrated the base. That stretch is minutes,
# and on 2026-08-17 it was read as a hung run and killed.
#
# Two surfaces, written together: the live phase an operator sees while it happens, and
# an event that OUTLIVES it — the phase is gone the moment the agent turn starts, and
# "why was this branch run again?" is a question asked afterwards.
# $live/$name are the caller's, by dynamic scope (the same idiom as worker_park).
mark_reengage() {
  live_set "$live" phase=re-engaging story=
  event_emit tasklist.re-engaged name="$name" state=running detail="$1"
}

# ---------------------------------------------------------------------------
# Worker — one per tasklist. Runs the agent loop in an isolated worktree, then
# (serialized) rebases → verifies → merges. Writes $STATE/<name>.status + .log.
# ---------------------------------------------------------------------------
run_worker() {
  local name="$1" iters="$2"
  local wt="$WT_ROOT/$name" branch; branch="$(jq -r '.branchName' "$SRC/$name.json")"
  # WORK REPO: where this tasklist's branch/worktree/commits/merge happen. `repo`
  # defaults to "." (the project itself — unchanged behavior). `repo:<path>` targets
  # a submodule (or any nested git repo); its branch is merged into <path>'s own base
  # and the resulting pointer is bumped in the project. `baseBranch` overrides the
  # integration branch per tasklist (default: the project's base).
  local sub work_repo work_base repo
  repo="$(jq -r '.repo // "."' "$SRC/$name.json" 2>/dev/null)"; [ -z "$repo" ] && repo="."
  work_base="$(jq -r '.baseBranch // empty' "$SRC/$name.json" 2>/dev/null)"; [ -z "$work_base" ] && work_base="$BASE_BRANCH"
  if [ "$repo" = "." ]; then
    sub=""; work_repo="$REPO"
  else
    sub="$repo"; work_repo="$REPO/$repo"
  fi
  # This worker's liveliness record. Exported so the agent loop (a child process)
  # writes its per-iteration/story/turn fields into the SAME record — engine/live.sh
  # is read-modify-write, so the two sides own disjoint fields without clobbering.
  local live; live="$(live_of "$name")"
  CHIEF_LIVE_FILE="$live"; export CHIEF_LIVE_FILE
  : > "$STATE/$name.status"
  {
    echo "### worker $name  (branch $branch, iters $iters${sub:+, repo $sub})  $(date)"
    live_set "$live" name="$name" phase=worktree story= iter=0 stall=0 waits=0 retry_at=0
    if [ -n "$sub" ] && ! git -C "$work_repo" rev-parse --git-dir >/dev/null 2>&1; then
      event_emit tasklist.bad-repo name="$name" state=failed detail="repo '$sub' is not a git repo under $REPO"
      echo "BAD-REPO" > "$STATE/$name.status"; echo "!! $name: repo '$sub' is not a git repo under $REPO — skipping"; return 0
    fi
    local skip_agent=0
    local integrate_note=""      # set when integrate_base left an instruction for the agent
    local wtstate="$wt/$STATE_REL"
    sweep_worktree "$wt" "$name"                     # reclaim last run's build artifacts first
    wt_git remove --force "$wt" 2>/dev/null || true   # free a stale worktree dir (keeps the branch)
    rm -rf "$wt"
    # RESUME: if a branch from a prior (interrupted) run exists — a run stopped by
    # Ctrl-C, token/quota exhaustion, or lost connectivity — reuse it instead of
    # restarting from scratch. RESET=1 forces a fresh start from the base branch.
    if [ "${RESET:-0}" != "1" ] && git -C "$work_repo" rev-parse --verify --quiet "$branch" >/dev/null 2>&1; then
      local left bhw="" vfail=""
      left="$(prd_state_source | jq '[.userStories[]|select(.passes==false)]|length' 2>/dev/null || echo '?')"
      # Does the branch actually diverge from the base? A branch that EXISTS but has
      # no commits vs base carries no real work — its committed pass-state is
      # meaningless (often a false all-pass from a prior misfire). Never skip the
      # agent for one; re-run it so real work gets produced.
      [ -n "$(branch_has_real_work "$branch" "$name")" ] && bhw=1
      # A prior post-rebase verify failure (persisted below) means an all-pass branch
      # still isn't mergeable — re-engage the agent to fix it rather than re-verify a
      # branch that will just fail again.
      [ -f "$SNAP/$name.verify-failed.log" ] && vfail=1
      if [ "$left" = "?" ]; then
        echo ">> $name: branch $branch unreadable — resetting from $work_base"
        git -C "$work_repo" branch -D "$branch" 2>/dev/null || true
        wt_git add "$wt" -b "$branch" "$work_base" >/dev/null 2>&1 || { echo "WORKTREE-FAILED" > "$STATE/$name.status"; echo "!! could not create worktree"; return 0; }
      else
        wt_git add "$wt" "$branch" >/dev/null 2>&1 || { echo "WORKTREE-FAILED" > "$STATE/$name.status"; echo "!! could not attach worktree to $branch"; return 0; }
        # The two RE-ENGAGE arms each say it twice: once to the log for a human, once
        # into the record + event stream for everything else (mark_reengage above).
        if [ "$left" = "0" ] && [ -n "$vfail" ]; then
          echo ">> $name: branch $branch passes all stories but FAILED verify last run — re-engaging the agent to fix it"
          mark_reengage "every story passes but the branch failed verify post-rebase last run ($SNAP_REL/$name.verify-failed.log)"
        elif [ "$left" = "0" ] && [ -z "$bhw" ]; then
          echo ">> $name: branch $branch marks all stories done but has NO commits vs $work_base — re-running the agent (ignoring the false all-pass)"
          mark_reengage "every story is marked done with no commits vs $work_base — the pass-flags are a misfire"
        elif [ "$left" = "0" ]; then
          echo ">> $name: all stories already pass on $branch — skip agent, go to verify+merge"; skip_agent=1
        else
          echo ">> $name: RESUMING $branch ($left stor$([ "$left" = 1 ] && echo y || echo ies) left)"
        fi
        # PICKUP FRESHNESS (see integrate_base): a branch from a prior run starts
        # this run as far behind base as it stopped, so the merge phase inherits a
        # whole run's drift on top of whatever this run adds. Integrate it NOW.
        if ! integrate_base "$name" "$branch" "$wt" "$work_repo" "$work_base"; then
          integrate_note=1
          if [ "$skip_agent" = "1" ]; then
            # An all-pass branch that cannot rebase would otherwise walk straight
            # into a merge phase that is ALREADY KNOWN to conflict. Re-engage the
            # agent instead — integrating the base is work, and it has the context.
            skip_agent=0
            echo ">> $name: all stories pass but the branch will not rebase onto $work_base — re-engaging the agent to integrate the base instead of walking into a known merge-phase conflict"
            mark_reengage "every story passes but the branch will not rebase onto $work_base"
          fi
        fi
      fi
    else
      git -C "$work_repo" branch -D "$branch" 2>/dev/null || true
      wt_git add "$wt" -b "$branch" "$work_base" >/dev/null 2>&1 || { echo "WORKTREE-FAILED" > "$STATE/$name.status"; echo "!! could not create worktree"; return 0; }
    fi
    # A submodule doesn't gitignore chief's runtime state (only `chief init` adds that
    # to the project). Exclude .chief/ locally in the work-repo so the agent can't
    # stage it onto the submodule branch (which would count as bogus "work").
    if [ -n "$sub" ]; then
      local _ex; _ex="$(git -C "$wt" rev-parse --git-path info/exclude 2>/dev/null)"
      [ -n "$_ex" ] && ! grep -qxF '.chief/' "$_ex" 2>/dev/null && echo '.chief/' >> "$_ex" 2>/dev/null || true

      # NESTED SUBMODULES. `git worktree add` writes tracked files but leaves a
      # nested submodule as an EMPTY DIRECTORY — the worktree gets the gitlink and
      # no content. A repo that mounts a dependency that way (insimul/babylon
      # mounts packages/core, which ~264 of its files import) would hand the agent
      # a tree whose imports cannot resolve, and every build would fail for a
      # reason that has nothing to do with the story it was given.
      #
      # Scoped to submodule work-repos on purpose. A top-level PROJECT is often a
      # meta-repo whose submodules are the projects themselves — initializing all
      # of them for a docs tasklist would check out gigabytes nobody asked for.
      # A project repo that genuinely mounts a dependency as a submodule needs the
      # same treatment; do it explicitly rather than paying that cost by default.
      #
      # Non-fatal, but never silent: an empty directory that reads as a checkout
      # is exactly the failure this exists to prevent, so a failure to populate
      # is announced rather than left for the agent to trip over.
      if [ -f "$wt/.gitmodules" ]; then
        if git -C "$wt" submodule update --init --recursive >/dev/null 2>&1; then
          echo ">> $name: initialized nested submodule(s) in the worktree"
        else
          echo "!! $name: could not init nested submodule(s) in $wt — a mounted dependency is an EMPTY directory; builds that import it will fail"
        fi
      fi
    fi
    # Seed the ISOLATED runtime state (gitignored) from the BRANCH's committed
    # tasklist — carries the passes-state on a resume; equals the pristine template
    # on a fresh branch (which is at the base-branch tip).
    mkdir -p "$wtstate"
    prd_state_source > "$wtstate/prd.json" 2>/dev/null; [ -s "$wtstate/prd.json" ] || cp "$SRC/$name.json" "$wtstate/prd.json"
    echo "$branch" > "$wtstate/.last-branch"
    # SCOPE GATE (engine/criteria.sh): a criterion naming another repo cannot be met
    # from this worktree, so it is caught HERE — before the first agent turn, rather
    # than after a run's worth of them ends in a story that reports green because
    # nothing ever read it. Undeclared cross-repo work is what produced
    # cuneiform:346/US-3 and 347/US-4; declaring it (`"crossRepo": […]`) clears this.
    local outside; outside="$(criteria_scope_report "$wtstate/prd.json" "$wt")"
    if [ -n "$outside" ]; then criteria_scope_stop "$outside"; return 0; fi
    plan_sync "$SNAP/$name.plans" "$wtstate/plans"          # plans a prior run already paid for
    { echo "# Chief Progress — $name"; echo "Started: $(date)"; echo "---"; } > "$wtstate/progress.txt"
    # If the last run's rebased branch failed the verify gate, surface those errors
    # into the agent's log so this run fixes them before reporting COMPLETE again.
    if [ -f "$SNAP/$name.verify-failed.log" ]; then
      {
        echo; echo "## ⚠️ PRIOR VERIFICATION FAILED — FIX THESE BEFORE REPORTING COMPLETE"
        echo '```'; cat "$SNAP/$name.verify-failed.log"; echo '```'
      } >> "$wtstate/progress.txt"
    fi
    # An un-rebasable base is handed to the agent the same way a persisted verify
    # failure is: through the progress.txt it reads at the top of every iteration.
    # (Same injection the iteration-boundary hook uses when base drifts mid-run.)
    [ -n "$integrate_note" ] && inject_integrate_note "$wt"
    # Per-worktree WARM-UP. A fresh worktree has tracked files only — no gitignored
    # build deps (node_modules/.venv/dist). Each tasklist's optional "warmup":[...]
    # runs (cwd = worktree) to provision what its checks need, ISOLATED per worktree
    # (so no concurrent-install corruption).
    live_set "$live" phase=seeded \
      passing="$(jq '[.userStories[]?|select(.passes==true)]|length' "$wtstate/prd.json" 2>/dev/null || echo 0)" \
      total="$(jq '.userStories|length' "$wtstate/prd.json" 2>/dev/null || echo 0)"
    warmups="$(jq -r '(.warmup // [])[]' "$SRC/$name.json" 2>/dev/null)"
    if [ -n "$warmups" ]; then
      echo ">> $name warm-up…"
      live_set "$live" phase=warmup
      while IFS= read -r cmd; do
        [ -z "$cmd" ] && continue
        echo "   warm: $cmd"
        ( cd "$wt" && eval "$cmd" ) || echo "   (warm-up failed: $cmd — continuing; the agent may install on demand)"
      done <<< "$warmups"
    fi
    # Agent loop, fully isolated: the engine's agent.sh runs with the worktree as the
    # project root, so all its state + git ops resolve inside $wt. Skipped when
    # resuming a branch that already completed all stories.
    local agent_rc=0
    if [ "$skip_agent" != "1" ]; then
      live_set "$live" phase=agent-turn
      # MID-RUN RE-INTEGRATION: while this agent works, the serialized merge phase
      # keeps advancing base underneath it. agent.sh runs this hook at each
      # ITERATION BOUNDARY — never inside a turn — and it re-enters this script's
      # integrate_boundary()/integrate_base(), so the pickup path and this one can
      # never drift apart. CHIEF_PROJECT is pinned back to the project because the
      # agent's environment points it at the worktree.
      local hook
      hook="$(printf 'CHIEF_PROJECT=%q bash %q --integrate-base %q %q %q %q %q' \
                "$REPO" "$ENGINE/driver.sh" "$name" "$branch" "$wt" "$work_repo" "$work_base")"
      # OPERATOR-PAUSE DRAIN: the agent loop consults this flag at its ITERATION
      # BOUNDARY and exits $AGENT_RC_PAUSED. It is passed as an absolute path
      # because the agent's $CHIEF_PROJECT is the worktree, while the pause is a
      # property of the REPO's run — one flag, every worker, no per-worktree copy
      # that could go stale against `chief resume`.
      # CHIEF_TASKLIST names this worker's tasklist for the agent's event lines — the
      # runtime prd.json is a nameless copy, so without it a `story.passed` could not
      # say which tasklist it belongs to.
      ( cd "$wt" && CHIEF_PROJECT="$wt" CHIEF_HOME="$ENGINE" CHIEF_TASKLIST="$name" \
          CHIEF_PROVIDER="$PROVIDER" CHIEF_MODEL="$MODEL" CHIEF_TOOL="$TOOL" \
          CHIEF_STATE_DIR="$STATE_REL" CHIEF_TASKS_DIR="$TASKS_REL" \
          CHIEF_AGENT_CONTEXT="${CHIEF_AGENT_CONTEXT:-}" CHIEF_ITER_HOOK="$hook" \
          CHIEF_PAUSE_FILE="$OPERATOR_PAUSE_FILE" CHIEF_VERBOSE="${CHIEF_VERBOSE:-}" \
          CHIEF_ACCOUNT_ENV_FILE="$ACCOUNT_ENV_FILE" CHIEF_ACCOUNT_LABEL="$ACCOUNT_LABEL" \
          CHIEF_RESEARCH="${CHIEF_RESEARCH:-}" CHIEF_RESEARCH_FILE="$RESEARCH_DIR/$name.md" \
          "$ENGINE/agent.sh" "$iters" "--chief-run=$CHIEF_RUN_ID" ) && agent_rc=0 || agent_rc=$?
    fi
    # ISOLATION GUARD: the agent must only touch its runtime prd.json (and, for a
    # repo:"." tasklist, the copy inside its OWN worktree). A submodule worktree has no
    # tasks/ dir, so agents sometimes reach OUT and flip pass-flags in the PROJECT's
    # tracked tasklist. That stray edit is never the source of truth (the snapshot +
    # runtime prd.json are), and leaving it dirty breaks two things: `git rm` refuses to
    # retire a modified file (the tasklist stays "pending" forever), and a tasklist that
    # never completes leaves the project tree dirty enough to fail the next run's
    # clean-tree preflight.
    # Serialized: this mutates the SHARED project index while sibling workers may be
    # retiring their own tasklists. Racing them made `git rm` lose the index.lock and
    # fail silently, leaving merged tasklists un-retired.
    live_set "$live" phase=reconcile
    idx_lock
    git -C "$REPO" checkout -- "$TASKS_REL/$name.json" 2>/dev/null || true
    idx_unlock
    # Reconcile: a story is done if EITHER the runtime prd.json or the branch's
    # tracked tasklist marks it passed.
    node -e '
      const fs=require("fs");
      const rt=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      let tr={}; try { for (const s of (JSON.parse(fs.readFileSync(process.argv[2],"utf8")).userStories||[])) tr[s.id]=s.passes; } catch(e){}
      let n=0; for (const s of rt.userStories) if (!s.passes && tr[s.id]) { s.passes=true; n++; }
      if (n) fs.writeFileSync(process.argv[1], JSON.stringify(rt,null,2)+"\n");
    ' "$wtstate/prd.json" "$wt/$TASKS_REL/$name.json" 2>/dev/null || true
    # Did the branch actually produce commits vs the base? This is the ground truth
    # a JSON pass-flag can lie about — an agent that declared COMPLETE against a
    # stale/wrong tasklist and committed nothing must NOT merge+retire (the
    # "false-merge" class). agent.sh exits 0 ONLY when it emitted <promise>COMPLETE</promise>.
    local has_work=""
    [ -n "$(branch_has_real_work "$branch" "$name")" ] && has_work=1
    # The same diff as a LIST, for the under-tagged-touches audit. Taken here, not
    # in the merge phase, so a branch that ends INCOMPLETE or conflicts is audited
    # too — those are the runs where a mis-tagged pair costs the most.
    audit_record_files "$name" "$branch"
    # Trust an explicit COMPLETE from an agent that DID commit real work: mark the
    # stories it left stale-false as passed so the branch proceeds to the verify gate
    # (verify — not the pass-flags — is the real merge bar). Not unconditionally —
    # evidence_gate promotes only the ones whose `notes` say how, and reports the rest.
    local unevidenced="" unmeasured=""
    if [ "$agent_rc" = "0" ] && [ "$skip_agent" != "1" ] && [ -n "$has_work" ]; then
      unevidenced="$(evidence_gate "$wtstate/prd.json")"
    fi
    unmeasured="$(measure_gate "$wtstate/prd.json")"   # EVERY path to a merge — engine/measure.sh
    local remaining total
    remaining="$(jq '[.userStories[]|select(.passes==false)]|length' "$wtstate/prd.json" 2>/dev/null || echo '?')"
    total="$(jq '.userStories|length' "$wtstate/prd.json" 2>/dev/null || echo '?')"
    cp "$wtstate/prd.json" "$SNAP/$name.json" 2>/dev/null || true
    plan_sync "$wtstate/plans" "$SNAP/$name.plans"          # bank what this run planned
    # _int() (defined with the self-heal helpers below, resolved at call time) keeps
    # an unreadable prd.json's '?' out of the arithmetic.
    live_set "$live" passing="$(( $(_int "$total") - $(_int "$remaining") ))" total="$(_int "$total")"
    # USAGE-LIMIT PAUSE: agent.sh exits $AGENT_RC_LIMIT when it stopped on a Claude
    # usage/session limit and won't retry. That is NOT a failure — the branch is fine,
    # it is only blocked until the window resets — so record a distinct, non-terminal
    # status and keep the branch + worktree for a resume. Checked BEFORE the no-work
    # and INCOMPLETE guards: a limit hit on the first turn legitimately leaves zero
    # commits, and mislabelling that EMPTY-NO-WORK would make it look false-complete.
    if [ "$agent_rc" = "$AGENT_RC_LIMIT" ]; then
      # Hand the scheduler the reset ETA agent.sh parsed out of the real limit
      # message (epoch). Absent/garbled, the scheduler falls back to its own
      # bounded backoff — but when it IS there, driver and worker agree on the
      # window because exactly one parser produced it.
      local retry_at; retry_at="$(cat "$wtstate/.limit-retry-at" 2>/dev/null || echo)"
      case "$retry_at" in ''|*[!0-9]*) retry_at="" ;; esac
      rm -f "$STATE/$name.retry-at"
      [ -n "$retry_at" ] && printf '%s' "$retry_at" > "$STATE/$name.retry-at"
      live_set "$live" phase=rate-limited retry_at="$(_int "$retry_at")"
      # The limit block projects the accounting that ALREADY happened here: the ETA
      # agent.sh parsed out of the provider's own message, and the wait count its
      # live record carries. Nothing is asked of the provider to fill it in — this is
      # the quota half of the data source chief-cloud's cost ledger persists.
      event_emit tasklist.rate-limited name="$name" state=rate-limited \
        limit_hit=1 retry_at="$retry_at" waits="$(live_get "$live" waits)" \
        detail="usage limit — branch kept${retry_at:+, reset ETA $retry_at}"
      echo "RATE-LIMITED $(( total - remaining ))/$total" > "$STATE/$name.status"
      echo "!! $name PAUSED on a Claude usage/session limit — branch $branch kept intact; resumes from its passes state${retry_at:+ (reset ETA $retry_at)}"
      return 0
    fi
    # THE PRE-GUARD PARKS (this arm and the three below it). Four agent exits stop
    # BEFORE the no-work and INCOMPLETE guards, because each legitimately leaves zero
    # commits and calling that EMPTY-NO-WORK would fail a tasklist for doing as it was
    # told: an operator pause armed at an iteration boundary, a plan that would not
    # form, a plan nobody has approved, and a research phase that could not draw the
    # map. ($AGENT_RC_UNVERIFIED, below them, sits above the same guards for the
    # mirror-image reason — see its own note.) All four keep branch AND worktree (we return before the merge phase, the
    # only thing that removes one), so the RESUME path picks them up from their
    # committed passes state with nothing rebuilt.
    #
    # The one case that does NOT park: a drain that found every story passing with
    # real commits behind them. Finishing that is verify+merge — cheap, agent-free
    # work — and a pause withholds AGENT TURNS, not the completion of finished work.
    # Parking it would strand a mergeable branch, and its dependents, for as long as
    # the (unbounded) hold lasts.
    if [ "$agent_rc" = "$AGENT_RC_PAUSED" ] && { [ "$remaining" != "0" ] || [ -z "$has_work" ]; }; then
      worker_park paused "operator pause — branch + worktree kept" \
        "!! $name PARKED on an OPERATOR PAUSE — branch $branch and its worktree kept; 'chief resume' continues from its passes state"
      return 0
    fi
    if [ "$agent_rc" = "$AGENT_RC_PAUSED" ]; then
      echo ">> $name drained on an OPERATOR PAUSE with all $total stor$([ "$total" = 1 ] && echo y || echo ies) passing — finishing verify+merge (a pause withholds agent turns, not finished work)"
    fi
    # The other two pre-guard parks (docs/plan-review.md). $AGENT_RC_PLAN is a plan
    # that would not form — a failed tasklist, but a NAMED one. $AGENT_RC_REVIEW is a
    # well-formed plan NO HUMAN HAS APPROVED, which reap() maps to the NON-terminal
    # 'awaiting-review' so dependents stay pending and the next run reads the verdict.
    if [ "$agent_rc" = "$AGENT_RC_PLAN" ]; then
      worker_park plan-invalid "the plan turn wrote no well-formed plan artifact — branch + worktree kept" \
        "!! $name stopped in the PLAN phase — no well-formed plan artifact (docs/plan-review.md); branch $branch and its worktree kept"
      return 0
    fi
    if [ "$agent_rc" = "$AGENT_RC_REVIEW" ]; then
      worker_park awaiting-review "the plan is unapproved and no reviewer could be reached — branch + worktree + plan kept" \
        "!! $name PARKED AWAITING REVIEW — its plan needs a human (docs/plan-review.md); branch $branch, its worktree and the plan are kept, and re-running resumes from an approval already given"
      return 0
    fi
    # RESEARCH FAILURE — the sharpest case of the reason above: the phase runs before
    # the FIRST story, so nothing was ever implemented. The map is reused verbatim and
    # never regenerated, so writing it by hand is the fix — which is what we say.
    if [ "$agent_rc" = "$AGENT_RC_RESEARCH" ]; then
      worker_park research-failed "the research phase produced no valid document — branch + worktree kept" \
        "!! $name RESEARCH FAILED — nothing was implemented. Write or repair $RESEARCH_REL/$name.md by hand (it is reused as-is), or re-run with CHIEF_RESEARCH=0 to skip the phase"
      return 0
    fi
    # UNVERIFIED IN-RUN — agent.sh stopped ITSELF at an iteration boundary, having
    # demoted the same story MEASURE_DEMOTE_LIMIT times running (its _measure_boundary).
    # Above the no-work guard for the mirror of the parks' reason: the stop can leave
    # zero commits and can equally leave a branch full of them, and neither is
    # EMPTY-NO-WORK. Why the report comes off disk rather than from `unmeasured` above:
    # see unmeasured_stop's header in engine/measure.sh.
    if [ "$agent_rc" = "$AGENT_RC_UNVERIFIED" ]; then
      echo "!! $name stopped MID-RUN on the bar rule — the same story was demoted at consecutive iteration boundaries with no observed value ever recorded; the rest of the loop was not spent re-marking it"
      unmeasured_stop "$(cat "$wtstate/.demoted.md" 2>/dev/null || echo '   ✗ (the boundary report was not kept)')"
      return 0
    fi
    # NO-WORK GUARD: an all-"pass" branch with zero diff vs base never did the work.
    # Fail it (dependents stay blocked) instead of silently merging an empty branch.
    if [ -z "$has_work" ]; then
      live_set "$live" phase=empty-no-work
      event_emit tasklist.no-work name="$name" state=failed detail="false-complete guard: no commits vs $work_base"
      echo "EMPTY-NO-WORK 0/$total" > "$STATE/$name.status"
      echo "!! $name produced NO commits vs $work_base${sub:+ in $sub} — not merging/retiring (false-complete guard)"; return 0
    fi
    # EVIDENCE + BAR GUARDS: a story the COMPLETE path wanted promoted that says
    # nothing about how it was done, and one claiming a bar with no value measured
    # against it. Both ordered BEFORE the INCOMPLETE arm — see unverified_stop.
    [ -n "$unevidenced" ] && { unverified_stop "$unevidenced"; return 0; }
    [ -n "$unmeasured" ] && { unmeasured_stop "$unmeasured"; return 0; }
    if [ "$remaining" != "0" ]; then
      live_set "$live" phase=incomplete
      event_emit tasklist.incomplete name="$name" state=failed detail="$(( total - remaining ))/$total stories passing when the iteration budget ran out"
      echo "INCOMPLETE $(( total - remaining ))/$total" > "$STATE/$name.status"
      echo "!! $name INCOMPLETE — branch $branch left in worktree for review"; return 0
    fi
    if [ "$AUTO_MERGE_MAIN" != "1" ]; then
      live_set "$live" phase=complete-unmerged story=
      event_emit tasklist.complete-unmerged name="$name" state=done detail="auto-merge off — branch $branch"
      echo "COMPLETE-UNMERGED $total/$total" > "$STATE/$name.status"
      echo ">> $name complete (auto-merge off) — branch $branch"; return 0
    fi
    # ---- MERGE QUEUE (opt-in; engine/mergequeue.sh) --------------------------
    # The ONE fork in the merge phase, and it is closed unless an operator opened it.
    # With MERGE_BATCH=1 — the default — mq_enabled is false and everything below runs
    # exactly as it always has. With batching on, a branch that may ride in a batch is
    # handed to the queue (which races for this same $MERGE_LOCK and writes the same
    # <name>.status reap() reads); a branch that may NOT — its own `verify` array, or a
    # `review` overlap zone — falls through to the floor, which is where it belongs.
    mq_enabled && mq_take_merge "$name" "$branch" "$work_repo" "$work_base" "$sub" "$wt" && return 0
    # ---- SERIALIZED merge phase (only one tasklist touches main at a time) ----
    local waited=0
    live_set "$live" phase=merge-wait
    while ! mkdir "$MERGE_LOCK" 2>/dev/null; do sleep 2; waited=$(( waited + 1 )); live_set "$live"; done
    echo ">> $name acquired merge lock after ${waited}x2s"
    (
      # Rebase/verify/merge happen in the WORK repo (the submodule for `repo:<sub>`,
      # else the project). On exit, restore its base branch. For a submodule the
      # project itself is never checked out onto a branch — only its pointer is bumped.
      # CRITICAL SECTION. From here until this subshell exits the WORK REPO is mid
      # git operation (checkout → rebase → verify → merge); a kill landing inside it
      # is what strands a repo needing manual `git rebase --abort`. The marker tells
      # the driver's teardown to wait this out before it reaps, and names the repo +
      # base to restore if the wait is spent. Removed on every exit path.
      #
      # The trap also gives back whatever uncommitted work the operator had in this
      # checkout (merge_stash_push/pop above). It reads $mstash at FIRE time, which is
      # why it is armed BEFORE the push: a kill landing between the two would other-
      # wise be the one window where the stash has no restorer. Declared empty first:
      # under `set -u` the trap must be able to read it even if the subshell dies
      # before the push assigns it.
      local mstash=""
      trap 'work_checkout "$work_repo" "$work_base" "$name" || true; merge_stash_pop "$work_repo" "$mstash" "$name" || echo "$work_repo|$mstash" > "$STATE/$name.stash"; rm -f "$STATE/$name.critical" 2>/dev/null' EXIT
      merge_critical_enter "$work_repo" "$name" "$work_base"; mstash="$MERGE_STASH"
      # Free the branch from its worktree so the work repo can check it out. The
      # sweep goes first: this is the last moment anyone looks at that directory, and
      # a `git worktree remove` that fails here is what strands a 1.4 GB `target`
      # behind a tasklist that finished cleanly.
      sweep_worktree "$wt" "$name"
      wt_git remove --force "$wt" 2>/dev/null || true
      # work_checkout, never a bare `git checkout` — a gitlink the ref moves and the
      # working tree does not is not uncommitted work (see its header).
      work_checkout "$work_repo" "$branch" "$name" || { live_set "$live" phase=checkout-failed
          event_emit tasklist.checkout-failed name="$name" state=failed detail="git checkout $branch failed in $work_repo"
          echo "CHECKOUT-FAILED" > "$STATE/$name.status"; exit 0; }
      # The fork point, read BEFORE the rebase rewrites the branch onto base — it is
      # what makes "which commits landed on base under this file" answerable in
      # EITHER conflict arm (see conflict_report). One rev-parse on the happy path.
      local pre_mb rpt refusal rb_out rb_rc=0 conflicted
      pre_mb="$(git -C "$work_repo" merge-base "$branch" "$work_base" 2>/dev/null || echo)"
      # Rebase onto the LATEST base (may have advanced since we branched).
      #
      # NOT every failed rebase is a merge conflict. Git also REFUSES to rebase a
      # dirty or half-operated-on repo, and that refusal used to be reported as a
      # REBASE-CONFLICT whose conflicted-file list read "git reported none" — a false
      # positive that parks a perfectly mergeable branch. So: diagnose the knowable
      # refusals up front, and after a failure let the INDEX decide which arm this is
      # (≥1 unmerged path = a real content conflict; zero = a refusal).
      live_set "$live" phase=rebasing
      refusal="$(rebase_refusal_cause "$work_repo")"
      if [ -z "$refusal" ] && git -C "$work_repo" merge-base --is-ancestor "$work_base" "$branch" 2>/dev/null; then
        # Strictly AHEAD of base (base is an ancestor of the branch) → the rebase is a
        # NO-OP: there is nothing on base left to replay onto. git agrees ("Current
        # branch is up to date") but it still has to open and lock the repo to say so,
        # and that is exactly where an environment fault turns a guaranteed no-op into a
        # non-zero exit — the field case this arm exists for (three branches strictly
        # ahead of main, every one parked as REBASE-CONFLICT). Don't ask the question.
        echo ">> $name: $branch is strictly ahead of $work_base — rebase is a no-op, skipping it"
      elif [ -z "$refusal" ]; then
        rb_out="$(git -C "$work_repo" rebase "$work_base" 2>&1)" || rb_rc=$?
        if [ "$rb_rc" != 0 ]; then
          # Read the index BEFORE the abort discards it — in EITHER arm.
          conflicted="$(git -C "$work_repo" diff --name-only --diff-filter=U 2>/dev/null)"
          if [ -n "$conflicted" ]; then
            # Forensics FIRST: the unmerged paths live in the index the abort discards.
            rpt="$SNAP/$name.rebase-conflict.md"
            conflict_report "$name" "$branch" "$work_repo" "$work_base" "$pre_mb" "REBASE-CONFLICT" "$rpt"
            rm -f "$SNAP/$name.merge-conflict.md" "$SNAP/$name.rebase-refused.md" 2>/dev/null || true
            git -C "$work_repo" rebase --abort 2>/dev/null || true
            live_set "$live" phase=rebase-conflict
            event_emit tasklist.rebase-conflict name="$name" state=failed detail="onto $work_base; forensics: $rpt"
            echo "REBASE-CONFLICT see $SNAP_REL/$name.rebase-conflict.md" > "$STATE/$name.status"
            echo "!! $name rebase conflict onto $work_base${sub:+ in $sub} — left for manual merge; what collided and with whom: $rpt"; exit 0
          fi
          # Refused (or stopped for a non-content reason). Git's own message is the
          # most accurate cause there is, so prefer it; then the pre-flight's reading
          # of the repo; then an honest admission rather than an invented conflict.
          refusal="$(printf '%s\n' "$rb_out" | sed -e 's/^[[:space:]]*//' -e '/^$/d' \
                       -e 's/^error: //' -e 's/^fatal: //' | head -3 | tr '\n' ' ' \
                       | sed -e 's/  */ /g' -e 's/ *$//' | cut -c1-200)"
          [ -n "$refusal" ] || refusal="$(rebase_refusal_cause "$work_repo")"
          [ -n "$refusal" ] || refusal="git rebase exited $rb_rc, left no conflicted paths, and printed nothing"
          git -C "$work_repo" rebase --abort 2>/dev/null || true
        fi
      fi
      if [ -n "$refusal" ]; then
        # A refusal is an ENVIRONMENT fault, not a collision: nothing merged, nothing
        # rewritten, $branch still exactly as the agent left it. It gets its OWN note —
        # conflict_report()'s runbook ("resolve inside the rebase") is the wrong advice
        # for a repo that could not start one. Stale conflict forensics from a previous
        # attempt would assert a collision that did not happen, so they go.
        rpt="$SNAP/$name.rebase-refused.md"
        refusal_report "$name" "$branch" "$work_repo" "$work_base" "$refusal" "$rpt"
        rm -f "$SNAP/$name.rebase-conflict.md" "$SNAP/$name.merge-conflict.md" 2>/dev/null || true
        live_set "$live" phase=rebase-refused
        event_emit tasklist.rebase-refused name="$name" state=failed detail="$refusal"
        echo "REBASE-REFUSED $refusal (see $SNAP_REL/$name.rebase-refused.md)" > "$STATE/$name.status"
        echo "!! $name: git REFUSED to rebase $branch onto $work_base${sub:+ in $sub} — this is NOT a content conflict (no conflicted paths): $refusal"
        echo "!! $name: nothing was merged and $branch is untouched — the cause and the command that clears it: $rpt"; exit 0
      fi
      submodules_sync "$work_repo" "$name"   # the replay may have moved a gitlink too
      # Re-verify the REBASED branch against the latest base, IN the work repo. On
      # failure, PERSIST the output to snapshots/<name>.verify-failed.log so the NEXT
      # run re-engages the agent (instead of skip-agent → re-verify → fail forever).
      if [ "$NO_VERIFY" != "1" ]; then
        echo ">> verifying $branch (rebased${sub:+, in $sub})"
        local vout vrc
        live_set "$live" phase=verifying
        vout="$(run_verify "$work_repo" "$name" 2>&1)"; vrc=$?
        printf '%s\n' "$vout"
        if [ "$vrc" != "0" ]; then
          printf '%s\n' "$vout" > "$SNAP/$name.verify-failed.log"
          live_set "$live" phase=verify-failed
          event_emit tasklist.verify-failed name="$name" state=failed detail="verify exited $vrc post-rebase; log: $SNAP_REL/$name.verify-failed.log"
          echo "VERIFY-FAILED" > "$STATE/$name.status"; echo "!! $name verify failed post-rebase (persisted for re-engagement)"; exit 0
        fi
      fi
      # ---- THE POLICY LAYER: a green gate is not always enough authority --------
      # AFTER the floor, never instead of it (engine/zones.sh + engine/budget.sh): a
      # non-zero return means "held — do not merge", and it has already said why.
      # One gate, one approval — a declared zone and an oversized story never both ask.
      if ! zones_merge_gate "$name" "$branch" "$work_repo" "$work_base" "$STATE" \
                            "$(touches_of "$name" | tr '\n' ' ')"; then
        worker_park awaiting-approval "the merge policy layer (overlap zone / diff budget) — rebased + verified, held for a human" \
          "   Branch $branch is kept (rebased, green) — approve what no gate can check, then re-run:  chief approve $name && chief run"
        exit 0
      fi
      live_set "$live" phase=merging
      work_checkout "$work_repo" "$work_base" "$name"
      if git -C "$work_repo" merge --no-ff "$branch" -m "Merge $branch (chief, auto-verified)"; then
        sha="$(git -C "$work_repo" rev-parse --short HEAD)"
        # finalize writes the completed record + retires the tasklist in the PROJECT,
        # and (for a submodule) bumps the project's pointer to the merged submodule sha.
        finalize_merged "$name" "$branch" "$sha" "$work_repo" "$sub"
        # cleared: this branch is green + merged, so every failure artifact from a
        # previous attempt (verify output, conflict forensics) is now stale.
        # The zone request + verdict go with them: the change they were about is now
        # ON the base, and a verdict that outlived its subject can only mislead.
        rm -f "$SNAP/$name.verify-failed.log" "$SNAP/$name.rebase-conflict.md" \
              "$SNAP/$name.merge-conflict.md" "$SNAP/$name.rebase-refused.md" \
              "$(zones_request_file "$STATE" "$name")" "$(zones_approval_file "$STATE" "$name")" 2>/dev/null || true
        live_set "$live" phase=merged story=
        event_emit tasklist.merged name="$name" state=done detail="$branch --no-ff into $work_base @$sha${sub:+ ($sub)}"
        echo "MERGED @$sha${sub:+ ($sub)}" > "$STATE/$name.status"; echo ">> $name MERGED @$sha${sub:+ in $sub}"
        # Under-tagging this branch shared with a co-scheduled peer, reported into
        # this worker's log as soon as it is knowable (peers that have not finished
        # their agent phase yet have no file set — the end-of-run summary is the
        # complete pass). Reporting only; the merge already happened.
        local af; af="$(audit_findings "$name")"
        [ -n "$af" ] && printf '%s\n' "$af"
      else
        # Same report, same shape — a conflict here is rarer (the branch just
        # rebased cleanly) but leaves a human in exactly the same position.
        rpt="$SNAP/$name.merge-conflict.md"
        conflict_report "$name" "$branch" "$work_repo" "$work_base" "$pre_mb" "MERGE-CONFLICT" "$rpt"
        rm -f "$SNAP/$name.rebase-conflict.md" "$SNAP/$name.rebase-refused.md" 2>/dev/null || true
        git -C "$work_repo" merge --abort 2>/dev/null || true
        live_set "$live" phase=merge-conflict
        event_emit tasklist.merge-conflict name="$name" state=failed detail="merging into $work_base; forensics: $rpt"
        echo "MERGE-CONFLICT see $SNAP_REL/$name.merge-conflict.md" > "$STATE/$name.status"
        echo "!! $name merge conflict — what collided and with whom: $rpt"
      fi
    )
    rmdir "$MERGE_LOCK" 2>/dev/null || true
  } >> "$STATE/$name.log" 2>&1
  # APPEND, not truncate: a tasklist can be dispatched more than once in a run
  # (usage-limit re-dispatch), and overwriting would erase the attempt that
  # explains the pause. The scheduler truncates the log once, at launch-time init.
}

# ---------------------------------------------------------------------------
# Scheduler (bash 3.2 — poll loop; state on the filesystem)
# ---------------------------------------------------------------------------
# Clear the USAGE-LIMIT window only. A reset ETA from a previous run is meaningless
# now, so the run starts with the account presumed available. $OPERATOR_PAUSE_FILE is
# pointedly NOT cleared here: pausing a repo and then starting a run must not lift the
# pause — Chief never revokes a human's hold, `chief resume` does (see the header).
rm -f "$LIMIT_PAUSE_FILE"
rm -f "$STATE/.cosched"     # the co-scheduling relation is per-run, not cumulative
for n in $NAMES; do
  set_state "$n" pending
  rm -f "$STATE/$n.why" "$STATE/$n.retry-at" "$STATE/$n.retries" "$STATE/$n.attempts" \
        "$STATE/$n.files" "$STATE/$n.touches"
  : > "$STATE/$n.log"     # run_worker APPENDS (it may be dispatched more than once)
done
echo "Chief PARALLEL run — tool=$TOOL  max-parallel=$PARALLEL  auto-merge=$AUTO_MERGE_MAIN  verify=$([ "$NO_VERIFY" = 1 ] && echo off || echo on)$(mq_enabled && printf '  merge-batch=%s' "$(mq_batch_max)")"
echo "Pending:$NAMES"; echo

# Block-and-explain UP FRONT anything whose deps can never be satisfied in this
# run — before spending hours on the rest. Marking them 'blocked' (not 'pending')
# also lets dep_broken() cascade the reason to everything downstream.
any_blocked=""
for n in $NAMES; do
  why=""
  for d in $(deps_of "$n"); do
    is_recorded_done "$d" && continue
    r="$(dep_why "$d")"; [ "$r" = "scheduled" ] && continue
    why="$why
needs \"$d\", which cannot complete in this run: $r"
  done
  [ -z "$why" ] && continue
  set_state "$n" blocked
  printf '%s\n' "${why#?}" > "$STATE/$n.why"
  [ -z "$any_blocked" ] && echo "  ⤬ Some tasklists can never start in this run:"
  any_blocked=1
  echo "  ⤬ $n BLOCKED"
  sed 's/^/       /' "$STATE/$n.why"
done
if [ -n "$any_blocked" ]; then
  echo "     Fix: land the dependency, drop the dependsOn edge, or — once the work has"
  echo "     really merged elsewhere — record it: echo '{\"mergedToMain\":true}' > $TASKS_REL/completed/<dep>.json"
  echo "     (docs/reference/cross-repo-dependencies.md)"
  echo
fi

# --- usage-limit self-heal (see SCHEDULER STATES in the header) --------------
# All state on the filesystem, integers only — bash 3.2, no associative arrays.
_int()          { case "${1:-}" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
retries_used()  { _int "$(cat "$STATE/$1.retries" 2>/dev/null)"; }
# Attempts spent on FAILURE retries. Deliberately a separate counter from .retries (the
# usage-limit re-dispatch budget): one tasklist can hit a usage limit AND fail its gate,
# and spending one budget on the other would silently shorten both.
attempts_used() { _int "$(cat "$STATE/$1.attempts" 2>/dev/null)"; }

# Which failures are worth another agent. An allowlist, NOT "anything that is not done" —
# a retry costs a full agent run, so it is spent only where a second attempt can plausibly
# succeed:
#
#   VERIFY-FAILED    the gate failed. Flaky (a timeout under load) or fixable — and the
#                    agent is re-engaged with the failure log persisted for it to read.
#   MERGE-CONFLICT   the branch collided with what landed while it worked. Chief's pickup
#   REBASE-CONFLICT  path already re-engages the agent to integrate; this gets it there
#                    automatically instead of waiting for an operator.
# THE PRINCIPLE: retry INTEGRATION failures, never PRODUCTION failures. The three above
# all mean "the work exists and is plausibly good, but the step that lands it failed" —
# a gate that flaked, or a base that moved underneath it. A second agent run genuinely
# fixes those. The ones below mean "the agent did not produce the work", which running the
# same agent again does not fix; it just spends the budget twice to learn the same thing.
#
# NOT retried, and each for its own reason:
#
#   INCOMPLETE       the agent spent its ENTIRE iteration budget and still did not finish.
#                    The most expensive thing to retry and the least likely to be
#                    transient — another `iters` worth of tokens to reach the same wall.
#                    Raising `iters` is the operator's call, not something Chief should do
#                    silently by tripling the budget.
#   EMPTY-NO-WORK    the false-complete guard fired: the agent claimed COMPLETE having
#                    committed nothing. That is a misbehaving agent, and the run should
#                    surface it rather than quietly paying for two more of the same.
#   CHECKOUT-FAILED  environmental or configuration faults. The tree, the repo or the
#   WORKTREE-FAILED  tasklist is wrong, and running the agent again cannot fix any of
#   BAD-REPO         them — it would just burn tokens against a broken setup.
#   UNKNOWN
#   REBASE-REFUSED   git declined to rebase at all (dirty work repo, a leftover
#                    rebase/merge state, an unreadable repo). No content collided, so
#                    there is nothing for an agent to integrate — the repo needs a
#                    human. Retrying would re-refuse for the same reason, forever.
#
# INCOMPLETE and EMPTY-NO-WORK are also load-bearing for the SCHEDULER: a genuine stall is
# TERMINAL, which is what blocks its dependents, while a usage-limit pause is not. Making
# either retryable blurs that distinction and leaves dependents neither blocked nor
# progressing — caught by test/limitstate.sh, which is how both got here.
# Deliberately NOT retryable: PLAN-INVALID. The three above are transient-shaped (a
# flaky test, a base that moved), so another attempt is a real chance. A plan turn
# that produced no well-formed artifact is a comprehension failure — usually a story
# whose criteria the agent could not turn into a file list — and re-running it spends
# another turn to reach the same wall while burying the one signal an operator needs.
retryable_status() {
  case "$1" in
    # Named ABOVE the catch-all on purpose. REBASE-REFUSED would fall through to it
    # and be denied anyway, but the deny is the whole point of the state: it is the
    # one failure here that shares a shape with the retryable three (the work exists,
    # the step that lands it failed) while sharing none of their cause. A retry buys a
    # REBASE-CONFLICT a moved base; a refusal has no such property — nothing about the
    # operator's checkout changes because chief ran the agent again. Spelling it out
    # keeps a future edit to the allowlist from silently re-admitting it.
    REBASE-REFUSED*) return 1 ;;
    VERIFY-FAILED*|MERGE-CONFLICT*|REBASE-CONFLICT*) return 0 ;;
    *) return 1 ;;
  esac
}
retry_at_of()   { _int "$(cat "$STATE/$1.retry-at" 2>/dev/null)"; }
pause_until()   { _int "$(cat "$LIMIT_PAUSE_FILE" 2>/dev/null)"; }
eta()           { date -r "$1" '+%H:%M' 2>/dev/null || date -d "@$1" '+%H:%M' 2>/dev/null || echo "$1"; }

# --- operator pause (see OPERATOR PAUSE in the header) -----------------------
# PRESENCE is the gate, not the content: a truncated or garbled flag file must still
# hold the run. Chief may never revoke a human's pause on its own, least of all
# because it failed to parse one — so the read that decides is `[ -f ]`, and _int()
# (the same idiom pause_until() uses) is applied only to the informational stamp.
# Neither of these touches $LIMIT_PAUSE_FILE: the two pauses never read or write
# each other's state, and while both are armed the run is held by both.
op_paused()       { [ -f "$OPERATOR_PAUSE_FILE" ]; }
op_paused_since() { _int "$(cat "$OPERATOR_PAUSE_FILE" 2>/dev/null)"; }

# Arm the pause after a worker stopped on a limit. Prefer the reset epoch the
# worker recorded (agent.sh's parse of the real message); else back off. The
# pause is GLOBAL and takes the LATEST known reset: one account = one window, so
# relaunching anything before then just burns another worker on the same wall.
limit_pause() {
  local n="$1" now ra cap
  now="$(date +%s)"; ra="$(retry_at_of "$n")"; cap=$(( now + RATE_LIMIT_REDISPATCH_MAX_WAIT ))
  [ "$ra" -eq 0 ]     && ra=$(( now + RATE_LIMIT_REDISPATCH_WAIT ))   # no ETA -> backoff
  [ "$ra" -lt "$now" ] && ra="$now"                                   # window already reopened
  [ "$ra" -gt "$cap" ] && ra="$cap"
  printf '%s' "$ra" > "$STATE/$n.retry-at"
  # Publish the SCHEDULER's ETA (it may have clamped the worker's) so the monitor
  # renders the window the run will actually wait out.
  live_set "$(live_of "$n")" phase=rate-limited retry_at="$ra"
  [ "$ra" -gt "$(pause_until)" ] && printf '%s' "$ra" > "$LIMIT_PAUSE_FILE"
  return 0
}

limit_retryable() {   # paused tasklists that still have re-dispatches left
  local n
  for n in $NAMES; do
    [ "$(get_state "$n")" = "rate-limited" ] || continue
    [ "$(retries_used "$n")" -lt "$RATE_LIMIT_REDISPATCH_MAX" ] && printf '%s ' "$n"
  done
}
pending_names() { local n; for n in $NAMES; do [ "$(get_state "$n")" = "pending" ] && printf '%s ' "$n"; done; }

# Called when nothing is running. Waits out an armed limit window and re-arms the
# paused tasklists as 'pending' so the launch loop picks them up again (run_worker
# RESUMEs the existing branch from its committed passes state — nothing rebuilt).
# Anything the pause itself held back rides along: the gate reopens in the same
# breath, so those launch right after. Returns 1 when no tasklist has re-dispatch
# budget left — spending the cap ENDS the run rather than waiting on a window
# nothing is allowed to use.
limit_resume() {
  local retryable now target n
  retryable="$(limit_retryable)"
  [ -z "$retryable" ] && return 1
  now="$(date +%s)"; target="$(pause_until)"
  if [ "$target" -gt "$now" ]; then
    echo "  ⏸ usage limit — the run is PAUSED until ~$(eta "$target") ($(( (target - now + 59) / 60 )) min), then resumes: $retryable$(pending_names)"
    while [ "$(date +%s)" -lt "$target" ]; do stop_sleep "$POLL_SECONDS"; done
  fi
  printf '0' > "$LIMIT_PAUSE_FILE"
  for n in $retryable; do
    printf '%s' "$(( $(retries_used "$n") + 1 ))" > "$STATE/$n.retries"
    rm -f "$STATE/$n.retry-at"
    live_set "$(live_of "$n")" phase=re-dispatch retry_at=0
    event_emit tasklist.re-dispatch name="$n" state=pending limit_hit=1 \
      waits="$(live_get "$(live_of "$n")" waits)" \
      detail="usage-limit window elapsed — retry $(retries_used "$n")/$RATE_LIMIT_REDISPATCH_MAX"
    set_state "$n" pending
    echo "  ↻ re-dispatching $n after the usage-limit window (retry $(retries_used "$n")/$RATE_LIMIT_REDISPATCH_MAX)"
  done
  return 0
}

# A repo paused BEFORE this run started still is: the launch gate below will hold
# every tasklist. Say so up front and name the lever — an unexplained run that
# schedules nothing reads as a bug, which is exactly what "rather than silently
# launching" is meant to avoid in the other direction.
if op_paused; then
  since="$(op_paused_since)"; [ "$since" = 0 ] && since=""    # unstamped flag: gate, don't date
  echo "  ⏸ OPERATOR PAUSE armed for this repo${since:+ (since ~$(eta "$since"))} — no tasklist will be launched."
  echo "     Chief never lifts it by itself (a usage-limit window it does): chief resume"
  echo
fi

reap() {   # collect any finished workers, update state
  local n pid st
  for n in $NAMES; do
    [ "$(get_state "$n")" = "running" ] || continue
    pid="$(cat "$STATE/$n.pid" 2>/dev/null || echo)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then continue; fi   # still alive
    [ -n "$pid" ] && { wait "$pid" 2>/dev/null || true; }
    st="$(cat "$STATE/$n.status" 2>/dev/null || echo UNKNOWN)"
    case "$st" in
      MERGED*|COMPLETE-UNMERGED*) set_state "$n" done ;;
      # Paused on a usage limit, not failed: non-terminal, and dep_broken() ignores
      # it so dependents stay pending instead of cascading to 'blocked'. limit_pause
      # arms the reset-aware window the scheduler re-dispatches it after.
      RATE-LIMITED*) set_state "$n" rate-limited; limit_pause "$n" ;;
      # Drained on an OPERATOR pause: parked, never failed. Non-terminal in the same
      # way, and dep_broken() ignores it too — but nothing here re-arms it, because
      # nothing in this run may. Only `chief resume` lifts a human's hold; the
      # scheduler's job is to record the park and let the run end.
      PAUSED*) set_state "$n" paused ;;
      # Parked for a HUMAN REVIEWER (docs/plan-review.md). Non-terminal on exactly
      # the same terms as the operator pause: dep_broken() ignores it, nothing here
      # re-arms it (only a verdict can), and the run ends with the branch, the plan
      # and every annotation kept for the next `chief run`.
      AWAITING-REVIEW*) set_state "$n" awaiting-review ;;
      # Held by the MERGE POLICY LAYER — an overlap zone (docs/reference/overlap-zones.md)
      # or an over-budget story (docs/reference/diff-budget.md). Non-terminal on the
      # same terms again — but note what is different: this branch already passed the
      # whole merge floor. Nothing here re-arms it either; `chief approve` records the
      # verdict and the next run reads it.
      AWAITING-APPROVAL*) set_state "$n" awaiting-approval ;;
      *) set_state "$n" failed ;;
    esac
    echo "  ● $n finished → $st"
    rm -f "$STATE/$n.pid"
    # RETRY. After the state is settled and the pid is reaped, so a re-armed tasklist is
    # indistinguishable from a fresh 'pending' one to the scheduler below. Only failures
    # are considered — a pause is not a failure and must never spend this budget.
    if [ "$(get_state "$n")" = "failed" ] && [ "$RETRY_MAX" -gt 1 ] && retryable_status "$st"; then
      local spent; spent="$(attempts_used "$n")"
      [ "$spent" -lt 1 ] && spent=1                      # the run that just ended was attempt 1
      if [ "$spent" -lt "$RETRY_MAX" ]; then
        printf '%s' "$(( spent + 1 ))" > "$STATE/$n.attempts"
        set_state "$n" pending
        echo "    ↻ retrying $n (attempt $(( spent + 1 ))/$RETRY_MAX) — $st"
      else
        printf '%s' "$spent" > "$STATE/$n.attempts"
        echo "    ✗ $n exhausted its retries ($spent/$RETRY_MAX) — leaving it failed"
      fi
    fi
  done
}

IN_SCHEDULER=1     # from here on, on_stop only RECORDS; stop_check does the work
drain_said=""      # the mid-run "pause armed, draining" notice is said once
while :; do
  stop_check
  # Mark tasklists whose dep failed as blocked (they can never run).
  for n in $NAMES; do
    [ "$(get_state "$n")" = "pending" ] || continue
    dep_broken "$n" || continue
    set_state "$n" blocked
    for d in $(deps_of "$n"); do
      dk="$(dep_key "$d")"
      case "$(get_state "$dk")" in
        failed)  echo "needs \"$d\", which FAILED in this run — see $STATE/$dk.log" >> "$STATE/$n.why" ;;
        blocked) echo "needs \"$d\", which is itself blocked (see its reason above)"  >> "$STATE/$n.why" ;;
      esac
    done
    echo "  ⤬ $n BLOCKED"; [ -f "$STATE/$n.why" ] && sed 's/^/       /' "$STATE/$n.why"
  done
  # Launch as many ready tasklists as the concurrency + conflict rules allow —
  # UNLESS a pause is armed. Two independent gates, both consulted every pass so a
  # pause armed MID-RUN stops the next launch, not just the first:
  #   · operator pause — a human wants this repo to stop spending agent turns.
  #     Unbounded in time, and lifted only by `chief resume`.
  #   · usage-limit window — one account means one window, so launching into it
  #     would just wall every worker; back off as a whole instead.
  # (Workers already running keep going: agent.sh has its own sleep/resume, and a
  # worker drains an operator pause at its own safe checkpoints.)
  while ! op_paused && [ "$(pause_until)" -le "$(date +%s)" ] && [ "$(n_running)" -lt "$PARALLEL" ]; do
    launched=""
    for n in $NAMES; do
      [ "$(get_state "$n")" = "pending" ] || continue
      deps_satisfied "$n" || continue
      touch_free "$n" || continue
      audit_launch "$n"      # record its domains + the peers it will run beside
      set_state "$n" running
      run_worker "$n" "$(iters_of "$n")" &
      echo "$!" > "$STATE/$n.pid"
      echo "  ▸ launch $n  (pid $!; touches: $(touches_of "$n" | tr '\n' ' '))"
      launched=1; break
    done
    [ -z "$launched" ] && break
  done
  # DRAINING. A pause armed MID-RUN leaves workers running; they stop at their own
  # iteration boundary, so the wait is one agent turn long (and a worker already past
  # its agent loop finishes verify+merge). Said once, because "the scheduler launched
  # nothing and is still sitting here" is otherwise indistinguishable from a hang.
  if [ -z "$drain_said" ] && op_paused && [ "$(n_running)" -gt 0 ]; then
    drain_said=1
    echo "  ⏸ OPERATOR PAUSE armed — launching nothing more and DRAINING: $(running_names)"
    echo "     Each finishes the iteration it is in (its commits land), then parks with its branch kept."
  fi
  # Termination: nothing running AND nothing merely waiting out a usage limit.
  # limit_resume() returns 0 only when it actually waited and/or re-armed work,
  # so a spent re-dispatch cap ends the run instead of hanging on it.
  if [ "$(n_running)" -eq 0 ]; then
    # An operator pause ends the run here rather than waiting out a limit window on
    # top of it: the wait would hold driver.lock for an unbounded human decision, and
    # the re-dispatch it ends in is budget the usage-limit self-heal needs — spending
    # it on work the pause forbids launching would let a few manual pauses silently
    # exhaust the cap. Nothing is lost: branches and worktrees are kept for resume.
    op_paused && break
    limit_resume && continue
    break
  fi
  stop_sleep "$POLL_SECONDS"
  reap
done
IN_SCHEDULER=0     # nothing left to wait on — a late signal can tear down inline
reap   # final sweep

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo; echo "==================================================================="
echo "  Parallel run summary"
ran=""; paused=""; parked=""; inreview=""; inzone=""; refused=""; stashed=""
for n in $NAMES; do
  printf '   - %-32s %s%s\n' "$n" "$(get_state "$n")$( [ -f "$STATE/$n.status" ] && printf '  [%s]' "$(cat "$STATE/$n.status")" )" \
    "$( [ "$(attempts_used "$n")" -gt 1 ] && printf '  (attempt %s/%s)' "$(attempts_used "$n")" "$RETRY_MAX" )"
  [ -f "$STATE/$n.why" ] && sed 's/^/       ↳ /' "$STATE/$n.why"
  case "$(get_state "$n")" in
    done|failed) ran=1 ;;
    rate-limited) ran=1; paused="$paused $n" ;;   # it ran; it is paused, not failed
    paused) ran=1; parked="$parked $n" ;;         # it ran; the operator stopped it
    awaiting-review) ran=1; inreview="$inreview $n" ;;  # it ran; a human hasn't approved its plan
    awaiting-approval) ran=1; inzone="$inzone $n" ;;   # it ran, rebased and verified green; a human hasn't approved the zone it changed
  esac
  # Collected off the STATUS, not the scheduler state: a refusal is 'failed' like any
  # other, and the summary block below is what separates it from one worth re-running.
  case "$(cat "$STATE/$n.status" 2>/dev/null || echo)" in REBASE-REFUSED*) refused="$refused $n" ;; esac
  # The merge phase parks the operator's uncommitted work for the length of its
  # critical section (merge_stash_push). This file exists only when giving it back
  # could not be done cleanly — the entry was KEPT, so the block below is the run's
  # obligation to say where it is.
  if [ -s "$STATE/$n.stash" ]; then
    sr="$(cut -d'|' -f1 < "$STATE/$n.stash")"; ss="$(cut -d'|' -f2 < "$STATE/$n.stash")"
    # Self-clearing: once the operator has applied and dropped it the object is gone,
    # and a pointer to a stash that no longer exists is worse than no pointer at all.
    if git -C "$sr" cat-file -e "${ss}^{commit}" 2>/dev/null; then stashed="$stashed $n"
    else rm -f "$STATE/$n.stash" 2>/dev/null || true; fi
  fi
done
echo "   (logs: $STATE/<name>.log)"
# Retried tasklists, said once and plainly. A tasklist that failed on its LAST attempt
# looks identical to one that failed on its first unless the count is reported — and the
# difference matters: the first is worth re-running, the second needs a human to read why.
retried=""; for n in $NAMES; do [ "$(attempts_used "$n")" -gt 1 ] && retried="$retried $n"; done
if [ -n "$retried" ]; then
  echo "   (retried after failing:$retried)"
  for n in $retried; do
    printf '    · %-30s attempt %s/%s — %s\n' "$n" "$(attempts_used "$n")" "$RETRY_MAX" \
      "$( [ "$(get_state "$n")" = done ] && echo "recovered" || echo "still failing; read $STATE_REL/$n.log" )"
  done
  [ "$RETRY_MAX" -le 1 ] && echo "    retry on failure is OFF (RETRY_MAX=$RETRY_MAX)."
fi
# A REFUSED rebase, said as its own thing. It is a failure, so without this it appears
# in the list above as one more red line and the operator reads the ABSENCE of a retry
# as chief giving up early — or, before it was excluded from the allowlist, as
# "exhausted its retries (3/3)", which reads as a hard problem with the WORK. Neither is
# what happened: the branch is intact, nothing collided, and the thing that has to
# change is the work repo, which only a human can change. So name the precondition and
# the fix, and say plainly that not retrying was the decision.
if [ -n "$refused" ]; then
  echo "   (git REFUSED to rebase — NOT a merge conflict, and NOT retried:$refused)"
  for rn in $refused; do
    rst="$(cat "$STATE/$rn.status" 2>/dev/null || echo)"
    rcause="${rst#REBASE-REFUSED }"; rcause="${rcause%% (see *}"
    printf '    · %-30s %s\n' "$rn" "$rcause"
    printf '      %s\n' "one attempt, deliberately: re-running the agent cannot clear the work repo, so it would re-refuse identically."
    printf '      %s\n' "clear the cause above in the work repo, then: chief run $rn"
    [ -f "$SNAP/$rn.rebase-refused.md" ] && printf '      %s\n' "the cause and the exact command: $SNAP_REL/$rn.rebase-refused.md"
  done
fi
# UNREPLAYED OPERATOR WORK. Loud, unconditional, and above every other note here,
# because it is the only line in this summary about something that is not chief's:
# the merge phase borrowed the operator's uncommitted changes and could not put them
# back (the merge touched the same lines). Nothing was dropped — the whole point of
# parking in git's own stash rather than a temp file is that the entry outlives every
# way this can go wrong — but an operator who never knew it was taken has no reason
# to run `git stash list`, so the run says it.
if [ -n "$stashed" ]; then
  echo "   ⚠️  YOUR UNCOMMITTED WORK IS IN THE STASH, not the working tree:$stashed"
  for sn in $stashed; do
    ssr="$(cut -d'|' -f1 < "$STATE/$sn.stash")"; ssha="$(cut -d'|' -f2 < "$STATE/$sn.stash")"
    printf '    · %-30s git -C %s stash apply %s\n' "$sn" "$ssr" "$ssha"
  done
  echo "    chief parked it to merge, and the merge changed the same lines — so it replayed with"
  echo "    conflicts and the entry was KEPT rather than dropped. Nothing is lost."
fi
# A usage-limit pause is not a failure and must not read like one: say plainly that
# the branch is intact, how much of the self-heal budget it spent, and that a re-run
# picks up where it stopped. A run that ends here ran out of RE-DISPATCHES, not road.
if [ -n "$paused" ]; then
  echo "   (paused on a Claude usage limit:$paused — branches kept; re-run to resume from where they stopped)"
  for n in $paused; do
    printf '    · %-30s re-dispatched %s/%s time(s) this run\n' "$n" "$(retries_used "$n")" "$RATE_LIMIT_REDISPATCH_MAX"
  done
  if [ "$RATE_LIMIT_REDISPATCH_MAX" = "0" ]; then
    echo "    auto re-dispatch is OFF (RATE_LIMIT_REDISPATCH_MAX=0)."
  else
    echo "    The re-dispatch cap (RATE_LIMIT_REDISPATCH_MAX=$RATE_LIMIT_REDISPATCH_MAX) is spent — raise it, or re-run once capacity is back."
  fi
  # Anything still 'pending' never got to launch: the shared-limit gate held it and
  # the run ended before the gate reopened. Say so, or it reads as a silent skip.
  still="$(pending_names)"
  # ${still} braced ON PURPOSE: the em dash that follows is multibyte, and bash
  # happily reads those bytes as part of an unbraced identifier — "$still—" is a
  # lookup of a name that never existed, which under `set -u` kills the run in
  # its own summary. Brace any $var butted against non-ASCII punctuation.
  [ -n "$still" ] && echo "    (never launched, held by the limit pause: ${still}— they run on the next 'chief run')"
fi
# An OPERATOR pause is a DECISION, not a fault, and the summary is where that has to
# be unmistakable: parked tasklists are listed here, never among the failures. Say
# how many, that each kept its branch AND worktree, and the exact two commands that
# pick the run back up — the hold is unbounded in time, so the reader may be seeing
# this hours or days later with none of the context they had when they armed it.
if [ -n "$parked" ]; then
  # Counted in a subshell (the n_running() idiom): `set --` out here would clobber
  # the driver's own positional parameters in its own summary.
  echo "   ⏸ OPERATOR PAUSE — $(set -- $parked; echo $#) tasklist(s) PARKED (not failed, not blocked):$parked"
  for n in $parked; do
    printf '    · %-30s %s — branch + worktree kept\n' "$n" "$(cat "$STATE/$n.status" 2>/dev/null || echo PAUSED)"
  done
  # Held at the gate rather than drained: these never launched at all, so they have
  # no branch to speak of. Distinguished from the parked list on purpose.
  held="$(pending_names)"
  [ -n "$held" ] && echo "    (never launched, held by the operator pause: ${held}— they start on the next run)"
  echo "    Nothing is half-done: no tasklist was stopped mid-rebase, mid-verify or mid-merge."
  echo "    Resume where they stopped (their committed passes state):  chief resume  &&  chief run"
fi
# Parked on a HUMAN VERDICT. Reported next to the operator pause and never among the
# failures, for the same reason: nothing is wrong with the branch, someone simply has
# not looked at the plan yet. The plan artifact is named because that is the thing to
# open — and because an approval, once given, is read off disk on the next run rather
# than asked for again.
if [ -n "$inreview" ]; then
  echo "   ⏸ AWAITING REVIEW — $(set -- $inreview; echo $#) tasklist(s) parked on a human verdict (not failed, not blocked):$inreview"
  for n in $inreview; do
    printf '    · %-30s %s — plan: %s\n' "$n" "$(cat "$STATE/$n.status" 2>/dev/null || echo AWAITING-REVIEW)" \
      "$STATE_REL/snapshots/$n.plans/"
  done
  echo "    Approve the plan (docs/plan-review.md), then pick it up where it stopped:  chief run"
fi
# Held by the MERGE POLICY LAYER — an overlap zone (docs/reference/overlap-zones.md)
# or an over-budget story (docs/reference/diff-budget.md). Reported apart from the
# three holds above because what is true of this one is stronger: the branch is
# rebased onto the latest base and its verify came back green. Nothing is wrong with
# it — the repo declared that green is not sufficient authority to merge this change.
if [ -n "$inzone" ]; then
  echo "   ⏸ AWAITING APPROVAL — $(set -- $inzone; echo $#) tasklist(s) rebased + verified GREEN, held by the merge policy layer:$inzone"
  for n in $inzone; do
    printf '    · %-30s %s\n' "$n" "$(cat "$STATE/$n.status" 2>/dev/null || echo AWAITING-APPROVAL)"
    zones_render "$(jq -r '(.zones // [])[] | [.policy, .zone, .matched, .reason] | @tsv' \
                      "$(zones_request_file "$STATE" "$n")" 2>/dev/null || echo)"
  done
  echo "    Approve what a gate cannot check (whether the designs agree, whether the size is warranted), then:  chief approve <name> && chief run"
fi
# Only claim there are branches to review if there actually are: chief/* heads not
# yet reachable from the base branch. A blanket "unmerged branches remain" sends
# people hunting for work that a no-op run never created.
unmerged=""
for b in $(git -C "$REPO" for-each-ref --format='%(refname:short)' refs/heads/chief/ 2>/dev/null); do
  git -C "$REPO" merge-base --is-ancestor "$b" "$BASE_BRANCH" 2>/dev/null || unmerged="$unmerged $b"
done
[ -n "$unmerged" ] && echo "   (unmerged branches for review:$unmerged · worktrees: $WT_ROOT)"
# What the run cost in DISK, alongside what it cost in tokens. Silent when nothing
# was reclaimed, so a docs-only run prints exactly what it used to.
swept="$(awk '{t += $1} END {print t + 0}' "$STATE/sweep.bytes" 2>/dev/null || echo 0)"
[ "${swept:-0}" -gt 0 ] && echo "   (reclaimed $(chief_sweep_human "$swept") of build artifacts from this run's worktrees)"
rm -f "$STATE/sweep.bytes" 2>/dev/null || true
# `touches` under-tagging: co-scheduled tasklists that turned out to edit the same
# files. Pure reporting — nothing above changed because of it. Silent when the run
# had no overlap (the normal case), so a clean run prints exactly what it used to.
audit_out="$(audit_findings)"
if [ -n "$audit_out" ]; then
  echo
  echo "   Co-scheduled tasklists changed the same file(s) while sharing no touches"
  echo "   domain. This run was still safe — every branch was rebased and re-verified"
  echo "   before merging — but the overlap was invisible to the scheduler:"
  printf '%s\n' "$audit_out"
fi
# MERGE QUEUE — the amortization, COUNTED rather than claimed (engine/mergequeue.sh).
# "batching amortizes verification" is a statement about a ratio, so the ratio is
# reported: gate invocations against branches they covered. Silent when batching was
# off, so a default run's summary is byte-for-byte the one it always printed.
if mq_enabled; then
  echo "   merge queue: $(mq_count verifications) batch-tip verification(s) covering $(mq_count covered) branch(es) (max batch $(mq_batch_max))"
  # The BISECT's own bill, on its own line and only when it was spent: probes + the
  # confirming runs are EXTRA gate invocations, and folding them into the line above
  # would let the amortization ratio quietly absorb the cost of isolating a culprit.
  if [ "$(mq_count probes)" != 0 ] || [ "$(mq_count dissolved)" != 0 ]; then
    echo "   merge queue: $(mq_count probes) extra verification(s) spent bisecting — $(mq_count isolated) branch(es) isolated, $(mq_count dissolved) batch(es) dissolved to the serialized floor"
  fi
  # The RATCHET axis keeps its own line for the same reason: a metric delta on a tip is
  # attributed by re-measuring each branch alone, never by bisection, and when nobody
  # is individually out of tolerance the outcome has a NAME rather than a suspect.
  if [ "$(mq_count ratchet_probes)" != 0 ] || [ "$(mq_count not_attributable)" != 0 ]; then
    echo "   merge queue: $(mq_count ratchet_probes) per-branch quality-ratchet re-measurement(s) — $(mq_count ratchet_isolated) branch(es) attributed, $(mq_count not_attributable) batch(es) RATCHET-NOT-ATTRIBUTABLE (dissolved to the serialized floor)"
  fi
fi
echo "==================================================================="

# ---------------------------------------------------------------------------
# Headless outcome — the exit code + JSON summary a host codes against.
# ---------------------------------------------------------------------------
# Read from the SAME per-tasklist state the block above just printed (<name>.state
# and <name>.status, via tasklist_outcome) — this surfaces the driver's decisions,
# it does not make new ones. Run-level precedence is fixed and documented, so the
# same set of terminal states always yields the same code: the outcome a human has
# to act on first wins, and "nothing happened" only wins when nothing else did.
hl_conflict=""; hl_verify=""; hl_failed=""; hl_held=""; hl_ok=""
for n in $NAMES; do
  case "$(tasklist_outcome "$n" "$(cat "$STATE/$n.status" 2>/dev/null || echo)")" in
    merged|complete-unmerged) hl_ok=1 ;;
    conflict)                 hl_conflict=1 ;;
    verify-failed)            hl_verify=1 ;;
    paused|rate-limited)      hl_held=1 ;;
    awaiting-review)          hl_held=1 ;;   # withheld pending a human verdict, not failed
    awaiting-approval)        hl_held=1 ;;   # withheld pending a human approval, not failed
    blocked|not-launched)     ;;   # never ran — the no-work rule below covers these
    no-work)                  hl_failed=1 ;;   # the false-complete guard fired: a fault
    *)                        hl_failed=1 ;;
  esac
done
if   [ -n "$hl_conflict" ]; then hl_outcome=conflict;      hl_code="$HL_RC_CONFLICT"
elif [ -n "$hl_verify"   ]; then hl_outcome=verify-failed; hl_code="$HL_RC_VERIFY"
elif [ -n "$hl_failed"   ]; then hl_outcome=failed;        hl_code="$HL_RC_FAILED"
elif [ -n "$hl_held"     ]; then hl_outcome=paused;        hl_code="$HL_RC_PAUSED"
# An operator pause that WITHHELD work is a held run, not an empty one — even when
# no worker ever started and so no tasklist carries a PAUSED status of its own.
elif op_paused && { [ -z "$ran" ] || [ -n "$(pending_names)" ]; }; then
  hl_outcome=paused; hl_code="$HL_RC_PAUSED"
elif [ -z "$ran" ] || [ -z "$hl_ok" ]; then hl_outcome=no-work; hl_code="$HL_RC_NOWORK"
else hl_outcome=merged; hl_code="$HL_RC_OK"
fi
headless_summary "$hl_outcome" "$hl_code"
# The event stream closes on the same computed outcome the exit code carries — one
# decision, published twice (a code for the caller, a line for a subscriber), never
# two. A consumer that saw `run.started` is guaranteed this line on every normal
# exit path; a killed run simply stops, which is why `ts` is on every event.
event_emit run.finished state="$hl_outcome" detail="exit=$hl_code"

# A run that launched nothing at all did no work — say so with a non-zero exit
# rather than reporting success. An OPERATOR PAUSE is the one reason for that which
# is not a fault: the run did exactly what it was told, so it says PAUSED and exits 0.
if [ -z "$ran" ]; then
  if op_paused; then
    echo "Nothing ran: an OPERATOR PAUSE is armed for this repo — every tasklist was held," >&2
    echo "and their branches and worktrees are untouched. Lift it and pick up where they"  >&2
    echo "stopped:  chief resume  &&  chief run" >&2
    exit "$(hl_rc "$hl_code" 0)"
  fi
  echo "Nothing ran: every scheduled tasklist is blocked on a dependency (reasons above)." >&2
  exit "$(hl_rc "$hl_code" 1)"
fi
exit "$(hl_rc "$hl_code" 0)"
