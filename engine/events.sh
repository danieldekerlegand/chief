#!/usr/bin/env bash
# engine/events.sh — the machine-readable EVENT STREAM (append-only NDJSON).
#
# WHY THIS EXISTS. Chief already publishes two views of a run: the human table
# (`chief ps`/`chief monitor`, reading $CHIEF_RUNS/<pid>.run + the per-tasklist
# <name>.live.json) and the end-of-run headless summary (docs/headless-invocation.md).
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
# CONTRACT (the consumer-facing half is docs/events.md — chief-cloud reads it)
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
#   • Bash 3.2 only: no associative arrays, no `declare -A`, no ${var^^}.

# The schema version stamped on every line. Bump `v` (and the `schema` string with it)
# only for a BREAKING change — a removed field, or one whose meaning changed. Purely
# additive fields do not bump it; that is what lets a consumer pin `v` and still get
# new data. docs/events.md is the contract this number refers to.
CHIEF_EVENT_V=1
CHIEF_EVENT_SCHEMA='chief.event/1'

# events_file_for RUNS_DIR RUN_ID -> the canonical event-log path for a run.
# One file per RUN (not per pid, not per tasklist): a run is the unit a host
# subscribes to, and its id is already stamped in <pid>.run as `runid=`.
events_file_for() { printf '%s/%s.events.jsonl' "${1:-}" "${2:-}"; }

# event_emit EVENT [KEY=VALUE …] — append one event. Always returns 0.
#
# Recognised keys (anything else is ignored, so a caller can pass a key a newer
# engine understands without breaking an older one):
#   name    the tasklist it is about        (omitted/empty -> null, e.g. run.* events)
#   story   the user-story id               (omitted/empty -> null)
#   state   the coarse state it lands in    (scheduler word, or the run outcome)
#   detail  free text for a HUMAN reading the stream — a sha, a git refusal, a
#           reason. Nullable and NOT part of the machine contract: never parse it.
event_emit() {
  local f="${CHIEF_EVENTS_FILE:-}" ev="${1:-}"
  [ -n "$f" ] && [ -n "$ev" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  shift
  local kv k v dir line
  local e_name="" e_story="" e_state="" e_detail=""
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      name)   e_name="$v" ;;
      story)  e_story="$v" ;;
      state)  e_state="$v" ;;
      detail) e_detail="$v" ;;
      *)      ;;
    esac
  done
  dir="$(dirname "$f")"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
  # A `detail` built from git's stderr can be long and multi-line; the framing
  # survives either way (jq escapes it), but a bounded one-line value keeps the
  # stream readable and the append inside the atomic-write size.
  e_detail="$(printf '%s' "$e_detail" | tr '\n\r\t' '   ' | cut -c1-300)"
  line="$(jq -nc \
      --argjson v "$CHIEF_EVENT_V" --arg schema "$CHIEF_EVENT_SCHEMA" \
      --argjson ts "$(date +%s)" \
      --arg runId "${CHIEF_RUN_ID:-}" --arg repo "${CHIEF_EVENT_REPO:-}" \
      --arg event "$ev" --arg name "$e_name" --arg story "$e_story" \
      --arg state "$e_state" --arg detail "$e_detail" \
      '{v:$v, schema:$schema, ts:$ts, runId:$runId, repo:$repo, event:$event,
        name:   (if $name   == "" then null else $name   end),
        story:  (if $story  == "" then null else $story  end),
        state:  (if $state  == "" then null else $state  end),
        detail: (if $detail == "" then null else $detail end)}' 2>/dev/null)" || return 0
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
