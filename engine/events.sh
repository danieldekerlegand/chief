#!/usr/bin/env bash
# engine/events.sh — the machine-readable EVENT STREAM (append-only NDJSON).
#
# WHY THIS EXISTS. Chief already publishes two views of a run: the human table
# (`chief ps`/`chief monitor`, reading $CHIEF_RUNS/<pid>.run + the per-tasklist
# <name>.live.json) and the end-of-run headless summary (docs/guides/headless-invocation.md).
# Both are SNAPSHOTS. A host that wants to know the moment a tasklist merged or went
# VERIFY-FAILED has no choice but to poll the live records and diff them itself —
# which loses every transition that happens between two polls and re-implements the
# driver's state machine in the consumer. This file adds the missing third view: an
# append-only log of the transitions themselves, one JSON object per line.
#
# IT IS A PROJECTION, NOT A STATE MACHINE. Every emit sits next to a write the driver
# (or the agent loop) ALREADY performs — a live_set phase change, a set_state, a
# <name>.status line. Nothing here decides anything, nothing here schedules anything,
# and deleting every event_emit call would leave the run byte-identical. That is the
# invariant: if an event and the live record ever disagree, the event is the bug.
#
# CONTRACT (the consumer-facing half is docs/reference/events.md — chief-cloud reads it)
#   • Path comes from $CHIEF_EVENTS_FILE. EMPTY (or absent jq) makes every emit a
#     silent no-op, so agent.sh standalone and an older/partial install behave exactly
#     as before. Diagnostics must never take down a run.
#   • The file is APPEND-ONLY and never rewritten, so a consumer can `tail -f` it and
#     re-read it after the run — unlike the <pid>.run file, which is deleted on exit.
#   • One event per line, each line independently valid JSON (NDJSON). Lines are built
#     with jq, so a story title or a git error can never break the framing.
#   • Concurrency: sibling workers append to the SAME file from different processes.
#     Each event is a single short (<4 KiB) write to an O_APPEND fd, which POSIX keeps
#     atomic — lines interleave, but never tear. Order across workers is not promised;
#     `ts` plus (name, event) is what a consumer orders on.
#   • Versioned: every line carries `v` and `schema`. Fields are only ever ADDED within
#     a major version, so a consumer must ignore keys it does not know.
#   • OBSERVATION-ONLY usage/cost/limit. Two optional objects — `usage` (tokens, cost,
#     duration for the turn) and `limit` (the usage-limit accounting the engine already
#     does) — are populated ONLY from signals the engine ALREADY has in hand: a
#     provider's own stdout, and the rate-limit bookkeeping in agent.sh/driver.sh.
#     Nothing here calls a provider API, polls a quota endpoint, or infers a number.
#     Every field is NULLABLE and PROVIDER-DEPENDENT: `claude --print` prints no usage
#     figures today, so on that provider `usage` is simply null and the line stays
#     schema-valid. A consumer (chief-cloud's spend/quota ledger) must treat null as
#     "not available here", never as zero.
#   • Bash 3.2 only: no associative arrays, no `declare -A`, no ${var^^}.

# The schema version stamped on every line. Bump `v` (and the `schema` string with it)
# only for a BREAKING change — a removed field, or one whose meaning changed. Purely
# additive fields do not bump it; that is what lets a consumer pin `v` and still get
# new data. docs/reference/events.md is the contract this number refers to.
CHIEF_EVENT_V=1
CHIEF_EVENT_SCHEMA='chief.event/1'

# events_file_for RUNS_DIR RUN_ID -> the canonical event-log path for a run.
# One file per RUN (not per pid, not per tasklist): a run is the unit a host
# subscribes to, and its id is already stamped in <pid>.run as `runid=`.
events_file_for() { printf '%s/%s.events.jsonl' "${1:-}" "${2:-}"; }

# _event_num VALUE -> VALUE when it is a bare number, else '' (= null downstream).
# Usage figures are SCRAPED from provider output, so this is the gate that keeps a
# scrape miss ("n/a", "$1.20", an error string) out of the numeric fields.
_event_num() {
  case "${1:-}" in
    ''|*[!0-9.]*) printf '' ;;
    *)            printf '%s' "$1" ;;
  esac
}

# event_emit EVENT [KEY=VALUE …] — append one event. Always returns 0.
#
# Recognised keys (anything else is ignored, so a caller can pass a key a newer
# engine understands without breaking an older one):
#   name    the tasklist it is about        (omitted/empty -> null, e.g. run.* events)
#   story   the user-story id               (omitted/empty -> null)
#   state   the coarse state it lands in    (scheduler word, or the run outcome)
#   detail  free text for a HUMAN reading the stream — a sha, a git refusal, a
#           reason. Nullable and NOT part of the machine contract: never parse it.
#
# Usage keys (folded into the `usage` object; omitted/empty -> that field is null,
# and an all-null object is emitted as `usage: null` rather than a hollow shell):
#   in_tokens · out_tokens · total_tokens · cost_usd · duration_ms · turns · model
# Limit keys (folded into the `limit` object, same all-null rule):
#   limit_hit (1/0) · retry_at (epoch) · waits · max_waits
# Numeric values are sanitised here: anything that is not digits-and-dots is dropped
# to null, so a provider that prints "unknown" can never put a string where a
# consumer's ledger expects a number.
event_emit() {
  local f="${CHIEF_EVENTS_FILE:-}" ev="${1:-}"
  [ -n "$f" ] && [ -n "$ev" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  shift
  local kv k v dir line
  local e_name="" e_story="" e_state="" e_detail=""
  local u_in="" u_out="" u_total="" u_cost="" u_dur="" u_turns="" u_model=""
  local l_hit="" l_retry="" l_waits="" l_max=""
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      name)   e_name="$v" ;;
      story)  e_story="$v" ;;
      state)  e_state="$v" ;;
      detail) e_detail="$v" ;;
      in_tokens)    u_in="$(_event_num "$v")" ;;
      out_tokens)   u_out="$(_event_num "$v")" ;;
      total_tokens) u_total="$(_event_num "$v")" ;;
      cost_usd)     u_cost="$(_event_num "$v")" ;;
      duration_ms)  u_dur="$(_event_num "$v")" ;;
      turns)        u_turns="$(_event_num "$v")" ;;
      model)        u_model="$(printf '%s' "$v" | tr -d '"\\$`' | tr '\n\r\t' '   ' | cut -c1-80)" ;;
      limit_hit)    l_hit="$v" ;;
      retry_at)     l_retry="$(_event_num "$v")" ;;
      waits)        l_waits="$(_event_num "$v")" ;;
      max_waits)    l_max="$(_event_num "$v")" ;;
      *)      ;;
    esac
  done
  dir="$(dirname "$f")"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
  # A `detail` built from git's stderr can be long and multi-line; the framing
  # survives either way (jq escapes it), but a bounded one-line value keeps the
  # stream readable and the append inside the atomic-write size.
  e_detail="$(printf '%s' "$e_detail" | tr '\n\r\t' '   ' | cut -c1-300)"
  # `usage`/`limit` collapse to null when NOTHING in them is known — an all-null
  # object would read as "the provider reported zeros", which is a different claim.
  line="$(jq -nc \
      --argjson v "$CHIEF_EVENT_V" --arg schema "$CHIEF_EVENT_SCHEMA" \
      --argjson ts "$(date +%s)" \
      --arg runId "${CHIEF_RUN_ID:-}" --arg repo "${CHIEF_EVENT_REPO:-}" \
      --arg event "$ev" --arg name "$e_name" --arg story "$e_story" \
      --arg state "$e_state" --arg detail "$e_detail" \
      --arg uin "$u_in" --arg uout "$u_out" --arg utot "$u_total" \
      --arg ucost "$u_cost" --arg udur "$u_dur" --arg uturns "$u_turns" \
      --arg umodel "$u_model" \
      --arg lhit "$l_hit" --arg lretry "$l_retry" --arg lwaits "$l_waits" \
      --arg lmax "$l_max" \
      'def num($s): if $s == "" then null else ($s|tonumber? // null) end;
       def str($s): if $s == "" then null else $s end;
       def obj($o): if ([$o[] | select(. != null)] | length) == 0 then null else $o end;
       {v:$v, schema:$schema, ts:$ts, runId:$runId, repo:$repo, event:$event,
        name:   str($name),
        story:  str($story),
        state:  str($state),
        detail: str($detail),
        usage:  obj({input_tokens:  num($uin),   output_tokens: num($uout),
                     total_tokens:  num($utot),  cost_usd:      num($ucost),
                     duration_ms:   num($udur),  turns:         num($uturns),
                     model:         str($umodel)}),
        limit:  obj({hit:     (if $lhit == "" then null
                               else ($lhit == "1" or $lhit == "true") end),
                     retry_at: num($lretry), waits: num($lwaits),
                     max_waits: num($lmax)})}' 2>/dev/null)" || return 0
  [ -n "$line" ] || return 0
  printf '%s\n' "$line" >> "$f" 2>/dev/null || true
  return 0
}

# events_prune RUNS_DIR [DAYS] — drop event logs older than DAYS (default 14).
# The <pid>.run files delete themselves on exit; these deliberately OUTLIVE their run
# (that is the point — a host may read them after the fact), so something has to bound
# the directory. Best-effort and never fatal.
events_prune() {
  local dir="${1:-}" days="${2:-14}"
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  case "$days" in ''|*[!0-9]*) return 0 ;; esac
  [ "$days" -gt 0 ] || return 0
  find "$dir" -maxdepth 1 -type f -name '*.events.jsonl' -mtime "+$days" -exec rm -f {} + 2>/dev/null || true
  return 0
}
