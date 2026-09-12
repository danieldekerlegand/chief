#!/usr/bin/env bash
# engine/terminal.sh — A STORY WHOSE CORRECT ANSWER IS `false`.
#
# THE DEFECT. Chief has exactly one notion of done — every story `passes:true` — so a
# story whose honest, measured result is NEGATIVE makes its tasklist permanently
# uncompletable. Measured on cuneiform `283-nixos-bare-metal-vpn-topology-target`,
# 2026-08-22 → 2026-08-25: its US-3 said in as many words "if it does not complete,
# THIS STORY STAYS `passes: false`", the flow genuinely does not complete
# (`maas-client-absent`), and `passes:false` was therefore the CORRECT outcome. The
# story was DONE and its answer was no. Chief re-drove the branch anyway — 63 commits,
# 59 iterations, 42 consecutive IDENTICAL measurements — and the agent's terminal note
# read "this tasklist can NEVER report all-stories-true… It needs MANUAL RETIREMENT."
# It was right, it said so in the only channel it had, and nothing could hear it.
#
# THE VOCABULARY. A story may declare `"terminalFalse": true`. That is a statement
# about the STORY, made when the tasklist is authored: "a negative finding here is a
# deliverable, not a failure to deliver." It does not assert what the answer is, and
# chief never evaluates the answer — it only stops requiring that the answer be yes.
#
# THREE STATES, NOT TWO. A story is SETTLED when the tasklist may stop asking about it:
#
#   passes:true                                  → settled, and the answer is YES
#   passes:false + terminalFalse + a measurement  → settled, and the answer is NO
#   anything else                                → OPEN, exactly as before
#
# `passes` is NOT flipped for the negative. It stays false because the answer really is
# false — that is the finding, and rewriting it to true to make the arithmetic work
# would destroy the only thing the tasklist produced. Completion is computed from
# SETTLED; `passes` keeps meaning what it has always meant. So the record can still be
# read by anything that never heard of this field, and a reader that has can tell the
# two apart, which is the second half of the defect: `283` rendered as unfinished work
# for three days.
#
# THE DECLARATION IS INERT WITHOUT EVIDENCE — and that is the whole safety argument.
# On its own, `terminalFalse:true` would be a way to mark hard stories complete: write
# the field, never do the work, ship. So a declared story settles only once its `notes`
# carry an OBSERVATION — engine/measure.sh's `observed`, the same predicate that
# decides whether a claimed bar was measured, shared rather than copied. A declared
# story with nothing recorded is not done; it is SKIPPED, it stays open, and
# terminal_inert_report names it. The two are not spellable the same way.
#
# WHAT IT IS NOT. It is not a way to fail quietly: the finding must be written down and
# it travels into the completed record (`chief retire --negative`). It is not inferred
# from prose — a story that merely SOUNDS like a verification is untouched — and it is
# not a magic value in `notes`, because `notes` is the place the finding goes and a
# field that is also a control channel cannot be edited by a human without risk.
#
# bash 3.2 · jq only.

# The engine reads the field name in exactly one place: here. `chief lint`, the docs
# and the tests quote it, so a rename is one edit plus the prose.
TERMINAL_FIELD='terminalFalse'

# One definition of `observed`, borrowed from the BAR rule (engine/measure.sh). Sourced
# on demand so this module works wherever it is pulled in — the driver and the agent
# loop already have measure.sh, `bin/chief` and the monitor may not.
if [ -z "${MEASURE_OBSERVED_JQ:-}" ]; then
  # shellcheck source=engine/measure.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/measure.sh"
fi

# The predicates, as jq `def`s over ONE story. Every count, report and filter below is
# these five names — there is no second expression of "settled" anywhere in the engine.
TERMINAL_JQ='
    def declared:  (.terminalFalse == true);
    def attempted: (((.notes // "") | tostring) | observed);
    def negative:  ((.passes != true) and declared and attempted);
    def inert:     ((.passes != true) and declared and (attempted | not));
    def settled:   ((.passes == true) or negative);
'

# terminal_prog PROGRAM — the two preludes in front of a caller's jq program.
_terminal_prog() { printf '%s%s%s' "$MEASURE_OBSERVED_JQ" "$TERMINAL_JQ" "$1"; }

# terminal_counts PRD — SET FOUR GLOBALS from one fork:
#   TERMINAL_TOTAL     stories in the tasklist
#   TERMINAL_PASSED    passes:true
#   TERMINAL_NEGATIVE  settled with the answer NO
#   TERMINAL_OPEN      not settled (what "remaining" now means)
# A SET-A-GLOBAL/PRINT-IT pair in the crossrepo.sh idiom: every caller in the driver
# wants at least two of these, and `$( )` is a fork. Unreadable input leaves the
# globals at '?' / 0 rather than aborting — a report that cannot read a tasklist must
# degrade, never take a run down.
terminal_counts() {
  local out
  # '?' — not 0 — for the three that are COUNTS OF STORIES: a tasklist chief could not
  # read has an UNKNOWN number of passes, and rendering that as zero is a report
  # claiming a fact it does not have. TERMINAL_NEGATIVE is the exception and is 0,
  # because "chief did not find a declared negative here" is true either way.
  TERMINAL_TOTAL='?'; TERMINAL_PASSED='?'; TERMINAL_NEGATIVE=0; TERMINAL_OPEN='?'
  out="$(jq -r "$(_terminal_prog '
    [ (.userStories // [])[] ] as $s
    | [ ($s|length),
        ([ $s[] | select(.passes == true) ] | length),
        ([ $s[] | select(negative) ] | length),
        ([ $s[] | select(settled | not) ] | length) ]
    | @tsv')" "$1" 2>/dev/null)" || return 0
  [ -n "$out" ] || return 0
  IFS=$'\t' read -r TERMINAL_TOTAL TERMINAL_PASSED TERMINAL_NEGATIVE TERMINAL_OPEN <<< "$out"
  return 0
}

# terminal_open PRD — the count of stories still OPEN. This is the number that used to
# be `[.userStories[]|select(.passes==false)]|length` at every completion site.
terminal_open() {
  jq "$(_terminal_prog '[ (.userStories // [])[] | select(settled | not) ] | length')" \
    "$1" 2>/dev/null || echo '?'
}

# terminal_next PRD — the id of the highest-priority OPEN story ('' when none are left).
# The story the agent is handed. A settled negative is skipped here, which is what stops
# `283`'s re-drive: the loop asks for work and is told there is none.
terminal_next() {
  jq -r "$(_terminal_prog '[ (.userStories // [])[] | select(settled | not) ][0].id // empty')" \
    "$1" 2>/dev/null || echo ""
}

# terminal_settled_ids PRD — the ids of every settled story, space-joined.
terminal_settled_ids() {
  jq -r "$(_terminal_prog '[ (.userStories // [])[] | select(settled) | .id ] | join(" ")')" \
    "$1" 2>/dev/null || echo ""
}

# terminal_negative_ids PRD — the ids of the stories that settled NEGATIVE.
terminal_negative_ids() {
  jq -r "$(_terminal_prog '[ (.userStories // [])[] | select(negative) | .id ] | join(" ")')" \
    "$1" 2>/dev/null || echo ""
}

# terminal_negative_report PRD — one block per settled-negative story: the id, the
# title, the word NO, and the finding verbatim (clipped). Empty when there are none.
#
# The FINDING is the point. A story that terminates false usually names the thing to do
# instead, and that closing action is the most valuable output of the whole tasklist —
# so every surface that reports one reports the notes with it, never just a count.
terminal_negative_report() {
  jq -r "$(_terminal_prog '
    def clip: if (. | length) > 300 then .[0:297] + "..." else . end;
    (.userStories // [])[]
    | select(negative)
    | "   ⊘ \(.id // "?") — \(.title // "(untitled)")\n"
      + "       answered: NO — terminal, declared by `terminalFalse`\n"
      + "       finding: \(((.notes // "") | tostring | clip))"')" "$1" 2>/dev/null
}

# terminal_done_list PRD — the "ALREADY DONE" roster the agent's prompt carries: one
# "  - <id> — <title>" line per SETTLED story, and the ones that settled negative say
# so. Lives here, not in the prompt builder, because it is the settled predicate again
# and there is one of those.
terminal_done_list() {
  jq -r "$(_terminal_prog '
    [ (.userStories // [])[] | select(settled) ]
    | map("  - \(.id) — \(.title // "untitled")"
          + (if negative then " — answered NO (terminal, measured)" else "" end))
    | join("\n")')" "$1" 2>/dev/null
}

# terminal_inert_report PRD — one block per story that DECLARED the negative terminal
# and recorded nothing. These are open, not done. Reported separately from the report
# above on purpose: "we measured and the answer is no" and "we never measured" must not
# read the same, or the field becomes a way to bury work.
terminal_inert_report() {
  jq -r "$(_terminal_prog '
    def clip: if (. | length) > 200 then .[0:197] + "..." else . end;
    (.userStories // [])[]
    | select(inert)
    | "   ○ \(.id // "?") — \(.title // "(untitled)")\n"
      + "       declares `terminalFalse` but records NO measurement — still open, not done\n"
      + "       recorded: "
      + (((.notes // "") | tostring) as $n
         | if ($n | test("\\S")) then "\"\($n | clip)\" — no observed value in it" else "(nothing)" end)')" \
    "$1" 2>/dev/null
}

# THE TWO THINGS A RUN SAYS ABOUT A DECLARED NEGATIVE (engine/terminal.sh), lifted out
# of run_worker because they are reports, not scheduling — and they live HERE, beside
# the predicate they report on, exactly as engine/measure.sh keeps unverified_stop
# beside its gate. Both read the caller's $name/$live-style scope the same way that
# module does, and terminal_say_negative calls the driver's event_emit by dynamic
# scope; neither is reachable from a reader that has no run behind it.
#
# terminal_say_inert — a story that declared `terminalFalse` and recorded NO
# measurement. It is OPEN, so the INCOMPLETE arm was always going to catch it; what it
# would have SAID is "the iteration budget ran out", which sends an operator to raise
# `iters` when the fix is to take the measurement. Prints the report and returns 0 when
# there was one to print, so the caller can substitute its own reason for the park.
terminal_say_inert() {
  local prd="$1" nm="$2" rep
  rep="$(terminal_inert_report "$prd")"
  [ -n "$rep" ] || return 1
  echo "!! $nm: a declared terminal-false story recorded NO measurement — declaring the negative does not settle it:"
  printf '%s\n' "$rep"
  return 0
}

# terminal_say_negative — every story is settled and some settled NEGATIVE. Said at the
# moment the tasklist is declared finished, because this is the log line that answers
# "what did it actually find": the report carries the finding verbatim, and the finding
# is usually the most valuable thing the tasklist produced.
terminal_say_negative() {
  local prd="$1" nm="$2" k="$3" t="$4" pl
  [ "$(_int "$k")" != "0" ] || return 0
  pl="$([ "$k" = 1 ] && echo y || echo ies)"
  echo ">> $nm: $k of $t stor$pl terminated with a NEGATIVE answer — declared terminal, measured, and DONE:"
  terminal_negative_report "$prd"
  event_emit tasklist.terminal-negative name="$nm" state=running \
    detail="$k stor$pl settled false: $(terminal_negative_ids "$prd")"
}

# The passes-state to seed the runtime prd.json from (and to count remaining
# stories on a resume). For a project tasklist it's the branch's committed tasklist
# (survives across resumes in-repo). A submodule branch carries no tasklist JSON, so
# fall back to the last snapshot, then the pristine template. $name/$branch/$sub/
# $work_repo/$TASKS_REL/$SNAP/$SRC are visible by dynamic scope.
#
# WHY THE SUBMODULE ARM IS THE ONE THAT NEEDED FIXING (tasklist 96). A project
# tasklist records every story as it lands: the agent commits the tracked tasklist
# with its pass-flag flipped, so the branch itself carries 2-of-3 and a run killed
# mid-tasklist resumes at exactly that. A submodule branch cannot — the tasklist
# lives in the PARENT and the work branch lives in the submodule, and the parent
# gets ONE commit for the whole tasklist (the terminal `complete @sha — bump <sub>
# + record + retire`). There is no per-story marker in between, so the snapshot IS
# the record, and it used to be written only at the END of a worker. A run killed
# mid-tasklist therefore resumed at 0-of-3 onto a branch already carrying the code
# for two of them — wasting iterations at best, and at worst re-implementing a
# story, which leaves TWO implementations of one story on one branch.
#
# THE MECHANISM CHOSEN, and its trade-off. The snapshot is promoted at every
# ITERATION BOUNDARY instead of once at the end (agent.sh's $CHIEF_PRD_SNAPSHOT,
# handed down below — the same "driver owns the durable path, agent promotes to it
# the moment the artifact is valid" shape as $CHIEF_RESEARCH_FILE). It lives under
# $STATE_ROOT, NOT in the worktree run_worker rm -rf's, so it survives both a
# rebuilt worktree and a driver restart — which is the failure being fixed.
#   · vs. a MARKER COMMIT on the submodule branch: that branch is merged verbatim
#     into the submodule's own history, so per-story bookkeeping commits would be
#     chief litter in a consumer's repo forever.
#   · vs. a PARENT-SIDE BRANCH: the parent deliberately has no chief/* branches at
#     all, and inventing one changes the terminal record's shape — the very thing
#     downstream readers of completed/ depend on not moving.
#   · the COST accepted: the snapshot is host state, not git. Deleting
#     .chief/state/ still loses the per-story record (RESET=1's behaviour, on
#     purpose), and the branch's commits remain the ground truth either way.
# Nothing here changes a PROJECT tasklist: this arm is not reached for one, so its
# resume still reads the committed tasklist and a fresher snapshot is inert.
prd_state_source() {
  if [ -z "${sub:-}" ]; then
    git -C "${work_repo:-$REPO}" show "$branch:$TASKS_REL/$name.json" 2>/dev/null
  elif [ -f "$SNAP/$name.json" ]; then
    cat "$SNAP/$name.json"
  else
    cat "$SRC/$name.json"
  fi
}

# prd_state_open — how many stories that state still leaves OPEN.
#
# OPEN, not `passes==false`: a story that declared the negative terminal and recorded
# the measurement behind it is SETTLED, and a resume that counted it as work left would
# put an agent back on a question that already has its answer. Here rather than in the
# driver because both halves are here: the state to read is prd_state_source's, the
# predicate that reads it is terminal_open's. Via a file because terminal_open takes a
# path, not a stream — everything the settled predicate does is one jq over a document.
prd_state_open() {
  local f="$STATE/.$name.state-src" out
  prd_state_source > "$f" 2>/dev/null
  out="$(terminal_open "$f")"
  rm -f "$f" 2>/dev/null || true
  printf '%s' "$out"
}


# terminal_live_counts LIVE PRD [KEY=VALUE …] — count PRD and publish the three
# progress numbers to the liveliness record in one step, with any extra fields the
# caller wants merged in the same write.
#
# ONE WRITER, so the seeding write and the boundary write cannot disagree about what
# `passing` means. They did: seeding published the passed count while the boundary
# published total-minus-open, which is passed PLUS the delivered negatives — the very
# collapse the third field exists to prevent, visible only on a tasklist that declares
# one. `passing` is TERMINAL_PASSED at both, `negative` is its own number at both.
terminal_live_counts() {
  local live="$1" prd="$2"; shift 2
  terminal_counts "$prd"
  live_set "$live" passing="$(_int "$TERMINAL_PASSED")" \
    negative="$(_int "$TERMINAL_NEGATIVE")" total="$(_int "$TERMINAL_TOTAL")" "$@"
}

