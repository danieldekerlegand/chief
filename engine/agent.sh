#!/bin/bash
# Chief Wiggum - Long-running AI agent loop
# Usage: ./agent.sh [--provider claude|devin|opencode|amp] [--model MODEL] [max_iterations]
#
# EXIT CODES — engine/driver.sh keys off these; keep them stable.
#   0  the PRD completed: the agent emitted <promise>COMPLETE</promise>.
#   1  GENUINE FAILURE — the loop gave up without completing: it stalled
#      (STALL_LIMIT no-progress iterations past the budget) or hit HARD_MAX.
#      Also used for bad invocation (unknown --tool). The work is NOT known to
#      be resumable; the driver treats this as a failed tasklist.
#   2  STOPPED ON A CLAUDE USAGE/SESSION LIMIT and will not retry (either
#      RATE_LIMIT_RETRY=0 or RATE_LIMIT_MAX_WAITS exhausted). This is NOT a
#      failure: nothing is wrong with the branch, it is simply blocked until the
#      limit window resets, and re-running it resumes from its passes state.
#      The driver must keep this distinct from 1 so a limit never counts as a
#      failed tasklist and never blocks dependents.
#   3  DRAINED ON AN OPERATOR PAUSE — a human armed $CHIEF_PAUSE_FILE (`chief
#      pause`) and this loop stopped starting new iterations. Like 2 it is NOT a
#      failure and NOT a stall: every commit the last iteration made is on the
#      branch, and `chief resume` continues from the committed passes state. The
#      check happens ONLY at an iteration boundary (see OPERATOR PAUSE below).
# A usage limit is detected BEFORE the progress/stall accounting (see
# _is_rate_limit below), so a limit-blocked turn can never be misread as a
# no-progress iteration that trips STALL_LIMIT and exits 1.

set -e

# Parse arguments
PROVIDER="${CHIEF_PROVIDER:-${CHIEF_TOOL:-claude}}"
MODEL="${CHIEF_MODEL:-}"
# What the caller actually ASKED for, as opposed to the default above — a preset
# resolves the provider itself, and only an EXPLICIT provider can conflict with it.
PROVIDER_EXPLICIT="${CHIEF_PROVIDER:-${CHIEF_TOOL:-}}"
TOOL="$PROVIDER"                         # compatibility name in status output
MAX_ITERATIONS=10

while [[ $# -gt 0 ]]; do
  case $1 in
    --provider)
      PROVIDER="$2"; PROVIDER_EXPLICIT="$2"
      shift 2
      ;;
    --provider=*)
      PROVIDER="${1#*=}"; PROVIDER_EXPLICIT="${1#*=}"
      shift
      ;;
    --model)
      MODEL="$2"
      shift 2
      ;;
    --model=*)
      MODEL="${1#*=}"
      shift
      ;;
    --tool)
      PROVIDER="$2"; PROVIDER_EXPLICIT="$2"
      TOOL="$2"
      shift 2
      ;;
    --tool=*)
      PROVIDER="${1#*=}"; PROVIDER_EXPLICIT="${1#*=}"
      TOOL="${1#*=}"
      shift
      ;;
    --chief-run=*)
      # The driver's RUN MARKER (engine/reap.sh). Consumed for nothing — its whole
      # job is to sit in this process's argv, where `ps`/`pgrep` can attribute the
      # frame (and the `claude` beneath it) to its repo and run. Without it, an
      # agent loop orphaned by a killed driver is unidentifiable: nothing else on
      # this command line says which repo it is spending quota for.
      shift
      ;;
    *)
      # Assume it's max_iterations if it's a number
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      fi
      shift
      ;;
  esac
done

ENGINE="${CHIEF_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# PRESET — a named bundle (engine/preset.sh) that resolves to provider·model plus
# whatever backend env that provider needs, BEFORE validation, so everything below
# only ever sees a plain resolved provider. Idempotent: bin/chief usually resolves
# it already and re-resolving the same pair here is a no-op, which keeps a direct
# `agent.sh` invocation (a host embedding chief, the offline tests) honest too.
# An unknown or unconfigured preset is a bad invocation — exit 1, never a silent
# fall-through to the default (paid) provider.
if [ -n "${CHIEF_PRESET:-}" ]; then
  # shellcheck disable=SC1091
  source "$ENGINE/preset.sh"
  CHIEF_PROVIDER="$PROVIDER_EXPLICIT"; CHIEF_MODEL="$MODEL"
  chief_preset_resolve || exit 1
  PROVIDER="$CHIEF_PROVIDER"; MODEL="$CHIEF_MODEL"; TOOL="$PROVIDER"
fi

# Validate provider choice
if [[ "$PROVIDER" != "claude" && "$PROVIDER" != "devin" && "$PROVIDER" != "opencode" && "$PROVIDER" != "amp" ]]; then
  echo "Error: Invalid provider '$PROVIDER'. Must be 'claude', 'devin', 'opencode', or 'amp'."
  exit 1
fi

# amp has no model selector (docs/providers.md#model-overrides). `chief run` refuses
# an explicit --model for it; when agent.sh is driven directly, say so ONCE here and
# drop the value — accept-and-ignore would let the banner, the liveliness record and
# the verbose trace all advertise a model the CLI never receives.
if [ "$PROVIDER" = amp ] && [ -n "$MODEL" ]; then
  echo "note: amp has no model selector — ignoring model '$MODEL' (docs/providers.md#model-overrides)" >&2
  MODEL=""
fi
: "${CHIEF_PROJECT:?CHIEF_PROJECT must be set — run this via the driver, not directly}"
STATE_DIR="$CHIEF_PROJECT/${CHIEF_STATE_DIR:-.chief/state}"
mkdir -p "$STATE_DIR"
PRD_FILE="$STATE_DIR/prd.json"
PROGRESS_FILE="$STATE_DIR/progress.txt"
ARCHIVE_DIR="$STATE_DIR/archive"
LAST_BRANCH_FILE="$STATE_DIR/.last-branch"
# Written ONLY on an exit-2 stop: the unix epoch at which the limit window is
# expected to reopen, parsed from the real limit message by _seconds_until_reset.
# engine/driver.sh reads it to schedule a reset-aware re-dispatch, so the worker
# and the scheduler agree on the ETA instead of parsing the message twice.
LIMIT_RETRY_FILE="$STATE_DIR/.limit-retry-at"
rm -f "$LIMIT_RETRY_FILE"
# Compose the agent prompt: generic loop instructions + the project's context.
PROMPT_FILE="$STATE_DIR/.prompt.md"
{
  cat "$ENGINE/instructions.md"
  ctx="${CHIEF_AGENT_CONTEXT:-}"
  if [ -n "$ctx" ] && [ -f "$CHIEF_PROJECT/$ctx" ]; then
    printf '\n\n---\n\n# Project-specific instructions (%s)\n\n' "$ctx"
    cat "$CHIEF_PROJECT/$ctx"
  fi
} > "$PROMPT_FILE"

# Archive previous run if branch changed
if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")
  
  if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
    # Archive the previous run
    DATE=$(date +%Y-%m-%d)
    # Strip "chief/" prefix from branch name for folder
    FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|^chief/||')
    ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"
    
    echo "Archiving previous run: $LAST_BRANCH"
    mkdir -p "$ARCHIVE_FOLDER"
    [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
    [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
    echo "   Archived to: $ARCHIVE_FOLDER"
    
    # Reset progress file for new run
    echo "# Chief Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
  fi
fi

# Track current branch
if [ -f "$PRD_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  if [ -n "$CURRENT_BRANCH" ]; then
    echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
  fi
fi

# Initialize progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Chief Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

# --- Adaptive iteration control + session-limit recovery ---------------------
# MAX_ITERATIONS is a SOFT budget, not a hard wall. As long as each iteration
# makes forward progress (a story flips to passes:true, OR a new commit lands),
# Chief keeps going past the budget — up to HARD_MAX — so a PRD that just needs
# a few more turns isn't cut off mid-flight. It gives up only once it has spent
# the budget AND stalled (no progress) for STALL_LIMIT consecutive iterations,
# or reaches the HARD_MAX safety ceiling.
STALL_LIMIT="${STALL_LIMIT:-2}"
HARD_MAX="${HARD_MAX:-$(( MAX_ITERATIONS*3 > 20 ? MAX_ITERATIONS*3 : 20 ))}"

# On a Claude session/usage limit, sleep until it resets and RESUME the same
# story instead of aborting the run.
#   RATE_LIMIT_RETRY=0     restore the old stop-on-limit behavior
#   RATE_LIMIT_WAIT=<sec>  fallback sleep when a reset time can't be parsed (1h)
#   RATE_LIMIT_MAX_WAITS   cap on how many times we'll wait, per PRD run
#   RATE_LIMIT_PATTERN     regex that identifies a limit message (tune if needed)
#   RATE_LIMIT_STATUS_PATTERN  weaker regex that only counts as a limit when the
#                          CLI ALSO exited non-zero (structured/terse errors)
#
# DETECTION IS THE WHOLE BALLGAME. A limit that the pattern misses is silently
# demoted to a "no progress" iteration, so the loop burns its budget and exits 1
# (stall) — indistinguishable, to the driver, from a genuinely failed tasklist.
# The default therefore covers every phrasing the Claude Code CLI is known to
# emit, not just the one-liner the first version was written against:
#   "Claude AI usage limit reached|1795000000"      (--print, epoch suffix)
#   "Claude usage limit reached. Your limit will reset at 3pm (America/Chicago)."
#   "5-hour limit reached ∙ resets 3pm"             (missed by the old pattern)
#   "Weekly limit reached · resets Nov 5 at 9am"    (missed by the old pattern)
#   "You've reached your usage limit"
#   API Error: 429 {"type":"error","error":{"type":"rate_limit_error",…}}
# Deliberately NOT matched: the per-model fallback notice ("Opus limit reached —
# now using Sonnet"), which is not a stop — the turn continues and does work.
RATE_LIMIT_RETRY="${RATE_LIMIT_RETRY:-1}"
RATE_LIMIT_WAIT="${RATE_LIMIT_WAIT:-3600}"
RATE_LIMIT_MAX_WAITS="${RATE_LIMIT_MAX_WAITS:-8}"
RATE_LIMIT_PATTERN="${RATE_LIMIT_PATTERN:-(usage limit reached|session limit reached|((5|five)[ -]hour|weekly|daily|monthly|hourly|plan|account|output|token)[ -]limit reached|(hit|reached|exceeded) (your|the) ([a-z0-9-]+ )?(session|usage|rate|weekly|daily|monthly|plan|output|token) limit|(your|the) limit will reset at|rate limit exceeded|rate_limit_error|too many requests|upgrade to increase your usage limit)}"
RATE_LIMIT_STATUS_PATTERN="${RATE_LIMIT_STATUS_PATTERN:-(429|rate[_ -]?limit|usage limit|session limit|overloaded_error)}"

# --- OPERATOR PAUSE (the drain checkpoint; see engine/driver.sh's header) -----
# The driver hands us the path of its operator-pause flag ($STATE/.paused, armed by
# `chief pause`). Unset — a standalone agent run — makes this a no-op, exactly like
# the liveliness record.
#
# CHECKPOINT PLACEMENT IS THE WHOLE CORRECTNESS STORY. It is consulted at ONE point:
# the top of the loop, i.e. strictly BETWEEN iterations. A turn already in flight
# always runs to completion, so a pause never discards work the agent did; and
# everything a pause must never interrupt (the driver's commit→rebase→verify→merge
# phase) is downstream of this loop exiting, so it is not even reachable from here.
#
# PRESENCE is the gate, never a parsed value: a human's hold must survive a
# truncated flag file. Same idiom as driver.sh's op_paused().
PAUSE_FILE="${CHIEF_PAUSE_FILE:-}"
_op_paused() { [ -n "$PAUSE_FILE" ] && [ -f "$PAUSE_FILE" ]; }

REPO="$CHIEF_PROJECT"
_passes() { jq '[.userStories[]? | select(.passes==true)] | length' "$PRD_FILE" 2>/dev/null || echo 0; }
_total()  { jq '.userStories | length' "$PRD_FILE" 2>/dev/null || echo '?'; }
_head()   { git -C "$REPO" rev-parse HEAD 2>/dev/null || echo none; }
_story()  { jq -r '[.userStories[]? | select(.passes==false)][0].id // empty' "$PRD_FILE" 2>/dev/null || echo ""; }
# The SET behind _passes()' count. The progress check below already re-reads the
# count each iteration; reading the ids alongside it is what lets the event stream
# name WHICH story passed instead of just that one more did.
_passed_ids() { jq -r '[.userStories[]? | select(.passes==true) | .id] | join(" ")' "$PRD_FILE" 2>/dev/null || echo ""; }

# --- LIVELINESS ---------------------------------------------------------------
# The driver hands us the path of this tasklist's liveliness record; unset (a
# standalone run) makes every live_* call a no-op. See engine/live.sh: this is what
# lets `chief ps` tell a working iteration from a hung one.
#
# Sourced relative to THIS FILE, not $ENGINE: $ENGINE honours an inherited
# $CHIEF_HOME, which may point at a DIFFERENT (older, or mid-update) install that
# has no live.sh — and losing the whole agent loop over a bookkeeping helper is not
# a trade worth making. Same reason for the no-op stubs: liveliness is diagnostics.
_AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_AGENT_DIR/live.sh" ]; then
  # shellcheck source=engine/live.sh
  . "$_AGENT_DIR/live.sh"
else
  live_set() { return 0; }
  live_get() { return 0; }
fi
# The machine-readable EVENT STREAM (engine/events.sh), sourced on exactly the same
# terms and for the same reason: $CHIEF_EVENTS_FILE is handed down by the driver, an
# empty one (a standalone run) is a no-op, and a missing file must cost us nothing.
if [ -f "$_AGENT_DIR/events.sh" ]; then
  # shellcheck source=engine/events.sh
  . "$_AGENT_DIR/events.sh"
else
  event_emit() { return 0; }
fi
LIVE="${CHIEF_LIVE_FILE:-}"
# Stories already passing when this loop started. The event stream reports the SET
# DIFFERENCE against it after every turn, so a turn that lands two stories reports
# two and a re-read of unchanged flags reports none.
PASSED_IDS=" $(_passed_ids) "
# _emit_story_events ITER — one `story.passed` per story that flipped during the turn
# that just returned. Called at ONE point (right after the provider returns) rather
# than at the progress check, because three of this loop's exits — COMPLETE, a usage
# limit, an operator-pause drain — happen BEFORE that check, and the last story of a
# tasklist always passes on the COMPLETE turn. Always returns 0.
_emit_story_events() {
  local now sid
  now=" $(_passed_ids) "
  for sid in $now; do
    case "$PASSED_IDS" in *" $sid "*) continue ;; esac
    event_emit story.passed name="${CHIEF_TASKLIST:-}" story="$sid" state=running \
      detail="iteration ${1:-?} — $(_passes)/$(_total) passing"
  done
  PASSED_IDS="$now"
  return 0
}
# --- USAGE / COST OBSERVATION (the event stream's `usage` block) ---------------
# OBSERVATION ONLY. Chief never asks a provider what a turn cost — it reads what the
# provider already printed on the stdout it was going to capture anyway. No API call,
# no polling loop, no second invocation. When a provider prints nothing usage-shaped
# (which is `claude --print` today), this yields nothing and the event's `usage` is
# null: a nullable, provider-dependent field, exactly as docs/events.md promises.
#
# _parse_usage OUTPUT -> ' key=value …' event_emit keys ('' when nothing was found).
# Two shapes, most trustworthy first:
#   1. A STRUCTURED result object — the `{"type":"result","total_cost_usd":…,
#      "usage":{"input_tokens":…}}` line that `claude --output-format json` (and
#      anything mimicking it) prints. jq reads it, so a missing key is simply absent.
#   2. A PLAIN-TEXT summary — "Total cost: $0.0421", "1234 input tokens". Deliberately
#      narrow: a scrape that guesses is worse than a null, because a cost ledger
#      cannot tell an invented number from a real one.
_parse_usage() {
  local out="$1" line got=""
  command -v jq >/dev/null 2>&1 || return 0
  line="$(printf '%s\n' "$out" \
    | grep -E '"(total_cost_usd|cost_usd|input_tokens|output_tokens)"[[:space:]]*:' \
    | tail -1)"
  if [ -n "$line" ]; then
    got="$(printf '%s' "$line" | jq -r '
        def kv($k; $v): if ($v|type) == "number" then "\($k)=\($v)" else empty end;
        [ kv("in_tokens";    (.usage.input_tokens  // .input_tokens)),
          kv("out_tokens";   (.usage.output_tokens // .output_tokens)),
          kv("total_tokens"; (.usage.total_tokens  // .total_tokens)),
          kv("cost_usd";     (.total_cost_usd // .cost_usd)),
          kv("duration_ms";  .duration_ms),
          kv("turns";        .num_turns) ] | join(" ")' 2>/dev/null || echo "")"
  fi
  if [ -z "$got" ]; then
    local cost tin tout
    cost="$(printf '%s\n' "$out" | grep -oiE 'cost:?[[:space:]]*\$?[0-9]+\.[0-9]+' \
      | tail -1 | grep -oE '[0-9]+\.[0-9]+' || echo "")"
    tin="$(printf '%s\n' "$out"  | grep -oiE '[0-9]+[[:space:]]+input[[:space:]]+tokens' \
      | tail -1 | grep -oE '[0-9]+' || echo "")"
    tout="$(printf '%s\n' "$out" | grep -oiE '[0-9]+[[:space:]]+output[[:space:]]+tokens' \
      | tail -1 | grep -oE '[0-9]+' || echo "")"
    got="${cost:+cost_usd=$cost }${tin:+in_tokens=$tin }${tout:+out_tokens=$tout}"
  fi
  printf '%s' "$got"
  return 0
}
# _emit_turn_event ITER — one `agent.turn` per provider turn that returned, emitted
# at the same point the loop already writes the post-turn live_set. It is what carries
# the per-turn usage figures (null when the provider printed none), so a host can keep
# a spend ledger without re-running or re-parsing anything. `model` comes from the
# engine's own configuration, not a scrape, so it is populated whenever one is set.
_emit_turn_event() {
  local u; u="$(_parse_usage "${OUTPUT:-}")"
  # shellcheck disable=SC2086  # $u is a deliberate word-split list of key=value args
  event_emit agent.turn name="${CHIEF_TASKLIST:-}" state=running \
    detail="iteration ${1:-?} — $(_passes)/$(_total) passing" \
    ${MODEL:+model=$MODEL} $u
  return 0
}
LIVE_BEAT_SECONDS="${LIVE_BEAT_SECONDS:-15}"
# A `claude --print` turn blocks this shell for MINUTES, so without a ticker the
# heartbeat would freeze on every healthy turn and the staleness signal would be
# useless (it would flag exactly the runs that are working hardest). Bump it from a
# forked child for the duration of the turn, and promote the phase to 'writing' the
# moment a commit lands — the one file-level signal observable from out here.
_beat_start() {
  [ -n "$LIVE" ] || return 0
  ( last="$(_head)"
    while :; do
      sleep "$LIVE_BEAT_SECONDS"
      now_h="$(_head)"
      if [ "$now_h" != "$last" ]; then live_set "$LIVE" phase=writing; last="$now_h"
      else live_set "$LIVE"; fi
    done ) 2>/dev/null &
  BEAT_PID=$!
  return 0
}
_beat_stop() {
  [ -n "${BEAT_PID:-}" ] || return 0
  kill "$BEAT_PID" 2>/dev/null || true
  wait "$BEAT_PID" 2>/dev/null || true
  BEAT_PID=""
  return 0
}
trap '_beat_stop' EXIT

# Seconds to sleep after a limit message: prefer a parsed reset time (a unix
# epoch near "reset", or a "…3pm"-style clock time), else RATE_LIMIT_WAIT; +60s
# buffer; capped at 6h.
_seconds_until_reset() {
  local out="$1" now epoch t secs; now=$(date +%s)
  epoch=$(printf '%s' "$out" | grep -oiE '(reset|limit)[^0-9]{0,40}1[0-9]{9}' | grep -oE '1[0-9]{9}' | head -1)
  if [ -z "$epoch" ]; then
    t=$(printf '%s' "$out" | grep -oiE '[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)' | head -1)
    if [ -n "$t" ]; then
      epoch=$(date -d "today $t" +%s 2>/dev/null || echo "")
      # Only trust a clock time that's still ahead today; a past time is ambiguous
      # (stale/tomorrow) so fall back to RATE_LIMIT_WAIT rather than oversleep.
      [ -n "$epoch" ] && [ "$epoch" -le "$now" ] && epoch=""
    fi
  fi
  if [ -n "$epoch" ] && [ "$epoch" -gt "$now" ]; then secs=$(( epoch - now + 60 )); else secs="$RATE_LIMIT_WAIT"; fi
  [ "$secs" -gt 21600 ] && secs=21600
  echo "$secs"
}

# Is this turn's output a usage/session limit stop? Two ways to say yes:
#   1. the output matches RATE_LIMIT_PATTERN (any known phrasing), or
#   2. the CLI exited NON-ZERO and the output carries a weaker structured hint
#      (a bare 429 / rate_limit_error payload with no prose around it).
# The exit status alone is never enough — the CLI exits non-zero for plenty of
# non-limit reasons — but it is what turns an ambiguous hint into a limit
# instead of a stalled iteration.
_is_rate_limit() {
  local out="$1" status="$2"
  if printf '%s\n' "$out" | grep -qiE "$RATE_LIMIT_PATTERN"; then return 0; fi
  if [ "$status" != "0" ] && printf '%s\n' "$out" | grep -qiE "$RATE_LIMIT_STATUS_PATTERN"; then return 0; fi
  return 1
}

# Run one provider in non-interactive mode. The prompt is supplied on stdin by the
# caller so every provider receives the same Chief instructions and project context.
_run_provider() {
  case "$PROVIDER" in
    claude)
      if [ -n "$MODEL" ]; then claude --dangerously-skip-permissions --print --model "$MODEL"
      else claude --dangerously-skip-permissions --print
      fi
      ;;
    devin)
      # devin's --print mode reads the prompt from --prompt-file (or a -- <PROMPT> arg),
      # NOT from stdin like claude/opencode — without it, it panics "print mode requires
      # a prompt" every iteration. PROMPT_FILE is the same file the caller pipes on stdin.
      if [ -n "$MODEL" ]; then devin --permission-mode bypass --respect-workspace-trust false --print --model "$MODEL" --prompt-file "$PROMPT_FILE"
      else devin --permission-mode bypass --respect-workspace-trust false --print --prompt-file "$PROMPT_FILE"
      fi
      ;;
    opencode)
      if [ -n "$MODEL" ]; then opencode run --model "$MODEL"
      else opencode run
      fi
      ;;
    amp)
      # No model branch by design: amp's CLI has no model selector (it picks its
      # own), so $MODEL is refused/dropped above rather than passed here.
      amp --dangerously-allow-all
      ;;
  esac
}

echo "Starting Chief — Provider: $PROVIDER${MODEL:+ (model: $MODEL)} — budget $MAX_ITERATIONS iters (extends while progressing; hard cap $HARD_MAX; stall limit $STALL_LIMIT)"

prev_pass=$(_passes); prev_head=$(_head)
i=0; stall=0; waits=0
while :; do
  # DRAIN CHECKPOINT (see OPERATOR PAUSE above). Asked here and nowhere else: the
  # previous iteration is fully accounted for (its commits are on the branch, its
  # boundary hook has run) and the next one has not started, so stopping now costs
  # nothing and strands nothing. Checked before the counter so `iter` records the
  # iterations actually spent.
  if _op_paused; then
    echo ""
    echo "Chief is stopping: an OPERATOR PAUSE is armed ($PAUSE_FILE) — no further iteration will start."
    echo "$(_passes)/$(_total) stories pass; everything committed so far is kept on the branch."
    echo "Exit 3 = drained on an operator pause — resumable with 'chief resume', NOT a failed tasklist."
    live_set "$LIVE" phase=operator-paused iter="$i" story="$(_story)" \
      passing="$(_passes)" total="$(_total)" stall="$stall" waits="$waits" retry_at=0
    exit 3
  fi
  i=$((i+1))
  echo ""
  echo "==============================================================="
  echo "  Chief Iteration $i ($TOOL) — budget $MAX_ITERATIONS · cap $HARD_MAX · $(_passes)/$(_total) passing"
  echo "==============================================================="
  live_set "$LIVE" phase=agent-turn iter="$i" story="$(_story)" \
    passing="$(_passes)" total="$(_total)" stall="$stall" waits="$waits" retry_at=0

  # Run the selected provider with the composed Chief prompt. The provider's own
  # exit status is preserved (PIPESTATUS, not tee's) for limit classification.
  TOOL_RC=0
  live_set "$LIVE" phase=provider-waiting
  # CHIEF_VERBOSE traces the exact provider invocation into the log — which provider,
  # which model, and the composed prompt it's being handed — so a misconfigured
  # provider/model shows up plainly instead of as a silent stall.
  [ -n "${CHIEF_VERBOSE:-}" ] && printf '>> [verbose] provider=%s%s · prompt=%s (%s lines)\n' \
    "$PROVIDER" "${MODEL:+ model=$MODEL}" "$PROMPT_FILE" \
    "$(wc -l < "$PROMPT_FILE" 2>/dev/null | tr -d ' ')" >&2
  _beat_start
  OUTPUT=$(_run_provider < "$PROMPT_FILE" 2>&1 | tee /dev/stderr; exit "${PIPESTATUS[0]}") || TOOL_RC=$?
  _beat_stop
  live_set "$LIVE" phase=agent-turn story="$(_story)" passing="$(_passes)" total="$(_total)"
  _emit_story_events "$i"
  _emit_turn_event "$i"

  # Completion signal — the token MUST be on a line by itself (optionally fenced in
  # backticks). Matching it ANYWHERE let an agent that merely QUOTED the token while
  # explaining it was NOT done ("I'm not reporting `<promise>COMPLETE</promise>` — it
  # stays passes:false") trip a false completion after one iteration; the driver then
  # force-passed every story and the merge only failed at the coverage gate. Anchoring
  # to a standalone line accepts a real emission and rejects a prose mention. Bias is
  # deliberate: a false negative just costs one extra iteration, a false positive
  # short-circuits the whole tasklist.
  if printf '%s\n' "$OUTPUT" | grep -qE '^[[:space:]]*`?<promise>COMPLETE</promise>`?[[:space:]]*$'; then
    echo ""
    echo "Chief completed all tasks! (iteration $i)"
    live_set "$LIVE" phase=complete passing="$(_passes)" total="$(_total)" story=
    exit 0
  fi

  # Session/usage limit -> sleep until reset and resume (a blocked turn is free).
  # Checked BEFORE the progress/stall accounting below so a limit can never be
  # counted as a no-progress iteration.
  if _is_rate_limit "$OUTPUT" "$TOOL_RC"; then
    if [ "$RATE_LIMIT_RETRY" = "1" ] && [ "$waits" -lt "$RATE_LIMIT_MAX_WAITS" ]; then
      waits=$((waits+1))
      secs=$(_seconds_until_reset "$OUTPUT")
      echo ""
      echo "Chief hit a session/usage limit. Sleeping ${secs}s (~$(( secs/60 )) min) then resuming — wait $waits/$RATE_LIMIT_MAX_WAITS."
      # Publish the pause BEFORE sleeping: a heartbeat that stops advancing for an
      # hour must read as 'paused until <eta>', not as the hang it looks like.
      live_set "$LIVE" phase=rate-limited-waiting waits="$waits" \
        retry_at="$(( $(date +%s) + secs ))"
      # The same pause, published to the event stream: a subscriber must be able to
      # tell "asleep on a usage limit until <eta>" from "hung" WITHOUT diffing the
      # live record, and the limit block is the quota half of chief-cloud's ledger.
      event_emit tasklist.rate-limit-wait name="${CHIEF_TASKLIST:-}" state=rate-limited \
        limit_hit=1 retry_at="$(( $(date +%s) + secs ))" waits="$waits" \
        max_waits="$RATE_LIMIT_MAX_WAITS" \
        detail="sleeping ${secs}s — wait $waits/$RATE_LIMIT_MAX_WAITS"
      sleep "$secs"
      i=$((i-1))   # the blocked turn doesn't consume the budget
      continue
    fi
    # Hand the driver the reset ETA before stopping, so the run can re-dispatch
    # this tasklist when the window reopens rather than stranding it.
    secs=$(_seconds_until_reset "$OUTPUT")
    echo "$(( $(date +%s) + secs ))" > "$LIMIT_RETRY_FILE" 2>/dev/null || true
    live_set "$LIVE" phase=rate-limited waits="$waits" \
      retry_at="$(cat "$LIMIT_RETRY_FILE" 2>/dev/null || echo 0)"
    echo ""
    echo "Chief hit a session/usage limit and won't retry (RATE_LIMIT_RETRY=$RATE_LIMIT_RETRY, waits=$waits/$RATE_LIMIT_MAX_WAITS). Stopping."
    echo "Exit 2 = blocked on a usage limit — resumable once the window resets, NOT a failed tasklist."
    echo "Reset ETA recorded for the driver: $(cat "$LIMIT_RETRY_FILE" 2>/dev/null) (in ~$(( secs/60 )) min)."
    exit 2
  fi

  # Progress check: did a story pass, or a new commit land?
  now_pass=$(_passes); now_head=$(_head)
  if [ "$now_pass" -gt "$prev_pass" ] || [ "$now_head" != "$prev_head" ]; then
    stall=0
    echo "Iteration $i: progress ($now_pass/$(_total) passing). Continuing..."
    live_set "$LIVE" phase=agent-turn stall=0 passing="$now_pass" total="$(_total)" story="$(_story)"
  else
    stall=$((stall+1))
    echo "Iteration $i: no progress (stall $stall/$STALL_LIMIT)."
    live_set "$LIVE" phase=stalled stall="$stall"
  fi
  prev_pass=$now_pass; prev_head=$now_head

  # ITERATION-BOUNDARY HOOK. $CHIEF_ITER_HOOK is a command the driver wants run
  # BETWEEN iterations — today, re-integrating the base branch that sibling merges
  # keep advancing under this branch (engine/driver.sh --integrate-base). It runs
  # only here, so it can never touch the tree while a turn is in flight, and its
  # failure is never fatal: integration is best-effort, the merge phase is the floor.
  if [ -n "${CHIEF_ITER_HOOK:-}" ]; then
    eval "$CHIEF_ITER_HOOK" || true
    # A hook may rewrite HEAD (a clean rebase does). Re-baseline, or the NEXT
    # iteration would read the hook's rewrite as the agent having made progress.
    prev_head=$(_head)
  fi

  # Give up only after spending the budget AND stalling, or at the hard ceiling.
  if [ "$stall" -ge "$STALL_LIMIT" ] && [ "$i" -ge "$MAX_ITERATIONS" ]; then
    echo ""
    echo "Chief stalled $stall iterations after its $MAX_ITERATIONS-iter budget without completing. Stopping."
    echo "Check $PROGRESS_FILE for status."
    exit 1
  fi
  if [ "$i" -ge "$HARD_MAX" ]; then
    echo ""
    echo "Chief hit the hard iteration ceiling ($HARD_MAX) without completing. Stopping."
    echo "Check $PROGRESS_FILE for status."
    exit 1
  fi
  sleep 2
done