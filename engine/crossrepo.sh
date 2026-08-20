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

crossrepo_root()      { printf '%s' "${REPO:-${CHIEF_PROJECT:-$PWD}}"; }
crossrepo_completed() { printf '%s' "${COMPLETED:-$(crossrepo_root)/${TASKS_REL:-${CHIEF_TASKS_DIR:-tasks/chief}}/completed}"; }

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

dep_record() {   # ref -> the completed-record path that would satisfy it ('' if unresolvable)
  local d="$1" rr
  rr="$(dep_repo "$d")"
  [ -z "$rr" ] && { printf '%s' "$(crossrepo_completed)/$d.json"; return 0; }
  rr="$(resolve_repo "$rr")"
  [ -n "$rr" ] || return 0
  printf '%s' "$rr/$(repo_tasks_rel "$rr")/completed/$(dep_task "$d").json"
}

is_recorded_done() {   # merged record exists? (in this repo, or the ref's own repo)
  local f; f="$(dep_record "$1")"
  [ -n "$f" ] && [ -f "$f" ] && [ -n "$(jq -r '.mergedToMain // empty' "$f" 2>/dev/null)" ]
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
