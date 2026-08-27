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

# ── the verdict a human recorded, and what it was recorded ABOUT ─────────────
#
# `chief decide` WRITES the verdict and driver.sh READS it, in two processes hours
# apart — and 106 shipped only the writer. The halt parked unconditionally, so
# recording a verdict left the tasklist in exactly the state it was already in, plus
# a field nothing consulted. Both halves live here now, so the shape cannot drift
# again: a second definition of "has a verdict" is how this breaks twice.

# decision_verdict_file PROJECT NAME -> the DURABLE record the driver reads.
#
# Beside the driver's other per-tasklist state and NOT in the tasklist JSON, for two
# reasons that both cost a verdict its life. run_worker's isolation guard runs
# `git checkout -- tasks/<name>.json` on every iteration (it exists to undo an agent
# that reached out of its worktree), which discards an uncommitted field. And
# COMMITTING the field is worse, not better: the branch waiting on the decision has
# usually committed its own edit to that same file — the pass-flags — so a verdict
# commit on the base collides with it at rebase and ends the decided tasklist in
# REBASE-CONFLICT. Gitignored state is invisible to both.
decision_verdict_file() {
  printf '%s/%s/decisions/%s.json\n' "${1%/}" "${CHIEF_STATE_DIR:-.chief/state}" "${2:-}"
}

# decision_verdict_json CHOICE NOTE ACTION STORIES_ID -> the record, as one object.
#
# THE shape, written once and read once. cmd_decide puts it in two places — the
# durable record above, and the `.verdict` field of the tasklist a human reads six
# months later — and decision_verdict_set reads it back out of either. Three call
# sites; one definition, here, so they cannot disagree about what a verdict is.
decision_verdict_json() {
  jq -n --arg choice "${1:-}" --arg note "${2:-}" --arg action "${3:-}" --arg stories "${4:-}" \
    '{choice:$choice, note:$note, action:$action, stories:$stories, recordedAt:(now|todateiso8601)}'
}

# decision_stories_id PRD -> a change-detector for the stories a verdict approves.
#
# The PROJECTION is the whole point. `passes` and `notes` differ between the copy the
# operator decided from (on the base branch: every story false, no notes) and the copy
# about to be merged (every story true, notes written), so binding to the file's raw
# bytes would never match once and the verdict would never apply to anything. What a
# human actually said yes to is id + title + acceptanceCriteria; change any of that and
# the yes is not transferable. Empty on unreadable/unparseable input rather than
# hashing nothing — `cksum` of an empty stream is a perfectly good constant, and it
# would make "no such file" and "no stories" collide.
#
# cksum is POSIX and everywhere; a staleness guard, not a security boundary. The same
# reasoning as engine/review.sh's review_plan_id, which this deliberately mirrors.
decision_stories_id() {
  local proj
  command -v jq >/dev/null 2>&1 || return 1
  proj="$(jq -S -c '[(.userStories // [])[]
                     | {id: (.id // ""), title: (.title // ""),
                        acceptanceCriteria: (.acceptanceCriteria // [])}]' "${1:-}" 2>/dev/null)" || return 1
  [ -n "$proj" ] || return 1
  printf '%s' "$proj" | cksum | tr -s ' ' '-' | tr -d ' \n'
}

# decision_verdict_set RECORD [STORIES_PRD …] — read the operator's verdict off disk
# and classify it. RECORD is decision_verdict_file's path, or any tasklist carrying a
# `.verdict` field. Each STORIES_PRD is a state the verdict is about to be applied to
# and must be bound to; with none given the record's own stories are used, which is
# what a caller holding only the tasklist wants. Silent — every answer is a global:
#
#   DECISION_STATE   none      nobody has decided — halt, exactly as this always has
#                    stale     a verdict exists, but not for THESE stories
#                    recorded  a verdict bound to every state in hand
#   DECISION_CHOICE  the verdict word · DECISION_NOTE its reasoning
#   DECISION_ACTION  the flag it was recorded with
#   DECISION_DETAIL  a sentence for the operator, set in every state
decision_verdict_set() {
  DECISION_STATE=none DECISION_CHOICE="" DECISION_NOTE="" DECISION_ACTION="" DECISION_DETAIL=""
  local rec="${1:-}" bound now sp v; shift 2>/dev/null || true
  [ -r "$rec" ] || { DECISION_DETAIL="waiting for a human verdict"; return 0; }
  command -v jq >/dev/null 2>&1 || { DECISION_DETAIL="jq is unavailable — no verdict can be read"; return 0; }
  # `.verdict // .` normalises the two places cmd_decide writes the SAME object to.
  v="$(jq -r '(.verdict // .) as $v
        | [($v.choice // ""), ($v.note // ""), ($v.action // ""), ($v.stories // "")]
        | map(tostring | gsub("\n"; " ")) | join("\u001f")' "$rec" 2>/dev/null)"
  # US, not tab: tab is IFS whitespace, so an empty middle field (a verdict recorded
  # before `action` existed) would shift every field after it left.
  IFS=$'\037' read -r DECISION_CHOICE DECISION_NOTE DECISION_ACTION bound <<EOF
$v
EOF
  [ -n "$DECISION_CHOICE" ] || { DECISION_DETAIL="waiting for a human verdict"; return 0; }
  [ "$#" -gt 0 ] || set -- "$rec"
  for sp in "$@"; do
    now="$(decision_stories_id "$sp")" || now=""
    if [ -z "$bound" ] || [ -z "$now" ] || [ "$bound" != "$now" ]; then
      DECISION_STATE=stale
      DECISION_DETAIL="the recorded verdict '$DECISION_CHOICE' was given for different stories than the ones in hand — decide again"
      return 0
    fi
  done
  DECISION_STATE=recorded
  DECISION_DETAIL="operator verdict '$DECISION_CHOICE'${DECISION_NOTE:+ — $DECISION_NOTE}"
  return 0
}

# decision_stop NAME REPO SRC_PRD WT_PRD — the halt, and the one thing that lifts it.
#
# 106 shipped `chief decide` writing a verdict and the driver's halt firing
# unconditionally, so recording a verdict left the tasklist in exactly the state it
# was already in, plus a field nothing consulted — the first decision tasklist to run
# in anger (lugh/460, 2,209 insertions gated on a licence call) could not be finished
# by any invocation of the command built to finish it. Both halves are here now.
#
# The record is read from the PROJECT, never from the worktree: the worktree's copies
# of the tasklist and of prd.json are both writable by the agent, and that is the
# whole difference between a human verdict and a model-authored one
# (test/decision-agent.sh pins it).
#
# BOUND to the stories in BOTH states it is being applied to — the live tasklist the
# operator decided from, and the branch state about to be merged. A verdict is consent
# to a specific brief: re-word the tasklist, or re-plan the branch, and it comes back
# here to be decided again rather than merging on an approval given for something else.
#
# Returns 0 when the branch may PROCEED to the ordinary verify+merge path, 1 when it
# was parked. $live/$total/$remaining/$STATE are run_worker's, by dynamic scope, and
# worker_park is the driver's — the same convention engine/measure.sh's unmeasured_stop
# and engine/criteria.sh's criteria_scope_stop already use.
decision_stop() {
  local name="$1" repo="$2" src="$3" wtprd="$4"
  decision_verdict_set "$(decision_verdict_file "$repo" "$name")" "$src" "$wtprd"
  if [ "$DECISION_STATE" != recorded ]; then
    worker_park awaiting-decision "the decision brief is prepared; $DECISION_DETAIL" \
      "!! $name AWAITING-DECISION — stories are complete, but only a human verdict can finish this tasklist ($DECISION_DETAIL)"
    return 1
  fi
  echo ">> $name DECIDED — $DECISION_DETAIL; the work it gated continues to the ordinary verify+merge path"
  return 0
}
