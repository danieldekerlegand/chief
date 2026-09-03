#!/usr/bin/env bash
# engine/crossrepo.sh — resolving a "<repo>:<stem>" REFERENCE to another repo's
# tasklist, and the two message shapes an unresolvable one gets.
#
# This is the lookup `dependsOn` has always used (docs/reference/cross-repo-dependencies.md),
# lifted out of the driver so the authoring-time gates can run the SAME resolution
# instead of a second implementation of it. Chief reads exactly one file across the
# boundary — the merged record `<repo>/<tasks>/completed/<stem>.json` — and never
# schedules, branches, or merges in another repo.
#
# Expects these globals from its caller (the lib.sh precedent), each with a fallback
# so bin/chief can source this without staging the driver's environment:
#   REPO / CHIEF_PROJECT        this repo's root — what a RELATIVE spec ("../koine") is
#                               resolved against
#   COMPLETED                   this repo's completed/ dir (absolute); derived from
#                               TASKS_REL / CHIEF_TASKS_DIR when unset
#   CHIEF_REPOS                 the known-repos registry file, for a bare-name spec
#
# bash 3.2: no associative arrays, no mapfile.

# SET-A-GLOBAL / PRINT-IT PAIRS. Every helper here that a hot loop calls assigns a
# global and forks nothing; where a caller reads the answer inline rather than
# through that global, the printing form it has always used is implemented in terms
# of the `_set` — never as a second copy of the rule. `$(f)` is a fork, and a
# report resolving one edge per tasklist across a portfolio pays it thousands of
# times — enough, measured, to cost more than every jq in the run put together. The
# rule each pair expresses is still written once; only the way the answer comes back
# differs. A printing form with no such caller is not part of the rule and is not
# kept for symmetry: `crossrepo_completed` was one, and was removed as dead
# (docs/explanation/dead-code-audit.md).
CROSSREPO_ROOT=""
CROSSREPO_COMPLETED=""
crossrepo_root_set()      { CROSSREPO_ROOT="${REPO:-${CHIEF_PROJECT:-$PWD}}"; }
crossrepo_completed_set() { CROSSREPO_COMPLETED="${COMPLETED:-${REPO:-${CHIEF_PROJECT:-$PWD}}/${TASKS_REL:-${CHIEF_TASKS_DIR:-tasks/chief}}/completed}"; }
crossrepo_root()      { crossrepo_root_set;      printf '%s' "$CROSSREPO_ROOT"; }

# A reference may be QUALIFIED as "<repo>:<tasklist>" to name work in a different
# repo — e.g. "pinakes:10-koine-align". Bare names stay repo-local. <repo> is either
# a path (absolute, ~/…, or relative to this repo) or the plain name of a repo in the
# known-repos registry ($CHIEF_REPOS, appended by `chief init`/`chief run`).
dep_repo() { case "$1" in *:*) printf '%s' "${1%%:*}" ;; esac; }   # empty when unqualified
dep_task() { printf '%s' "${1##*:}"; }

resolve_repo() {   # repo spec -> absolute path, or nothing when it can't be resolved
  local spec="$1" cand hits
  case "$spec" in
    "~/"*) cand="${HOME:-}/${spec#\~/}"; [ -n "${HOME:-}" ] || cand="" ;;
    /*)    cand="$spec" ;;
    */*)   cand="$(crossrepo_root)/$spec" ;;          # relative to this repo
    *)     cand="" ;;
  esac
  if [ -n "$cand" ]; then
    [ -d "$cand/.chief" ] && (cd "$cand" 2>/dev/null && pwd)
    return 0
  fi
  [ -f "${CHIEF_REPOS:-}" ] || return 0               # bare name -> the registry
  hits="$(while read -r p; do
            [ -n "$p" ] && [ "$(basename "$p")" = "$spec" ] && [ -d "$p/.chief" ] && printf '%s\n' "$p"
          done < "$CHIEF_REPOS" | sort -u)"
  [ "$(printf '%s' "$hits" | grep -c .)" = "1" ] && printf '%s' "$hits"   # ambiguous = unresolved
  return 0
}

repo_tasks_rel() {   # another repo's CHIEF_TASKS_DIR (parsed, NOT sourced — it's foreign config)
  local v; v="$(sed -n 's/^[[:space:]]*CHIEF_TASKS_DIR=\([^ #]*\).*/\1/p' "$1/.chief/config" 2>/dev/null | tail -1)"
  printf '%s' "${v:-tasks/chief}"
}

DEP_RECORD=""
dep_record_set() {   # ref -> DEP_RECORD: the completed-record path that would satisfy
  local d="$1" rr                          # it, or "" when the reference cannot land
  case "$d" in
    *:*) rr="${d%%:*}" ;;                  # dep_repo, inline: a fork per edge otherwise
    *)   crossrepo_completed_set; DEP_RECORD="$CROSSREPO_COMPLETED/$d.json"; return 0 ;;
  esac
  rr="$(resolve_repo "$rr")"
  [ -n "$rr" ] || { DEP_RECORD=""; return 0; }
  DEP_RECORD="$rr/$(repo_tasks_rel "$rr")/completed/${d##*:}.json"
}
dep_record() { dep_record_set "$1"; printf '%s' "$DEP_RECORD"; }

# THE RULE, written ONCE. A completed record satisfies an edge when it carries a
# non-empty `mergedToMain`. Both readings below — the single file, and the whole
# directory at once — apply THIS filter, so the fast path is the same rule as the
# slow one rather than a second copy of it that can drift.
CHIEF_MERGED_JQ='.mergedToMain // empty'

is_recorded_done() {   # merged record exists? (in this repo, or the ref's own repo)
  local f d; dep_record_set "$1"; f="$DEP_RECORD"
  # The stat FIRST, and it is not merely an optimization: most unsatisfied edges in a
  # backlog point at work that has not been done at all, so there is no file to read
  # and no index worth building for the directory it would have been in. Only an edge
  # whose record EXISTS has a question about mergedToMain to answer.
  [ -n "$f" ] && [ -f "$f" ] || return 1
  if [ "$CHIEF_MERGED_INDEX" = 1 ]; then
    d="${f%/*}"
    chief_merged_index_dir "$d"
    if chief_in_list "$d" "$_MERGED_OK"; then
      chief_in_list "$f" "$_MERGED_SET"; return $?
    fi
  fi
  [ -n "$(jq -r "$CHIEF_MERGED_JQ" "$f" 2>/dev/null)" ]
}

# --- the completed-record INDEX ---------------------------------------------
# One jq per completed/ DIRECTORY instead of one per edge. A report over a whole
# portfolio asks the question above hundreds of times against the same few
# directories, and a fork per question does not survive that scale.
#
# OPT-IN, and off by default, because it is a cache and the SCHEDULER'S view must
# not be one: a run asks "is this dep merged" repeatedly over hours during which
# records are appearing, and an answer cached at startup would hold a tasklist back
# for the rest of the run. A one-shot reader (`chief status`) turns it on; the
# driver never does, so its behaviour is byte-for-byte what it always was.
CHIEF_MERGED_INDEX=0
_MERGED_TRIED=""    # directories already attempted
_MERGED_OK=""       # ...of those, the ones whose index is COMPLETE and authoritative
_MERGED_SET=""      # record paths in them carrying mergedToMain

chief_merged_index_on() { CHIEF_MERGED_INDEX=1; }

chief_in_list() {   # $1 = value, $2 = newline-delimited list (entries newline-terminated)
  case "
$2" in *"
$1
"*) return 0 ;; esac
  return 1
}

chief_merged_index_dir() {   # $1 = a completed/ dir — index it once, or refuse it once
  local dir="$1" out f files=()
  chief_in_list "$dir" "$_MERGED_TRIED" && return 0
  _MERGED_TRIED="$_MERGED_TRIED$dir
"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.json; do [ -e "$f" ] && files+=("$f"); done
  if [ "${#files[@]}" -gt 0 ]; then
    # A record jq cannot parse aborts the read partway. A HALF index is worse than
    # none — it would report a merged dep as unmerged — so the directory is refused
    # outright and every edge in it falls back to the per-file read above, correct
    # as ever and merely slower.
    out="$(jq -r "input_filename as \$f | ($CHIEF_MERGED_JQ) | tostring | select(. != \"\") | \$f" \
             "${files[@]}" 2>/dev/null)" || return 0
    _MERGED_SET="$_MERGED_SET$out
"
  fi
  _MERGED_OK="$_MERGED_OK$dir
"
}

# --- the two ways a qualified reference fails to land -----------------------
# Factored out rather than duplicated so every gate that reports a bad reference —
# the driver's blocked-dep diagnostics, `chief lint` on a counterpart declaration —
# says the same sentence about the same failure. A reader who has seen one has seen
# both.
crossrepo_unresolved_repo_msg() {   # REF (whose repo half did not resolve)
  local d="$1" rr; rr="$(dep_repo "$d")"
  echo "repo \"$rr\" could not be resolved — it is not a path, and no uniquely-named repo matches it in ${CHIEF_REPOS:-the known-repos registry} (run 'chief init' or 'chief run' in that repo once to register it, or qualify with a path: \"../$rr:$(dep_task "$d")\")"
}
crossrepo_no_such_tasklist_msg() {   # RESOLVED-REPO-PATH REF
  local rp="$1" d="$2"
  echo "$rp has no tasklist \"$(dep_task "$d")\" — neither $(repo_tasks_rel "$rp")/$(dep_task "$d").json nor a completed record exists there (misspelled? the name is the filename minus .json)"
}

# crossrepo_locate REF — where REF's tasklist lives, as "<state> <path>":
#   active <file>      an unmerged tasks/chief/<stem>.json in the resolved repo
#   merged <file>      a completed/<stem>.json carrying mergedToMain
#   filed  <file>      a completed/<stem>.json WITHOUT mergedToMain (retired, never merged)
#   norepo             the repo half did not resolve here
#   missing            the repo resolved, but it holds no such tasklist
crossrepo_locate() {
  local d="$1" rr rp rel rec src
  rr="$(dep_repo "$d")"
  if [ -n "$rr" ]; then
    rp="$(resolve_repo "$rr")"
    [ -n "$rp" ] || { printf 'norepo'; return 0; }
    rel="$(repo_tasks_rel "$rp")"
  else
    rp="$(crossrepo_root)"; rel="${TASKS_REL:-${CHIEF_TASKS_DIR:-tasks/chief}}"
  fi
  rec="$rp/$rel/completed/$(dep_task "$d").json"
  src="$rp/$rel/$(dep_task "$d").json"
  if [ -f "$rec" ]; then
    if [ -n "$(jq -r '.mergedToMain // empty' "$rec" 2>/dev/null)" ]
      then printf 'merged %s' "$rec"; else printf 'filed %s' "$rec"; fi
    return 0
  fi
  [ -f "$src" ] && { printf 'active %s' "$src"; return 0; }
  printf 'missing'
}
