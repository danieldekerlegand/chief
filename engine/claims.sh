#!/usr/bin/env bash
# engine/claims.sh — the DOCUMENT CLAIM: a document in this repo that asserts
# something checkable about ANOTHER repo's tree, declared in a field so a gate can
# check it instead of a human re-reading fourteen repos.
#
# `downstreamCounterpart` (engine/counterpart.sh) connects a TASKLIST to the tasklist
# that completes it. Nothing connected a DOCUMENT to the tree it makes a claim about,
# and the obligation runs the wrong way to fix itself: agora has no reason to know
# that koine wrote a verification doc against agora's tree.
#
# THE MEASURED CASE. koine's `docs/reference/kcs-encoding-gate-verification.md`
# recorded that three KCS pressure tests had no encoding and that "three encodings now
# wait on nobody". agora closed all three in 378fd3c at 2026-08-26 12:30:18 — 49
# minutes after that document was last written, at 11:41:14. koine did not learn for a
# week; its promotability ladder repeated the claim, and two tasklists were authored
# on 2026-09-02 carrying it into a run before anybody read the tree. The KGP gate is
# the same shape with the sign reversed: a downstream deliverable believed to have
# landed that had not, found only by reading the merge commit.
#
# PROSE IS NOT THE MECHANISM — counterpart.sh's principle, inherited unchanged. A
# document that names a downstream fact only in its text is invisible here, and must
# stay invisible: the alternative is grepping prose for claims, which is a search for
# assertions in English and is exactly the thing that does not work. What is checked
# is what was DECLARED, and the caller says so out loud rather than reporting clean.
#
# So the claim becomes a record in a registry the repo owns, `.chief/claims.json`:
#
#   { "claims": [
#       { "document": "docs/reference/<the-doc-making-the-claim>.md",
#         "claim":    "absent",
#         "repo":     "agora",
#         "path":     "console/src/kcs/scenarios/resume-checkpoint.ts" } ] }
#
# (The `document` value is a real repo-relative path; it is a placeholder here only
# because a literal one would read as a dead link to chief's own doc-link gate.)
# A bare top-level array is accepted too. Contract: docs/reference/cross-repo-dependencies.md.
#
# THE VOCABULARY IS DELIBERATELY SMALL, and every member is a predicate over a path:
# `present` (that path exists in the other repo's tree) and `absent` (it does not).
# A claim that cannot be reduced to a predicate does not belong in the registry — it
# stays prose, and stays invisible, exactly as an undeclared counterpart does. Growing
# the vocabulary means adding a checkable predicate, never a checkable-sounding one.
#
# The repo half is resolved by crossrepo.sh's `resolve_repo` — the SAME lookup
# `dependsOn` and `downstreamCounterpart` use. A second resolver would drift from the
# first, and drift between two accounts of one fact is the bug class this whole module
# is about. Chief reads no file across the boundary here: it asks the filesystem
# whether a path exists, and nothing else.
#
# bash 3.2: no associative arrays, no mapfile. jq is the only dependency.
# Requires engine/crossrepo.sh to be sourced first (crossrepo_root · resolve_repo).

CLAIMS_FILE_DEFAULT=".chief/claims.json"
CLAIMS_VERBS="present absent"

# claims_file — the registry, absolute. `$CHIEF_CLAIMS_FILE` relocates it (a path
# relative to the repo root, or an absolute one), which is what lets a test point at
# a fixture without writing into the repo it is testing.
claims_file() {
  case "${CHIEF_CLAIMS_FILE:-}" in
    "") printf '%s/%s' "$(crossrepo_root)" "$CLAIMS_FILE_DEFAULT" ;;
    /*) printf '%s' "$CHIEF_CLAIMS_FILE" ;;
    *)  printf '%s/%s' "$(crossrepo_root)" "$CHIEF_CLAIMS_FILE" ;;
  esac
}

# The reader's field separator is US (0x1f), NOT a tab: `document` is the only field a
# malformed record is guaranteed to carry, so every other one can legitimately come
# back empty, and tab is IFS *whitespace* — a run of them collapses and shifts every
# later field left. US is not whitespace, so the empties survive `read` intact
# (engine/status.sh's `read_records` makes the same choice for the same reason).
CLAIMS_JQ='
  (if type == "array" then . else (.claims // []) end)
  | .[]? | select(type == "object")
  | [ (.document // ""), (.claim // ""), (.repo // ""), (.path // "") ]
  | map(tostring | gsub("[\n\r\t]"; " "))
  | join("\u001f")'

# claims_records — one US-separated `document·claim·repo·path` per declared claim.
# Empty output = this repo declares none, which is the state of almost every repo and
# costs one `[ -f ]`: no registry, no jq, no scan.
claims_records() {
  local f; f="$(claims_file)"
  [ -f "$f" ] || return 0
  jq -r "$CLAIMS_JQ" "$f" 2>/dev/null
}

# claims_count — how many declarations the gate SAW, for the caller's summary line.
claims_count() { claims_records | grep -c . || true; }

# --- the check ----------------------------------------------------------------
# Three outcomes, and only one of them is a finding:
#
#   • the predicate HOLDS — silent. Most claims hold most of the time, and a checker
#     that flags everything is as useless as one that flags nothing.
#   • the predicate is FALSE — `violated`. The document says something the downstream
#     tree does not support.
#   • the check could not RUN — `unresolvable`. A repo that is not checked out on this
#     host, a document that no longer exists, a verb outside the vocabulary, a path
#     that tries to leave the repo. None of these is evidence the claim is false, and
#     conflating them would make a partial checkout look like a wall of stale docs.
#
# claims_scan — one TAB-separated record per finding, on stdout:
#
#   violated<TAB><document><TAB><claim><TAB><repo>:<path><TAB><what the tree shows>
#   unresolvable<TAB><document><TAB><claim><TAB><repo>:<path><TAB><why not>
#
# It DEGRADES, never aborts: one bad record is one line and the scan moves on, because
# a laptop missing one sibling repo must still get the other findings.
claims_emit() {   # STATE DOCUMENT CLAIM REPO PATH DETAIL
  printf '%s\t%s\t%s\t%s:%s\t%s\n' "$1" "${2:-(no document)}" "${3:-?}" "${4:-?}" "${5:-?}" "$6"
}

claims_scan() {
  local root doc claim repo path rp
  root="$(crossrepo_root)"
  claims_records | while IFS="$(printf '\037')" read -r doc claim repo path; do
    [ -n "$doc$claim$repo$path" ] || continue
    if [ -z "$doc" ] || [ -z "$claim" ] || [ -z "$repo" ] || [ -z "$path" ]; then
      claims_emit unresolvable "$doc" "$claim" "$repo" "$path" \
        "incomplete declaration — document, claim, repo and path are all required"
      continue
    fi
    case " $CLAIMS_VERBS " in
      *" $claim "*) ;;
      *) claims_emit unresolvable "$doc" "$claim" "$repo" "$path" \
           "unknown claim \"$claim\" — the vocabulary is: $CLAIMS_VERBS"; continue ;;
    esac
    # The claim's SUBJECT has to exist, or the record is stale in the other direction:
    # a renamed or deleted document whose claim is still being checked reads as
    # verified when nothing verified it.
    if [ ! -e "$root/$doc" ]; then
      claims_emit unresolvable "$doc" "$claim" "$repo" "$path" \
        "no such document in this repo — $root/$doc"
      continue
    fi
    # The predicate is "this path IN that repo's tree". An absolute path, or one that
    # walks out with `..`, is not that question, and is refused rather than answered.
    case "$path" in
      /*|*..*) claims_emit unresolvable "$doc" "$claim" "$repo" "$path" \
                 "path must be relative to the repo root and must not contain \"..\""; continue ;;
    esac
    rp="$(resolve_repo "$repo")"
    if [ -z "$rp" ]; then
      claims_emit unresolvable "$doc" "$claim" "$repo" "$path" \
        "repo \"$repo\" is not checked out here"
      continue
    fi
    if [ -e "$rp/$path" ]; then
      [ "$claim" = absent ] && claims_emit violated "$doc" "$claim" "$repo" "$path" "it EXISTS: $rp/$path"
    else
      [ "$claim" = present ] && claims_emit violated "$doc" "$claim" "$repo" "$path" "it is MISSING: $rp/$path"
    fi
  done
  return 0
}

# --- the report as a human reads it -------------------------------------------
# The check REPORTS and never fails anything, and that is counterpart.sh's reasoning
# inherited rather than re-argued: correcting a stale document is a JUDGEMENT. The
# tree may have moved on and the document be simply out of date; the tree may have
# regressed and the document be right; the claim may have been written about a path
# that was later renamed. None of those is a thing a gate may decide, and a lint that
# returned non-zero — or a run that refused to launch — on the strength of somebody
# else's merge would block authoring work that is otherwise fine. Every caller here
# is print-only, and `claims_report_block` returns 0 unconditionally.

# claims_correction_note — printed next to the finding rather than filed in a doc,
# because this is the moment somebody is about to act on it. The FIRST move is not
# editing the sentence: it is reading the downstream commit that changed the tree,
# because a claim is usually load-bearing somewhere else (koine's ladder repeated its
# stale one, and two tasklists were authored carrying it into a run).
claims_correction_note() {
  cat <<'NOTE'
    ↳ read the downstream change FIRST, then correct the document — a claim this
      stale is usually repeated somewhere that reads the document (a ladder, a
      tasklist description, a gate's rationale), and correcting only the sentence
      leaves every copy of it standing. If the claim was right and the tree
      regressed, the finding belongs downstream, not in the document.
NOTE
}

# claims_stale_report — claims_scan rendered for a human, one line each. Every line
# names the DOCUMENT, the CLAIM it makes, and what the downstream tree actually shows,
# because the next action is correcting that document and it should not need a second
# investigation to start (counterpart_shipped_report's shape, and deliberately so).
#
# `unresolvable` renders as a QUESTION, never as a violation: "that repo is not
# checked out here" and "the claim is false" are different facts, and a check that
# conflated them would make a partial checkout read as a wall of stale documents.
# crossrepo.sh already draws that line; this only preserves it.
claims_stale_report() {
  local st doc claim ref detail
  claims_scan | while IFS="$(printf '\t')" read -r st doc claim ref detail; do
    case "$st" in
      violated)     printf '  ⚑ %s — claims %s is %s, but %s\n' "$doc" "$ref" "$(printf '%s' "$claim" | tr '[:lower:]' '[:upper:]')" "$detail" ;;
      unresolvable) printf '  ? %s — its claim about %s could not be checked (%s)\n' "$doc" "$ref" "$detail" ;;
    esac
  done
}

# claims_report_block — the whole block, or nothing at all. One rendering shared by
# every caller, so two commands cannot drift into two accounts of one finding.
#
# The heading follows the content, as counterpart's does: an `unresolvable` line on
# its own is not "a document is stale", it is a check that could not run, and the
# correction note belongs only where there is something to correct.
claims_report_block() {
  local rep; rep="$(claims_stale_report)"
  [ -n "$rep" ] || return 0
  case "$rep" in
    *'⚑'*) printf 'a document here claims something its downstream tree does not support:\n' ;;
    *)     printf 'declared document claims could not be checked:\n' ;;
  esac
  printf '%s\n' "$rep"
  case "$rep" in *'⚑'*) claims_correction_note ;; esac
  return 0
}
