#!/usr/bin/env bash
# engine/measure.sh — the BAR check on acceptance criteria.
#
# Some criteria state a bar you can HOLD A RESULT AGAINST: "reaches GREEN", "the
# baseline to beat is 77 failed", "exit 0", "renders BYTE-IDENTICALLY". Those are the
# best criteria a tasklist can carry — falsifiable, no interpretation needed — and
# they are exactly the ones that failed silently (2026-08-16/17): cuneiform:348/US-2
# claimed 77-failures-to-GREEN, delivered 25 failed, and reported 3/3. Nothing ever
# compared a claim to a result because nothing ever recorded a result.
#
# CHIEF IS NOT A SECOND TEST RUNNER. It cannot run cuneiform's suite, it does not know
# what GREEN means there, and a gate that tried would be wrong in a new way. What it
# CAN require is the thing whose absence made the failure invisible: when a story
# claims a bar, the run must record the OBSERVED VALUE beside the claim, in the story's
# own `notes`. The number is then in the record where a human — or the next
# iteration — can hold it against the bar.
#
# WHERE CHIEF CANNOT EVALUATE THE BAR, THE STORY IS `unverified`, NOT `passes`.
# That is the honest third state, and it is the same rule `chief quality` already uses
# for a metric no analyzer could measure: it lands in `unmeasured[]` and the ratchet
# SKIPS it, rather than reading an absent number as "nothing got worse". An absent
# measurement is not a passing one. So the story keeps `passes:false`, gains
# `unverified:true`, and the branch stops instead of merging as if it were done.
#
# DELIBERATELY LENIENT ON THE OBSERVATION SIDE. The bar half is a closed list of
# phrases (below); the evidence half accepts any recorded value at all — a number, an
# exit status, "green", "clean". It does NOT check that the observation MEETS the bar,
# because that is the judgement chief has no standing to make. A gate that failed
# honest work would be switched off inside a week, and then the five cases come back;
# one that only demands the measurement be written down costs an honest run nothing,
# because a run that took a measurement has the number to hand.
#
# RUNS ON EVERY PATH TO A MERGE, including the agent-free all-pass resume. A demotion
# lands in the RUNTIME record, while the branch's committed tasklist still reads
# `passes:true` — so the next run re-seeds it as passing, prints "all stories already
# pass — skip agent", and would walk straight through the gate that just stopped it.
# The evidence gate can only run where an agent ran, because it PROMOTES; this one
# only ever demotes, which makes it safe to run everywhere and useless if it does not.
#
# bash 3.2 · jq only. Called from engine/driver.sh's COMPLETE path, once per run.

# The bar phrases, as one Oniguruma alternation (matched case-insensitively). Kept in
# one place because both halves of the report read it — what fired, and what to quote.
MEASURE_BAR_RE='(exit(s|ed)?( code)?|returns?|\brc\b)[ \t]*[:=]?[ \t]*(non-?zero|zero|[0-9]+)'
MEASURE_BAR_RE="$MEASURE_BAR_RE"'|byte-?identical(ly)?|bit-?identical(ly)?'
MEASURE_BAR_RE="$MEASURE_BAR_RE"'|\bgreen\b'
MEASURE_BAR_RE="$MEASURE_BAR_RE"'|(at least|at most|no more than|no fewer than|fewer than|less than|more than|greater than|under|below|over|within|up to|exactly)[ \t]+[0-9]'
MEASURE_BAR_RE="$MEASURE_BAR_RE"'|[0-9]+(\.[0-9]+)?[ \t]*%'
MEASURE_BAR_RE="$MEASURE_BAR_RE"'|\b(0|zero|no)[ \t]+(failure|failures|failing|error|errors|regression|regressions|violation|violations)\b'
MEASURE_BAR_RE="$MEASURE_BAR_RE"'|\b[0-9]+[ \t]+(failed|failing|passing|passed|tests?|checks?|errors?|failures?)\b'
MEASURE_BAR_RE="$MEASURE_BAR_RE"'|\bbaseline\b[^.]{0,60}[0-9]'

# measure_gate PRD — hold every PASSING story to the bars its criteria state.
#
# Applies to a story whichever way it came to pass: chief promoted it, or the agent
# marked it itself. The evidence gate's exemption for self-reported work (US-1) is
# about ceremony — a note saying HOW — and this is not that. A bar is a claim about a
# NUMBER, and who typed the pass-flag does not make an unrecorded number recorded.
#
# Demotes offenders in place (`passes:false`, `unverified:true`), clears a stale
# `unverified` off any story that now records its value, and prints one block per
# offender: EVERY bar the criterion states, the criterion verbatim, and what the notes
# did say. Every bar, not just the first — cuneiform:348/US-2's own criterion opens on
# "reaches GREEN acceptance" and carries "77 failed, 860 passed, 39 errors" past the
# 200-char clip, so reporting one match hid the number that made the case.
# Empty output = every claimed bar has an observation beside it.
measure_gate() {
  local prd="$1" t
  jq -r --arg bar "$MEASURE_BAR_RE" '
    def clip: if (. | length) > 200 then .[0:197] + "..." else . end;
    # An OBSERVED VALUE in the notes: any number, once the tokens that are names
    # rather than measurements are removed (story ids, cross-repo refs, issue
    # numbers), or an explicit result word. Lenient by design — see the header.
    def observed:
      ( (. // "") | tostring
        | gsub("\\bus-?[0-9]+"; " "; "i")
        | gsub("\\b[a-z][a-z0-9_-]*:[0-9]+"; " "; "i")
        | gsub("#[0-9]+"; " ") ) as $n
      | ($n | test("[0-9]"))
        or ($n | test("\\b(green|passe[sd]|passing|clean|identical|failing|failures?)\\b"; "i"));
    .userStories[]?
    | select(.passes == true)
    | . as $us
    | ((.notes // "") | tostring) as $n
    | [ (.acceptanceCriteria // [])[]? | tostring | select(test($bar; "i")) ] as $bars
    | select(($bars | length) > 0 and (($n | observed) | not))
    | "   ✗ \($us.id // "?") — \($us.title // "(untitled)")\n"
      + ( [ $bars[]
            | "       states a bar: " + ([match($bar; "gi").string | "\"\(.)\""] | join(", "))
              + "\n       claimed: \"\(clip)\"" ]
          | join("\n") )
      + "\n       recorded: "
      + (if ($n | test("\\S")) then "\"\($n | clip)\" — no observed value in it" else "(nothing)" end)
  ' "$prd" 2>/dev/null
  t="$(mktemp)"
  jq --arg bar "$MEASURE_BAR_RE" '
    def observed:
      ( (. // "") | tostring
        | gsub("\\bus-?[0-9]+"; " "; "i")
        | gsub("\\b[a-z][a-z0-9_-]*:[0-9]+"; " "; "i")
        | gsub("#[0-9]+"; " ") ) as $n
      | ($n | test("[0-9]"))
        or ($n | test("\\b(green|passe[sd]|passing|clean|identical|failing|failures?)\\b"; "i"));
    def unmeasured:
      (.passes == true)
      and ([ (.acceptanceCriteria // [])[]? | tostring | select(test($bar; "i")) ] | length) > 0
      and ((((.notes // "") | tostring) | observed) | not);
    .userStories |= map(if unmeasured then .passes = false | .unverified = true
                        else del(.unverified) end)
  ' "$prd" > "$t" 2>/dev/null && mv "$t" "$prd" || rm -f "$t"
}

# ── THE UNVERIFIED MARKER ─────────────────────────────────────────────────────
# An UNVERIFIED stop has to OUTLIVE the run that produced it, for exactly the reason
# a post-rebase verify failure does (driver.sh's $SNAP/<name>.verify-failed.log):
# the demotion lands in the RUNTIME prd.json, and the next run re-seeds that from the
# branch's COMMITTED tasklist — which still reads passes:true. So the resume computes
# 0 stories left, prints "all stories already pass — skip agent, go to verify+merge",
# spends no agent turn at all, and the gate that stopped the run stops it again, in
# the same words, forever. insimul 261-slice-corpus-babylon-reference did that three
# runs running before a human flipped the pass-flag back by hand.
#
# So it is written down where the RESUME can read it, on the verify-failure's terms:
# one file per tasklist under $SNAP (outside the worktree run_worker rm -rf's), born
# with the stop and cleared by the merge that clears every other stale failure
# artifact. It carries the REPORT VERBATIM — the stories, the bars they state and the
# criteria as measure_gate printed them — because the resume's job is to hand the
# agent the specific bars still owed a number, not generic advice to check its work.
unverified_marker() { printf '%s/%s.unverified.md\n' "${SNAP:-${STATE:-.}/snapshots}" "$1"; }

# unverified_persist NAME REPORT — record an UNVERIFIED stop for the next resume.
#
# ONLY the two UNVERIFIED stops call this. Every OTHER stop already re-engages the
# agent on its own terms — INCOMPLETE and EMPTY-NO-WORK leave stories reading false,
# a usage limit and an operator pause leave the branch mid-tasklist — so a marker
# there would buy nothing and cost an agent turn on every future resume of a branch
# that never needed one. Over-firing is the failure mode to fear here: this fix is
# only worth having if the tasklists it does NOT apply to still finish agent-free.
unverified_persist() {
  local f; f="$(unverified_marker "$1")"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  printf '%s\n' "$2" > "$f" 2>/dev/null || true
}

# Fail the tasklist on measure_gate's report. Shares the UNVERIFIED status with the
# evidence gate on purpose — both mean "this branch is not known to have done what it
# says", and an operator reads the same exit code (headless `6`) and the same
# vocabulary for both. The MESSAGE is what separates them, because the fix does: an
# unevidenced story needs a note saying how, an unmeasured one needs the number.
# $1 = the report. $name/$branch/$live/$total/$remaining/$STATE are run_worker's, by
# dynamic scope — the same convention unverified_stop and criteria_scope_stop use.
#
# TWO CALLERS, ONE VERDICT. The merge floor passes measure_gate's own return value. The
# IN-RUN stop ($AGENT_RC_UNVERIFIED — agent.sh gave up re-telling one story to record
# its value) passes the report the ITERATION BOUNDARY banked to disk, because by then
# measure_gate returns nothing to pass: the boundary has already put the story back to
# passes:false, and this gate only ever reports PASSING stories. Same status, same
# words, same fix — said hours earlier, which is the whole point of the earlier check.
unmeasured_stop() {
  local n; n="$(_int "$(printf '%s\n' "$1" | grep -c '✗' 2>/dev/null || true)")"
  unverified_persist "$name" "$1"          # so the NEXT run re-engages instead of re-failing
  live_set "$live" phase=unverified
  event_emit tasklist.unverified name="$name" state=failed \
    detail="$n stor$([ "$n" = 1 ] && echo y claims || echo ies claim) a measurable bar with no observed value recorded"
  echo "UNVERIFIED $(( $(_int "$total") - $(_int "$remaining") ))/$total" > "$STATE/$name.status"
  echo "!! $name UNVERIFIED — $n stor$([ "$n" = 1 ] && echo y claims a bar || echo ies claim bars) nothing measured:"
  printf '%s\n' "$1"
  echo "   Recorded for the resume in ${SNAP_REL:-$SNAP}/$name.unverified.md — the next run re-engages the agent on these stories rather than skipping straight back to this gate."
  echo "   Not merging; marked 'unverified' rather than passing — chief cannot evaluate these bars, so it will not record them as met. Put the OBSERVED value in the story's 'notes' (branch $branch is kept in its worktree)."
}
