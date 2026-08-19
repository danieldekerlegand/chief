#!/usr/bin/env bash
# engine/status.sh — `chief status`: what is LEFT, and what can START NOW.
#
# `chief list` prints one line per tasklist with a story count. It answers "how far
# along is each one", which is a different question from "what is the state of the
# backlog": no totals, no live/parked split, and no notion of what is runnable
# versus waiting on an unmerged dependency. This is that second question, and it is
# answered by running the SCHEDULER'S OWN GATE in report mode.
#
# THE ONE INVARIANT. Runnable here means exactly what runnable means to the driver:
# every dependsOn edge resolves to a completed/ record carrying mergedToMain. The
# verdict is computed by engine/deps.sh — the module driver.sh sources for the same
# decision — and never by a private copy. A report that used its own merge
# resolution would drift from the scheduler and become worse than no report: it
# would name work as startable that a run would then refuse to start.
#
# DEGRADE, NEVER ABORT. A backlog is exactly where malformed input accumulates —
# an unparseable tasklist, a dependency naming a repo that no longer exists. Each
# is counted, named in the `problems` section, and the rest of the report still
# renders. A status command that dies on one bad file is a status command that
# cannot be used on the backlog it exists to describe.
#
# Exit status is 0 whatever the backlog looks like. This reports state; it does not
# grade it.
set -uo pipefail

ENGINE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=engine/deps.sh
. "$ENGINE/deps.sh"

: "${CHIEF_REPOS:=}"
REPO=""; TASKS_REL=""; SRC=""; COMPLETED=""     # deps.sh's contract; set by deps_scope

BLOCKED_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --blocked)   BLOCKED_ONLY=1; shift ;;
    -h|--help)
      cat <<'USAGE'
chief status — what is left in the backlog, and what can start now.

  chief status              totals for this repo: remaining (live/parked),
                            runnable vs blocked, completed, and any problems
  chief status --blocked    only what is waiting, naming the edge that holds it

Runnable means what it means to the scheduler: every dependsOn edge resolves to a
completed record carrying mergedToMain. Always exits 0 — this reports state.
USAGE
      exit 0 ;;
    *) echo "chief status: unknown flag: $1" >&2; exit 2 ;;
  esac
done

# ── scope ────────────────────────────────────────────────────────────────────
# Deliberately NOT load_project: that hard-exits with "no .chief/config found"
# (bin/chief), which is the right answer for `run` and the wrong one for a report.
find_repo_up() {
  local d="$PWD"
  while [ "$d" != "/" ]; do
    [ -f "$d/.chief/config" ] && { (cd "$d" && pwd); return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

if ! ROOT="$(find_repo_up)"; then
  echo "chief status: no chief-initialized repo at or above $PWD."
  echo "  Run it inside a repo that has been through 'chief init'."
  exit 0
fi
deps_scope "$ROOT"

# ── the pass over one repo's records ─────────────────────────────────────────
# Accumulated in newline-delimited strings rather than arrays: bash 3.2 is the
# compatibility floor and has no associative arrays (see driver.sh's header).
runnable=""      # names, one per line
blocked=""       # "name<TAB>dep<TAB>class<TAB>detail", one per line — first unmet edge
parked=""        # names
unreadable=""    # names — counted as remaining, but no verdict is honest
problems=""      # "name<TAB>message"
n_live=0 n_parked=0 n_runnable=0 n_blocked=0 n_unreadable=0 n_completed=0

add_problem() { problems="$problems$1	$2
"; }

for f in "$SRC"/*.json; do
  [ -e "$f" ] || continue
  name="$(basename "$f" .json)"

  if ! jq -e . "$f" >/dev/null 2>&1; then
    # No verdict is possible and inventing one would be the lie this file exists to
    # avoid — it is remaining work, it is a problem, and it is neither runnable nor
    # blocked. The driver, whose jq also fails here, treats it as dependency-free and
    # would launch it; that divergence is deliberate and reported rather than hidden.
    n_live=$((n_live + 1)); n_unreadable=$((n_unreadable + 1))
    unreadable="$unreadable$name
"
    add_problem "$name" "not valid JSON (jq cannot parse it) — no runnable/blocked verdict is possible"
    continue
  fi

  if [ "$(jq -r '.parked // false' "$f" 2>/dev/null)" = "true" ]; then
    n_parked=$((n_parked + 1)); parked="$parked$name
"
    continue
  fi
  n_live=$((n_live + 1))

  jq -e 'has("dependsOn")' "$f" >/dev/null 2>&1 \
    || add_problem "$name" "no \"dependsOn\" field — read as no dependencies (the schema expects the key, even empty)"

  # THE VERDICT. deps_of + is_recorded_done are the scheduler's, unmodified.
  unmet="" ucls="" udet=""
  for d in $(deps_of "$name"); do
    is_recorded_done "$d" && continue
    unmet="$d"
    v="$(dep_verdict "$d")"
    ucls="${v%%	*}"; udet="${v#*	}"
    break
  done

  if [ -z "$unmet" ]; then
    n_runnable=$((n_runnable + 1)); runnable="$runnable$name
"
  else
    n_blocked=$((n_blocked + 1))
    blocked="$blocked$name	$unmet	$ucls	$udet
"
    case "$ucls" in
      norepo)  add_problem "$name" "dependsOn \"$unmet\": $udet" ;;
      retired) add_problem "$name" "dependsOn \"$unmet\" is PERMANENTLY unsatisfiable: $udet" ;;
    esac
  fi
done

for f in "$COMPLETED"/*.json; do [ -e "$f" ] || continue; n_completed=$((n_completed + 1)); done

n_remaining=$((n_live + n_parked))

# ── render ───────────────────────────────────────────────────────────────────
list_names() { printf '%s' "$1" | while IFS= read -r n; do [ -n "$n" ] && printf '      %s\n' "$n"; done; }

# One blocked line: the tasklist, the edge, and — for the retirement trap — the fact
# that the edge is permanently dead rather than merely early.
render_blocked() {
  printf '%s' "$blocked" | while IFS='	' read -r n d cls det; do
    [ -n "$n" ] || continue
    case "$cls" in
      retired) printf '      %-28s needs %s — PERMANENTLY BLOCKED: %s\n' "$n" "$d" "$det" ;;
      norepo)  printf '      %-28s needs %s — UNRESOLVABLE: %s\n'        "$n" "$d" "$det" ;;
      *)       printf '      %-28s needs %s — %s\n'                      "$n" "$d" "$det" ;;
    esac
  done
}

if [ "$BLOCKED_ONLY" = 1 ]; then
  printf 'chief status --blocked — %s (scope: this repo)\n\n' "$ROOT"
  if [ "$n_blocked" = 0 ]; then
    echo "  nothing is blocked — all $n_runnable live tasklist(s) can start now."
  else
    printf '  blocked  %d of %d live\n' "$n_blocked" "$n_live"
    render_blocked
  fi
  exit 0
fi

printf 'chief status — %s (scope: this repo)\n\n' "$ROOT"
printf '  remaining   %4d    live %d · parked %d\n' "$n_remaining" "$n_live" "$n_parked"
printf '    runnable  %4d\n' "$n_runnable"
list_names "$runnable"
printf '    blocked   %4d\n' "$n_blocked"
render_blocked
if [ "$n_unreadable" -gt 0 ]; then
  printf '    unreadable %3d    counted as remaining; no verdict possible\n' "$n_unreadable"
  list_names "$unreadable"
fi
if [ "$n_parked" -gt 0 ]; then
  printf '  parked      %4d    never scheduled until the flag is dropped\n' "$n_parked"
  list_names "$parked"
fi
printf '  completed   %4d    history, not backlog (%s/completed)\n' "$n_completed" "$TASKS_REL"

if [ -n "$problems" ]; then
  printf '\n  problems    %4d\n' "$(printf '%s' "$problems" | grep -c .)"
  printf '%s' "$problems" | while IFS='	' read -r n msg; do
    [ -n "$n" ] && printf '      ✗ %-26s %s\n' "$n" "$msg"
  done
fi
exit 0
