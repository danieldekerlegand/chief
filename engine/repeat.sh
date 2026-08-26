#!/usr/bin/env bash
# engine/repeat.sh — AN OUTCOME CHIEF KEEPS REDISCOVERING.
#
# THE DEFECT, and it is the SAFETY NET for the one engine/terminal.sh fixes. A story
# whose honest answer is negative can now say so (`terminalFalse`), but that is a
# DECLARATION made when the tasklist is authored — and the tasklist that needs it is
# exactly the one nobody thought to write it on. cuneiform
# `283-nixos-bare-metal-vpn-topology-target`, 2026-08-22 → 2026-08-25: 63 commits, 21
# iterations in a single run, 59 across the program, and **42 consecutive IDENTICAL
# measurements** of a flow that does not complete. The agent never faked it and never
# stopped saying so. Nothing could hear it, and the run ended INCOMPLETE — a wrong
# verdict on finished work.
#
# WHY THE STALL COUNTER CANNOT SEE THIS, which is the whole reason this module exists
# rather than a threshold on an existing one. The stall counter (engine/agent.sh) asks
# "did the work advance?" and `283` advanced it every single turn: it re-ran the
# measurement, wrote the finding down and committed real files outside the state
# directory. `112` — a bookkeeping commit is not progress — does not catch it either,
# for the same reason, and it is the fix most likely to be mistaken for this one. Both
# of those ask whether an ITERATION COUNTED. This asks whether the TASKLIST IS GOING
# ANYWHERE, and the answer was available from its own record by iteration 6.
#
# THE RULE, stated on the RECORDED OUTCOME and never on the commit count: when the
# story chief is driving records the SAME thing at $REPEAT_LIMIT consecutive iteration
# boundaries — same id, same `passes`, same measurement — the loop stops and says the
# tasklist appears unable to complete. `283` produced a real commit every iteration and
# each one was genuine, just not new, so counting commits is counting the wrong thing.
#
# WHAT COUNTS AS A RECORDED OUTCOME, and why it is not simply "notes are unchanged". A
# story mid-implementation has nothing recorded yet, and three quiet iterations of
# ordinary work must never read as a repeat. So the outcome only exists once `notes`
# carry an OBSERVATION — engine/measure.sh's `observed`, borrowed through
# engine/terminal.sh exactly as the inert rule borrows it, so there is one answer to
# "was this measured" across all three rules. No observation, no fingerprint, counter
# reset. That also makes this rule DISJOINT from the bar rule by construction: a story
# demoted for claiming a bar it never measured has no observation, so it is
# MEASURE_DEMOTE_LIMIT's business and never reaches this one.
#
# WHAT CHIEF DOES NOT DO HERE. It does not decide the answer is `false` — it cannot,
# and a heuristic that guessed would be a way to bury unfinished work. It stops, names
# the story, quotes the finding, and names the TWO ACTIONS that resolve it (amend the
# criterion, or declare the negative terminal). `283`'s operator was told only that it
# stalled, and went to re-scope a tasklist whose work was intact and whose agent had
# already written the correct diagnosis.
#
# bash 3.2 · jq only.

# N, with a stated default. 3 = the outcome recorded, then rediscovered twice with the
# tasklist's own record unchanged. Low enough to fire inside an ordinary `iters` budget
# (283 was diagnosable by iteration 6 and ran to 42), high enough that a story whose
# measurement genuinely lands on the turn it is written is never charged for it.
REPEAT_LIMIT="${REPEAT_LIMIT:-3}"

# SETTLED and OBSERVED come from engine/terminal.sh (which in turn borrows `observed`
# from engine/measure.sh). Sourced on demand so this module works wherever it is pulled
# in — the agent loop already has both, a one-shot reader may have neither.
if [ -z "${TERMINAL_JQ:-}" ]; then
  # shellcheck source=engine/terminal.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/terminal.sh"
fi

# repeat_fingerprint PRD — the RECORDED OUTCOME of the story chief is driving, as one
# comparable line: `<id> US <passes> US <notes, whitespace-collapsed>`. Empty — never a
# constant — when there is nothing to compare: no open story, or an open story that has
# recorded no observation yet. Empty means "reset the counter", so a tasklist mid-work
# can never accumulate repeats by being quiet.
#
# The comparison is on the collapsed text, so an agent that REWORDS its finding is not
# counted as repeating itself. That is the same conservatism measure.sh's DEMOTE_KEY
# uses, and it is the right direction to be wrong in: a missed repeat costs iterations,
# a false one stops a tasklist that was working.
repeat_fingerprint() {
  jq -r "$(_terminal_prog '
    [ (.userStories // [])[] | select(settled | not) ][0] as $s
    | if $s == null then empty
      else ((($s.notes // "") | tostring | gsub("[[:space:]]+"; " ")
             | sub("^ +"; "") | sub(" +$"; ""))) as $n
        | if ($n | observed) then "\($s.id // "?")\u001f\($s.passes)\u001f\($n)" else empty end
      end')" "$1" 2>/dev/null
}

# The counter, in-process only and deliberately so — the same argument measure.sh's
# DEMOTE_REPEATS makes. A resumed run has not yet been told anything by the agent it
# would be counting against, so it starts at zero and gives that agent the same
# $REPEAT_LIMIT boundaries any other run would.
REPEAT_KEY=""; REPEAT_COUNT=0; REPEAT_STORY=""

# repeat_bump PRD — fold this boundary into the count. SET-A-GLOBAL ($REPEAT_KEY /
# $REPEAT_COUNT / $REPEAT_STORY) and RETURNS 0 only when the limit is reached, so the
# caller is one `if`. Never fatal: an unreadable PRD yields no fingerprint, which
# resets — chief does not stop a tasklist on a file it could not read.
repeat_bump() {
  local fp
  fp="$(repeat_fingerprint "$1")"
  if [ -z "$fp" ]; then REPEAT_KEY=""; REPEAT_COUNT=0; REPEAT_STORY=""; return 1; fi
  if [ "$fp" = "$REPEAT_KEY" ]; then
    REPEAT_COUNT=$(( REPEAT_COUNT + 1 ))
  else
    REPEAT_KEY="$fp"; REPEAT_COUNT=1
  fi
  REPEAT_STORY="${fp%%$'\037'*}"
  [ "$REPEAT_COUNT" -ge "$REPEAT_LIMIT" ]
}

# repeat_report PRD COUNT — the story, and the finding it keeps re-recording, verbatim.
# The FINDING is the point, for the reason terminal_negative_report gives: a story that
# keeps answering the same thing is usually naming the work to do instead, and that is
# the most valuable output the tasklist has produced.
repeat_report() {
  jq -r --arg n "${2:-0}" "$(_terminal_prog '
    def clip: if (. | length) > 300 then .[0:297] + "..." else . end;
    [ (.userStories // [])[] | select(settled | not) ][0]
    | select(. != null)
    | "   ⟳ \(.id // "?") — \(.title // "(untitled)")\n"
      + "       recorded the SAME outcome at \($n) consecutive iteration boundaries — `passes` unchanged, measurement unchanged\n"
      + "       finding: \(((.notes // "") | tostring | clip))"')" "$1" 2>/dev/null
}

# repeat_actions — the two things that resolve it, because "it stalled" is what sent
# `283`'s operator to re-scope a tasklist that was not broken. Chief cannot choose
# between them: only a human knows whether the bar was wrong or the answer is no.
# Quoted heredoc — the backticks below are prose, and an unquoted one would RUN them.
repeat_actions() {
  cat <<'EOF'
   Two things resolve this, and chief will not choose between them:
     1. AMEND THE CRITERION — if the bar as written cannot be reached, rewrite the
        story to ask for what can actually be delivered, then re-run.
     2. DECLARE THE NEGATIVE TERMINAL — if `false` IS the honest answer, add
        "terminalFalse": true to that story (docs/reference/tasklist-schema.md). It
        then SETTLES on the measurement it already recorded, `passes` stays false
        because the answer is false, and the finding travels into completed/.
        Then either re-run this tasklist (chief finishes and merges it), or — if
        nothing more should run against it — file it where it stands:
            chief retire --negative <tasklist>
   Chief does not decide which of those is true: it cannot evaluate the finding, and
   guessing would be a way to bury unfinished work.
EOF
}

# repeat_stop_report PRD COUNT — the whole block, as it is both printed to the run log
# and banked for the driver. One composer, so the two can never say different things.
repeat_stop_report() {
  echo "!! This tasklist appears UNABLE TO COMPLETE — the story below has recorded the same outcome at $2 consecutive iteration boundaries (limit $REPEAT_LIMIT). Commits were landing every time; none of them changed the answer:"
  repeat_report "$1" "$2"
  repeat_actions
}

# Fail the tasklist on the IN-RUN repeat stop (agent.sh's $AGENT_RC_REPEAT). Here, not
# in the driver, for the reason unmeasured_stop is in engine/measure.sh: the rule and
# the park it causes are one policy, and a driver arm that restated either would drift
# from it. $1 = the report the boundary banked in the worktree — the AGENT's own, from
# repeat_stop_report above, so the run log and the boundary can never say different
# things. It is copied to $STATE because the end-of-run summary still quotes it after
# the worktree is gone, exactly as the stall reason is. $name/$branch/$STATE are
# run_worker's, by dynamic scope, and worker_park is the driver's — the same convention
# unmeasured_stop and unverified_stop already use.
cannot_complete_stop() {
  cp "$1" "$STATE/$name.cannot-complete" 2>/dev/null || true
  worker_park cannot-complete \
    "the same story recorded the same outcome at consecutive iteration boundaries — the tasklist cannot complete as written; branch + worktree kept" \
    "!! $name CANNOT COMPLETE — chief kept re-answering one question and the answer never moved; branch $branch and its worktree are kept, and every commit with them"
  sed 's/^/   /' "$STATE/$name.cannot-complete" 2>/dev/null \
    || echo "   (the boundary report was not kept)"
}
