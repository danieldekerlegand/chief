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
CHIEF_MACHINE_CORES=1
# The OPERATOR's requested budget, captured BEFORE the safe default below shadows it.
# `-` rather than `:-` so an explicitly empty value is still distinguishable from unset.
# Without this capture, `chief_machine_budget_init` read its own default back as if the
# operator had asked for it, the core-count branch became unreachable, and every machine
# ran at a budget of 1 agent turn no matter how many cores it had.
CHIEF_MACHINE_BUDGET_REQUESTED="${CHIEF_MACHINE_BUDGET-}"
CHIEF_MACHINE_BUDGET=1
CHIEF_MACHINE_BUDGET_DISABLED=0
CHIEF_MACHINE_BUDGET_READY=0
CHIEF_MACHINE_LOAD_AVERAGE=""

# THE SECOND BUDGET, and the expensive one. An agent turn is dominated by
# `provider-waiting` -- network latency, not compute; the phase table gives that
# phase a 900s staleness threshold for exactly that reason. A GATE (rebase, build,
# full test suite) IS the compute. Budgeting agent turns against the physical core
# count therefore limits the CHEAP resource with a number derived from the EXPENSIVE
# one, which is how a 14-core host reached load average 14.32 with five turns live
# and nine slots still nominally free (2026-09-03).
#
# THE DEFAULT IS 2, AND IT IS A RATIO RATHER THAN A FEEL. cuneiform caps cargo at
# `jobs = 7` with its reasoning written down: "7 is half the physical cores, chosen
# so TWO concurrent gates exactly saturate the machine rather than oversubscribing
# it 2x." A per-repo cap expressed as a FRACTION of the host saturates at
# cores / (cores/2) = 2 gates at ANY core count, so this default deliberately does
# NOT scale with cores -- it is the reciprocal of the share each gate already claims
# for itself. Chief cannot read another repo's job cap, so 2 is the number that makes
# cuneiform's stated assumption true host-wide instead of true only inside cuneiform.
# A host too small to give one gate that share falls to the floor of 1.
#
# It is a SEPARATE knob from CHIEF_MACHINE_BUDGET, which keeps its own default (the
# core count), its own env override and its own 0|off|false|none escape hatch. The
# two govern different resources and collapsing them is the defect this fixes.

CHIEF_MACHINE_GATE_BUDGET_REQUESTED="${CHIEF_MACHINE_GATE_BUDGET-}"
CHIEF_MACHINE_GATE_BUDGET=2
CHIEF_MACHINE_GATE_BUDGET_DISABLED=0
CHIEF_MACHINE_GATE_WAITED=0

# THE THIRD INPUT, and the only one that can see work chief did not start.
# CHIEF_MACHINE_LOAD_AVERAGE was written and read inside one function and spent
# entirely on printing the word OVERSUBSCRIBED beside a number; it is now an
# ADMISSION input. The two budgets above count chief's own records, so a host
# carrying an operator's build, a browser and a VM reads to them as idle.
#
# THE CEILING IS THE CORE COUNT, for the same reason the display already compares
# against it: one runnable thread per physical core is saturation, and past that
# every new gate is taking time from a gate already running rather than finding
# idle silicon. CHIEF_MACHINE_LOAD_LIMIT overrides the number and 0|off|false|none
# turns load-based admission off entirely -- the escape hatch an operator needs
# when they KNOW the load is foreign and will not clear.
#
# IT IS BOUNDED, NOT ABSOLUTE. Load average includes what chief cannot finish and
# cannot even see, so a rule that simply waits for it to fall can wait forever
# while chief itself is idle. The bound is in `chief_machine_load_allows`: chief
# defers to the load line only while chief is CONTRIBUTING to it -- with no gate
# of its own in flight, work is admitted whatever the number says.
CHIEF_MACHINE_LOAD_LIMIT_REQUESTED="${CHIEF_MACHINE_LOAD_LIMIT-}"
CHIEF_MACHINE_LOAD_LIMIT=0
CHIEF_MACHINE_LOAD_DISABLED=0
# WHICH resource said no, set by `chief_machine_admits` on every refusal. A hold
# that cannot name what it is waiting for reads as a hang.
CHIEF_MACHINE_HOLD_REASON=""

chief_machine_core_count() {
  local n
  n="$(sysctl -n hw.physicalcpu 2>/dev/null || echo)"
  case "$n" in
    ''|*[!0-9]*|0)
      n="$(lscpu -p=CORE 2>/dev/null | awk '!/^#/ && !seen[$1]++ {n++} END {print n+0}')"
      ;;
  esac
  case "$n" in ''|*[!0-9]*|0) n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo)" ;; esac
  case "$n" in ''|*[!0-9]*|0) n="$(nproc 2>/dev/null || echo)" ;; esac
  case "$n" in ''|*[!0-9]*|0) n=1 ;; esac
  printf '%s' "$n"
}

# CHIEF_MACHINE_BUDGET is the number of simultaneous agent turns allowed across
# the host. Zero/off is the explicit escape hatch for the pre-budget behavior.
chief_machine_budget_init() {
  local requested="${CHIEF_MACHINE_BUDGET_REQUESTED-}"
  CHIEF_MACHINE_CORES="$(chief_machine_core_count)"
  CHIEF_MACHINE_BUDGET_DISABLED=0
  case "$requested" in
    0|off|false|none) CHIEF_MACHINE_BUDGET_DISABLED=1; CHIEF_MACHINE_BUDGET=0 ;;
    ''|*[!0-9]*) CHIEF_MACHINE_BUDGET="$CHIEF_MACHINE_CORES" ;;
    *) CHIEF_MACHINE_BUDGET="$requested" ;;
  esac
  # The gate budget resolves here too, from its own request and by its own rule --
  # one init so `chief_machine_budget_ensure` cannot leave half the state at its
  # file-level default, which is the drift that made `chief ps` print 1 core on a
  # 14-core host.
  local gate="${CHIEF_MACHINE_GATE_BUDGET_REQUESTED-}"
  CHIEF_MACHINE_GATE_BUDGET_DISABLED=0
  case "$gate" in
    0|off|false|none) CHIEF_MACHINE_GATE_BUDGET_DISABLED=1; CHIEF_MACHINE_GATE_BUDGET=0 ;;
    ''|*[!0-9]*) CHIEF_MACHINE_GATE_BUDGET=2 ;;
    *) CHIEF_MACHINE_GATE_BUDGET="$gate" ;;
  esac
  [ "$CHIEF_MACHINE_CORES" -ge 2 ] || CHIEF_MACHINE_GATE_BUDGET=1
  # The load ceiling resolves here too, by the same rule and in the same place --
  # a knob resolved anywhere else is a knob half of `chief_machine_budget_ensure`'s
  # callers read at its file-level default.
  local loadlim="${CHIEF_MACHINE_LOAD_LIMIT_REQUESTED-}"
  CHIEF_MACHINE_LOAD_DISABLED=0
  case "$loadlim" in
    0|off|false|none) CHIEF_MACHINE_LOAD_DISABLED=1; CHIEF_MACHINE_LOAD_LIMIT=0 ;;
    ''|*[!0-9.]*|*.*.*) CHIEF_MACHINE_LOAD_LIMIT="$CHIEF_MACHINE_CORES" ;;
    *) CHIEF_MACHINE_LOAD_LIMIT="$loadlim" ;;
  esac
  CHIEF_MACHINE_BUDGET_READY=1
}

# Resolve cores/budget on FIRST USE. `chief ps` (engine/monitor.sh) sources this file
# but never called the init, so every reader there rendered the file-level defaults --
# printing "1 physical core(s)" on a 14-core host while the driver, which DOES init,
# printed 14 in the same session. A display that depends on each caller remembering to
# initialise will drift again, so make it self-initialising instead.
chief_machine_budget_ensure() {
  [ "${CHIEF_MACHINE_BUDGET_READY:-0}" = 1 ] || chief_machine_budget_init
}

chief_machine_budget_allows() {
  chief_machine_budget_ensure
  [ "$CHIEF_MACHINE_BUDGET_DISABLED" = 1 ] || [ "$CHIEF_MACHINE_AGENT_TURNS" -lt "$CHIEF_MACHINE_BUDGET" ]
}

# The gate budget's ONE hard invariant: it may hold a gate back, and it may never
# refuse EVERY gate. Zero gates live is admitted unconditionally -- whatever the
# budget, whatever the load -- so a scheduler that has stopped the world cannot also
# have stopped itself. A capacity control that can refuse everything halts the
# portfolio permanently, which is strictly worse than the contention it prevents.
chief_machine_gate_budget_allows() {
  chief_machine_budget_ensure
  if [ "$CHIEF_MACHINE_GATE_BUDGET_DISABLED" = 1 ]; then return 0; fi
  if [ "${CHIEF_MACHINE_GATES:-0}" -le 0 ]; then return 0; fi
  [ "$CHIEF_MACHINE_GATES" -lt "$CHIEF_MACHINE_GATE_BUDGET" ]
}

# THE ONE SAMPLER. Every reader takes its number from CHIEF_MACHINE_LOAD_AVERAGE
# and only this function writes it -- the display line, the admission predicate and
# the hold reason are then reading the same reading. A second sampling path is how
# `chief ps` and the scheduler come to disagree about the same machine, and the
# disagreement is invisible because both numbers are individually true.
chief_machine_load_sample() {
  CHIEF_MACHINE_LOAD_AVERAGE="$(chief_machine_load_average)"
}

# The load line as an ADMISSION input, bounded so it can never stall the portfolio.
#
# Callers refresh CHIEF_MACHINE_GATES (chief_machine_activity) and
# CHIEF_MACHINE_LOAD_AVERAGE (chief_machine_load_sample) first; this reads the
# globals and samples nothing itself.
#
# THE BOUND: chief defers to the load line only while chief is CONTRIBUTING to it.
# Load average counts an operator's own build, a browser, a VM -- work chief did
# not start, cannot finish and cannot see. With no gate of chief's in flight there
# is nothing for chief to wait for, so waiting would be an unbounded stall on
# somebody else's compute; that case is admitted regardless of the number. It is
# also the same floor the gate budget already stands on, so a cleared host always
# moves whichever control is consulted.
chief_machine_load_allows() {
  chief_machine_budget_ensure
  if [ "$CHIEF_MACHINE_LOAD_DISABLED" = 1 ]; then return 0; fi
  if [ "${CHIEF_MACHINE_GATES:-0}" -le 0 ]; then return 0; fi
  if chief_machine_load_over; then return 1; fi
  return 0
}

# IS THE MACHINE PAST THE CEILING -- the FACT, with the bound above not applied.
# Two readers need different halves of it: the predicate needs "held", and the
# display needs to tell "held" apart from "over the ceiling and admitting anyway",
# which is the one case the old line could not say and the case the incident host
# was actually in. One comparison, so the number an operator reads and the number
# the scheduler decided on can never be computed two different ways.
chief_machine_load_over() {
  chief_machine_budget_ensure
  if [ "$CHIEF_MACHINE_LOAD_DISABLED" = 1 ]; then return 1; fi
  local load="${CHIEF_MACHINE_LOAD_AVERAGE:-}"
  # An unreadable load average is not a high one: `?` reads as under, as absent does.
  case "$load" in ''|'?') return 1 ;; esac
  awk -v l="$load" -v c="$CHIEF_MACHINE_LOAD_LIMIT" 'BEGIN { exit (l + 0 > c + 0) ? 0 : 1 }'
}

# chief_machine_admits launch|gate
# The whole admission decision for one call site, and the ONLY place the two
# budgets meet the load line. Sets CHIEF_MACHINE_HOLD_REASON to the resource that
# is short so a hold can name it; both call sites refresh the counters first.
chief_machine_admits() {
  CHIEF_MACHINE_HOLD_REASON=""
  case "${1:-gate}" in
    launch)
      chief_machine_budget_allows || {
        CHIEF_MACHINE_HOLD_REASON="machine budget: $CHIEF_MACHINE_AGENT_TURNS/$CHIEF_MACHINE_BUDGET agent turn(s) live across the machine"
        return 1; } ;;
    *)
      chief_machine_gate_budget_allows || {
        CHIEF_MACHINE_HOLD_REASON="gate budget: $CHIEF_MACHINE_GATES/$CHIEF_MACHINE_GATE_BUDGET gate(s) live across the machine"
        return 1; } ;;
  esac
  chief_machine_load_allows || {
    CHIEF_MACHINE_HOLD_REASON="machine load: load average $CHIEF_MACHINE_LOAD_AVERAGE over $CHIEF_MACHINE_LOAD_LIMIT core(s), $CHIEF_MACHINE_GATES chief gate(s) live"
    return 1; }
  return 0
}

# One line, printed to the worker's log and appended to the run's machine-budget.log
# so a hold reads the same way the agent-turn hold already does.
chief_machine_gate_note() {
  printf '  %s\n' "${2:-}"
  [ -n "${1:-}" ] || return 0
  printf '%s\n' "$(date +%s) ${2:-}" >> "$1" 2>/dev/null || true
}

# chief_machine_gate_admit NAME [LIVE_FILE] [LOG_FILE]
# BLOCKS until the host has room for one more gate, then returns 0.
#
# ADMISSION ONLY. It never kills, suspends or restarts a gate already running: an
# interrupted gate is a corrupt verdict and a wasted rebuild, which costs more than
# the contention. The only lever is WHEN a worker is allowed to begin one.
#
# IT ALWAYS RETURNS 0 EVENTUALLY, on two independent floors. The predicate admits
# whenever nothing of chief's is gating (both the gate budget and the load rule
# stand on that same floor), and the wait itself is bounded by
# CHIEF_MACHINE_GATE_HOLD_MAX (default 1800s), after which the gate starts anyway
# and says so in the log. Neither floor depends on the other being correct.
chief_machine_gate_admit() {
  local name="${1:-gate}" live="${2:-}" log="${3:-}" said=0 waited=0
  local step="${CHIEF_MACHINE_GATE_POLL:-5}" max="${CHIEF_MACHINE_GATE_HOLD_MAX:-1800}"
  CHIEF_MACHINE_GATE_WAITED=0
  chief_machine_budget_ensure
  # Only when BOTH controls are off is there nothing to ask. Disabling the gate
  # budget is not disabling the load rule -- they are separate knobs, and a single
  # early return here would have made the first silently switch off the second.
  if [ "$CHIEF_MACHINE_GATE_BUDGET_DISABLED" = 1 ] && [ "$CHIEF_MACHINE_LOAD_DISABLED" = 1 ]; then
    return 0
  fi
  while :; do
    chief_machine_activity "${CHIEF_RUNS:-}"
    # Re-sampled every pass, or a hold taken at a spike would never see it clear.
    chief_machine_load_sample
    if chief_machine_admits gate; then break; fi
    if [ "$waited" -ge "$max" ]; then
      chief_machine_gate_note "$log" "RELEASE $name hold spent after ${waited}s (CHIEF_MACHINE_GATE_HOLD_MAX=$max) — starting anyway against $CHIEF_MACHINE_HOLD_REASON"
      break
    fi
    if [ "$said" = 0 ]; then
      said=1
      chief_machine_gate_note "$log" "⏸ HOLD $name $CHIEF_MACHINE_HOLD_REASON"
    fi
    if [ -n "$live" ] && command -v live_set >/dev/null 2>&1; then
      live_set "$live" phase=gate-budget-waiting
    fi
    sleep "$step"
    waited=$(( waited + step ))
  done
  CHIEF_MACHINE_GATE_WAITED="$waited"
  [ "$said" = 0 ] || chief_machine_gate_note "$log" "RESUME $name admitted at $CHIEF_MACHINE_GATES/$CHIEF_MACHINE_GATE_BUDGET gate(s), load $CHIEF_MACHINE_LOAD_AVERAGE, after ${waited}s"
  return 0
}

chief_machine_load_average() {
  local load
  load="${CHIEF_LOAD_AVERAGE:-}"
  if [ -z "$load" ]; then
    load="$(sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print $1}' )"
  fi
  if [ -z "$load" ] && [ -r /proc/loadavg ]; then
    load="$(awk '{print $1}' /proc/loadavg 2>/dev/null)"
  fi
  case "$load" in
    ''|*[!0-9.]*|*.*.*) printf '?'; return 0 ;;
    *) printf '%s' "$load" ;;
  esac
}

# THE LOAD LINE, and the word it is allowed to print.
#
# `OVERSUBSCRIBED` used to mean "load > cores" and nothing else happened as a
# result of it -- a string beside a number. Now that the number is an admission
# input, the word is reserved for the case where it CHANGED something: the ceiling
# is refusing a gate right now. Over the ceiling with no gate of chief's in flight
# is the BOUND doing its job (`chief_machine_load_allows` above), and the line says
# so instead -- an alarm word on a machine chief is admitting work onto teaches an
# operator to ignore the alarm.
chief_machine_load_line() {
  chief_machine_budget_ensure
  local load="${CHIEF_MACHINE_LOAD_AVERAGE:-}"
  [ -n "$load" ] || { chief_machine_load_sample; load="$CHIEF_MACHINE_LOAD_AVERAGE"; }
  printf 'load average: %s / %s physical core(s)' "$load" "$CHIEF_MACHINE_CORES"
  if [ "$CHIEF_MACHINE_LOAD_DISABLED" = 1 ]; then
    printf ' · ceiling off'
    return 0
  fi
  # Named only when it is NOT the cores figure already printed, so an operator who
  # moved the ceiling sees the line the decision was actually made against.
  [ "$CHIEF_MACHINE_LOAD_LIMIT" = "$CHIEF_MACHINE_CORES" ] || \
    printf ' · ceiling %s' "$CHIEF_MACHINE_LOAD_LIMIT"
  if chief_machine_load_over; then
    if chief_machine_load_allows; then
      printf ' · over ceiling — admitting, no chief gate in flight'
    else
      printf ' · OVERSUBSCRIBED — new gates held'
    fi
  fi
  return 0
}

# A budget's own number, or the word for one an operator switched off. Three knobs
# and one phrasing for "off", so a disabled budget cannot read as a budget of 0.
chief_machine_cap() { # $1 value  $2 disabled
  if [ "${2:-0}" = 1 ]; then printf 'off'; else printf '%s' "${1:-0}"; fi
}

# "live/budget". The bare counts WERE the incident display: `5 agent turn(s) ·
# 0 gate(s)` is a pair of true numbers that says nothing about whether five is a
# lot, and beside a saturated load average it read as an idle machine.
chief_machine_ratio() { # $1 live  $2 budget  $3 disabled
  printf '%s/%s' "${1:-0}" "$(chief_machine_cap "${2:-0}" "${3:-0}")"
}

# ALL THREE KNOBS, in the order they are consulted. The old line named one budget
# and the core count its default derives from; the other two were settable,
# documented, and invisible in the one place a run states what it will enforce.
chief_machine_budget_line() {
  chief_machine_budget_ensure
  printf 'machine budget: %s agent turn(s) · %s gate(s) · load ceiling %s · on %s physical core(s)' \
    "$(chief_machine_cap "$CHIEF_MACHINE_BUDGET" "$CHIEF_MACHINE_BUDGET_DISABLED")" \
    "$(chief_machine_cap "$CHIEF_MACHINE_GATE_BUDGET" "$CHIEF_MACHINE_GATE_BUDGET_DISABLED")" \
    "$(chief_machine_cap "$CHIEF_MACHINE_LOAD_LIMIT" "$CHIEF_MACHINE_LOAD_DISABLED")" \
    "$CHIEF_MACHINE_CORES"
}

# Slack in ONE budget: its own subtraction, floored at zero. Pure arithmetic --
# whether a control is currently REFUSING is the caller's question, because the
# answer to that one belongs to `chief_machine_admits` and nowhere else.
chief_machine_slack() { # $1 live  $2 budget  $3 disabled
  if [ "${3:-0}" = 1 ]; then printf 'unlimited'; return 0; fi
  local left=$(( ${2:-0} - ${1:-0} ))
  [ "$left" -ge 0 ] || left=0
  printf '%s' "$left"
}

# WHAT ADMISSION WOULD DO RIGHT NOW, in the two numbers an operator is deciding on.
#
# Headroom is the ADMISSION answer, not the subtraction. The incident line reported
# `5 agent turn(s) · 0 gate(s)` against a budget of 14 on a box already at load
# 14.32, and read as nine free slots; a control that is currently refusing therefore
# reports ZERO however much of its own budget is unspent, and names itself. The
# reason is `chief_machine_admits`' own string -- the same one the launch loop and
# the gate boundary write to `machine-budget.log` -- so a display can never describe
# a hold in different words than the scheduler used to take it.
chief_machine_headroom_line() {
  chief_machine_budget_ensure
  local turns gates reason=""
  turns="$(chief_machine_slack "$CHIEF_MACHINE_AGENT_TURNS" "$CHIEF_MACHINE_BUDGET" "$CHIEF_MACHINE_BUDGET_DISABLED")"
  gates="$(chief_machine_slack "$CHIEF_MACHINE_GATES" "$CHIEF_MACHINE_GATE_BUDGET" "$CHIEF_MACHINE_GATE_BUDGET_DISABLED")"
  if ! chief_machine_admits launch; then turns=0; reason="$CHIEF_MACHINE_HOLD_REASON"; fi
  if ! chief_machine_admits gate;   then gates=0; reason="$CHIEF_MACHINE_HOLD_REASON"; fi
  printf 'headroom: %s agent turn(s) · %s gate(s)' "$turns" "$gates"
  [ -z "$reason" ] || printf ' · holding on %s' "$reason"
}

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
    # WHAT A GATE COSTS, not what happens near one. `merge-wait` is a worker sleeping
    # on its run's merge lock and `merge-conflict` is a parked terminal state; neither
    # spends a core, and both used to count. That was harmless while the number was
    # only printed — now that admission READS it, N workers queued behind one lock
    # would read as N gates and starve every other repo on the host.
    worktree|warmup|reconcile|rebasing|verifying|zone-check|merging)
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
  chief_machine_budget_ensure
  printf '%s live run(s) · %s agent turn(s) · %s gate(s) · %s' \
    "$CHIEF_MACHINE_RUNS" \
    "$(chief_machine_ratio "$CHIEF_MACHINE_AGENT_TURNS" "$CHIEF_MACHINE_BUDGET" "$CHIEF_MACHINE_BUDGET_DISABLED")" \
    "$(chief_machine_ratio "$CHIEF_MACHINE_GATES" "$CHIEF_MACHINE_GATE_BUDGET" "$CHIEF_MACHINE_GATE_BUDGET_DISABLED")" \
    "$(chief_machine_load_line)"
  if [ "${CHIEF_MACHINE_STALE:-0}" -gt 0 ]; then
    printf ' · %s stale record(s) ignored' "$CHIEF_MACHINE_STALE"
  fi
  return 0
}
