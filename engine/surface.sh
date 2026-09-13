#!/usr/bin/env bash
# engine/surface.sh — WHAT WITHIN A WATCHED PATH IS LOAD-BEARING.
#
# THE DEFECT THIS EXISTS FOR IS GRANULARITY, NOT THE HOLD. engine/zones.sh asks the
# merge phase's one "green is not enough authority" question, and its load-bearing
# matcher is `path:<glob>` against the branch's real changed files. That matcher is
# FILE-LEVEL, and a file is the wrong unit for the question being asked. A zone that
# watches `engine/*.sh` because the scheduler's CONTRACT is where two agents' designs
# must not diverge also fires on a branch that added a routine consumer three
# directories down — same file set, entirely different risk. Measured 2026-09-10: every
# `review` rule in two downstream repositories was rewritten to `serialize` on one day,
# each registry carrying a dated DISARMED banner, because every hold read as noise and
# every hold was approved unread. An approval nobody reads is worse than no approval:
# it manufactures a record of a review that did not happen.
#
# So a zone gains a way to say what WITHIN the watched path is the surface it cares
# about, and a change that does not touch that surface is not held:
#
#     review  surface:engine/*.sh:^[a-z_]+\(\)   the function contract, not its callers
#
# A `surface:` zone matches when the branch's diff to a file matching <glob> ADDS OR
# REMOVES a line matching <ere>. Adding a caller of `zones_match` does not rewrite the
# line `zones_match() {`; changing what `zones_match` IS does. That is the whole
# discrimination, and it is deliberately the crudest one that separates the two cases —
# see THE LIMIT below.
#
# WHY THE DIFF AND NOT THE FILE'S CONTENT. Matching the regex against the file as it
# now stands would hold every branch that touched a file which HAPPENS to contain a
# function declaration — which is every file, and which is the file-level rule again
# wearing a regex. The changed LINES are the only reading under which "added a
# consumer" and "changed the contract" have different answers.
#
# BOTH SIGNS, ON PURPOSE. A removal is a change to the surface exactly as an addition
# is — deleting a declaration is the most consequential edit a branch can make to one —
# so `-` lines count. A pure move (removed here, re-added there) therefore holds, and
# that is the right answer: the declaration's home changed.
#
# FAIL CLOSED. When the diff cannot be read at all, `surface_match` returns 2 and
# engine/zones.sh falls back to plain `path:<glob>` matching — the old, coarser rule.
# A review gate that silently stops holding when git has a bad day has disarmed itself,
# which is precisely the failure this tasklist is repairing.
#
# THE LIMIT, stated where it cannot be missed: this targets holds more precisely. It
# does not judge whether a design is right. A branch held by a `surface:` zone has
# cleared the whole merge floor and is being shown to a person because the surface it
# changed is one this repo decided a person should look at — the reading is still the
# person's work. docs/reference/overlap-zones.md
#
# GLOB SEMANTICS ARE ZONES.SH'S, not a second copy: the <glob> half is filtered by the
# caller through zones_path_match(), so `path:` and `surface:` can never come to mean
# different things about the same pattern. This file owns exactly one thing — what the
# branch's diff says about a regex.
#
# Bash 3.2 only: no associative arrays, no `declare -A`, no process substitution.

# surface_scope REPO RANGE — the diff a subsequent surface_match reads, recorded by
# whoever is about to evaluate the registry. RANGE is a single git diff argument
# (`<base>...HEAD`, `<base>...<branch>`), so each call site states its own scope and
# this file never guesses one: the merge gate measures from the tip a member was
# stacked on, the batch-admission check from the base. Called in the PARENT of any
# subshell that evaluates zones (a global written inside `$( )` is lost).
surface_scope() {
  SURFACE_REPO="${1:-}"
  SURFACE_RANGE="${2:-}"
}

# surface_match MATCHER -> the `surface:` rule, evaluated. MATCHER is the payload after
# `surface:` — `<glob>:<ere>`, split at the FIRST colon, so a glob may not contain one
# (paths that do are pathological; the registry says so).
#
#   0  MATCHED — SURFACE_HITS carries EVERY matching change, one `<file>: <±line>` per
#      line, and SURFACE_HIT is the first of them. All of them, because "which surface
#      did this branch touch" is the question the hold is read to answer, and the first
#      hit alone is what made the old report unreadable: a branch that rewrites four
#      declarations is a different thing from one that renames one, and reporting only
#      `engine/a.sh: -alpha() {` cannot say which it is. The SIGN is carried with the
#      text because a removed declaration and an added one are the two facts a reader
#      needs kept apart. engine/zones.sh truncates the list for display with a count.
#   1  did not match
#   2  THE DIFF IS UNREADABLE — the caller must fall back to path-level matching
#   3  MALFORMED — the caller reports it on stderr and skips the rule, never fatal
#
# The regex is compiled once in a BEGIN block before it is used, because an invalid ERE
# aborts awk mid-stream and a registry typo may not take down a run.
surface_match() {
  local glob ere diff line f l
  SURFACE_HIT=""; SURFACE_HITS=""
  case "${1:-}" in *:*) ;; *) return 3 ;; esac
  glob="${1%%:*}"; ere="${1#*:}"
  [ -n "$glob" ] && [ -n "$ere" ] || return 3
  # THE REGEX REACHES AWK THROUGH THE ENVIRONMENT, NEVER THROUGH -v. awk processes
  # escape sequences in a -v assignment, so `-v re='^[a-z_]+\(\)'` arrives as
  # `^[a-z_]+()` — a valid ERE with an empty group, which matches EVERY line. The gate
  # would then hold every branch that touched a watched file, which is the coarse rule
  # this matcher exists to replace, restored silently. ENVIRON is not escape-processed.
  # Compiled once in BEGIN before it is used: an invalid ERE aborts awk mid-stream, and
  # a registry typo may not take down a run.
  SURFACE_ERE="$ere" LC_ALL=C awk 'BEGIN { if ("" ~ ENVIRON["SURFACE_ERE"]) exit 0; exit 0 }' \
    </dev/null >/dev/null 2>&1 || return 3
  [ -n "${SURFACE_REPO:-}" ] && [ -n "${SURFACE_RANGE:-}" ] || return 2
  # CAPTURED, not piped straight into the reader below, so that a git failure is a
  # DISTINCT answer from an empty diff. Piped, `git diff <bad-ref> | awk` yields no
  # lines and rc 0 from awk, which reads exactly like "the branch touched no surface" —
  # fail-open, in the one place this file promises to fail closed. One `git diff -U0`
  # per rule rather than one per changed file: the hunk headers are the only thing
  # thrown away and the changed-file count is unbounded. --no-ext-diff so an operator's
  # diff driver cannot change what a policy gate reads.
  diff="$(git -C "$SURFACE_REPO" diff -U0 --no-color --no-ext-diff "$SURFACE_RANGE" 2>/dev/null)" \
    || return 2
  # LC_ALL=C because BSD awk aborts on a multi-byte character in a UTF-8 locale and
  # every diff in this codebase is full of em-dashes.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    f="${line%%$'\t'*}"; l="${line#*$'\t'}"
    zones_path_match "$glob" "$f" || continue
    [ -n "$SURFACE_HIT" ] || SURFACE_HIT="$f: $l"
    SURFACE_HITS="$SURFACE_HITS$f: $l
"
  done <<EOF
$(printf '%s\n' "$diff" | SURFACE_ERE="$ere" LC_ALL=C awk '
    BEGIN { re = ENVIRON["SURFACE_ERE"] }
    # HEADER LINES ARE ONLY HEADERS INSIDE A HEADER. A removed line whose own text is
    # "-- a/foo" renders as "--- a/foo" and is indistinguishable from a file header out
    # of context, so ---/+++ are read only between `diff --git` and the first hunk, and
    # body lines only after one.
    /^diff --git / { inhdr = 1; p = ""; q = ""; next }
    inhdr && /^--- /    { q = substr($0, 5); next }
    inhdr && /^\+\+\+ / {
      p = substr($0, 5)
      if (p == "/dev/null") p = q      # a deletion names the file on the OTHER side
      sub(/^[ab]\//, "", p)
      next
    }
    /^@@/  { inhdr = 0; next }
    inhdr  { next }
    p == "" { next }
    # EVERY matching line, not the first one per file: the whole point of reporting a
    # hold is to say what surface the branch touched, and one line out of four is a
    # report a reader cannot act on. The caller bounds the list for display.
    /^[+-]/ {
      l = substr($0, 2)
      if (l !~ re) next
      # The line becomes one TSV field and then one JSON string: a tab in it would
      # shift every field after it, so tabs are squeezed and the line is trimmed and
      # bounded rather than printed raw. The +/- is re-attached AFTER the trim, so an
      # indented declaration and a column-0 one read alike apart from their sign.
      gsub(/[\t\r]/, " ", l); sub(/^ +/, "", l); sub(/ +$/, "", l)
      if (length(l) > 100) l = substr(l, 1, 97) "..."
      printf "%s\t%s%s\n", p, substr($0, 1, 1), l
    }
  ')
EOF
  SURFACE_HITS="${SURFACE_HITS%$'\n'}"
  [ -n "$SURFACE_HITS" ] || return 1
  return 0
}
