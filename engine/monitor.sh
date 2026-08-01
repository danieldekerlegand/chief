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
# For a tasklist that is actually working, the coarse word 'running' says nothing
# about whether it is WORKING or HUNG. So each row also carries the fine-grained
# liveliness record (engine/live.sh, written by agent.sh + driver.sh): the current
# phase, how long it has been in that phase, the story and iteration, and how long
# since the run last did anything. The record is optional in every direction — no
# file, no fields, no jq — and its absence degrades to exactly the row this printed
# before it existed.
#
# And when that last-activity age crosses CHIEF_STALE_SECONDS (default 900 = 15m) a
# RUNNING tasklist is flagged at-risk: a red ⚠ glyph in place of the ● and an explicit
# '⚠ stalled' on its detail line. That is the third bucket the operator needs — a run
# is actively-progressing (● + a ticking heartbeat), paused on a usage limit (⏸ + a
# retry ETA), or stalled (⚠) — and none of them can be mistaken for another. The flag
# is derived purely from the record + the registry; the monitor never touches a run.
#
# Invoked by the CLI:
#   chief ps                 -> monitor.sh once
#   chief monitor [interval] -> monitor.sh watch [interval]   (refresh in place)
#
# Bash 3.2 compatible (no associative arrays). jq is used opportunistically for
# story counts; absent jq just yields "?/?".
set -uo pipefail

RUNS="${CHIEF_RUNS:-${CHIEF_PREFIX:-$HOME/.chief}/runs}"
MODE="${1:-once}"
INTERVAL="${2:-2}"

# How long a RUNNING tasklist may go without a heartbeat before it reads as stalled.
# The default is generous on purpose: an agent turn ticks the record every ~15s
# (agent.sh's in-turn ticker), but a driver phase with no ticker — a verify that runs
# `npm ci` + `cargo build`, a long rebase — can legitimately go quiet for minutes.
# 15m is well under the multi-hour silence this signal exists to catch.
STALE_AFTER="${CHIEF_STALE_SECONDS:-900}"
case "$STALE_AFTER" in ''|*[!0-9]*) STALE_AFTER=900 ;; esac

# Colors only on a TTY (so piping `chief ps | …` stays clean).
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'
  RED=$'\033[31m'; CYN=$'\033[36m'; RST=$'\033[0m'
else
  BOLD=; DIM=; GRN=; YEL=; RED=; CYN=; RST=
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

# Is this heartbeat age past the staleness threshold? Unknown age (no record, no
# heartbeat) is NEVER stale — absent evidence must not manufacture an alarm.
is_stale() { # $1 age in seconds
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge "$STALE_AFTER" ]
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
  if [ "${3:-}" = stale ]; then
    note="$note · ⚠ stalled — no activity for $(dur "${age:-}")"
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
    esac
    printf '       %s↳ stop it:  kill %s    then:  chief reap    (reaps whatever it leaves behind)%s\n' "$DIM" "$pid" "$RST"
  done
  return 0
}

render() {
  local now runfiles="" f pid n_active=0
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  set -- "$RUNS"/*.run
  [ -e "$1" ] && runfiles="$*"

  # Header (count active first so a run whose pid just died isn't counted).
  for f in $runfiles; do
    [ -e "$f" ] || continue
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
      printf '%sAll registered runs have exited.%s\n' "$DIM" "$RST"
    fi
    return 0
  fi
  printf '%sCHIEF%s · %s%d active run(s)%s%s · %s%s%s\n' "$BOLD" "$RST" "$CYN" "$n_active" "$RST" \
    "$([ "$UNREG_N" -gt 0 ] && printf ' · %s⚠ %d unregistered%s' "$RED" "$UNREG_N" "$RST")" "$DIM" "$now" "$RST"
  if [ "$n_active" -eq 0 ]; then
    # Only a registry that HAD entries can have "all exited" — with no run files at
    # all the only thing running is the unregistered driver below.
    [ -n "$runfiles" ] && printf '%sAll registered runs have exited.%s\n' "$DIM" "$RST"
    unreg_render
    return 0
  fi

  for f in $runfiles; do
    [ -e "$f" ] || continue
    pid="$(field pid "$f")"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue

    local repo base par tool state staterel tasks wt names label started limitmax
    repo="$(field repo "$f")";       base="$(field base "$f")"
    par="$(field parallel "$f")";    tool="$(field tool "$f")"
    state="$(field state "$f")";     staterel="$(field staterel "$f")"
    tasks="$(field tasks "$f")";     wt="$(field wt "$f")"
    names="$(field names "$f")";     started="$(field started "$f")"
    limitmax="$(field limitmax "$f")"
    [ -n "$staterel" ] || staterel=".chief/state"
    label="$(basename "$repo")"

    printf '\n%s%s%s  %s(pid %s · -p%s · %s · %s · →%s)%s\n' \
      "$BOLD" "$label" "$RST" "$DIM" "$pid" "${par:-1}" "${tool:-claude}" "$(elapsed "${started:-}")" "${base:-main}" "$RST"
    printf '%s  %s%s\n' "$DIM" "$repo" "$RST"
    holds_render "$state" "$names"

    local n st glyph gl lbl br prog act live age stale
    for n in $names; do
      st="$(cat "$state/parallel/$n.state" 2>/dev/null || echo)"
      # The record also carries the coarse state (set_state writes both), so a row
      # survives a missing/half-written <name>.state file.
      [ -n "$st" ] || st="$(live_get "$(live_file "$n" "$state")" state)"
      [ -n "$st" ] || st=unknown
      # At-risk = scheduler says RUNNING but the record stopped ticking. A paused
      # tasklist is deliberately excluded: it has its own glyph and an ETA, and a
      # long quiet wait is what it is SUPPOSED to be doing.
      age="$(live_age "$(live_file "$n" "$state")")"
      stale=0
      [ "$st" = running ] && is_stale "$age" && stale=1
      glyph="$(glyph_for "$st")"; gl="${glyph%%|*}"; lbl="${glyph##*|}"
      # Braced: an unbraced $RED before a multibyte glyph is parsed as part of the
      # variable NAME by bash 3.2 ("RED⚠: unbound variable").
      [ "$stale" = 1 ] && gl="${RED}⚠${RST}"
      br="$(branch_of "$n" "$tasks")"
      prog="$(stories "$n" "$wt" "$staterel" "$state" "$tasks")"
      [ "$prog" = '?/?' ] && prog="$(live_prog "$n" "$state")"
      printf '   %b %-22s %-9s %-7s %s%s%s\n' "$gl" "$n" "$lbl" "$prog" "$DIM" "$br" "$RST"
      if [ "$st" = rate-limited ]; then
        printf '       %s↳ %s%s\n' "$CYN" "$(limit_note "$n" "$state" "$limitmax")" "$RST"
      elif [ "$st" = paused ]; then
        # The operator hold. Same ⏸, its own note — and NOT the live_note line: the
        # record's phase here is always 'operator-paused', which would only repeat
        # the word without saying what was kept or how to pick it back up.
        printf '       %s↳ %s%s\n' "$YEL" "$(op_note "$n" "$state")" "$RST"
      else
        # What it's doing right now (phase · elapsed-in-phase · story · iter · age)
        # above the note the agent last wrote. Both are optional; neither line prints
        # empty. A stale row says so in words, in red, so the flag survives a grep.
        if [ "$stale" = 1 ]; then
          live="$(live_note "$n" "$state" stale)"
          [ -n "$live" ] || live="⚠ stalled — no activity for $(dur "$age")"
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
    done
  done
  [ "$UNREG_N" -gt 0 ] && unreg_render
  return 0
}

if [ "$MODE" = watch ]; then
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
