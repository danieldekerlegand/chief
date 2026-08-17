#!/usr/bin/env bash
# engine/live.sh — the per-tasklist LIVELINESS record (shared by agent/driver/monitor).
#
# WHY THIS EXISTS. The scheduler persists exactly ONE coarse word per tasklist
# ($STATE/<name>.state: pending|running|done|failed|blocked|rate-limited|paused|
# awaiting-review|awaiting-approval). Everything
# that answers "is this 'running' tasklist WORKING or HUNG?" — which iteration it is
# on, which story, what it is doing right now, when it last did anything — only ever
# reached the worker's stdout and was lost. That is how a tasklist sat for ~2h with no
# visible signal while it was merely asleep on a usage limit. This file adds a small
# record NEXT TO the coarse state so `chief ps` / `chief monitor` can read the fine-grained truth.
#
# CONTRACT
#   • Path is passed in as $1. An EMPTY path makes every writer a silent no-op, so
#     agent.sh run standalone (no driver) behaves exactly as it did before, and a
#     missing record degrades to today's coarse <name>.state view — never an error.
#   • Writes are ATOMIC (temp in the same dir + mv) and READ-MODIFY-WRITE, so
#     agent.sh (iteration / story / turn fields) and driver.sh (warmup / verify /
#     rebase / merge / limit phases) can own disjoint fields of the SAME record from
#     different processes without clobbering each other's.
#   • The record lives under the gitignored .chief/state/ and is NEVER committed.
#   • Every write stamps `heartbeat` — so `now - heartbeat` is a true liveliness age
#     — and stamps `phase_since` whenever `phase` actually changes.
#   • Bash 3.2 only: no associative arrays. The reader is sed-based, so `chief ps`
#     can read the record even where jq is absent.
#
# PHASE VOCABULARY (the fine-grained sub-phase; the coarse lifecycle is `state`):
#   agent.sh   agent-turn · provider-waiting · writing · rate-limited-waiting · stalled ·
#              operator-paused · research · research-failed · plan-turn · plan-ready ·
#              plan-invalid · review-wait · awaiting-review
#   driver.sh  worktree · warmup · reconcile · merge-wait · rebasing · verifying ·
#              zone-check · merging · merged · done · operator-paused ·
#              research-failed · plan-invalid · awaiting-review · awaiting-approval
# The plan-* phases belong to the opt-in PLAN REVIEW checkpoint (docs/plan-review.md)
# and appear only on a tasklist that enabled it: 'plan-turn' is the agent writing a
# plan instead of code, 'plan-ready' the artifact passing its schema check, and
# 'plan-invalid' the stop when it does not. 'review-wait' is the bounded window in
# which a human reviewer is being waited on, and 'awaiting-review' the park when that
# window closes with no approval — a hold, not a fault (docs/plan-review.md).
# The zone phases belong to the OVERLAP ZONE REGISTRY (docs/reference/overlap-zones.md)
# and sit at the far end of the merge phase: 'zone-check' is the branch's real changed
# files being matched against the repo's declared zones, and 'awaiting-approval' the
# hold when one with policy `review` matched and no human has said yes to THIS change.
# It is the only hold whose branch has already passed the whole merge floor.
# The research-* phases belong to the opt-in RESEARCH PHASE, which runs ONCE per
# tasklist BEFORE the first story and before any plan turn: 'research' is the agent
# mapping the code into the structured document every story then reads, and
# 'research-failed' the stop when the bounded attempts produce none. Both carry
# `iter=0` and no story on purpose — the phase precedes the story loop's counter.
# 'operator-paused' is the OPERATOR pause (a human's `chief pause`); the two
# rate-limited phases are the account's usage-limit window. Never conflate them — a
# reader has to be able to tell which one is holding the run.
# Anything else renders verbatim — the monitor never switches on an allow-list.

# Field order is the write order. Numeric fields are emitted unquoted (0 = unset);
# everything else is emitted as a JSON string.
LIVE_FIELDS='name state phase story iter passing total stall waits retry_at phase_since heartbeat'
LIVE_NUMERIC=' iter passing total stall waits retry_at phase_since heartbeat '

# live_get FILE KEY -> the raw value ('' when the file or key is absent).
# The writer's format is rigid (one `  "key": value,` per line), so a sed reader is
# enough and jq stays optional. Quotes and a trailing comma are stripped either way.
live_get() {
  [ -n "${1:-}" ] && [ -f "$1" ] || return 0
  sed -n "s/^[[:space:]]*\"$2\":[[:space:]]*//p" "$1" 2>/dev/null | head -1 \
    | sed 's/,$//; s/^"//; s/"$//'
  return 0
}

# live_age FILE -> seconds since the last write ('' when there is no heartbeat).
live_age() {
  local hb now
  hb="$(live_get "${1:-}" heartbeat)"
  case "$hb" in ''|0|*[!0-9]*) return 0 ;; esac
  now="$(date +%s)"
  [ "$now" -lt "$hb" ] && { printf '0'; return 0; }
  printf '%s' "$(( now - hb ))"
  return 0
}

# Values are controlled (ids, slugs, integers), but a story title or a phase built
# from user data must never be able to break the JSON — strip quotes/backslashes,
# flatten whitespace, and cap the length.
_live_scrub() { printf '%s' "${1:-}" | tr -d '"\\$`' | tr '\n\r\t' '   ' | cut -c1-120; }

# live_set FILE [KEY=VALUE …] — merge fields into the record and stamp the heartbeat.
# With no KEY=VALUE it is a pure heartbeat bump (what the in-turn ticker uses).
# Always returns 0: liveliness bookkeeping must never take down a run (agent.sh runs
# under `set -e`).
live_set() {
  local f="${1:-}"; shift 2>/dev/null || true
  [ -n "$f" ] || return 0
  local dir tmp now key kv k v val n=0 old_phase
  # Listed explicitly (not `eval local`) so the per-field scratch vars stay OUT of
  # the caller's globals — driver.sh and agent.sh both source this file.
  local _lv_name _lv_state _lv_phase _lv_story _lv_iter _lv_passing _lv_total \
        _lv_stall _lv_waits _lv_retry_at _lv_phase_since _lv_heartbeat
  dir="$(dirname "$f")"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
  now="$(date +%s)"
  # Load what is already on disk, so a writer only has to know its own fields.
  for key in $LIVE_FIELDS; do
    eval "_lv_$key=\"\$(live_get \"\$f\" \"\$key\")\""
  done
  old_phase="${_lv_phase:-}"
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case " $LIVE_FIELDS " in *" $k "*) ;; *) continue ;; esac    # ignore unknown keys
    eval "_lv_$k=\"\$(_live_scrub \"\$v\")\""
  done
  # phase_since tracks the CURRENT phase's start — bumped only on a real change, so
  # the monitor's elapsed-in-phase means something.
  [ "${_lv_phase:-}" != "$old_phase" ] && _lv_phase_since="$now"
  case "${_lv_phase_since:-}" in ''|0|*[!0-9]*) _lv_phase_since="$now" ;; esac
  _lv_heartbeat="$now"
  # $$ is the same in a subshell on bash 3.2, so add $RANDOM: agent.sh's heartbeat
  # ticker is a forked child of the same pid and must not share a temp path.
  tmp="$f.$$$RANDOM.tmp"
  {
    printf '{\n'
    for key in $LIVE_FIELDS; do
      eval "val=\"\${_lv_$key:-}\""
      [ "$n" -gt 0 ] && printf ',\n'
      case "$LIVE_NUMERIC" in
        *" $key "*)
          case "$val" in ''|*[!0-9]*) val=0 ;; esac      # '?'/empty -> 0 (= unknown)
          printf '  "%s": %s' "$key" "$val" ;;
        *) printf '  "%s": "%s"' "$key" "$val" ;;
      esac
      n=$(( n + 1 ))
    done
    printf '\n}\n'
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}
