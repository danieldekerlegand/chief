#!/usr/bin/env bash
# engine/counterpart.sh — the MARKER LINK: a tasklist that declares which downstream
# tasklist will actually complete it.
#
# A tasklist in one repo can be a marker for work that belongs in another — koine
# carries ten of them, each saying so in its own first line ("CROSS-REPO, owned and
# built in AGORA, not koine"), because the spec repo holds the spec and the
# implementation lives downstream. Nothing connected the two ends: `supersededBy` is
# hand-authored metadata chief reads never, so when the downstream tasklist merged,
# the marker upstream kept sitting in the backlog, indistinguishable from work that
# still needed doing. Measured 2026-08-18/19: five of koine's ten markers had already
# shipped and every one was still listed as pending.
#
# So the link becomes a FIELD, in the one notation chief already resolves for
# `dependsOn` (docs/reference/cross-repo-dependencies.md):
#
#   "downstreamCounterpart": ["agora:75-encode-scenarios-as-kcs"]
#
# and `supersededBy` is its backward half, written when the marker is retired. Both
# are documented in docs/reference/tasklist-schema.md.
#
# PROSE IS NOT THE MECHANISM, and that is the point of putting it in a field. A
# marker whose counterpart is named only in its `description` — which is how every
# one of koine's ten was written — is invisible here, and this module never claims
# otherwise: what it reports is what it can see, and its callers say so.
#
# bash 3.2: no associative arrays, no mapfile. jq is the only dependency.
# Requires engine/crossrepo.sh to be sourced first (resolve_repo · crossrepo_locate ·
# the two unresolvable-reference message shapes).

COUNTERPART_FIELD="downstreamCounterpart"

# counterpart_refs FILE — the declared counterpart references, one per line.
# Accepts a bare string as well as an array, because "the tasklist that completes
# this one" is usually one but not always: koine's 66 names two (a schema half in
# agora and an adoption half in lugh). Empty output = no declaration.
counterpart_refs() {
  jq -r --arg f "$COUNTERPART_FIELD" '
      (.[$f] // [])
      | (if type == "string" then [.] else . end)
      | .[]? | select(type == "string") | select(length > 0)' "$1" 2>/dev/null
}

# counterpart_lint_report FILE — one "  ✗ …" line per declared reference that does
# not resolve, using the SAME sentence a bad dependsOn edge gets. Empty output =
# every declaration lands somewhere real.
#
# A pointer to nothing is worse than no pointer, because it reads as checked: the
# whole value of the field is that a later gate can follow it without a human
# looking, and a typo'd repo or stem would make that gate silently find nothing and
# report all-clear.
counterpart_lint_report() {
  local f="$1" ref rr rp
  counterpart_refs "$f" | while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case "$(crossrepo_locate "$ref")" in
      norepo)
        printf '      ✗ %s: %s\n' "$COUNTERPART_FIELD" "$ref"
        printf '        %s\n' "$(crossrepo_unresolved_repo_msg "$ref")" ;;
      missing)
        # An unqualified stem is resolved against THIS repo, exactly as a bare dep is.
        rr="$(dep_repo "$ref")"
        if [ -n "$rr" ]; then rp="$(resolve_repo "$rr")"; else rp="$(crossrepo_root)"; fi
        printf '      ✗ %s: %s\n' "$COUNTERPART_FIELD" "$ref"
        printf '        %s\n' "$(crossrepo_no_such_tasklist_msg "$rp" "$ref")" ;;
    esac
  done
}

# --- the check: a counterpart that MERGED while its marker is still live -------
# The failure this whole module exists for. The marker is a placeholder; the work
# happened downstream; nothing upstream noticed. `chief list` kept counting five of
# koine's markers as pending for as long as it took a human to search fourteen repos
# by content — and the one that led its park sentence with a dependency instead of
# the word "placeholder" was missed on the first pass.
#
# Resolution is crossrepo.sh's, the driver's own: chief reads exactly one file across
# the boundary, the counterpart's completed record, and asks the one question
# `dependsOn` asks of it — does it carry `mergedToMain`.
#
# What is NOT a finding:
#   • a counterpart still in flight (`active`) — the normal state, and four of koine's
#     five markers were in it while the fifth had shipped. A check that flagged those
#     would be noise, and noise is how a report stops being read.
#   • a counterpart FILED without `mergedToMain` — a completed record that never
#     merged. It cannot satisfy a dependency edge either, and it is the retirement
#     trap, not a shipped counterpart.
#   • a marker that already carries `supersededBy` — retired. The human acted.

# counterpart_scan FILE… — one TAB-separated record per finding, on stdout:
#
#   done<TAB><marker><TAB><ref><TAB><merge-sha><TAB><record-path>
#   unresolvable<TAB><marker><TAB><ref><TAB><reason><TAB>
#
# and nothing at all for the three non-findings above. Callers pass the LIVE
# tasklists (`tasks/chief/*.json`); a marker already moved to `completed/` is not a
# marker anymore.
#
# It DEGRADES, never aborts: a counterpart in a repo that is not checked out on this
# host is one `unresolvable` record and the scan moves to the next file, because a
# partial checkout is the common case and a laptop missing one sibling repo must
# still get the other findings.
counterpart_scan() {
  local f marker ref loc st path sha
  for f in "$@"; do
    [ -f "$f" ] || continue
    # Already retired: the human has acted, and re-reporting it is a false finding.
    if [ -n "$(jq -r '.supersededBy // empty' "$f" 2>/dev/null)" ]; then continue; fi
    marker="$(basename "$f" .json)"
    counterpart_refs "$f" | while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      loc="$(crossrepo_locate "$ref")"
      st="${loc%% *}"; path="${loc#* }"
      case "$st" in
        merged)
          sha="$(jq -r '.mergedToMain // empty' "$path" 2>/dev/null)"
          printf 'done\t%s\t%s\t%s\t%s\n' "$marker" "$ref" "${sha:-?}" "$path" ;;
        norepo)
          printf 'unresolvable\t%s\t%s\t%s\t\n' "$marker" "$ref" \
            "repo \"$(dep_repo "$ref")\" is not checked out here" ;;
        missing)
          printf 'unresolvable\t%s\t%s\t%s\t\n' "$marker" "$ref" \
            "no tasklist \"$(dep_task "$ref")\" there" ;;
      esac
    done
  done
}

# counterpart_shipped_report FILE… — counterpart_scan rendered for a human, one line
# each. Every line names the marker, the counterpart and the merge sha, because the
# next action is retiring that marker and it should not need a second investigation
# to start. Empty output = nothing shipped that is still sitting in the backlog.
counterpart_shipped_report() {
  local st marker ref detail path
  counterpart_scan "$@" | while IFS="$(printf '\t')" read -r st marker ref detail path; do
    case "$st" in
      done)         printf '  ⚑ %s — its downstream counterpart has MERGED: %s @%s\n' "$marker" "$ref" "$detail" ;;
      unresolvable) printf '  ? %s — counterpart %s could not be checked (%s)\n' "$marker" "$ref" "$detail" ;;
    esac
  done
}
