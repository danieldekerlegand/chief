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

# decision_verdict_json CHOICE NOTE ACTION STORIES_ID [WHO] -> the record, as one object.
#
# THE shape, written once and read once. cmd_decide puts it in two places — the
# durable record above, and the `.verdict` field of the tasklist a human reads six
# months later — and decision_verdict_set reads it back out of either. Three call
# sites; one definition, here, so they cannot disagree about what a verdict is.
#
# ACTION is the AUTHORITY half and the reason a verdict word is never parsed: the
# choice is the operator's own vocabulary ("postgres", "approved", "the MIT row"),
# and chief holds no dictionary that could tell a yes from a no in it. What the
# branch may do is carried by the flag the operator recorded it with, which is a
# closed set — see decision_authority.
#
# WHO answers "which human decided this" on a record read six months later, and in
# the event stream a host subscribes to. Best-effort by design: git's configured
# identity, else the login name. Provenance for a human, never an authorisation
# check — the authorisation is that `chief decide` is the only writer at all.
decision_verdict_json() {
  local who="${5:-}"
  [ -n "$who" ] || who="$(git config user.email 2>/dev/null || true)"
  [ -n "$who" ] || who="${USER:-$(id -un 2>/dev/null || echo unknown)}"
  jq -n --arg choice "${1:-}" --arg note "${2:-}" --arg action "${3:-}" --arg stories "${4:-}" \
     --arg who "$who" \
    '{choice:$choice, note:$note, action:$action, stories:$stories, who:$who,
      recordedAt:(now|todateiso8601)}'
}

# decision_authority ACTION -> what the flag the verdict was recorded with lets the
# prepared branch DO. The one place that mapping exists, because it is the whole
# safety property: `chief decide` validates the flag against this set, and the driver
# reads its answer. A second opinion about which flags mean "ship it" is how a
# mechanism that can only say yes gets built by accident.
#
#   merge   --proceed  the operator said the gated work may go: ordinary verify+merge
#   refuse  --decline  the operator said no: the branch is kept, and never merged
#   none    --unpark / --retire, or a record older than these flags. Both of those
#           actions assume the DELIVERABLE IS THE VERDICT — one clears a park, the
#           other files the tasklist — and neither is consent to merge code. A
#           tasklist carrying code keeps halting until one of the two above is given.
decision_authority() {
  case "${1:-}" in
    proceed) printf 'merge' ;;
    decline) printf 'refuse' ;;
    *)       printf 'none' ;;
  esac
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
#   DECISION_ACTION  the flag it was recorded with · DECISION_WHO who recorded it
#   DECISION_AUTHORITY  what that flag lets the branch do (decision_authority);
#                    'none' in every state but `recorded`, so a caller that reads
#                    only this one global can never merge on a stale or absent verdict
#   DECISION_DETAIL  a sentence for the operator, set in every state
decision_verdict_set() {
  DECISION_STATE=none DECISION_CHOICE="" DECISION_NOTE="" DECISION_ACTION="" DECISION_DETAIL=""
  DECISION_WHO="" DECISION_AUTHORITY=none
  local rec="${1:-}" bound now sp v; shift 2>/dev/null || true
  [ -r "$rec" ] || { DECISION_DETAIL="waiting for a human verdict"; return 0; }
  command -v jq >/dev/null 2>&1 || { DECISION_DETAIL="jq is unavailable — no verdict can be read"; return 0; }
  # `.verdict // .` normalises the two places cmd_decide writes the SAME object to.
  v="$(jq -r '(.verdict // .) as $v
        | [($v.choice // ""), ($v.note // ""), ($v.action // ""), ($v.stories // ""), ($v.who // "")]
        | map(tostring | gsub("\n"; " ")) | join("\u001f")' "$rec" 2>/dev/null)"
  # US, not tab: tab is IFS whitespace, so an empty middle field (a verdict recorded
  # before `action` existed) would shift every field after it left.
  IFS=$'\037' read -r DECISION_CHOICE DECISION_NOTE DECISION_ACTION bound DECISION_WHO <<EOF
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
  DECISION_AUTHORITY="$(decision_authority "$DECISION_ACTION")"
  DECISION_DETAIL="operator verdict '$DECISION_CHOICE'${DECISION_WHO:+ by $DECISION_WHO}${DECISION_NOTE:+ — $DECISION_NOTE}"
  # A verdict recorded with a flag that authorises nothing is NOT a yes and must not
  # read like one. `--unpark` and `--retire` both assume the deliverable is the verdict
  # itself, so on a tasklist carrying code they leave the work exactly where it was —
  # and the sentence has to name the flag that would move it, or the operator is back
  # to reading the driver to find out why a recorded verdict changed nothing.
  [ "$DECISION_AUTHORITY" != none ] || DECISION_DETAIL="$DECISION_DETAIL (recorded with \
--${DECISION_ACTION:-none}, which authorises no merge — re-record with --proceed or --decline)"
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
# THREE outcomes, because a decision point that can only say yes is not one. What the
# operator authorised is read off DECISION_AUTHORITY — the flag, never the verdict word,
# which is the operator's own vocabulary and not a language chief speaks:
#
#   merge   the gated work continues to the ordinary rebase → verify → merge path
#   refuse  DECISION-DECLINED: a terminal, successful, NEGATIVE outcome. The branch and
#           worktree are kept — the operator declined the work, they did not lose it —
#           and nothing merges. Dependents are cascaded (dep_broken in driver.sh) for a
#           stated reason: what they depend on is never arriving
#   none    a verdict exists but authorises no merge (--unpark / --retire) — halt, and
#           say which flag would move it
#
# Returns 0 when the branch may PROCEED to the ordinary verify+merge path, 1 when it
# was parked. $live/$total/$remaining/$STATE are run_worker's, by dynamic scope, and
# worker_park is the driver's — the same convention engine/measure.sh's unmeasured_stop
# and engine/criteria.sh's criteria_scope_stop already use.
decision_stop() {
  local name="$1" repo="$2" src="$3" wtprd="$4"
  decision_verdict_set "$(decision_verdict_file "$repo" "$name")" "$src" "$wtprd"
  # WHICH HUMAN DECIDED WHAT, in the run's own event stream. 106 US-3 asked for this
  # and nothing emitted it, so a completed run recorded the merge and not the consent
  # behind it. Emitted for any verdict actually READ — the machine half is `state` (the
  # action) and the human half is `detail`; the park/proceed event that follows is the
  # transition, this is the authority for it. Guarded because decision.sh is also
  # sourced by agent.sh and research.sh, which have no event stream.
  if [ "$DECISION_STATE" = recorded ] && command -v event_emit >/dev/null 2>&1; then
    event_emit tasklist.decision name="$name" state="${DECISION_ACTION:-none}" \
      detail="verdict '$DECISION_CHOICE' by ${DECISION_WHO:-unknown} (--${DECISION_ACTION:-none} → ${DECISION_AUTHORITY}): ${DECISION_NOTE:-no note}"
  fi
  case "$DECISION_AUTHORITY" in
    merge)
      echo ">> $name DECIDED — $DECISION_DETAIL; the work it gated continues to the ordinary verify+merge path"
      return 0 ;;
    refuse)
      worker_park decision-declined "the operator DECLINED this decision; $DECISION_DETAIL — branch kept, nothing merged" \
        "!! $name DECISION-DECLINED — the operator declined it, so the work it gated does NOT merge ($DECISION_DETAIL)"
      return 1 ;;
    *)
      worker_park awaiting-decision "the decision brief is prepared; $DECISION_DETAIL" \
        "!! $name AWAITING-DECISION — stories are complete, but only a human verdict can finish this tasklist ($DECISION_DETAIL)"
      return 1 ;;
  esac
}
