#!/usr/bin/env bash
# Shared predicate for tasklists whose deliverable is a human decision.
is_decision_tasklist() {
  local prd="${1:-}"
  [ -r "$prd" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e '
    ((.type // "") | ascii_upcase) == "DECISION"
    or ((.kind // "") | ascii_upcase) == "DECISION"
    or (.decision == true)
    or ((.decision // "") | ascii_upcase) == "DECISION"
  ' "$prd" >/dev/null 2>&1
}
