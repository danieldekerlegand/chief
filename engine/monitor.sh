#!/usr/bin/env bash
# engine/monitor.sh — show active Chief runs across ALL repos on this host.
#
# Reads the global run registry (default ~/.chief/runs), where each live driver
# drops a small <pid>.run file naming its repo, schedule, and state dir. For each
# run this prints the repo, the per-tasklist scheduler state, story progress
# (passing/total), the branch, and — for a running tasklist — its latest progress
# note. Read-only. Run files whose owning pid is dead are pruned as they're seen.
#
# A tasklist paused on a Claude usage/session limit (scheduler state 'rate-limited',
# see the SCHEDULER STATES block in driver.sh) renders as 'paused' with the retry
# ETA and the re-dispatch count — a limit-interrupted run self-heals, so it must
# read as waiting, not as failed/blocked and not as a hang.
#
# There is a SECOND pause with the same glyph and a completely different meaning: an
# OPERATOR pause (scheduler state 'paused', armed by `chief pause`). Chief lifts the
# usage-limit one by itself and NEVER lifts the operator one, so a reader who cannot
# tell them apart cannot tell "wait 28 minutes" from "wait for a human". Both render
# ⏸; the note says which — 'paused: usage limit — retry at 15:10' vs 'paused: operator
# hold — … resume: chief resume' — and when BOTH are armed on a repo the run header
# says so explicitly, because lifting either one alone changes nothing.
#
# There is a THIRD hold on the same glyph: 'awaiting-review' (label 'in-review'), a
# plan-review tasklist whose plan no human has approved yet (docs/plan-review.md).
# Same reasoning again — quota, operator and reviewer are three different people to
# go and find — so it gets its own label and its own note. It is a hold, never a
# fault: the branch, the worktree and the plan are all intact.
#
# For a tasklist that is actually working, the coarse word 'running' says nothing
# about whether it is WORKING or HUNG. So each row also carries the fine-grained
# liveliness record (engine/live.sh, written by agent.sh + driver.sh): the current
# phase, how long it has been in that phase, the story and iteration, and how long
# since the run last did anything. The record is optional in every direction — no
# file, no fields, no jq — and its absence degrades to exactly the row this printed
# before it existed.
#
# And when that last-activity age crosses the threshold THIS PHASE has earned
# (CHIEF_STALE_SECONDS, default 900 = 15m, re-tuned per phase below) a RUNNING
# tasklist is flagged at-risk: a red ⚠ glyph in place of the ● and an explicit
# '⚠ stalled in <phase>' on its detail line — the state it is stuck in, not just the
# silence, because the silence alone is a thing an operator learns to ignore. A
# tasklist whose WORKER PID is gone takes a ✗ instead: absent is a different and worse
# finding than quiet, and rendering the two identically is how a working run gets
# killed. So: actively-progressing (● + a ticking heartbeat), paused on a usage limit
# (⏸ + a retry ETA), stalled (⚠ + which state), or gone (✗) — and none of them can be
# mistaken for another. All of it is derived from the record + the registry + a
# kill -0; the monitor never touches a run.
#
# Invoked by the CLI:
#   chief ps                 -> monitor.sh once
#   chief monitor [interval] -> monitor.sh watch [interval]   (refresh in place)
#
# Bash 3.2 compatible (no associative arrays). jq is used opportunistically for
# story counts; absent jq just yields "?/?".
set -uo pipefail

# shellcheck source=engine/paths.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/paths.sh"
RUNS="$(chief_runs_dir)"
MODE="${1:-once}"
INTERVAL="${2:-2}"

# How long a RUNNING tasklist may go without a heartbeat before it reads as stalled.
# The default is generous on purpose: an agent turn ticks the record every ~15s
# (agent.sh's in-turn ticker), but a driver phase with no ticker — a verify that runs
# `npm ci` + `cargo build`, a long rebase — can legitimately go quiet for minutes.
# 15m is well under the multi-hour silence this signal exists to catch.
STALE_AFTER="${CHIEF_STALE_SECONDS:-900}"
case "$STALE_AFTER" in ''|*[!0-9]*) STALE_AFTER=900 ;; esac

# QUIET-BY-DESIGN PHASES — the ONE list of record phases whose silence IS the
# behaviour rather than a symptom of it. Data, in one place: exempting a state is
# adding a word here, never a condition at a render site.
#
# MEASURED 2026-08-13. Ten tasklists across three repos rendered
# `rate-limited-waiting for 16m · ⚠ stalled — no activity for 16m` — chief printing
# the reason for the silence and then flagging the silence, on one line, from the same
# live_note() call. Every driver was alive (S+) and every run resumed when the window
# reopened. agent.sh's `_rate_limit_wait` publishes the phase and THEN sleeps, so the
# record cannot tick: the heartbeat gap IS the wait, exactly, and flagging it is
# flagging chief's own countdown.
#
# The hold phases after it are here for the same reason plus one more: they are
# normally reached with a coarse state that already excludes them from this check, so
# listing them costs nothing and stops a record whose `phase` outran its `state` from
# reproducing the bug.
#
# NOT ON THIS LIST, deliberately:
#   provider-waiting   the whole duration of an agent turn (agent.sh sets it right
#                      before the provider CLI and holds it until the CLI returns).
#                      Quiet is USUAL here, not by design — a provider that never
#                      returns is a real hang. On 2026-08-17 two runs sat in this
#                      phase having produced 0 bytes and never reached iteration 1;
#                      an exemption would have hidden the only genuine anomalies of
#                      that night. It wants a LONGER threshold, not silence.
#   verifying · warmup a non-tty `cargo test` block-buffers its output, so a gate can
#                      be 36m quiet and working (cuneiform:314, 2026-08-13 — the child
#                      test binary changed between samples). Indistinguishable from a
#                      wedged one from out here, so: a longer threshold, not silence.
STALE_QUIET_PHASES=' rate-limited-waiting rate-limited operator-paused awaiting-review awaiting-approval '

# The CEILING on that exemption — quiet by design is not quiet forever. A usage window
# that never reopens is exactly what an operator has to be told about, so the exemption
# expires rather than making a state permanently unflaggable. The figure is the
# engine's own bound on one wait rather than a round number: `_seconds_until_reset`
# (agent.sh) caps a single limit sleep at 21600s, so past 6h + one default window the
# sleep should long since have returned and the phase should have moved. The waits
# actually observed on 2026-08-13 were 5–16m and cleared on their own.
STALE_QUIET_AFTER="${CHIEF_STALE_QUIET_SECONDS:-23400}"      # 21600 + STALE_AFTER
case "$STALE_QUIET_AFTER" in ''|*[!0-9]*) STALE_QUIET_AFTER=23400 ;; esac

# PER-PHASE THRESHOLDS — `phase:seconds`, one entry per phase that was RE-TUNED
# against a measurement. This is the second half of the same idea as the list above:
# suppressing the flag outright would trade a false positive for a blind spot, so what
# moves is the THRESHOLD, never the concept. 15m is alarming for an agent turn and
# unremarkable for a usage window; both numbers can be right at once only if the
# number is per-phase.
#
# A phase ABSENT from this table takes $STALE_AFTER, so the default is unchanged for
# every phase nobody has evidence about. An entry is a claim, and a claim wants the
# figure that was actually OBSERVED — not a round number that felt safe:
#
#   verifying · warmup   36m + one default window. A non-tty `cargo test`
#                        block-buffers its output, so cuneiform:314 ran 36m (2160s)
#                        quiet on 2026-08-13 while working — sampling the child PID
#                        showed the test binary CHANGING between samples
#                        (render_oauth_session_gate -> render_offline_walker). Neither
#                        phase has a ticker behind it (only the agent turn does), so
#                        the gate's silence IS the record's silence, and the flag has
#                        to clear the longest gate actually seen plus one window.
#   provider-waiting     the DEFAULT, stated here rather than left to fall through —
#                        an explicit entry is what makes "we looked at this one" a
#                        fact in the table rather than an omission. agent.sh's
#                        `_beat_start` ticks the record every ${LIVE_BEAT_SECONDS:-15}s
#                        for the whole provider call, so 15m of silence in this phase
#                        is ~60 missed beats: the turn is not long, the ticker is
#                        DEAD. Lengthening it would hide exactly the runs that need
#                        the flag — on 2026-08-17 two sat in this phase having
#                        produced 0 bytes and never reached iteration 1.
#
# Interpolated, not literal: re-tuning $STALE_AFTER (CHIEF_STALE_SECONDS) still moves
# every phase that only ever agreed with the default.
STALE_PHASE_SECONDS="
  verifying:3060
  warmup:3060
  provider-waiting:$STALE_AFTER
"

# Colors only on a TTY (so piping `chief ps | …` stays clean).
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'
  RED=$'\033[31m'; CYN=$'\033[36m'; MAG=$'\033[35m'; RST=$'\033[0m'
else
  BOLD=; DIM=; GRN=; YEL=; RED=; CYN=; MAG=; RST=
fi

field() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -1; }

# The liveliness-record readers (live_get / live_age). Sourced via ${BASH_SOURCE[0]}
# and NEVER through a $CHIEF_HOME-derived path: an inherited CHIEF_HOME (an outer
# chief run, an older install) can point at a DIFFERENT engine tree. If the sibling
# is missing — an engine tree predating live.sh — the stubs keep every row rendering
# exactly as it did before.
_MON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_MON_DIR/live.sh" ]; then
  # shellcheck source=engine/live.sh
  . "$_MON_DIR/live.sh"
else
  live_get() { return 0; }
  live_age() { return 0; }
fi
live_file() { printf '%s' "$2/parallel/$1.live.json"; }   # $1 name $2 state root

# Live-driver identification (engine/reap.sh): chief_find_unregistered_drivers,
# which answers the question this view never asked — is there a driver RUNNING that
# no run file knows about? Sourced through ${BASH_SOURCE[0]} and guarded exactly
# like live.sh above: against an older engine tree the stub keeps every row
# rendering as it did before, and the view simply reports nothing extra.
if [ -f "$_MON_DIR/reap.sh" ]; then
  # shellcheck source=engine/reap.sh
  . "$_MON_DIR/reap.sh"
else
  CHIEF_UNREG=""; CHIEF_UNREG_INFO=""
  chief_find_unregistered_drivers() { CHIEF_UNREG=""; CHIEF_UNREG_INFO=""; }
  # Against an engine tree without the PID-namespace helpers, every record reads as
  # local — which is exactly how this view behaved before they existed.
  chief_run_file_ns() { printf ''; }
  chief_ns_foreign()  { return 1; }
fi

dur() {       # $1 = seconds -> "45s" / "12m" / "3h04m"
  local s="${1:-}"
  case "$s" in ''|*[!0-9]*) printf '?'; return ;; esac
  if   [ "$s" -lt 60 ]; then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%dm' "$(( s / 60 ))"
  else printf '%dh%02dm' "$(( s / 3600 ))" "$(( (s % 3600) / 60 ))"; fi
}

elapsed() {   # $1 = start epoch -> how long ago that was
  local start="${1:-}" now s
  case "$start" in ''|*[!0-9]*) printf '?'; return ;; esac
  now=$(date +%s)
  s=$(( now - start )); [ "$s" -lt 0 ] && s=0
  dur "$s"
}

stories() {   # $1 name $2 wtroot $3 staterel $4 stateroot $5 tasks -> "pass/total"
  local n="$1" prd p t
  for prd in "$2/$1/$3/prd.json" "$4/snapshots/$1.json" "$5/$1.json"; do
    [ -f "$prd" ] || continue
    p="$(jq '[.userStories[]?|select(.passes==true)]|length' "$prd" 2>/dev/null)"
    t="$(jq '.userStories|length' "$prd" 2>/dev/null)"
    if [ -n "$p" ] && [ -n "$t" ]; then printf '%s/%s' "$p" "$t"; return; fi
  done
  printf '?/?'
}

live_prog() { # $1 name $2 stateroot -> "pass/total" from the record (jq-free fallback)
  local lf p t
  lf="$(live_file "$1" "$2")"
  p="$(live_get "$lf" passing)"; t="$(live_get "$lf" total)"
  case "$t" in ''|0|*[!0-9]*) printf '?/?'; return ;; esac
  case "$p" in ''|*[!0-9]*) p=0 ;; esac
  printf '%s/%s' "$p" "$t"
}

# Elapsed-in-phase. live.sh moves `phase_since` only when the phase ACTUALLY changes,
# so this is the age of the current phase, not of the last write — it is what separates
# "verifying for 20s" from "verifying for 40m".
live_phase_age() { # $1 name $2 stateroot -> "12m" ('' when unknown)
  local ps
  ps="$(live_get "$(live_file "$1" "$2")" phase_since)"
  case "$ps" in ''|0|*[!0-9]*) return 0 ;; esac
  elapsed "$ps"
}

# How much silence THIS phase is allowed before it reads as stalled. The single place
# the policy is consulted, so the row's at-risk decision and the note it renders
# cannot drift apart — which is the whole defect: one half of the line said
# `rate-limited-waiting`, the other half called the same silence a stall.
#
# Three tiers, most specific first, and every phase resolves through exactly one of
# them: a measured per-phase entry, the quiet-by-design ceiling, then the default.
# Re-tuning a phase is one line in the table; exempting one is one word in the list.
stale_threshold_for_phase() { # $1 phase ('' = unknown) -> seconds
  local p="${1:-}" e
  # 1. an explicit entry — a number someone measured for THIS state. It wins over the
  #    tier below on purpose: a figure with an observation behind it beats a bucket.
  if [ -n "$p" ]; then
    for e in $STALE_PHASE_SECONDS; do
      case "$e" in "$p":*) printf '%s' "${e#*:}"; return 0 ;; esac
    done
  fi
  # 2. quiet by design — the ceiling, so the exemption expires instead of being one.
  case "$STALE_QUIET_PHASES" in
    *" $p "*) printf '%s' "$STALE_QUIET_AFTER"; return 0 ;;
  esac
  # 3. everything else, including an unknown phase: the pre-existing behaviour.
  printf '%s' "$STALE_AFTER"
}

# Is this heartbeat age past the staleness threshold FOR THIS PHASE? Unknown age (no
# record, no heartbeat) is NEVER stale — absent evidence must not manufacture an alarm.
# An unknown PHASE takes the default threshold, which is the pre-existing behaviour.
is_stale() { # $1 age in seconds [$2 phase]
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge "$(stale_threshold_for_phase "${2:-}")" ]
}

# IS THE WORKER STILL THERE? A quiet run and an ABSENT one are different conditions
# — the first wants patience, the second wants `chief reap` — and until now both
# rendered as the same yellow note, which is how nine runs came to be killed on
# 2026-08-17 on the assumption they were the same thing. Two files the scheduler
# already maintains answer it without touching the run:
#   <name>.pid      driver.sh writes it when it forks the worker, removes it in reap()
#   <name>.status   run_worker TRUNCATES it at its top and writes the verdict on the
#                   way out — so a non-empty status means the worker FINISHED and the
#                   scheduler simply has not reaped it yet (one $POLL_SECONDS tick).
#                   Finishing is not dying, and a row must not flash ✗ for a tick.
# Unknown in either direction is NOT dead: no pid file, an unreadable one, a pid that
# is alive — absent evidence must not manufacture an alarm, the same rule is_stale
# follows. The pid is read raw, which is only meaningful because the caller has
# already excluded runs from another PID NAMESPACE (render skips a foreign run before
# it reaches its rows); a bare pid from another namespace means nothing here.
worker_gone() { # $1 name $2 stateroot -> 0 when its worker died without a verdict
  local pid
  pid="$(cat "$2/parallel/$1.pid" 2>/dev/null || echo)"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null && return 1
  [ -s "$2/parallel/$1.status" ] && return 1
  return 0
}

# The at-risk detail line when there is NO record to read, or one with no phase in it.
# live_note's line names the state that went quiet; here there is no state to name, so
# this stays the generic sentence it has always been — one for each finding.
# It still carries ELAPSED-IN-PHASE when the record has a `phase_since` but no phase
# to put beside it: this is the second of the two render paths, and a duration that
# appears in one view and not the other reproduces the very split this file keeps
# closing — one half of the line saying more than the other half.
flag_fallback() { # $1 dead-flag $2 age $3 elapsed-in-phase ('' unknown) -> the line
  local held=""
  [ -n "${3:-}" ] && held=" · in this state for $3"
  if [ "${1:-0}" = 1 ]; then printf '✗ dead — its worker pid is gone and left no verdict%s · chief reap' "$held"
  else printf '⚠ stalled — no activity for %s%s' "$(dur "${2:-}")" "$held"; fi
}

# The fine-grained detail line: what this tasklist is doing RIGHT NOW (the record's
# phase, rendered verbatim — the monitor never switches on an allow-list), how long it
# has been in that phase, which story and iteration it is on, and the time since its
# last activity. Empty when there is no record or no phase, which is what makes the
# fallback automatic. With $3=stale the trailing age becomes the at-risk flag instead.
live_note() { # $1 name $2 stateroot [$3 stale] -> one line ('' when nothing to add)
  local lf note phase story iter stall age pa
  lf="$(live_file "$1" "$2")"
  [ -f "$lf" ] || return 0
  phase="$(live_get "$lf" phase)"
  [ -n "$phase" ] || return 0
  story="$(live_get "$lf" story)"; iter="$(live_get "$lf" iter)"
  stall="$(live_get "$lf" stall)"; age="$(live_age "$lf")"
  pa="$(live_phase_age "$1" "$2")"
  note="$phase"
  [ -n "$pa" ] && note="$note for $pa"
  [ -n "$story" ] && note="$note · $story"
  case "$iter"  in ''|0|*[!0-9]*) ;; *) note="$note · iter $iter"   ;; esac
  case "$stall" in ''|0|*[!0-9]*) ;; *) note="$note · stall $stall" ;; esac
  # The caller asks for the flag; this asks the POLICY whether this phase has earned
  # it. Same predicate the row's glyph uses, so the two halves of the line always
  # agree — and a caller that has not consulted the policy cannot reintroduce
  # `rate-limited-waiting for 16m · ⚠ stalled — no activity for 16m`.
  # GONE outranks QUIET. Checked first and independently of $3, because a worker that
  # died is worth saying however fresh its last heartbeat was — a run killed ten
  # seconds ago is not stale yet and is still never coming back.
  if [ "$(live_get "$lf" state)" = running ] && worker_gone "$1" "$2"; then
    note="$note · ✗ dead — its worker pid is gone and left no verdict · chief reap"
  elif [ "${3:-}" = stale ] && is_stale "$age" "$phase"; then
    # The flag carries the DIAGNOSIS, not just the silence: which state it was stuck
    # in, and the limit that state has earned. 'stalled in rate-limited-waiting …
    # past its 6h30m limit' is actionable; 'no activity for 2h' is a thing to ignore.
    note="$note · ⚠ stalled in $phase — no activity for $(dur "${age:-}"), past its $(dur "$(stale_threshold_for_phase "$phase")") limit"
  else
    [ -n "$age" ] && note="$note · $(dur "$age") ago"
  fi
  printf '%s' "$note"
}

branch_of() { # $1 name $2 tasks
  local b
  b="$(jq -r '.branchName // empty' "$2/$1.json" 2>/dev/null)"
  if [ -n "$b" ] && [ "$b" != "null" ]; then printf '%s' "$b"; else printf 'chief/%s' "$1"; fi
}

activity_of() { # $1 = progress.txt path -> latest meaningful line (truncated)
  [ -f "$1" ] || return 0
  awk 'NF && $0 !~ /^#/ && $0 !~ /^---/ {last=$0} END{if(last)print last}' "$1" 2>/dev/null | cut -c1-76
}

glyph_for() { # $1 = state -> "<color><glyph><reset>|<label>"
  case "$1" in
    running)         printf '%s●%s|running' "$YEL" "$RST" ;;
    done)            printf '%s✓%s|done'    "$GRN" "$RST" ;;
    failed)          printf '%s✗%s|failed'  "$RED" "$RST" ;;
    blocked)         printf '%s⤬%s|blocked' "$RED" "$RST" ;;
    rate-limited)    printf '%s⏸%s|paused'  "$CYN" "$RST" ;;
    # The OPERATOR pause. Same ⏸ (it is a pause, not a fault — never a failure
    # glyph), a distinct label so `chief ps | grep` can tell the two apart, and a
    # distinct note below.
    paused)          printf '%s⏸%s|paused-op' "$YEL" "$RST" ;;
    # Parked on a HUMAN VERDICT (docs/plan-review.md). A hold, so the same ⏸ and
    # never a failure glyph — and its own label, because "who is holding this" is
    # the only question the row has to answer: an account's quota, an operator, or
    # a reviewer who has not looked yet.
    awaiting-review) printf '%s⏸%s|in-review' "$CYN" "$RST" ;;
    # Held at an OVERLAP ZONE (docs/reference/overlap-zones.md). The same ⏸ once
    # more — it is a hold, not a fault — and its own label, because this row is the
    # one whose branch already PASSED everything: rebased, verified green, waiting
    # only on the judgement no gate can make.
    awaiting-approval) printf '%s⏸%s|zone-hold' "$MAG" "$RST" ;;
    pending)         printf '%s○%s|pending' "$DIM" "$RST" ;;
    *)               printf '%s·%s|%s'      "$DIM" "$RST" "${1:-unknown}" ;;
  esac
}

clock() {     # $1 = epoch -> "14:22"  (BSD date, then GNU date, then the raw epoch)
  date -r "$1" '+%H:%M' 2>/dev/null || date -d "@$1" '+%H:%M' 2>/dev/null || printf '%s' "$1"
}

# The paused-tasklist detail line. Everything it reads is what driver.sh's
# usage-limit self-heal writes: <name>.retry-at (this tasklist's reset epoch), the
# liveliness record's retry_at (the same epoch, stamped with the phase change),
# .limit-pause-until (the run-wide window, since one account = one window) and
# <name>.retries (re-dispatches spent). Any of them may be absent — the pause is
# still legible without an ETA, which is the whole point of the line. It closes
# with the heartbeat age, so a pause that has stopped ticking is visible too.
# Retry annotation. driver.sh writes <name>.attempts when a FAILED tasklist is re-armed
# (see RETRY ON FAILURE there); it is absent until a first retry, so an untouched tasklist
# renders exactly as before. Shown for running rows (this is attempt 2 of 3) and for failed
# ones (it used all 3), because "failed" means something different once retries are spent.
retry_note() {  # $1 name  $2 stateroot  $3 cap ("" if unknown) -> "attempt n/max" or ""
  local n="$1" sd="$2/parallel" cap="$3" tries
  tries="$(cat "$sd/$n.attempts" 2>/dev/null || echo 0)"
  case "$tries" in ''|*[!0-9]*) tries=0 ;; esac
  [ "$tries" -lt 2 ] && return 0
  case "$cap" in ''|*[!0-9]*) printf 'attempt %s' "$tries" ;; *) printf 'attempt %s/%s' "$tries" "$cap" ;; esac
}

limit_note() {  # $1 name  $2 stateroot  $3 cap ("" if unknown) -> one line
  local n="$1" sd="$2/parallel" cap="$3" at now left tries note age pa
  at="$(cat "$sd/$n.retry-at" 2>/dev/null || echo)"
  case "$at" in ''|0|*[!0-9]*) at="$(live_get "$(live_file "$n" "$2")" retry_at)" ;; esac
  case "$at" in ''|0|*[!0-9]*) at="$(cat "$sd/.limit-pause-until" 2>/dev/null || echo)" ;; esac
  case "$at" in ''|0|*[!0-9]*) at= ;; esac
  note='paused: usage limit'
  if [ -n "$at" ]; then
    now="$(date +%s)"; left=$(( (at - now + 59) / 60 )); [ "$left" -lt 0 ] && left=0
    note="$note — retry at $(clock "$at") (${left}m)"
  else
    note="$note — retries when the window resets"
  fi
  tries="$(cat "$sd/$n.retries" 2>/dev/null || echo 0)"
  case "$tries" in ''|*[!0-9]*) tries=0 ;; esac
  case "$cap" in ''|*[!0-9]*) ;; *) note="$note · re-dispatch $tries/$cap" ;; esac
  pa="$(live_phase_age "$n" "$2")"
  [ -n "$pa" ] && note="$note · paused $pa"
  age="$(live_age "$(live_file "$n" "$2")")"
  [ -n "$age" ] && note="$note · $(dur "$age") ago"
  printf '%s' "$note"
}

# The usage-limit WINDOW for a repo (run-wide, one account = one window): the future
# epoch in .limit-pause-until, or '' when nothing is armed. An expired stamp is not a
# hold, so it reads as absent — the driver clears it lazily.
limit_window() {  # $1 stateroot -> epoch | ''
  local at
  at="$(cat "$1/parallel/.limit-pause-until" 2>/dev/null || echo)"
  case "$at" in ''|0|*[!0-9]*) return 0 ;; esac
  [ "$at" -gt "$(date +%s)" ] && printf '%s' "$at"
  return 0
}

# The OPERATOR pause flag for a repo. PRESENCE is the gate (bin/chief pause writes an
# informational epoch stamp into it, but a truncated file must still read as armed —
# same rule the driver and agent gate on).
op_armed()  { [ -f "$1/parallel/.paused" ]; }
op_since()  {  # $1 stateroot -> epoch | ''  (the stamp, when it is one)
  local s; s="$(cat "$1/parallel/.paused" 2>/dev/null || echo)"
  case "$s" in ''|0|*[!0-9]*) return 0 ;; esac
  printf '%s' "$s"
}

# The paused-tasklist detail line for an OPERATOR pause — the sibling of limit_note
# above, and deliberately not shaped like it: there is no ETA to show and no
# re-dispatch budget being spent, because Chief will never lift this one. What the
# reader needs instead is that nothing was lost (branch AND worktree kept) and the
# exact command that picks it back up. It closes with the phase/heartbeat ages, so a
# park that happened days ago still dates itself.
op_note() {   # $1 name  $2 stateroot -> one line
  local n="$1" note since lim pa age
  note='paused: operator hold'
  since="$(op_since "$2")"
  if op_armed "$2"; then
    note="$note (chief pause)${since:+ — armed $(clock "$since")}"
  else
    # Parked by a pause that has since been lifted without a resume sweep: the
    # tasklist stays parked until something re-arms it, so name that something.
    note="$note — the flag is already lifted; 'chief resume' re-arms this as pending"
  fi
  note="$note · branch + worktree kept · resume: chief resume"
  # BOTH holds: resuming alone would not start it. Say so on the row itself — the
  # header banner is easy to scroll past when a run has many tasklists.
  lim="$(limit_window "$2")"
  [ -n "$lim" ] && note="$note · usage-limit window also armed until $(clock "$lim")"
  pa="$(live_phase_age "$n" "$2")"
  [ -n "$pa" ] && note="$note · parked $pa"
  age="$(live_age "$(live_file "$n" "$2")")"
  [ -n "$age" ] && note="$note · $(dur "$age") ago"
  printf '%s' "$note"
}

# The two HUMAN-VERDICT holds' detail lines — the plan-review park and the overlap-zone
# park. Unlike the usage-limit and operator holds there is no per-tasklist ETA or budget
# to read: the whole answer is WHICH person has not looked yet, and how to unblock it.
# They were written inline in render()'s row loop; they live here because both of them
# were missing the one thing every other row already had — HOW LONG the hold has been
# held. 'awaiting review' says nothing an operator can act on; 'awaiting review · held
# 3h12m' is the difference between a checkpoint working and a checkpoint forgotten, and
# it is the same `phase_since` reading limit_note and op_note already print.
# Prints the whole ↳ line (both arms are a hold, so both keep the row's ⏸ colouring).
hold_note() { # $1 name $2 stateroot $3 coarse state -> one full '↳' line
  local pa held zreq zz zf
  pa="$(live_phase_age "$1" "$2")"; held="${pa:+ · held $pa}"
  if [ "$3" = awaiting-review ]; then
    printf '       %s↳ awaiting review: a human has not approved its plan · branch + worktree + plan kept%s · approve it, then: chief run%s\n' \
      "$CYN" "$held" "$RST"
    return 0
  fi
  # Reading the request the driver wrote: the interesting part is which domain stopped
  # it, and that is the whole answer to "why is a green branch not merged". Degrades to
  # the bare fact when the request (or jq) is unavailable.
  zreq="$2/parallel/$1.zone-request.json"
  zz="$(jq -r '[(.zones // [])[] | .zone] | join(", ")' "$zreq" 2>/dev/null || echo)"
  zf="$(jq -r '(.files // []) | length' "$zreq" 2>/dev/null || echo)"
  printf '       %s↳ awaiting approval: rebased + verified GREEN, held at %s%s%s · approve: chief approve %s%s\n' \
    "$MAG" "${zz:-a review-policy overlap zone}" \
    "$([ -n "$zf" ] && printf ' (%s changed file(s))' "$zf")" "$held" "$1" "$RST"
}

# The run-level HOLDS banner: what is stopping this repo from launching anything,
# printed under the run header before the per-tasklist rows. Silent when nothing is
# armed (the normal case). Both holds gate the launch loop independently, so with
# both armed the run resumes only when the window resets AND a human runs
# `chief resume` — the one fact neither line says on its own.
holds_render() {  # $1 stateroot  $2 names
  local lim now left n draining=""
  lim="$(limit_window "$1")"
  op_armed "$1" || { [ -n "$lim" ] || return 0; }
  if op_armed "$1"; then
    local since=""
    since="$(op_since "$1")"
    printf '   %s⏸ OPERATOR PAUSE armed%s%s%s — no tasklist launches, no new agent iterations · lift: chief resume%s\n' \
      "$YEL" "${since:+ $(elapsed "$since") ago}" "$RST" "$DIM" "$RST"
    # Workers still alive under an armed pause are DRAINING, not ignoring it: each
    # stops at its next iteration boundary (and one already past its agent loop
    # finishes verify+merge). Without this the rows read as a pause that isn't working.
    for n in $2; do
      [ "$(cat "$1/parallel/$n.state" 2>/dev/null || echo)" = running ] && draining="$draining $n"
    done
    [ -n "$draining" ] && printf '     %s↳ draining:%s — each stops at its next iteration boundary, then parks%s\n' \
      "$DIM" "$draining" "$RST"
  fi
  if [ -n "$lim" ]; then
    now="$(date +%s)"; left=$(( (lim - now + 59) / 60 )); [ "$left" -lt 0 ] && left=0
    printf '   %s⏸ usage-limit window until %s (%dm)%s%s — Chief waits this one out itself%s\n' \
      "$CYN" "$(clock "$lim")" "$left" "$RST" "$DIM" "$RST"
  fi
  if op_armed "$1" && [ -n "$lim" ]; then
    printf '     %s↳ BOTH holds are armed — lifting either one alone changes nothing%s\n' "$YEL" "$RST"
  fi
  return 0
}

# ── the registry's INVERSE ────────────────────────────────────────────────────
# Pruning a run file whose pid is dead was only half the job. The other half — a
# driver that is ALIVE with no run file — is the half that hurt: the field report
# that produced this work read 'no active runs' while an agent was mid-iteration,
# burning quota nothing was watching. An unregistered driver is therefore shown as
# such, never hidden, and never counted as if it were a healthy run.
UNREG_N=0
unreg_scan() {
  UNREG_N=0
  chief_find_unregistered_drivers
  [ -n "$CHIEF_UNREG" ] || return 0
  # shellcheck disable=SC2086
  set -- $CHIEF_UNREG
  UNREG_N="$#"
  return 0
}

# Identify it back to its repo and its work, because "something is wrong" is not
# actionable: the operator needs to know what this pid is driving before deciding
# to kill it, and what state the single-driver lock is in afterwards.
unreg_render() {
  local pid tag repo lock work label
  printf '\n%s⚠ %d unregistered driver(s)%s — alive, but missing from the run registry (%s):\n' \
    "$RED" "$UNREG_N" "$RST" "$RUNS"
  printf '%s\n' "$CHIEF_UNREG_INFO" | while IFS=$'\t' read -r pid tag repo lock work; do
    [ -n "$pid" ] || continue
    label="$(basename "${repo:-unknown}")"
    printf '   %s⚠%s %s%s%s  %s(pid %s · run %s)%s\n' \
      "$RED" "$RST" "$BOLD" "$label" "$RST" "$DIM" "$pid" "${tag:-?}" "$RST"
    printf '     %s%s%s\n' "$DIM" "${repo:-?}" "$RST"
    if [ -n "$work" ]; then
      # shellcheck disable=SC2086
      set -- $work                                  # "<name> <state>" pairs
      while [ "$#" -ge 2 ]; do
        printf '       %s↳ in flight: %-22s %s%s\n' "$CYN" "$1" "$2" "$RST"
        shift 2
      done
    else
      printf '       %s↳ no scheduler state yet — it may not have dispatched a tasklist%s\n' "$DIM" "$RST"
    fi
    case "$lock" in
      held)     printf '       %s↳ holds this repo'"'"'s driver.lock — a new run here will refuse to start%s\n' "$DIM" "$RST" ;;
      missing)  printf '       %s↳ driver.lock is GONE — only this check stands between it and a second driver%s\n' "$YEL" "$RST" ;;
      other:*)  printf '       %s↳ driver.lock is held by pid %s, not this one%s\n' "$YEL" "${lock#other:}" "$RST" ;;
      stale:*)  printf '       %s↳ driver.lock names dead pid %s%s\n' "$YEL" "${lock#stale:}" "$RST" ;;
      foreign:*) printf '       %s↳ driver.lock was taken in ANOTHER PID namespace (pid %s) — liveness unknowable from here%s\n' \
                   "$YEL" "${lock#foreign:}" "$RST" ;;
    esac
    printf '       %s↳ stop it:  kill %s    then:  chief reap    (reaps whatever it leaves behind)%s\n' "$DIM" "$pid" "$RST"
  done
  return 0
}

# Run files this process must not interpret: written where their pids were numbered
# in a different PID namespace. Named, so an operator who is sharing a prefix between
# containers sees WHY `chief ps` is quieter than the directory listing suggests.
foreign_note() {   # $1 = count
  [ "${1:-0}" -gt 0 ] || return 0
  printf '%s%d run file(s) belong to another PID namespace (another container sharing %s) — not shown, not removed.%s\n' \
    "$DIM" "$1" "$RUNS" "$RST"
}

render() {
  local now runfiles="" f pid n_active=0 n_foreign=0 n_files=0
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  set -- "$RUNS"/*.run
  [ -e "$1" ] && runfiles="$*"

  # Header (count active first so a run whose pid just died isn't counted).
  #
  # This loop DELETES the run file of a run whose pid is gone — reasonable when the
  # pid is ours to check, destructive when it is not. A shared $CHIEF_PREFIX (a
  # bind-mounted ~/.chief, one volume in two containers) puts another PID namespace's
  # entries in this directory, where their pids mean nothing here and would read as
  # dead: a `chief ps` in a container would quietly delete the registry of a live run
  # in another. Those entries are left ALONE — not counted, not rendered, not removed
  # — and reported as a one-line footnote instead.
  for f in $runfiles; do
    [ -e "$f" ] || continue
    n_files=$(( n_files + 1 ))
    if chief_ns_foreign "$(chief_run_file_ns "$f")"; then n_foreign=$(( n_foreign + 1 )); continue; fi
    pid="$(field pid "$f")"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then n_active=$(( n_active + 1 )); else rm -f "$f" 2>/dev/null; fi
  done
  # Scanned BEFORE the header prints: a driver nobody registered is still a run, and
  # a headline that omits it is the exact lie this fixes.
  unreg_scan
  if [ "$n_active" -eq 0 ] && [ "$UNREG_N" -eq 0 ]; then
    if [ -z "$runfiles" ]; then
      printf '%sCHIEF%s · no active runs · %s%s%s\n' "$BOLD" "$RST" "$DIM" "$now" "$RST"
      printf '%sStart one with:  chief run -p N%s\n' "$DIM" "$RST"
    else
      printf '%sCHIEF%s · %s0 active run(s)%s · %s%s%s\n' "$BOLD" "$RST" "$CYN" "$RST" "$DIM" "$now" "$RST"
      # Only claim they exited if any of them were ours to check.
      [ "$n_foreign" -lt "$n_files" ] && printf '%sAll registered runs have exited.%s\n' "$DIM" "$RST"
      foreign_note "$n_foreign"
    fi
    return 0
  fi
  printf '%sCHIEF%s · %s%d active run(s)%s%s · %s%s%s\n' "$BOLD" "$RST" "$CYN" "$n_active" "$RST" \
    "$([ "$UNREG_N" -gt 0 ] && printf ' · %s⚠ %d unregistered%s' "$RED" "$UNREG_N" "$RST")" "$DIM" "$now" "$RST"
  foreign_note "$n_foreign"
  if [ "$n_active" -eq 0 ]; then
    # Only a registry that HAD entries can have "all exited" — with no run files at
    # all the only thing running is the unregistered driver below.
    [ -n "$runfiles" ] && [ "$n_foreign" -lt "$n_files" ] && printf '%sAll registered runs have exited.%s\n' "$DIM" "$RST"
    unreg_render
    return 0
  fi

  for f in $runfiles; do
    [ -e "$f" ] || continue
    chief_ns_foreign "$(chief_run_file_ns "$f")" && continue
    pid="$(field pid "$f")"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue

    local repo base par tool model state staterel tasks wt names label started limitmax retrymax pm \
          acct acctfile
    repo="$(field repo "$f")";       base="$(field base "$f")"
    par="$(field parallel "$f")";    tool="$(field tool "$f")"
    model="$(field model "$f")"
    state="$(field state "$f")";     staterel="$(field staterel "$f")"
    tasks="$(field tasks "$f")";     wt="$(field wt "$f")"
    names="$(field names "$f")";     started="$(field started "$f")"
    limitmax="$(field limitmax "$f")"
    retrymax="$(field retrymax "$f")"
    # ACCOUNT DESIGNATION (docs/reference/account-credentials.md) — WHICH account this run
    # spends, never its credentials: the registry carries the operator's label and the
    # env-file PATH, and the file's values are never written anywhere the monitor reads.
    acct="$(field accountlabel "$f")"; acctfile="$(field account "$f")"
    [ -n "$acct" ] || acct="$([ -n "$acctfile" ] && basename "$acctfile")"
    [ -n "$staterel" ] || staterel=".chief/state"
    label="$(basename "$repo")"
    # provider, plus its model when one was selected: "devin · claude-opus-5-high"
    pm="${tool:-claude}"; [ -n "$model" ] && pm="$pm · $model"
    # An undesignated run says nothing here — the segment appears only when the run
    # was actually pinned to an account, so "no segment" still reads as "inherited".
    [ -n "$acct" ] && pm="$pm · acct:$acct"

    printf '\n%s%s%s  %s(pid %s · -p%s · %s · %s · →%s)%s\n' \
      "$BOLD" "$label" "$RST" "$DIM" "$pid" "${par:-1}" "$pm" "$(elapsed "${started:-}")" "${base:-main}" "$RST"
    printf '%s  %s%s\n' "$DIM" "$repo" "$RST"
    holds_render "$state" "$names"

    local n st glyph gl lbl br prog act live age stale dead rn bo lf lph
    for n in $names; do
      st="$(cat "$state/parallel/$n.state" 2>/dev/null || echo)"
      lf="$(live_file "$n" "$state")"
      # The record also carries the coarse state (set_state writes both), so a row
      # survives a missing/half-written <name>.state file.
      [ -n "$st" ] || st="$(live_get "$lf" state)"
      [ -n "$st" ] || st=unknown
      # At-risk = scheduler says RUNNING but the record stopped ticking FOR LONGER
      # THAN ITS PHASE ALLOWS. A paused tasklist is deliberately excluded: it has its
      # own glyph and an ETA, and a long quiet wait is what it is SUPPOSED to be
      # doing. The record's phase says the same thing one level down — a run asleep on
      # a usage limit is quiet on purpose while the scheduler still calls it running —
      # so the threshold is per-phase (STALE_QUIET_PHASES above), not one number.
      age="$(live_age "$lf")"
      lph="$(live_get "$lf" phase)"
      stale=0
      [ "$st" = running ] && is_stale "$age" "$lph" && stale=1
      dead=0                       # …and ABSENT is not the same finding as quiet
      [ "$st" = running ] && worker_gone "$n" "$state" && dead=1
      glyph="$(glyph_for "$st")"; gl="${glyph%%|*}"; lbl="${glyph##*|}"
      # Braced: an unbraced $RED before a multibyte glyph is parsed as part of the
      # variable NAME by bash 3.2 ("RED⚠: unbound variable").
      [ "$stale" = 1 ] && gl="${RED}⚠${RST}"
      # …and the LABEL moves with the glyph. A gone row that still reads `running` in
      # the one column an operator scans is the 2026-08-17 mistake in miniature: the
      # scheduler's word for it is stale by definition (nothing survives to update it),
      # so the row says what is TRUE, not what was last written down.
      [ "$dead" = 1 ] && { gl="${RED}✗${RST}"; lbl=gone; }   # outranks ⚠: gone is not slow
      br="$(branch_of "$n" "$tasks")"
      prog="$(stories "$n" "$wt" "$staterel" "$state" "$tasks")"
      [ "$prog" = '?/?' ] && prog="$(live_prog "$n" "$state")"
      rn="$(retry_note "$n" "$state" "$retrymax")"
      printf '   %b %-22s %-9s %-7s %s%s%s%s\n' "$gl" "$n" "$lbl" "$prog" "$DIM" "$br" \
        "$([ -n "$rn" ] && printf ' · %s' "$rn")" "$RST"
      if [ "$st" = rate-limited ]; then
        printf '       %s↳ %s%s\n' "$CYN" "$(limit_note "$n" "$state" "$limitmax")" "$RST"
      elif [ "$st" = paused ]; then
        # The operator hold. Same ⏸, its own note — and NOT the live_note line: the
        # record's phase here is always 'operator-paused', which would only repeat
        # the word without saying what was kept or how to pick it back up.
        printf '       %s↳ %s%s\n' "$YEL" "$(op_note "$n" "$state")" "$RST"
      elif [ "$st" = awaiting-review ] || [ "$st" = awaiting-approval ]; then
        hold_note "$n" "$state" "$st"
      else
        # What it's doing right now (phase · elapsed-in-phase · story · iter · age)
        # above the note the agent last wrote. Both are optional; neither line prints
        # empty. A stale row says so in words, in red, so the flag survives a grep.
        if [ "$stale" = 1 ] || [ "$dead" = 1 ]; then
          live="$(live_note "$n" "$state" stale)"
          [ -n "$live" ] || live="$(flag_fallback "$dead" "$age" "$(live_phase_age "$n" "$state")")"
          printf '       %s↳ %s%s\n' "$RED" "$live" "$RST"
        else
          live="$(live_note "$n" "$state")"
          [ -n "$live" ] && printf '       %s↳ %s%s\n' "$CYN" "$live" "$RST"
        fi
        if [ "$st" = running ]; then
          act="$(activity_of "$wt/$n/$staterel/progress.txt")"
          [ -n "$act" ] && printf '       %s↳ %s%s\n' "$DIM" "$act" "$RST"
        fi
      fi
      # The per-story DIFF-SIZE BUDGET's finding (engine/budget.sh), on a row in ANY
      # state and silent unless a story went over. It belongs outside the arms above
      # because the case it exists for is the default one: under `warn` the branch
      # MERGES, so this row will read `done`, and the oversize would otherwise have
      # been visible only in a worker log nobody reopens.
      bo="$(jq -r 'select(.over == true)
             | "diff budget: " + ([ (.stories // [])[] | select(.over)
                 | .story + " " + (.lines | tostring) + "L/" + (.files | tostring) + "F" ] | join(", "))
               + " · budget " + (.limit.lines | tostring) + "L/" + (.limit.files | tostring) + "F per story ("
               + (.mode // "warn") + ")"' "$state/parallel/$n.budget.json" 2>/dev/null || echo)"
      [ -n "$bo" ] && printf '       %s↳ %s%s\n' "$YEL" "$bo" "$RST"
    done
  done
  [ "$UNREG_N" -gt 0 ] && unreg_render
  return 0
}

# `lib` renders NOTHING. It is the seam a test uses to source this file and drive the
# rendering helpers (stale_threshold_for_phase · is_stale · live_note) directly against
# a synthetic record — which is how "which phases are exempt from the stall flag" stays
# a checkable table instead of a reading of the shell. Unreachable from the CLI:
# bin/chief only ever passes `once` (chief ps) or `watch` (chief monitor).
if [ "$MODE" = lib ]; then
  :
elif [ "$MODE" = watch ]; then
  trap 'printf "\033[?25h"' EXIT                  # always restore the cursor
  trap 'exit 0' INT TERM                          # clean exit on Ctrl-C (EXIT trap runs)
  printf '\033[?25l'                              # hide cursor while watching
  while :; do
    printf '\033[2J\033[H'                        # clear + home
    render
    printf '\n%s(refresh %ss · Ctrl-C to exit)%s\n' "$DIM" "$INTERVAL" "$RST"
    sleep "$INTERVAL"
  done
else
  render
fi
