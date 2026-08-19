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
# SCOPE IS STATED, NEVER ASSUMED. A portfolio number whose coverage is unstated is
# a number nobody can check, so every render names the scope that produced it and
# how that scope was resolved. Three scopes:
#
#   this repo   cwd is at or below a chief-initialized repo — that repo alone
#   walk        cwd is not, so the tree BENEATH it is walked, reconciled with the
#               registry entries that live under it
#   registry    --all: every repo in $CHIEF_REPOS, regardless of cwd
#
# and four ways the walk is kept from lying about the count, each one a trap that
# was hit for real on this host rather than a hypothetical:
#
#   nesting     a repo is one whose ROOT the walk finds. A tasks/chief BELOW an
#               already-matched root is that repo's own business — a fixture, an
#               example, a vendored sample — and is not a second repo.
#   worktrees   a worktree is a full copy of a repo, .chief/config and all. They
#               normally live outside the scanned tree (CHIEF_WORKTREE_ROOT), so
#               the walk is normally safe — but an operator who relocates that root
#               under the tree would otherwise see every in-flight tasklist counted
#               TWICE, in a report whose entire purpose is arithmetic. The guard is
#               therefore explicit rather than incidental.
#   identity    walk and registry are reconciled by RESOLVED ABSOLUTE PATH, so a
#               symlink or a trailing slash cannot mint a phantom second repo, and
#               a repo found both ways is counted ONCE (its source says "both").
#   exclusion   an operator excludes a subtree with the ignore file, without
#               editing this walk — and an excluded repo is REPORTED as excluded,
#               because a repo that silently vanishes reads as a repo with no work.
#
# Exit status is 0 whatever the backlog looks like. This reports state; it does not
# grade it. Full reference: docs/reference/status.md
set -uo pipefail

ENGINE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=engine/paths.sh
. "$ENGINE/paths.sh"
# shellcheck source=engine/deps.sh
. "$ENGINE/deps.sh"

: "${CHIEF_REPOS:=}"
REPO=""; TASKS_REL=""; SRC=""; COMPLETED=""     # deps.sh's contract; set by deps_scope

# How deep beneath the walk base a repo ROOT may sit. Bounded because the walk runs
# from wherever the operator happens to stand, and an unbounded find from a home
# directory is a report that never finishes.
DEPTH="${CHIEF_STATUS_DEPTH:-4}"

BLOCKED_ONLY=0
ALL=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --blocked)   BLOCKED_ONLY=1; shift ;;
    --all)       ALL=1; shift ;;
    -h|--help)
      cat <<'USAGE'
chief status — what is left in the backlog, and what can start now.

  chief status              totals for this repo: remaining (live/parked),
                            runnable vs blocked, completed, and any problems
  chief status --blocked    only what is waiting, naming the edge that holds it
  chief status --all        every repo in the known-repos registry, regardless of cwd

Run from a directory that is NOT a chief project, it walks the tree beneath you and
reports every chief-initialized repo it finds, per repo and in total. The header
always states which scope produced the numbers.

Environment:
  CHIEF_STATUS_DEPTH   how deep beneath the walk base a repo root may sit (default 4)
  CHIEF_IGNORE         ignore-list file; an entry excludes that path and everything
                       beneath it (default $CHIEF_PREFIX/ignore)

Runnable means what it means to the scheduler: every dependsOn edge resolves to a
completed record carrying mergedToMain. Always exits 0 — this reports state.
USAGE
      exit 0 ;;
    *) echo "chief status: unknown flag: $1" >&2; exit 2 ;;
  esac
done

# ── identity, membership, and the tree walk ──────────────────────────────────
# Every path that reaches a count goes through abspath() first. That is the whole
# of the de-duplication argument: `cd -P` resolves symlinks and normalizes trailing
# slashes and `.`/`..`, so two spellings of one repo become one string, and string
# equality is then a sound test for "same repo".
abspath()      { ( cd -P "${1:-/nonexistent}" 2>/dev/null && pwd ); }
is_chief_repo() { [ -f "$1/.chief/config" ]; }

# The same normalization for a path that need NOT exist — an ignore-list entry naming
# a directory the operator has not created yet, or a registry entry whose repo has
# been deleted. Without it, a registry or ignore file written as /var/… never matches
# a walk base resolved to /private/var/… and the entry silently does nothing, which is
# the worst possible failure for an exclusion mechanism.
abspath_like() {
  local p="$1" a
  a="$(abspath "$p")";              [ -n "$a" ] && { printf '%s' "$a"; return 0; }
  a="$(abspath "$(dirname "$p")")"; [ -n "$a" ] && { printf '%s/%s' "$a" "$(basename "$p")"; return 0; }
  printf '%s' "$p"
}

in_list() {   # $1 = value, $2 = newline-delimited list (trailing newline required)
  case "
$2" in *"
$1
"*) return 0 ;; esac
  return 1
}

# Directories the walk never descends into: dot-directories (except .chief itself,
# which is what we are looking for) and the toolchain artifact trees that make an
# unbounded find slow without ever containing a repo root.
walk_repos() {   # $1 = base -> absolute repo roots beneath it, one per line, sorted
  local base="$1" c root abs
  find "$base" -mindepth 1 -maxdepth "$((DEPTH + 1))" \
       \( -type d \( \( -name '.*' ! -name '.chief' \) -o -name node_modules \
                     -o -name vendor -o -name target -o -name dist -o -name build \) -prune \) -o \
       \( -type d -name '.chief' -print \) 2>/dev/null \
  | while IFS= read -r c; do
      root="${c%/.chief}"
      is_chief_repo "$root" || continue
      abs="$(abspath "$root")"
      [ -n "$abs" ] && printf '%s\n' "$abs"
    done | sort -u
}

# A repo is one whose ROOT we found. Sorted input puts a parent before every child
# (a parent path is a prefix of its children), so one pass suffices: drop any root
# that lives beneath a root already accepted. This is what keeps a repo's own
# fixture — examples/minimal/tasks/chief here — from joining the portfolio as a
# second backlog and double-counting nothing into a total.
prune_nested() {
  local accepted="" r k keep
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    keep=1
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      case "$r" in "$k"/*) keep=0; break ;; esac
    done <<INNER
$accepted
INNER
    if [ "$keep" = 1 ]; then accepted="$accepted$r
"; printf '%s\n' "$r"; fi
  done
}

registry_entries() {   # raw registry lines, trailing slash stripped, deduped
  local p
  [ -n "$CHIEF_REPOS" ] && [ -f "$CHIEF_REPOS" ] || return 0
  while IFS= read -r p; do
    p="${p%/}"; [ -n "$p" ] || continue
    printf '%s\n' "$p"
  done < "$CHIEF_REPOS" | sort -u
}

# ── the ignore list ──────────────────────────────────────────────────────────
IGNORES=""
load_ignores() {
  local f line
  f="$(chief_ignore_file)"
  IGNORE_FILE="$f"
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$line" ] || continue
    case "$line" in
      "~/"*) [ -n "${HOME:-}" ] && line="$HOME/${line#\~/}" ;;
      /*)    ;;
      *)     line="$PWD/$line" ;;    # relative entries resolve against cwd
    esac
    line="${line%/}"
    IGNORES="$IGNORES$line
"
    # Both spellings, because either may be the one that matches (see abspath_like).
    case "$line" in *[*?[]*) ;; *) IGNORES="$IGNORES$(abspath_like "$line")
" ;; esac
  done < "$f"
}

is_ignored() {   # $1 = absolute repo path
  local p="$1" e
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    case "$e" in
      *[*?[]*)
        # shellcheck disable=SC2254   # deliberate: an entry may be a glob
        case "$p" in $e) return 0 ;; esac ;;
      *)
        [ "$p" = "$e" ] && return 0
        case "$p" in "$e"/*) return 0 ;; esac ;;
    esac
  done <<EOF
$IGNORES
EOF
  return 1
}

# ── scope resolution ─────────────────────────────────────────────────────────
# Deliberately NOT load_project: that hard-exits with "no .chief/config found"
# (bin/chief), which is the right answer for `run` and the wrong one for a report.
find_repo_up() {
  local d="$PWD"
  while [ "$d" != "/" ]; do
    [ -f "$d/.chief/config" ] && { (cd -P "$d" && pwd); return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

BASE="$(abspath "$PWD")"; BASE="${BASE:-$PWD}"
WT_ROOT="$(abspath "$(chief_worktree_root)")"      # empty when it does not exist yet
load_ignores

MODE=""; SCOPE_LINE=""; MULTI=0
WALKED=""; REGISTERED=""; CANDIDATES=""
REPOS=""            # "<abs path>\t<source>" — the repos actually reported
EXCLUDED=""; STALE=""; WT_SKIPPED=""

if [ "$ALL" = 1 ]; then
  MODE=registry; MULTI=1
  REGISTERED="$(registry_entries)
"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    a="$(abspath "$p")"
    if [ -z "$a" ] || ! is_chief_repo "$a"; then STALE="$STALE$p
"; continue; fi
    CANDIDATES="$CANDIDATES$a
"
  done <<EOF
$REGISTERED
EOF
  CANDIDATES="$(printf '%s' "$CANDIDATES" | sort -u | prune_nested)
"
  SCOPE_LINE="the known-repos registry ($CHIEF_REPOS), regardless of cwd"
elif ROOT="$(find_repo_up)"; then
  MODE=repo; MULTI=0
  CANDIDATES="$ROOT
"
  SCOPE_LINE="this repo"
else
  MODE=walk; MULTI=1
  WALKED="$(walk_repos "$BASE")
"
  # Reconciliation, explicit: the walk, PLUS the registry entries that live under
  # the same base. Both sides are resolved absolute paths, so the union is a set.
  # RESOLVE FIRST, then ask whether it is under the base. The other order is the bug:
  # a registry written as /var/... and a base resolved to /private/var/... are the same
  # directory on this platform, and comparing the raw spellings silently drops the repo.
  reg_under=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    a="$(abspath "$p")"
    if [ -z "$a" ] || ! is_chief_repo "$a"; then
      case "$(abspath_like "$p")" in "$BASE"|"$BASE"/*) STALE="$STALE$p
" ;; esac
      continue
    fi
    case "$a" in "$BASE"|"$BASE"/*) reg_under="$reg_under$a
" ;; esac
  done <<EOF
$(registry_entries)
EOF
  REGISTERED="$reg_under"
  CANDIDATES="$(printf '%s%s' "$WALKED" "$REGISTERED" | sort -u | prune_nested)
"
  SCOPE_LINE="the tree beneath $BASE (depth $DEPTH), reconciled with the registry"
fi

# The two filters every scope pays, in order. Both REPORT what they removed, because
# a repo that vanishes from a portfolio total reads exactly like a repo with no work.
under_wt() { [ -n "$WT_ROOT" ] || return 1; [ "$1" = "$WT_ROOT" ] && return 0; case "$1" in "$WT_ROOT"/*) return 0 ;; esac; return 1; }
while IFS= read -r p; do
  [ -n "$p" ] || continue
  # Both filters are about a SCOPE THAT WAS INFERRED. An operator standing in a repo
  # named it, and neither "that is a worktree" nor "that is on the ignore list" is an
  # answer to a direct question — `chief status` there reports there, as US-1 does.
  if [ "$MODE" != repo ]; then
    if under_wt "$p"; then WT_SKIPPED="$WT_SKIPPED$p
"; continue; fi
    if is_ignored "$p"; then EXCLUDED="$EXCLUDED$p
"; continue; fi
  fi
  case "$MODE" in
    registry) src=registry ;;
    repo)     src=cwd ;;
    *)        if in_list "$p" "$WALKED"; then
                src=walk; in_list "$p" "$REGISTERED" && src=both
              else src=registry; fi ;;
  esac
  REPOS="$REPOS$p	$src
"
done <<EOF
$CANDIDATES
EOF

# ── the pass over one repo's records ─────────────────────────────────────────
# Accumulated in newline-delimited strings rather than arrays: bash 3.2 is the
# compatibility floor and has no associative arrays (see driver.sh's header).
runnable=""      # names, one per line
blocked=""       # "name<TAB>dep<TAB>class<TAB>detail", one per line — first unmet edge
parked=""        # names
unreadable=""    # names — counted as remaining, but no verdict is honest
problems=""      # "name<TAB>message"
rows=""          # "label<TAB>remaining<TAB>live<TAB>parked<TAB>runnable<TAB>blocked<TAB>completed"
n_live=0 n_parked=0 n_runnable=0 n_blocked=0 n_unreadable=0 n_completed=0 n_repos=0

add_problem() { problems="$problems$1	$2
"; }

# scan_repo ROOT LABEL — one repo's records, folded into the totals above. The body
# is US-1's pass, unchanged except that deps_scope() is re-pointed per repo (which
# is exactly what deps.sh's four-globals contract exists for) and names are
# qualified with the repo label whenever more than one repo is in scope.
scan_repo() {
  local root="$1" label="$2" source="$3" f name q d v unmet ucls udet
  local r_live=0 r_parked=0 r_runnable=0 r_blocked=0 r_completed=0
  deps_scope "$root"

  for f in "$SRC"/*.json; do
    [ -e "$f" ] || continue
    name="$(basename "$f" .json)"
    q="$name"; [ "$MULTI" = 1 ] && q="$label/$name"

    if ! jq -e . "$f" >/dev/null 2>&1; then
      # No verdict is possible and inventing one would be the lie this file exists to
      # avoid — it is remaining work, it is a problem, and it is neither runnable nor
      # blocked. The driver, whose jq also fails here, treats it as dependency-free and
      # would launch it; that divergence is deliberate and reported rather than hidden.
      r_live=$((r_live + 1)); n_unreadable=$((n_unreadable + 1))
      unreadable="$unreadable$q
"
      add_problem "$q" "not valid JSON (jq cannot parse it) — no runnable/blocked verdict is possible"
      continue
    fi

    if [ "$(jq -r '.parked // false' "$f" 2>/dev/null)" = "true" ]; then
      r_parked=$((r_parked + 1)); parked="$parked$q
"
      continue
    fi
    r_live=$((r_live + 1))

    jq -e 'has("dependsOn")' "$f" >/dev/null 2>&1 \
      || add_problem "$q" "no \"dependsOn\" field — read as no dependencies (the schema expects the key, even empty)"

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
      r_runnable=$((r_runnable + 1)); runnable="$runnable$q
"
    else
      r_blocked=$((r_blocked + 1))
      blocked="$blocked$q	$unmet	$ucls	$udet
"
      case "$ucls" in
        norepo)  add_problem "$q" "dependsOn \"$unmet\": $udet" ;;
        retired) add_problem "$q" "dependsOn \"$unmet\" is PERMANENTLY unsatisfiable: $udet" ;;
      esac
    fi
  done

  for f in "$COMPLETED"/*.json; do [ -e "$f" ] || continue; r_completed=$((r_completed + 1)); done

  n_live=$((n_live + r_live)); n_parked=$((n_parked + r_parked))
  n_runnable=$((n_runnable + r_runnable)); n_blocked=$((n_blocked + r_blocked))
  n_completed=$((n_completed + r_completed)); n_repos=$((n_repos + 1))
  rows="$rows$label	$((r_live + r_parked))	$r_live	$r_parked	$r_runnable	$r_blocked	$r_completed	$source
"
}

# LABEL: the shortest spelling that stays unambiguous. Under a walk that is the path
# relative to the base; elsewhere the ~-shortened absolute path. Never the basename —
# two repos may share one, and this report's job is arithmetic nobody has to re-check.
label_for() {
  local p="$1"
  case "$MODE" in
    walk) case "$p" in "$BASE"/*) printf '%s' "${p#"$BASE"/}"; return 0 ;; esac ;;
  esac
  case "${HOME:-}" in
    "") printf '%s' "$p" ;;
    *)  case "$p" in "$HOME"/*) printf '~/%s' "${p#"$HOME"/}" ;; *) printf '%s' "$p" ;; esac ;;
  esac
}

while IFS='	' read -r p src; do
  [ -n "$p" ] || continue
  scan_repo "$p" "$(label_for "$p")" "$src"
done <<EOF
$REPOS
EOF

n_remaining=$((n_live + n_parked))

# ── render ───────────────────────────────────────────────────────────────────
list_names() { printf '%s' "$1" | while IFS= read -r n; do [ -n "$n" ] && printf '      %s\n' "$n"; done; }
count_of()   { printf '%s' "$1" | grep -c . ; }

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

# What the walk deliberately did NOT count. Printed in every render, including
# --blocked: a repo that is missing from a portfolio total for a good reason must
# say so, or "no work here" and "not looked at" become the same output.
render_scope_notes() {
  if [ -n "$WT_SKIPPED" ]; then
    printf '  worktrees   %4d    skipped: inside CHIEF_WORKTREE_ROOT (%s) — counting them would double every in-flight tasklist\n' \
      "$(count_of "$WT_SKIPPED")" "$WT_ROOT"
    list_names "$WT_SKIPPED"
  fi
  if [ -n "$EXCLUDED" ]; then
    printf '  excluded    %4d    listed in %s\n' "$(count_of "$EXCLUDED")" "$IGNORE_FILE"
    list_names "$EXCLUDED"
  fi
  if [ -n "$STALE" ]; then
    printf '  stale       %4d    in the registry (%s) but no longer a chief repo on disk\n' \
      "$(count_of "$STALE")" "$CHIEF_REPOS"
    list_names "$STALE"
  fi
}

render_problems() {
  [ -n "$problems" ] || return 0
  printf '\n  problems    %4d\n' "$(count_of "$problems")"
  printf '%s' "$problems" | while IFS='	' read -r n msg; do
    [ -n "$n" ] && printf '      ✗ %-26s %s\n' "$n" "$msg"
  done
}

if [ "$MULTI" = 1 ]; then
  header="portfolio — $n_repos repo(s)"
else
  header="$(printf '%s' "$REPOS" | cut -f1 | head -1)"
fi

if [ "$BLOCKED_ONLY" = 1 ]; then
  printf 'chief status --blocked — %s (scope: %s)\n\n' "$header" "$SCOPE_LINE"
  if [ "$n_repos" = 0 ]; then
    echo "  no chief-initialized repo in scope."
  elif [ "$n_blocked" = 0 ]; then
    echo "  nothing is blocked — all $n_runnable live tasklist(s) can start now."
  else
    printf '  blocked  %d of %d live\n' "$n_blocked" "$n_live"
    render_blocked
  fi
  render_scope_notes
  exit 0
fi

printf 'chief status — %s (scope: %s)\n\n' "$header" "$SCOPE_LINE"

if [ "$n_repos" = 0 ]; then
  case "$MODE" in
    registry) echo "  the known-repos registry is empty — run 'chief init' or 'chief run' in a repo once to register it." ;;
    *)        echo "  no chief-initialized repo at, above or beneath $BASE (depth $DEPTH)."
              echo "  Run it inside a repo that has been through 'chief init', or from a directory above several." ;;
  esac
  render_scope_notes
  exit 0
fi

if [ "$MULTI" = 1 ]; then
  # The per-repo table: one row per repo, then the portfolio totals it sums to.
  # The `source` column is the reconciliation, made visible: `walk` was found on disk
  # beneath the base, `registry` is a known repo the walk did not reach (pruned, or
  # deeper than CHIEF_STATUS_DEPTH), `both` is one repo the two agreed on — counted
  # once, because the union was taken over RESOLVED ABSOLUTE PATHS.
  printf '  %-32s %9s %5s %6s %8s %7s %9s  %s\n' repo remaining live parked runnable blocked completed source
  printf '%s' "$rows" | while IFS='	' read -r l rem lv pk rn bl cp sc; do
    [ -n "$l" ] && printf '  %-32s %9s %5s %6s %8s %7s %9s  %s\n' "$l" "$rem" "$lv" "$pk" "$rn" "$bl" "$cp" "$sc"
  done
  printf '  %-32s %9s %5s %6s %8s %7s %9s\n' '' --------- ----- ------ -------- ------- ---------
  printf '  %-32s %9d %5d %6d %8d %7d %9d\n' TOTAL "$n_remaining" "$n_live" "$n_parked" "$n_runnable" "$n_blocked" "$n_completed"
  printf '\n'
  if [ "$n_unreadable" -gt 0 ]; then
    printf '  unreadable  %4d    counted as remaining; no verdict possible\n' "$n_unreadable"
    list_names "$unreadable"
  fi
  render_scope_notes
  render_problems
  exit 0
fi

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
render_scope_notes
render_problems
exit 0
