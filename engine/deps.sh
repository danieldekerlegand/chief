#!/usr/bin/env bash
# engine/deps.sh — DEPENDENCY RESOLUTION: the one answer to "is this tasklist's
# dependsOn satisfied, and if not, why not".
#
# This is the scheduler's own gate, lifted out of driver.sh so a second reader can
# ask the same question without re-implementing it. `driver.sh` sources it to decide
# what to LAUNCH; `status.sh` sources it to decide what to REPORT as runnable. A
# report built on a private copy of this logic would drift from the scheduler and
# then lie — naming work as runnable that the driver would refuse to start — so
# there is deliberately only one implementation and both callers reach it here.
#
# The "<repo>:<stem>" half of that resolution — dep_repo · dep_task · resolve_repo ·
# repo_tasks_rel · dep_record · is_recorded_done · crossrepo_locate — is NOT defined
# here: it is engine/crossrepo.sh, sourced below, because the authoring-time gates
# (`chief lint`'s counterpart check) need the same lookup and a second copy of "where
# does <repo>:<stem> live" would drift the first time either changed. This module is
# the SCHEDULING layer on top of it.
#
# CONTRACT. These are functions over four globals the caller owns, not over an
# environment this file establishes:
#   REPO       absolute path of the repo whose tasklists are being resolved
#   TASKS_REL  its tasks dir, relative     (e.g. tasks/chief)
#   SRC        "$REPO/$TASKS_REL"          (live tasklists)
#   COMPLETED  "$SRC/completed"            (merged records)
#   CHIEF_REPOS  the known-repos registry (read-only here)
# driver.sh sets all four before it sources this file. A caller that walks SEVERAL
# repos calls deps_scope() per repo instead — same functions, different subject.
#
# NOTHING here writes, forks a git command, or consults scheduler state. It reads
# tasklist JSON and completed records off disk, which is what makes it safe to run
# from a reporting command against repos that have live runs in them.

# shellcheck source=engine/crossrepo.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/crossrepo.sh"

# deps_scope REPO — point the resolvers at one repo. The multi-repo counterpart of
# the assignments driver.sh makes once at startup; sets the same four globals from
# the repo's own .chief/config so a project that relocated CHIEF_TASKS_DIR is read
# correctly rather than assumed.
deps_scope() {
  REPO="$1"
  TASKS_REL="$(repo_tasks_rel "$REPO")"
  SRC="$REPO/$TASKS_REL"
  COMPLETED="$SRC/completed"
  deps_memo "" ""              # a memo is scoped to one repo; never carry it across
}

# A ONE-ENTRY MEMO in front of deps_of, for a caller that has ALREADY read the
# record for its own reasons and is about to ask this file for the same array. A
# reader walking a thousand records in order asks about each one immediately after
# reading it, so a cache of one entry is a full cache — and one entry cannot go
# stale behind anybody, because the next tasklist replaces it. The scheduler never
# calls deps_memo, so deps_of is the same jq for it that it always was.
#
# The point is the FORK, not the parse: deps_of is the one place a reader would
# otherwise re-read a file it is holding in a variable, and at portfolio scale that
# is a jq per tasklist. It stays the single accessor either way — the alternative,
# a caller reading `.dependsOn` for itself, is the second implementation this
# module exists to not have.
_DEPS_MEMO_NAME=""
_DEPS_MEMO_VAL=""
deps_memo() { _DEPS_MEMO_NAME="$1"; _DEPS_MEMO_VAL="$2"; }

DEPS_LIST=""
deps_of_set() {   # NAME -> DEPS_LIST, whitespace-separated, for `for d in $DEPS_LIST`
  if [ -n "$_DEPS_MEMO_NAME" ] && [ "$1" = "$_DEPS_MEMO_NAME" ]; then
    DEPS_LIST="$_DEPS_MEMO_VAL"; return 0
  fi
  DEPS_LIST="$(jq -r '(.dependsOn // [])[]' "$SRC/$1.json" 2>/dev/null)"
}
deps_of() { deps_of_set "$1"; printf '%s\n' "$DEPS_LIST"; }

# dep_verdict DEP — classify ONE unsatisfied edge, for a reader rather than a
# scheduler. Echoes "<class>\t<detail>" where class is one of:
#   norepo    the "<repo>:" half does not resolve to a chief repo on this host
#   retired   a completed/ record EXISTS but carries no mergedToMain — the
#             RETIREMENT TRAP. That record can never satisfy the edge, so the
#             dependent is blocked FOREVER until the dep is repointed; reporting it
#             as merely "waiting" would hide a permanent stall behind a transient
#             status, which is the one thing this classification exists to prevent.
#   unmerged  the record does not exist yet — ordinary unfinished upstream work.
# Only ever called for a dep is_recorded_done() has already rejected. It NAMES a
# cause; it never re-decides satisfaction (that stays is_recorded_done's alone, so
# the report and the scheduler cannot disagree about the verdict itself).
# The set/print pair crossrepo.sh explains: a report classifies every unmet edge in
# the backlog, and `$(dep_verdict …)` is a fork apiece.
DEP_CLASS=""
DEP_DETAIL=""
dep_verdict_set() {
  local d="$1" rr rec
  rr=""; case "$d" in *:*) rr="${d%%:*}" ;; esac      # dep_repo, inline: one fewer fork
  if [ -n "$rr" ] && [ -z "$(resolve_repo "$rr")" ]; then
    DEP_CLASS=norepo
    DEP_DETAIL="repo \"$rr\" is not a path and matches no uniquely-named repo in ${CHIEF_REPOS:-the known-repos registry}"
    return 0
  fi
  dep_record_set "$d"; rec="$DEP_RECORD"
  if [ -n "$rec" ] && [ -f "$rec" ]; then
    DEP_CLASS=retired
    DEP_DETAIL="its record $rec has no \"mergedToMain\" — that record can never satisfy the edge"
    return 0
  fi
  DEP_CLASS=unmerged
  DEP_DETAIL="no merged record yet ($rec)"
}
dep_verdict() { dep_verdict_set "$1"; printf '%s\t%s\n' "$DEP_CLASS" "$DEP_DETAIL"; }
