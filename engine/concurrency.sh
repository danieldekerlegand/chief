#!/usr/bin/env bash
# engine/concurrency.sh — read the host-wide run registry for machine activity.
#
# This is deliberately a reader over the registry that `chief ps` already uses.
# It owns no lock, daemon, or second state store.  A driver PID is the authority
# for whether a registry record is live; tasklist live records then say whether
# that driver is spending an agent turn or running a gate.

# Sets globals rather than printing so callers in hot paths do not fork through
# command substitution.  Bash 3.2 compatible: no associative arrays.
CHIEF_MACHINE_RUNS=0
CHIEF_MACHINE_AGENT_TURNS=0
CHIEF_MACHINE_GATES=0
CHIEF_MACHINE_STALE=0

concurrency_field() {
  sed -n "s/^$1=//p" "${2:-}" 2>/dev/null | head -1
}

concurrency_pid_live() {
  # reap.sh's predicate excludes zombies; using it here is important because
  # kill -0 alone reports a reaped-but-unwaited worker as live.
  if command -v chief_pid_alive >/dev/null 2>&1; then
    chief_pid_alive "${1:-}"
  else
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$1" 2>/dev/null
  fi
}

concurrency_phase_kind() {
  case "${1:-}" in
    agent-turn|provider-waiting|writing|integrating|re-dispatch|rate-limited-waiting)
      printf agent ;;
    worktree|warmup|reconcile|merge-wait|rebasing|verifying|zone-check|merging|merge-conflict)
      printf gate ;;
  esac
}

# chief_machine_activity [RUNS_DIR]
# Sets CHIEF_MACHINE_* and leaves stale records untouched.  `chief ps` remains
# responsible for pruning them; a budget reader must never delete state while
# another run is starting.
chief_machine_activity() {
  local runs="${1:-${CHIEF_RUNS:-}}" f pid state names n lf phase kind
  CHIEF_MACHINE_RUNS=0
  CHIEF_MACHINE_AGENT_TURNS=0
  CHIEF_MACHINE_GATES=0
  CHIEF_MACHINE_STALE=0
  [ -n "$runs" ] || return 0
  for f in "$runs"/*.run; do
    [ -e "$f" ] || continue
    if command -v chief_ns_foreign >/dev/null 2>&1 && \
       chief_ns_foreign "$(chief_run_file_ns "$f")"; then
      continue
    fi
    pid="$(concurrency_field pid "$f")"
    if ! concurrency_pid_live "$pid"; then
      CHIEF_MACHINE_STALE=$(( CHIEF_MACHINE_STALE + 1 ))
      continue
    fi
    CHIEF_MACHINE_RUNS=$(( CHIEF_MACHINE_RUNS + 1 ))
    state="$(concurrency_field state "$f")"
    names="$(concurrency_field names "$f")"
    for n in $names; do
      lf="$state/parallel/$n.live.json"
      if command -v live_get >/dev/null 2>&1; then
        phase="$(live_get "$lf" phase)"
      else
        phase="$(sed -n 's/.*"phase":[[:space:]]*"\([^"]*\)".*/\1/p' "$lf" 2>/dev/null | head -1)"
      fi
      kind="$(concurrency_phase_kind "$phase")"
      case "$kind" in
        agent) CHIEF_MACHINE_AGENT_TURNS=$(( CHIEF_MACHINE_AGENT_TURNS + 1 )) ;;
        gate)  CHIEF_MACHINE_GATES=$(( CHIEF_MACHINE_GATES + 1 )) ;;
      esac
    done
  done
}

chief_machine_activity_line() {
  printf '%s live run(s) · %s agent turn(s) · %s gate(s)' \
    "$CHIEF_MACHINE_RUNS" "$CHIEF_MACHINE_AGENT_TURNS" "$CHIEF_MACHINE_GATES"
  [ "$CHIEF_MACHINE_STALE" -gt 0 ] && \
    printf ' · %s stale record(s) ignored' "$CHIEF_MACHINE_STALE"
}
