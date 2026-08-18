#!/bin/bash
# Chief Wiggum - Long-running AI agent loop
# Usage: ./agent.sh [--provider claude|devin|opencode|amp] [--model MODEL] [max_iterations]
#
# EXIT CODES — engine/driver.sh keys off these; keep them stable.
#   0  the PRD completed: the agent emitted <promise>COMPLETE</promise>.
#   1  GENUINE FAILURE — the loop gave up without completing: it stalled
#      (STALL_LIMIT no-progress iterations past the budget) or hit HARD_MAX.
#      Also used for bad invocation (unknown --tool). The work is NOT known to
#      be resumable; the driver treats this as a failed tasklist.
#   2  STOPPED ON A CLAUDE USAGE/SESSION LIMIT and will not retry (either
#      RATE_LIMIT_RETRY=0 or RATE_LIMIT_MAX_WAITS exhausted). This is NOT a
#      failure: nothing is wrong with the branch, it is simply blocked until the
#      limit window resets, and re-running it resumes from its passes state.
#      The driver must keep this distinct from 1 so a limit never counts as a
#      failed tasklist and never blocks dependents.
#   3  DRAINED ON AN OPERATOR PAUSE — a human armed $CHIEF_PAUSE_FILE (`chief
#      pause`) and this loop stopped starting new iterations. Like 2 it is NOT a
#      failure and NOT a stall: every commit the last iteration made is on the
#      branch, and `chief resume` continues from the committed passes state. The
#      check happens ONLY at an iteration boundary (see OPERATOR PAUSE below).
#   4  THE PLAN PHASE COULD NOT PRODUCE A WELL-FORMED PLAN — this tasklist has
#      plan review enabled ("review":"plan") and the PLAN turn either wrote no
#      artifact or wrote one that fails the schema check. Like 2 and 3 this is NOT
#      a stall and NOT a merge-blocking code failure: it is an ACTIONABLE stop with
#      the branch untouched. It exists so a bad plan can never fall through into
#      code — the one outcome plan review is there to prevent (see PLAN PHASE below
#      and docs/plan-review.md).
#   5  AWAITING REVIEW — a well-formed plan exists but NO HUMAN HAS APPROVED IT, and
#      no approval can be obtained here: the reviewer is not installed, the host is
#      non-interactive, the review window elapsed, or the annotate -> re-plan budget
#      is spent. Like 2 and 3 this is a PARK, not a failure — the branch, the plan
#      and every annotation are kept, and re-running resumes with the verdict already
#      on disk (a given approval is never asked for twice). It is the one thing the
#      gate must do instead of proceeding: an unreachable reviewer is not an
#      approval (see engine/review.sh and docs/plan-review.md).
#   6  THE RESEARCH PHASE FAILED — the tasklist asked for an up-front research
#      document (engine/research.sh) and the bounded attempts budget ran out
#      without producing one that carries every required section. Distinct from 1
#      on purpose: NOTHING was implemented, so this is not a stall and not a
#      partially-built branch — it is "the map could not be drawn", and the fix is
#      to write/repair $CHIEF_RESEARCH_FILE by hand or turn research off. The one
#      thing this must never be is a silent fall-through into implementation on a
#      map that isn't there. Numbered AFTER the plan codes because research runs
#      BEFORE them: the phase order is research -> plan -> implement, and the two
#      phases compose without either requiring the other (see RESEARCH PHASE below
#      and engine/research.sh).
#   7  UNVERIFIED IN-RUN — the SAME story was demoted at the ITERATION BOUNDARY
#      (engine/measure.sh via _measure_boundary below) for MEASURE_DEMOTE_LIMIT
#      consecutive iterations: it claims a measurable bar, the boundary named it
#      and quoted that bar in the turn's own prompt, and the turn re-marked it
#      with the value still absent. Stopping is the point — chief cannot produce
#      that number, so every further turn is the loop re-marking one story.
#      Distinct from 1 because it is NOT a stall: commits may well be landing.
#      Distinct from 2/3/4/5/6 because the branch is NOT untouched — it may carry
#      real work, and it is kept, along with its worktree. The driver reports the
#      same UNVERIFIED status, in the same words, that the merge floor would have
#      reported hours later; re-running resumes once the value is in `notes`.
# A usage limit is detected BEFORE the progress/stall accounting (see
# _is_rate_limit below), so a limit-blocked turn can never be misread as a
# no-progress iteration that trips STALL_LIMIT and exits 1.

set -e

# Parse arguments
PROVIDER="${CHIEF_PROVIDER:-${CHIEF_TOOL:-claude}}"
MODEL="${CHIEF_MODEL:-}"
# What the caller actually ASKED for, as opposed to the default above — a preset
# resolves the provider itself, and only an EXPLICIT provider can conflict with it.
PROVIDER_EXPLICIT="${CHIEF_PROVIDER:-${CHIEF_TOOL:-}}"
TOOL="$PROVIDER"                         # compatibility name in status output
MAX_ITERATIONS=10

while [[ $# -gt 0 ]]; do
  case $1 in
    --provider)
      PROVIDER="$2"; PROVIDER_EXPLICIT="$2"
      shift 2
      ;;
    --provider=*)
      PROVIDER="${1#*=}"; PROVIDER_EXPLICIT="${1#*=}"
      shift
      ;;
    --model)
      MODEL="$2"
      shift 2
      ;;
    --model=*)
      MODEL="${1#*=}"
      shift
      ;;
    --tool)
      PROVIDER="$2"; PROVIDER_EXPLICIT="$2"
      TOOL="$2"
      shift 2
      ;;
    --tool=*)
      PROVIDER="${1#*=}"; PROVIDER_EXPLICIT="${1#*=}"
      TOOL="${1#*=}"
      shift
      ;;
    --chief-run=*)
      # The driver's RUN MARKER (engine/reap.sh). Consumed for nothing — its whole
      # job is to sit in this process's argv, where `ps`/`pgrep` can attribute the
      # frame (and the `claude` beneath it) to its repo and run. Without it, an
      # agent loop orphaned by a killed driver is unidentifiable: nothing else on
      # this command line says which repo it is spending quota for.
      shift
      ;;
    *)
      # Assume it's max_iterations if it's a number
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      fi
      shift
      ;;
  esac
done

ENGINE="${CHIEF_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# PRESET — a named bundle (engine/preset.sh) that resolves to provider·model plus
# whatever backend env that provider needs, BEFORE validation, so everything below
# only ever sees a plain resolved provider. Idempotent: bin/chief usually resolves
# it already and re-resolving the same pair here is a no-op, which keeps a direct
# `agent.sh` invocation (a host embedding chief, the offline tests) honest too.
# An unknown or unconfigured preset is a bad invocation — exit 1, never a silent
# fall-through to the default (paid) provider.
if [ -n "${CHIEF_PRESET:-}" ]; then
  # shellcheck disable=SC1091
  source "$ENGINE/preset.sh"
  CHIEF_PROVIDER="$PROVIDER_EXPLICIT"; CHIEF_MODEL="$MODEL"
  chief_preset_resolve || exit 1
  PROVIDER="$CHIEF_PROVIDER"; MODEL="$CHIEF_MODEL"; TOOL="$PROVIDER"
fi

# Validate provider choice
if [[ "$PROVIDER" != "claude" && "$PROVIDER" != "devin" && "$PROVIDER" != "opencode" && "$PROVIDER" != "amp" ]]; then
  echo "Error: Invalid provider '$PROVIDER'. Must be 'claude', 'devin', 'opencode', or 'amp'."
  exit 1
fi

# amp has no model selector (docs/guides/providers.md#model-overrides). `chief run` refuses
# an explicit --model for it; when agent.sh is driven directly, say so ONCE here and
# drop the value — accept-and-ignore would let the banner, the liveliness record and
# the verbose trace all advertise a model the CLI never receives.
if [ "$PROVIDER" = amp ] && [ -n "$MODEL" ]; then
  echo "note: amp has no model selector — ignoring model '$MODEL' (docs/guides/providers.md#model-overrides)" >&2
  MODEL=""
fi
# ACCOUNT DESIGNATION — the run may be pinned to a specific provider account via a
# credential env FILE (bin/chief --account-env / CHIEF_ACCOUNT_ENV_FILE). Only the
# PATH travels in the environment; the values are read at the provider boundary
# (_apply_account_env below). Checked here, at launch, because the alternative to a
# loud failure is spending an operator's OTHER account's quota by accident: a
# designation that cannot be read is never allowed to degrade into "inherit whatever
# this shell happens to carry".
if [ -n "${CHIEF_ACCOUNT_ENV_FILE:-}" ]; then
  if [ ! -f "$CHIEF_ACCOUNT_ENV_FILE" ] || [ ! -r "$CHIEF_ACCOUNT_ENV_FILE" ]; then
    echo "Error: account env file not readable: $CHIEF_ACCOUNT_ENV_FILE" >&2
    echo "       (chief run --account-env <file> / CHIEF_ACCOUNT_ENV_FILE — no fallback to the inherited account)" >&2
    exit 1
  fi
fi
: "${CHIEF_PROJECT:?CHIEF_PROJECT must be set — run this via the driver, not directly}"
STATE_DIR="$CHIEF_PROJECT/${CHIEF_STATE_DIR:-.chief/state}"
mkdir -p "$STATE_DIR"
PRD_FILE="$STATE_DIR/prd.json"
PROGRESS_FILE="$STATE_DIR/progress.txt"
ARCHIVE_DIR="$STATE_DIR/archive"
LAST_BRANCH_FILE="$STATE_DIR/.last-branch"
# Written ONLY on an exit-2 stop: the unix epoch at which the limit window is
# expected to reopen, parsed from the real limit message by _seconds_until_reset.
# engine/driver.sh reads it to schedule a reset-aware re-dispatch, so the worker
# and the scheduler agree on the ETA instead of parsing the message twice.
LIMIT_RETRY_FILE="$STATE_DIR/.limit-retry-at"
rm -f "$LIMIT_RETRY_FILE"
# THE RESEARCH DOCUMENT, in its two locations — declared HERE rather than beside the
# RESEARCH PHASE below because _compose_prompt (next) reads it, and every story turn
# is composed through that one function.
#   RESEARCH_DOC    the copy inside the WORKTREE. What the research turn writes and
#                   what validation reads. Disposable: the driver deletes and rebuilds
#                   the worktree on every run.
#   RESEARCH_STORE  the DURABLE path the driver hands down ($CHIEF_RESEARCH_FILE,
#                   .chief/state/research/<name>.md in the project). Survives the
#                   worktree, survives process death — and is the file A HUMAN OPENS
#                   AND EDITS between iterations. The store is the source of truth:
#                   _research_refresh copies it DOWN at the top of every iteration, so
#                   a correction made by hand is what the next story reads. That is
#                   the leverage the whole phase is for — correcting the map has to be
#                   cheaper than correcting the code it would otherwise produce.
RESEARCH_DOC="$STATE_DIR/research.md"
RESEARCH_STORE="${CHIEF_RESEARCH_FILE:-}"
# THE BOUNDARY DEMOTION NOTICE — what `_measure_boundary` (below) demoted, in the
# words `engine/measure.sh` already prints at merge, held on disk so the NEXT turn's
# prompt can carry it.
#
# A demotion the agent is not TOLD about reads to it as its own edit failing to save,
# and the only thing it can conclude is to make the same edit again. Naming the story
# and quoting the bar is the whole difference between "chief undid my work" and "chief
# is asking for the number I already have". It is deliberately NOT generic advice —
# `instructions.md` step 8 is generic advice, it is in the prompt on every single turn,
# and the four runs of 2026-08-17 that this tasklist exists for all received it.
#
# Written by the boundary check and cleared by it (a boundary that demotes nothing has
# nothing outstanding to say). Removed at startup because $STATE_DIR outlives the
# process on an in-place run, and last run's demotion is not this run's news.
DEMOTION_FILE="$STATE_DIR/.demoted.md"
rm -f "$DEMOTION_FILE"
# The repeat accounting behind MEASURE_DEMOTE_LIMIT (above). In-process only, and
# deliberately so: a resumed run starts from `rm -f "$DEMOTION_FILE"` with no notice
# outstanding, so it must also start with no repeat held against the agent it has not
# yet spoken to. DEMOTE_KEY is the REASON — the sorted ids the last boundary demoted.
DEMOTE_KEY=""
DEMOTE_REPEATS=0
# _compose_prompt INSTRUCTIONS DEST — the prompt one turn is handed: the engine's
# loop instructions followed by the project's own context. A turn picks its
# INSTRUCTIONS (implement, or the PLAN turn below) and everything downstream of that
# choice must stay identical — a plan written against different project conventions
# than the code it becomes is worse than no plan at all.
#
# The RESEARCH DOCUMENT goes in next-to-last, when there is one, and the BOUNDARY
# DEMOTION NOTICE (above) after it — everything else in the prompt is standing context,
# and that notice is the one part of it about the turn being composed right now.
#
# The research document goes in after the project context, ordered by specificity —
# engine loop, then project conventions, then the map of the code THIS tasklist is
# about to change. Injected here rather than at each call site so the implement turn
# and the PLAN turn cannot end up with different maps;
# a plan reasoned from a map the implementation never saw is the same class of bug as
# a plan written against different project conventions.
#
# The guard is deliberately a capability check, not a flag: no research.sh in this
# install (or no valid document yet, which is the case for the very first compose
# above the research phase) simply means no research section, and the prompt is
# byte-for-byte what it has always been.
_compose_prompt() {
  local src="$1" dest="$2" ctx="${CHIEF_AGENT_CONTEXT:-}"
  {
    cat "$src"
    if [ -n "$ctx" ] && [ -f "$CHIEF_PROJECT/$ctx" ]; then
      printf '\n\n---\n\n# Project-specific instructions (%s)\n\n' "$ctx"
      cat "$CHIEF_PROJECT/$ctx"
    fi
    if command -v research_validate >/dev/null 2>&1 && research_validate "$RESEARCH_DOC"; then
      printf '\n\n---\n\n# Research — the validated map of this codebase for THIS tasklist\n\n'
      printf 'This was produced ONCE, up front, by a research turn that read the code (and\n'
      printf 'may since have been corrected by a human). It is here so you do NOT have to\n'
      printf 'rediscover the codebase: start from this map instead of re-deriving it, and\n'
      printf 'spend your context on the change.\n\n'
      printf 'Trust it as a starting point, not as scripture. If you find it WRONG while\n'
      printf 'implementing, say so in your progress note — a wrong map costs every\n'
      printf 'remaining story, and it is corrected by editing `%s`\n' \
        "${CHIEF_STATE_DIR:-.chief/state}/research.md"
      printf 'in the project (a human does this between iterations; your edit inside the\n'
      printf 'worktree does not persist). Do not rewrite it as part of a story.\n\n'
      printf -- '---\n\n'
      cat "$RESEARCH_DOC"
    fi
    # THE DEMOTION NOTICE goes LAST — after the map, after the conventions, at the end
    # of the prompt, because it is the only part of it that is about THIS turn. Injected
    # here rather than appended to $PROMPT_FILE by the caller so it cannot be lost: the
    # implement prompt is rebuilt from scratch by _research_refresh at the top of every
    # iteration, and the PLAN turn composes its own file — one call site, three prompts.
    if [ -s "$DEMOTION_FILE" ]; then
      printf '\n\n---\n\n# STOP — chief DEMOTED a story you marked. It is back at `passes: false`.\n\n'
      printf 'This is not your edit failing to save, and re-marking it is not the fix.\n\n'
      printf 'At the end of the last iteration chief held every story reading `passes: true`\n'
      printf 'to the bars its OWN acceptance criteria state. The story below claims a bar and\n'
      printf 'its `notes` recorded no observed value, so chief set `passes: false` and\n'
      printf '`unverified: true` on it, verbatim as it will be reported at merge time:\n\n'
      cat "$DEMOTION_FILE"
      printf '\nChief cannot evaluate that bar itself — which is why it will not record it as\n'
      printf 'met, and why nothing but your own observation clears this. DO IT FIRST, before\n'
      printf 'any other work this turn:\n\n'
      printf '  1. Put the value you OBSERVED — the number, the exit status, the word "green" —\n'
      printf "     into that story's \`notes\` in \`%s/prd.json\`\n" "${CHIEF_STATE_DIR:-.chief/state}"
      printf '     (and in the tracked tasklist, if that file is in your worktree).\n'
      printf '  2. Set its `passes` back to `true` in the same edit.\n'
      printf '  3. If the output is no longer in your context, RE-RUN the check and record\n'
      printf '     what it actually printed. Do not reconstruct it from memory.\n\n'
      printf 'Do NOT mark it again without the value. The same check runs at the end of THIS\n'
      printf 'iteration and will demote it again.\n'
    fi
  } > "$dest"
}

# _research_refresh — re-seed the worktree's research document FROM THE DURABLE STORE
# and rebuild the implement prompt around it.
#
# Called at the top of every iteration, and that timing is the whole point of AC-2: a
# human who opens $RESEARCH_STORE between iterations and fixes the map has their
# correction picked up by the NEXT story, with no re-run and no research turn. Compose
# once at startup and the tasklist would be stuck with the first map it drew.
#
# The plan turn inherits it for free — _plan_prompt composes through _compose_prompt
# later in the same iteration, so plan and implement always reason from one map.
# A HARD no-op when research is off, and that guard is the point: $CHIEF_RESEARCH=0
# has to mean "no research this run" even when a document from a previous run is still
# sitting in the store. Off is off — otherwise the override that exists to skip the
# phase would still be paying its context cost.
_research_refresh() {
  [ "${RESEARCH_ON:-0}" = "1" ] || return 0
  if [ -n "$RESEARCH_STORE" ] && [ -f "$RESEARCH_STORE" ]; then
    cp "$RESEARCH_STORE" "$RESEARCH_DOC" 2>/dev/null || true
  fi
  _compose_prompt "$ENGINE/instructions.md" "$PROMPT_FILE"
}
PROMPT_FILE="$STATE_DIR/.prompt.md"
_compose_prompt "$ENGINE/instructions.md" "$PROMPT_FILE"
# The prompt the CURRENT turn is running with — the implement prompt above, or the
# PLAN turn's (see PLAN PHASE below). Providers read it two different ways (stdin for
# claude/opencode, --prompt-file for devin), so it has to be one variable both paths
# use, or the plan turn would hand devin the implement prompt.
ACTIVE_PROMPT="$PROMPT_FILE"

# Archive previous run if branch changed
if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")
  
  if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
    # Archive the previous run
    DATE=$(date +%Y-%m-%d)
    # Strip "chief/" prefix from branch name for folder
    FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|^chief/||')
    ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"
    
    echo "Archiving previous run: $LAST_BRANCH"
    mkdir -p "$ARCHIVE_FOLDER"
    [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
    [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
    echo "   Archived to: $ARCHIVE_FOLDER"
    
    # Reset progress file for new run
    echo "# Chief Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
  fi
fi

# Track current branch
if [ -f "$PRD_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  if [ -n "$CURRENT_BRANCH" ]; then
    echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
  fi
fi

# Initialize progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Chief Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

# --- Adaptive iteration control + session-limit recovery ---------------------
# MAX_ITERATIONS is a SOFT budget, not a hard wall. As long as each iteration
# makes forward progress (a story flips to passes:true, OR a new commit lands),
# Chief keeps going past the budget — up to HARD_MAX — so a PRD that just needs
# a few more turns isn't cut off mid-flight. It gives up only once it has spent
# the budget AND stalled (no progress) for STALL_LIMIT consecutive iterations,
# or reaches the HARD_MAX safety ceiling.
STALL_LIMIT="${STALL_LIMIT:-2}"
# THE SAME IDEA FOR THE BAR CHECK AT THE BOUNDARY. STALL_LIMIT bounds a loop that
# is achieving NOTHING; MEASURE_DEMOTE_LIMIT bounds a loop that is achieving the
# SAME THING over and over — a story demoted for an unrecorded measurement, then
# re-marked with the measurement still missing. Stall accounting cannot see that
# one: the turn commits, HEAD moves, and the loop reads it as progress every time,
# so it runs to HARD_MAX rediscovering the same demotion.
# Counted CONSECUTIVELY and PER REASON (the set of story ids the boundary demoted),
# so an agent that records the value for one story and then trips over the next is
# never counted as repeating itself. 2 = one demotion, one turn told about it by
# name and by bar, and then stop — a third turn has nothing new to learn.
MEASURE_DEMOTE_LIMIT="${MEASURE_DEMOTE_LIMIT:-2}"
HARD_MAX="${HARD_MAX:-$(( MAX_ITERATIONS*3 > 20 ? MAX_ITERATIONS*3 : 20 ))}"

# On a Claude session/usage limit, sleep until it resets and RESUME the same
# story instead of aborting the run.
#   RATE_LIMIT_RETRY=0     restore the old stop-on-limit behavior
#   RATE_LIMIT_WAIT=<sec>  fallback sleep when a reset time can't be parsed (1h)
#   RATE_LIMIT_MAX_WAITS   cap on how many times we'll wait, per PRD run
#   RATE_LIMIT_PATTERN     regex that identifies a limit message (tune if needed)
#   RATE_LIMIT_STATUS_PATTERN  weaker regex that only counts as a limit when the
#                          CLI ALSO exited non-zero (structured/terse errors)
#
# DETECTION IS THE WHOLE BALLGAME. A limit that the pattern misses is silently
# demoted to a "no progress" iteration, so the loop burns its budget and exits 1
# (stall) — indistinguishable, to the driver, from a genuinely failed tasklist.
# The default therefore covers every phrasing the Claude Code CLI is known to
# emit, not just the one-liner the first version was written against:
#   "Claude AI usage limit reached|1795000000"      (--print, epoch suffix)
#   "Claude usage limit reached. Your limit will reset at 3pm (America/Chicago)."
#   "5-hour limit reached ∙ resets 3pm"             (missed by the old pattern)
#   "Weekly limit reached · resets Nov 5 at 9am"    (missed by the old pattern)
#   "You've reached your usage limit"
#   API Error: 429 {"type":"error","error":{"type":"rate_limit_error",…}}
# Deliberately NOT matched: the per-model fallback notice ("Opus limit reached —
# now using Sonnet"), which is not a stop — the turn continues and does work.
RATE_LIMIT_RETRY="${RATE_LIMIT_RETRY:-1}"
RATE_LIMIT_WAIT="${RATE_LIMIT_WAIT:-3600}"
RATE_LIMIT_MAX_WAITS="${RATE_LIMIT_MAX_WAITS:-8}"
RATE_LIMIT_PATTERN="${RATE_LIMIT_PATTERN:-(usage limit reached|session limit reached|((5|five)[ -]hour|weekly|daily|monthly|hourly|plan|account|output|token)[ -]limit reached|(hit|reached|exceeded) (your|the) ([a-z0-9-]+ )?(session|usage|rate|weekly|daily|monthly|plan|output|token) limit|(your|the) limit will reset (at|in)|rate limit exceeded|rate_limit_error|too many requests|upgrade to increase your usage limit)}"
RATE_LIMIT_STATUS_PATTERN="${RATE_LIMIT_STATUS_PATTERN:-(429|rate[_ -]?limit|usage limit|session limit|overloaded_error)}"

# --- OPERATOR PAUSE (the drain checkpoint; see engine/driver.sh's header) -----
# The driver hands us the path of its operator-pause flag ($STATE/.paused, armed by
# `chief pause`). Unset — a standalone agent run — makes this a no-op, exactly like
# the liveliness record.
#
# CHECKPOINT PLACEMENT IS THE WHOLE CORRECTNESS STORY. It is consulted at ONE point:
# the top of the loop, i.e. strictly BETWEEN iterations. A turn already in flight
# always runs to completion, so a pause never discards work the agent did; and
# everything a pause must never interrupt (the driver's commit→rebase→verify→merge
# phase) is downstream of this loop exiting, so it is not even reachable from here.
#
# PRESENCE is the gate, never a parsed value: a human's hold must survive a
# truncated flag file. Same idiom as driver.sh's op_paused().
PAUSE_FILE="${CHIEF_PAUSE_FILE:-}"
_op_paused() { [ -n "$PAUSE_FILE" ] && [ -f "$PAUSE_FILE" ]; }

REPO="$CHIEF_PROJECT"
_passes() { jq '[.userStories[]? | select(.passes==true)] | length' "$PRD_FILE" 2>/dev/null || echo 0; }
_total()  { jq '.userStories | length' "$PRD_FILE" 2>/dev/null || echo '?'; }
_head()   { git -C "$REPO" rev-parse HEAD 2>/dev/null || echo none; }
_story()  { jq -r '[.userStories[]? | select(.passes==false)][0].id // empty' "$PRD_FILE" 2>/dev/null || echo ""; }
# The SET behind _passes()' count. The progress check below already re-reads the
# count each iteration; reading the ids alongside it is what lets the event stream
# name WHICH story passed instead of just that one more did.
_passed_ids() { jq -r '[.userStories[]? | select(.passes==true) | .id] | join(" ")' "$PRD_FILE" 2>/dev/null || echo ""; }

# --- PLAN PHASE (docs/plan-review.md) -----------------------------------------
# OPT-IN, and off by default. A tasklist that sets "review":"plan" gets one extra
# turn per story BEFORE any edit: the agent writes a structured plan artifact and
# nothing else. The leverage argument is the whole point — a misread requirement
# caught in a ten-line plan is a misread requirement that never became three hundred
# lines of code — but it only holds if the plan phase can never be skipped silently
# and can never fall through into implementation half-formed. Hence:
#
#   • ENABLEMENT is read from the runtime PRD (`.review`), so it travels with the
#     tasklist and shows up in a reviewable diff. $CHIEF_REVIEW overrides it for a
#     host embedding chief. Anything other than "plan" is off.
#   • THE ARTIFACT IS A FILE, not a message. It lands under $STATE_DIR/plans/ — the
#     same filesystem-resumable state everything else in chief lives in — so process
#     death, a usage-limit stop and an operator pause all leave it intact and the
#     next turn (or the next RUN) reads the plan already written instead of paying
#     for it twice. The driver mirrors the directory into its snapshots so it also
#     survives the worktree being rebuilt.
#   • WELL-FORMEDNESS IS CHECKED HERE, by schema, not by trusting the turn's prose.
#     A plan that fails the check stops the loop with exit 4 and a PLAN-INVALID
#     state. It is deliberately NOT retried in place: the bounded contract is one
#     plan turn per story, and a loop that re-asks for a plan until it parses is
#     exactly the unbounded spend the budget exists to prevent.
#   • AND A PLAN IS NOT A PERMISSION. US-1 stopped here; the checkpoint is only worth
#     its iteration if a HUMAN sees the plan, so engine/review.sh gates implementation
#     on an approval from plannotator's documented annotate gate. An unreachable
#     reviewer parks the tasklist (exit 5) — it never counts as a yes.
PLAN_DIR="$STATE_DIR/plans"
PLAN_PROMPT_FILE="$STATE_DIR/.plan-prompt.md"
REVIEW_MODE="${CHIEF_REVIEW:-$(jq -r '.review // "none"' "$PRD_FILE" 2>/dev/null || echo none)}"
case "$REVIEW_MODE" in plan) ;; *) REVIEW_MODE=none ;; esac

# _plan_valid FILE STORY — does the artifact satisfy the documented schema?
# Silent (the caller reports); returns non-zero for a missing file, unparseable
# JSON, or any missing/empty required field. `and` short-circuits in jq, so the
# type guards ahead of each `all(...)` keep a null field from raising.
_plan_valid() {
  local f="${1:-}" id="${2:-}"
  [ -s "$f" ] || return 1
  command -v jq >/dev/null 2>&1 || return 0   # no jq: cannot check, do not block
  jq -e --arg id "$id" '
    def nes: (type == "string") and (length > 0);
    (.story == $id)
    and (.summary | nes)
    and (.changes | type == "array") and ((.changes | length) > 0)
    and (all(.changes[];
          (.path | nes) and (.change | nes)
          and (.action == "create" or .action == "modify" or .action == "delete")))
    and (.verification | type == "array") and ((.verification | length) > 0)
    and (all(.verification[]; (.phase | nes) and (.command | nes)))
  ' "$f" >/dev/null 2>&1
}

# _plan_prompt STORY PLAN_FILE — compose the PLAN turn's prompt. Same engine+project
# stack as the implement turn, plus a concrete `## This turn` footer naming the story
# the plan must declare and the exact path to write it to. Both are computed by the
# caller (they depend on $CHIEF_STATE_DIR), and an agent left to guess either produces
# an artifact the check above cannot find.
_plan_prompt() {
  local id="$1" rel="${2#"$CHIEF_PROJECT"/}" fb
  mkdir -p "$PLAN_DIR" 2>/dev/null || true
  _compose_prompt "$ENGINE/plan-instructions.md" "$PLAN_PROMPT_FILE"
  {
    printf '\n\n---\n\n## This turn\n\n'
    printf -- '- Story to plan: **%s** — `%s`\n' "$id" \
      "$(jq -r --arg id "$id" '[.userStories[]?|select(.id==$id)][0].title // ""' \
           "$PRD_FILE" 2>/dev/null || echo "")"
    printf -- '- Write the plan artifact to: `%s` (relative to the repo root)\n' "$rel"
    printf -- '- `"story"` in that artifact must be exactly `%s`.\n' "$id"
    # THE REVIEWER'S OWN WORDS, verbatim, when a previous plan for this story was
    # sent back. This is the entire value of a rejection: a re-plan briefed with
    # "you missed the S3 path" is a different plan, while a re-plan told only that
    # it was rejected is the same plan with different adjectives.
    [ -z "${REVIEW_LIB_MISSING:-}" ] && fb="$(review_feedback "$2")"
    [ -n "$fb" ] && printf '\n### A human reviewed your previous plan and sent it back\n\nRe-plan so that these are answered. Do not re-submit the same plan.\n\n%s\n' "$fb"
  } >> "$PLAN_PROMPT_FILE"
  return 0
}

# --- LIVELINESS ---------------------------------------------------------------
# The driver hands us the path of this tasklist's liveliness record; unset (a
# standalone run) makes every live_* call a no-op. See engine/live.sh: this is what
# lets `chief ps` tell a working iteration from a hung one.
#
# Sourced relative to THIS FILE, not $ENGINE: $ENGINE honours an inherited
# $CHIEF_HOME, which may point at a DIFFERENT (older, or mid-update) install that
# has no live.sh — and losing the whole agent loop over a bookkeeping helper is not
# a trade worth making. Same reason for the no-op stubs: liveliness is diagnostics.
_AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_AGENT_DIR/live.sh" ]; then
  # shellcheck source=engine/live.sh
  . "$_AGENT_DIR/live.sh"
else
  live_set() { return 0; }
  live_get() { return 0; }
fi
# The machine-readable EVENT STREAM (engine/events.sh), sourced on exactly the same
# terms and for the same reason: $CHIEF_EVENTS_FILE is handed down by the driver, an
# empty one (a standalone run) is a no-op, and a missing file must cost us nothing.
if [ -f "$_AGENT_DIR/events.sh" ]; then
  # shellcheck source=engine/events.sh
  . "$_AGENT_DIR/events.sh"
else
  event_emit() { return 0; }
fi
# The BAR RULE (engine/measure.sh), sourced on the same terms as the two above — a
# missing file degrades to a no-op rather than taking the loop down with it. It is the
# SAME function engine/driver.sh runs at the merge phase; sourcing it here is what
# makes the boundary check and the merge floor one rule with two moments, instead of
# two implementations that can drift.
if [ -f "$_AGENT_DIR/measure.sh" ]; then
  # shellcheck source=engine/measure.sh
  . "$_AGENT_DIR/measure.sh"
else
  measure_gate() { return 0; }
fi
# The HUMAN-APPROVAL half of the plan checkpoint (engine/review.sh), on the same
# terms again — with one difference that matters: its absent-file fallback is not a
# no-op. A plan-review tasklist running on an install that has no review.sh has no
# reviewer, and "no reviewer" already has a state (a park, exit 5). Degrading it to
# a no-op would be the one behaviour the checkpoint forbids: proceeding unapproved.
# shellcheck source=engine/review.sh
[ -f "$_AGENT_DIR/review.sh" ] && . "$_AGENT_DIR/review.sh" || REVIEW_LIB_MISSING=1
LIVE="${CHIEF_LIVE_FILE:-}"
# Stories already passing when this loop started. The event stream reports the SET
# DIFFERENCE against it after every turn, so a turn that lands two stories reports
# two and a re-read of unchanged flags reports none.
PASSED_IDS=" $(_passed_ids) "
# _emit_story_events ITER — one `story.passed` per story that flipped during the turn
# that just returned. Called at ONE point (right after the provider returns) rather
# than at the progress check, because three of this loop's exits — COMPLETE, a usage
# limit, an operator-pause drain — happen BEFORE that check, and the last story of a
# tasklist always passes on the COMPLETE turn. Always returns 0.
_emit_story_events() {
  local now sid
  now=" $(_passed_ids) "
  for sid in $now; do
    case "$PASSED_IDS" in *" $sid "*) continue ;; esac
    event_emit story.passed name="${CHIEF_TASKLIST:-}" story="$sid" state=running \
      detail="iteration ${1:-?} — $(_passes)/$(_total) passing"
  done
  PASSED_IDS="$now"
  return 0
}
# _measure_boundary ITER — hold the turn that just returned to the BAR rule HERE, at
# the iteration boundary, where the agent can still act on it.
#
# WHY HERE AND NOT ONLY AT THE MERGE. engine/measure.sh is the same predicate the
# driver runs on every path to a merge, and that placement is the FLOOR: it catches
# everything, and it catches it at the one moment nothing can be done about it — the
# agent is gone, the run is over, and a human has to open the branch, re-run whatever
# produced the number and type it in. Measured 2026-08-17: four runs across three
# repos, and not one of them was a defect in the WORK; every one was missing only the
# value that proves it. Run the same predicate BETWEEN iterations and the offending
# story is back at `passes:false` on the very next turn, while the agent still has the
# command output in its context and can paste the number in with one edit.
#
# Safe to run here for the reason measure.sh's own header gives: it ONLY EVER DEMOTES.
# It cannot pass a story that would not otherwise pass, so on an honest run — one that
# wrote down the number it took — it costs a jq pass and changes nothing.
#
# NOT REACHED ON THE COMPLETE TURN: the loop exits above this point, so a story marked
# by the last turn is still the merge floor's business, exactly as before. This is the
# EARLIER of two moments for one rule, never a replacement for the later one.
#
# AND IT TELLS THE NEXT TURN. A demotion the agent never sees is indistinguishable
# from its own edit not having saved, and the only repair for that is to make the same
# edit again — which is the loop this check would otherwise create. So the report is
# banked in $DEMOTION_FILE and the prompt is recomposed around it (see _compose_prompt),
# naming the story and quoting the bar in measure.sh's own words. Not generic advice:
# instructions.md step 8 is the generic advice, every turn already gets it, and the
# runs this exists for got it too.
#
# AND IT IS BOUNDED. Telling the agent buys nothing if it can be told forever: an agent
# that re-marks the story without the value, turn after turn, commits every time, so
# HEAD moves, the stall counter reads progress, and the loop runs to HARD_MAX on one
# story. MEASURE_DEMOTE_LIMIT consecutive demotions FOR THE SAME STORIES ends the run
# instead (_demote_escalate below) — with the demotion named, and the branch kept.
_measure_boundary() {
  local report key
  command -v measure_gate >/dev/null 2>&1 || return 0
  report="$(measure_gate "$PRD_FILE" 2>/dev/null || true)"
  if [ -z "$report" ]; then
    # A boundary that demotes nothing has nothing outstanding to tell the next turn —
    # so drop the notice and rebuild the prompt without it. Cleared HERE rather than
    # "after one turn" so the notice always describes the state the check last found:
    # the turn that records its number stops being nagged the moment it does.
    DEMOTE_KEY=""; DEMOTE_REPEATS=0
    if [ -s "$DEMOTION_FILE" ]; then
      rm -f "$DEMOTION_FILE"
      _compose_prompt "$ENGINE/instructions.md" "$PROMPT_FILE"
    fi
    return 0
  fi
  echo ""
  echo "!! Iteration ${1:-?}: demoted back to passes:false — a story claims a measurable bar and recorded no observed value:"
  printf '%s\n' "$report"
  echo "   Chief cannot evaluate the bar, so it will not record it as met. Put the value you OBSERVED in that story's 'notes', then mark it again."
  # SAID TO THE AGENT, not only to the log. The log is read by an operator, hours
  # later, on a run that has already ended — the same audience and the same moment the
  # merge-time report already had. What is new here is that the next TURN can act, and
  # it acts on its prompt: bank the report and recompose, so the very next invocation
  # opens with what was demoted and which bar it has to answer.
  printf '%s\n' "$report" > "$DEMOTION_FILE"
  _compose_prompt "$ENGINE/instructions.md" "$PROMPT_FILE"
  # It is not a passing story any more, so the event stream's set difference must stop
  # remembering it as one — otherwise the re-mark that lands it properly, with its
  # number, would emit no `story.passed` at all. Re-baselining here is also what makes
  # the honest repair count as PROGRESS: the loop's `prev_pass` is taken from the count
  # this check LEFT BEHIND (it runs above the progress accounting), so the next turn's
  # evidenced re-mark raises the count above it and resets `stall` — a story fixed the
  # way it was asked to be fixed is never charged as a no-progress iteration.
  PASSED_IDS=" $(_passed_ids) "
  # THE REASON, as ids rather than prose: measure_gate has just left `unverified:true`
  # on exactly the stories it demoted THIS time (it clears the flag off everything
  # else), so the PRD itself carries the key — no re-parsing of the report's text, and
  # no false "same reason" when the agent merely reworded a valueless note.
  key="$(jq -r '[.userStories[]?|select(.unverified==true)|.id]|sort|join(",")' "$PRD_FILE" 2>/dev/null || echo)"
  if [ -n "$key" ] && [ "$key" = "$DEMOTE_KEY" ]; then
    DEMOTE_REPEATS=$((DEMOTE_REPEATS+1))
  else
    DEMOTE_KEY="$key"; DEMOTE_REPEATS=1
  fi
  if [ "$DEMOTE_REPEATS" -ge "$MEASURE_DEMOTE_LIMIT" ]; then
    _demote_escalate "${1:-?}" "$report"
  fi
  return 0
}
# _demote_escalate ITER REPORT — stop the loop on a demotion it keeps rediscovering.
#
# Reached only when the boundary demoted THE SAME stories MEASURE_DEMOTE_LIMIT times
# running, having named them and quoted their bars in the prompt each time. At that
# point the one thing chief knows is that more turns will not help: it cannot run the
# suite, it cannot evaluate the bar, and the agent has now twice declined to write down
# a value it either has or never took. Spending the rest of the budget on that is the
# failure this exists to prevent, and it is worse than the merge-time report it replaces
# — that one at least cost only the merge.
#
# NOT A STALL (exit 1). Commits may be landing on every one of these turns; that is
# precisely why the stall counter cannot see this loop. Exit 7 keeps the branch, the
# worktree and the commits, and the driver reports it in the merge floor's own words.
_demote_escalate() {
  echo ""
  echo "Chief is stopping: the same story was demoted at $DEMOTE_REPEATS consecutive iteration boundaries (limit $MEASURE_DEMOTE_LIMIT) with the value still unrecorded, and the loop will not be spent re-marking it:"
  printf '%s\n' "$2"
  echo "Chief cannot produce that number — it does not know what the bar means in this repo and will not record a claim it cannot check. Put the value you OBSERVED in that story's 'notes' and re-run; every commit made so far is kept on the branch."
  echo "Exit 7 = UNVERIFIED in-run — NOT a stall and NOT a failed branch."
  live_set "$LIVE" phase=unverified iter="$1" story="$(_story)" \
    passing="$(_passes)" total="$(_total)" stall="${stall:-0}"
  # STORY scope here; the driver emits the TASKLIST-scope terminal when it sees exit 7
  # — the same split story.plan-invalid uses, so a consumer counting tasklist outcomes
  # never double-counts.
  event_emit story.unverified name="${CHIEF_TASKLIST:-}" story="$DEMOTE_KEY" state=failed \
    detail="demoted at $DEMOTE_REPEATS consecutive iteration boundaries — a claimed bar with no observed value"
  exit 7
}
# --- USAGE / COST OBSERVATION (the event stream's `usage` block) ---------------
# OBSERVATION ONLY. Chief never asks a provider what a turn cost — it reads what the
# provider already printed on the stdout it was going to capture anyway. No API call,
# no polling loop, no second invocation. When a provider prints nothing usage-shaped
# (which is `claude --print` today), this yields nothing and the event's `usage` is
# null: a nullable, provider-dependent field, exactly as docs/reference/events.md promises.
#
# _parse_usage OUTPUT -> ' key=value …' event_emit keys ('' when nothing was found).
# Two shapes, most trustworthy first:
#   1. A STRUCTURED result object — the `{"type":"result","total_cost_usd":…,
#      "usage":{"input_tokens":…}}` line that `claude --output-format json` (and
#      anything mimicking it) prints. jq reads it, so a missing key is simply absent.
#   2. A PLAIN-TEXT summary — "Total cost: $0.0421", "1234 input tokens". Deliberately
#      narrow: a scrape that guesses is worse than a null, because a cost ledger
#      cannot tell an invented number from a real one.
_parse_usage() {
  local out="$1" line got=""
  command -v jq >/dev/null 2>&1 || return 0
  line="$(printf '%s\n' "$out" \
    | grep -E '"(total_cost_usd|cost_usd|input_tokens|output_tokens)"[[:space:]]*:' \
    | tail -1)"
  if [ -n "$line" ]; then
    got="$(printf '%s' "$line" | jq -r '
        def kv($k; $v): if ($v|type) == "number" then "\($k)=\($v)" else empty end;
        [ kv("in_tokens";    (.usage.input_tokens  // .input_tokens)),
          kv("out_tokens";   (.usage.output_tokens // .output_tokens)),
          kv("total_tokens"; (.usage.total_tokens  // .total_tokens)),
          kv("cost_usd";     (.total_cost_usd // .cost_usd)),
          kv("duration_ms";  .duration_ms),
          kv("turns";        .num_turns) ] | join(" ")' 2>/dev/null || echo "")"
  fi
  if [ -z "$got" ]; then
    local cost tin tout
    cost="$(printf '%s\n' "$out" | grep -oiE 'cost:?[[:space:]]*\$?[0-9]+\.[0-9]+' \
      | tail -1 | grep -oE '[0-9]+\.[0-9]+' || echo "")"
    tin="$(printf '%s\n' "$out"  | grep -oiE '[0-9]+[[:space:]]+input[[:space:]]+tokens' \
      | tail -1 | grep -oE '[0-9]+' || echo "")"
    tout="$(printf '%s\n' "$out" | grep -oiE '[0-9]+[[:space:]]+output[[:space:]]+tokens' \
      | tail -1 | grep -oE '[0-9]+' || echo "")"
    got="${cost:+cost_usd=$cost }${tin:+in_tokens=$tin }${tout:+out_tokens=$tout}"
  fi
  printf '%s' "$got"
  return 0
}
# _emit_turn_event ITER — one `agent.turn` per provider turn that returned, emitted
# at the same point the loop already writes the post-turn live_set. It is what carries
# the per-turn usage figures (null when the provider printed none), so a host can keep
# a spend ledger without re-running or re-parsing anything. `model` comes from the
# engine's own configuration, not a scrape, so it is populated whenever one is set.
_emit_turn_event() {
  local u; u="$(_parse_usage "${OUTPUT:-}")"
  # shellcheck disable=SC2086  # $u is a deliberate word-split list of key=value args
  event_emit agent.turn name="${CHIEF_TASKLIST:-}" state=running \
    detail="iteration ${1:-?} — $(_passes)/$(_total) passing" \
    ${MODEL:+model=$MODEL} $u
  return 0
}
LIVE_BEAT_SECONDS="${LIVE_BEAT_SECONDS:-15}"
# A `claude --print` turn blocks this shell for MINUTES, so without a ticker the
# heartbeat would freeze on every healthy turn and the staleness signal would be
# useless (it would flag exactly the runs that are working hardest). Bump it from a
# forked child for the duration of the turn, and promote the phase to 'writing' the
# moment a commit lands — the one file-level signal observable from out here.
_beat_start() {
  [ -n "$LIVE" ] || return 0
  ( last="$(_head)"
    while :; do
      sleep "$LIVE_BEAT_SECONDS"
      now_h="$(_head)"
      if [ "$now_h" != "$last" ]; then live_set "$LIVE" phase=writing; last="$now_h"
      else live_set "$LIVE"; fi
    done ) 2>/dev/null &
  BEAT_PID=$!
  return 0
}
_beat_stop() {
  [ -n "${BEAT_PID:-}" ] || return 0
  kill "$BEAT_PID" 2>/dev/null || true
  wait "$BEAT_PID" 2>/dev/null || true
  BEAT_PID=""
  return 0
}
trap '_beat_stop' EXIT

# A "…3pm"-style clock token -> today's epoch, on WHATEVER date(1) the host has.
# GNU takes -d; BSD/macOS rejects it outright and needs -j -f with an explicit
# format. Trying only the GNU form meant that on a Mac this whole arm silently
# produced nothing, so "your limit will reset at 3pm" — the standard Claude
# phrasing — fell through to the RATE_LIMIT_WAIT fallback and slept an hour no
# matter how near the window actually was. Empty when the token is unusable;
# the caller decides what an unparseable time means.
_clock_to_epoch() {
  local raw="$1" hh mm ap today e=""
  ap=$(printf '%s' "$raw" | grep -oiE '(am|pm)' | head -1 | tr '[:lower:]' '[:upper:]')
  hh=$(printf '%s' "$raw" | grep -oE '^[0-9]{1,2}' | head -1)
  mm=$(printf '%s' "$raw" | grep -oE ':[0-9]{2}' | head -1); mm="${mm#:}"
  [ -n "$hh" ] && [ -n "$ap" ] || return 0
  [ -n "$mm" ] || mm=00
  [ "${#hh}" = 1 ] && hh="0$hh"
  today=$(date +%Y-%m-%d)
  e=$(date -d "$today $hh:$mm $ap" +%s 2>/dev/null) \
    || e=$(date -j -f '%Y-%m-%d %I:%M %p' "$today $hh:$mm $ap" +%s 2>/dev/null) \
    || e=""
  case "$e" in ''|*[!0-9]*) e="" ;; esac
  printf '%s' "$e"
}

# Seconds to sleep after a limit message: prefer a parsed reset time — a unix
# epoch near "reset", a "…3pm"-style clock time, or a RELATIVE "…in 16 minutes"
# — else RATE_LIMIT_WAIT; +60s buffer; capped at 6h.
_seconds_until_reset() {
  local out="$1" now epoch t rel n secs; now=$(date +%s)
  epoch=$(printf '%s' "$out" | grep -oiE '(reset|limit)[^0-9]{0,40}1[0-9]{9}' | grep -oE '1[0-9]{9}' | head -1)
  if [ -z "$epoch" ]; then
    t=$(printf '%s' "$out" | grep -oiE '[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)' | head -1)
    if [ -n "$t" ]; then
      epoch="$(_clock_to_epoch "$t")"
      # Only trust a clock time that's still ahead today; a past time is ambiguous
      # (stale/tomorrow) so fall back to RATE_LIMIT_WAIT rather than oversleep.
      [ -n "$epoch" ] && [ "$epoch" -le "$now" ] && epoch=""
    fi
  fi
  # RELATIVE DURATION — "your limit will reset in 16 minutes", "retry in 30s". A
  # provider that meters a rolling THROUGHPUT window (Devin's overall message rate
  # limit) only ever phrases it this way: no epoch, no clock time. Without this arm
  # such a message fell through to RATE_LIMIT_WAIT, so a 16-minute block slept a
  # full hour — and under -p N every co-scheduled worker slept it too, because they
  # all trip the throughput cap in the same burst. Anchored to a reset/try-again
  # phrase so an unrelated "5 minutes" in the agent's own prose cannot set the
  # timer, and read as the LAST number in the match so an anchor's own digits never
  # become the duration.
  if [ -z "$epoch" ]; then
    rel=$(printf '%s' "$out" | grep -oiE '(reset|try again|retry in|available again)[^0-9]{0,20}[0-9]{1,4}[[:space:]]*(seconds?|minutes?|hours?|secs?|mins?|hrs?)' | head -1)
    if [ -n "$rel" ]; then
      n=$(printf '%s' "$rel" | grep -oE '[0-9]{1,4}' | tail -1)
      case "$(printf '%s' "$rel" | tr '[:upper:]' '[:lower:]')" in
        *hour*|*hr*) epoch=$(( now + n * 3600 )) ;;
        *min*)       epoch=$(( now + n * 60 ))   ;;
        *sec*)       epoch=$(( now + n ))        ;;
      esac
    fi
  fi
  if [ -n "$epoch" ] && [ "$epoch" -gt "$now" ]; then secs=$(( epoch - now + 60 )); else secs="$RATE_LIMIT_WAIT"; fi
  [ "$secs" -gt 21600 ] && secs=21600
  echo "$secs"
}

# Is this turn's output a usage/session limit stop? Two ways to say yes:
#   1. the output matches RATE_LIMIT_PATTERN (any known phrasing), or
#   2. the CLI exited NON-ZERO and the output carries a weaker structured hint
#      (a bare 429 / rate_limit_error payload with no prose around it).
# The exit status alone is never enough — the CLI exits non-zero for plenty of
# non-limit reasons — but it is what turns an ambiguous hint into a limit
# instead of a stalled iteration.
_is_rate_limit() {
  local out="$1" status="$2"
  if printf '%s\n' "$out" | grep -qiE "$RATE_LIMIT_PATTERN"; then return 0; fi
  if [ "$status" != "0" ] && printf '%s\n' "$out" | grep -qiE "$RATE_LIMIT_STATUS_PATTERN"; then return 0; fi
  return 1
}

# _rate_limit_wait OUTPUT — what to DO about a turn that _is_rate_limit said yes to.
#   returns 0  slept until the window reopens; the caller should re-run the same turn
#              (and must NOT charge it to any budget — a blocked turn is free)
#   returns 1  will not retry; the reset ETA is recorded in $LIMIT_RETRY_FILE for the
#              driver and the caller must exit 2
# Shared by the story loop and the research phase so there is exactly ONE place that
# decides how long to sleep, how many waits are left, and what the driver is told.
# Duplicating this was the alternative, and the limit path is the last logic in the
# engine that should ever exist in two versions: a divergence here is invisible until
# it silently converts a blocked run into a "failed" one. Mutates $waits (a global,
# read back by the liveliness record).
_rate_limit_wait() {
  local out="$1" secs
  if [ "$RATE_LIMIT_RETRY" = "1" ] && [ "${waits:-0}" -lt "$RATE_LIMIT_MAX_WAITS" ]; then
    waits=$(( ${waits:-0} + 1 ))
    secs=$(_seconds_until_reset "$out")
    echo ""
    echo "Chief hit a session/usage limit. Sleeping ${secs}s (~$(( secs/60 )) min) then resuming — wait $waits/$RATE_LIMIT_MAX_WAITS."
    # Publish the pause BEFORE sleeping: a heartbeat that stops advancing for an
    # hour must read as 'paused until <eta>', not as the hang it looks like.
    live_set "$LIVE" phase=rate-limited-waiting waits="$waits" \
      retry_at="$(( $(date +%s) + secs ))"
    # The same pause, published to the event stream: a subscriber must be able to
    # tell "asleep on a usage limit until <eta>" from "hung" WITHOUT diffing the
    # live record, and the limit block is the quota half of chief-cloud's ledger.
    event_emit tasklist.rate-limit-wait name="${CHIEF_TASKLIST:-}" state=rate-limited \
      limit_hit=1 retry_at="$(( $(date +%s) + secs ))" waits="$waits" \
      max_waits="$RATE_LIMIT_MAX_WAITS" \
      detail="sleeping ${secs}s — wait $waits/$RATE_LIMIT_MAX_WAITS"
    sleep "$secs"
    return 0
  fi
  # Hand the driver the reset ETA before stopping, so the run can re-dispatch
  # this tasklist when the window reopens rather than stranding it.
  secs=$(_seconds_until_reset "$out")
  echo "$(( $(date +%s) + secs ))" > "$LIMIT_RETRY_FILE" 2>/dev/null || true
  live_set "$LIVE" phase=rate-limited waits="${waits:-0}" \
    retry_at="$(cat "$LIMIT_RETRY_FILE" 2>/dev/null || echo 0)"
  echo ""
  echo "Chief hit a session/usage limit and won't retry (RATE_LIMIT_RETRY=$RATE_LIMIT_RETRY, waits=${waits:-0}/$RATE_LIMIT_MAX_WAITS). Stopping."
  echo "Exit 2 = blocked on a usage limit — resumable once the window resets, NOT a failed tasklist."
  echo "Reset ETA recorded for the driver: $(cat "$LIMIT_RETRY_FILE" 2>/dev/null) (in ~$(( secs/60 )) min)."
  return 1
}

# ACCOUNT CREDENTIAL SEAM (docs/reference/account-credentials.md) — read the designated
# KEY=VALUE file and export its pairs into the CURRENT shell. Called only from the
# provider subshell below, so nothing outside the provider invocation ever sees the
# credential.
#
# Parsed, never SOURCED, on purpose: an env file is data handed to chief by an
# operator (or by a pooler like chief-cloud), and `.`-ing it would execute whatever
# it contains under the agent's privileges. Only lines that ARE assignments are
# honoured; anything else is ignored rather than run. Values are exported by the
# `export` BUILTIN — never spliced into a command line — so they never reach argv
# where `ps` could read them.
#
# Format: `KEY=VALUE` (an optional leading `export ` is tolerated), one per line,
# `#` comments and blank lines skipped, a single layer of surrounding double or
# single quotes stripped. No expansion, no continuation lines: a value is the rest
# of the line, verbatim.
_apply_account_env() {
  local file="$1" line key val n=0 xt=0
  # NON-LEAKAGE, first line: this is the ONLY place in chief that holds a credential
  # VALUE in a variable, so it is also the only place a shell TRACE could print one.
  # An operator debugging a run with `bash -x` (or a host that sets SHELLOPTS) would
  # otherwise get every `export KEY=VALUE` echoed to stderr — which agent.sh tees
  # straight into the per-iteration log `chief logs` serves. Trace off for the body,
  # restored exactly as we found it.
  case "$-" in *x*) xt=1; set +x ;; esac
  [ -r "$file" ] || { echo "ERROR: unreadable account env file: $file" >&2
                      [ "$xt" = 1 ] && set -x; return 1; }
  # Own redirect: the caller hands the provider its prompt on stdin, and reading the
  # env file from there instead would swallow it.
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    line="${line#export }"
    key="${line%%=*}"; val="${line#*=}"
    [ "$key" = "$line" ] && continue                      # no '=' — not an assignment
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue  # not a legal env name
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    export "$key=$val"
    n=$(( n + 1 ))
  done < "$file"
  [ "$n" -gt 0 ] || { echo "ERROR: account env file defines no KEY=VALUE pairs: $file" >&2
                      [ "$xt" = 1 ] && set -x; return 1; }
  # Reported, never exposed: the COUNT of variables applied and the file's path say
  # the designation took effect; the names and values stay in this subshell.
  [ -n "${CHIEF_VERBOSE:-}" ] && printf '>> [verbose] account env applied: %s var(s) from %s\n' \
    "$n" "$file" >&2
  [ "$xt" = 1 ] && set -x
  return 0
}

# Run one provider in non-interactive mode. The prompt is supplied on stdin by the
# caller so every provider receives the same Chief instructions and project context.
#
# When the run carries an account designation, the credential env is applied HERE and
# nowhere else — inside the subshell that execs the provider — so the driver's git /
# verify / merge phases and the iteration hook keep running under chief's own
# environment. A designation that has become unreadable mid-run fails the turn loudly
# instead of silently falling back to the inherited account.
_run_provider() {
  if [ -n "${CHIEF_ACCOUNT_ENV_FILE:-}" ]; then
    ( _apply_account_env "$CHIEF_ACCOUNT_ENV_FILE" || exit 1
      _provider_exec )
  else
    _provider_exec
  fi
}

_provider_exec() {
  case "$PROVIDER" in
    claude)
      if [ -n "$MODEL" ]; then claude --dangerously-skip-permissions --print --model "$MODEL"
      else claude --dangerously-skip-permissions --print
      fi
      ;;
    devin)
      # devin's --print mode reads the prompt from --prompt-file (or a -- <PROMPT> arg),
      # NOT from stdin like claude/opencode — without it, it panics "print mode requires
      # a prompt" every iteration. PROMPT_FILE is the same file the caller pipes on stdin.
      if [ -n "$MODEL" ]; then devin --permission-mode bypass --respect-workspace-trust false --print --model "$MODEL" --prompt-file "$ACTIVE_PROMPT"
      else devin --permission-mode bypass --respect-workspace-trust false --print --prompt-file "$ACTIVE_PROMPT"
      fi
      ;;
    opencode)
      if [ -n "$MODEL" ]; then opencode run --model "$MODEL"
      else opencode run
      fi
      ;;
    amp)
      # No model branch by design: amp's CLI has no model selector (it picks its
      # own), so $MODEL is refused/dropped above rather than passed here.
      amp --dangerously-allow-all
      ;;
  esac
}

echo "Starting Chief — Provider: $PROVIDER${MODEL:+ (model: $MODEL)} — budget $MAX_ITERATIONS iters (extends while progressing; hard cap $HARD_MAX; stall limit $STALL_LIMIT)"

# Initialized BEFORE the research phase, not with prev_pass/prev_head below: a limit
# hit during research goes through the same _rate_limit_wait as a story turn, and
# that helper reads and advances $waits. Resetting the counters after research would
# hand the story loop a fresh wait budget it has already partly spent.
i=0; stall=0; waits=0

# --- RESEARCH PHASE (engine/research.sh) --------------------------------------
# ONCE per tasklist, BEFORE the first story: map the code into a structured document
# that every story then reads instead of re-deriving it. See research.sh's header for
# why; this block is only the dispatch, the validation and the persistence.
#
# THE PERSISTENCE IS THE HALF THAT IS EASY TO GET WRONG. The document the model writes
# lives in the WORKTREE's state dir, and the driver deletes and rebuilds that worktree
# on every run — so a document that only ever existed there would be regenerated by
# each resumed run, which is precisely the cost this phase exists to pay once.
# $CHIEF_RESEARCH_FILE is the driver's DURABLE path (outside the worktree, under the
# project's .chief/state/). We seed FROM it and promote back TO it the moment a valid
# document exists — not at the end of the loop — so a run killed mid-story still
# leaves the research banked.
#
# That same file is the human-edit surface: a hand-corrected document validates,
# so it is reused verbatim and never regenerated.
# THE BUDGET (acceptance: the phase is bounded). At most this many PROVIDER TURNS,
# total, for the whole tasklist. Two is deliberate: one honest attempt plus one retry
# that is TOLD which sections came back empty. A limit-blocked turn is not charged
# against it (it never reached the model), exactly as in the story loop.
RESEARCH_MAX_ATTEMPTS="${CHIEF_RESEARCH_MAX_ATTEMPTS:-2}"
RESEARCH_PROMPT_FILE="$STATE_DIR/.research-prompt.md"
if [ -f "$_AGENT_DIR/research.sh" ]; then
  # shellcheck source=engine/research.sh
  . "$_AGENT_DIR/research.sh"
else
  # An install that predates this module. Research is skipped — it is the only thing
  # an engine without the module can do — but NEVER silently when it was asked for:
  # a run that believes it got a research phase and did not is the failure mode this
  # whole feature is trying to remove.
  research_enabled() {
    case "${CHIEF_RESEARCH:-}" in
      1|on|yes|true) echo "WARNING: research was requested but $_AGENT_DIR/research.sh is missing — continuing WITHOUT a research phase" >&2 ;;
    esac
    return 1
  }
fi

# RESEARCH_ON is what every LATER consumer keys off (_research_refresh, and through
# it the map injected into each turn's prompt). Asked exactly once, here: the answer
# depends on $CHIEF_RESEARCH and the tasklist, neither of which changes mid-run, and
# re-asking it per iteration is how "research off" turns into "research off except in
# the one place that forgot to check".
RESEARCH_ON=0
if research_enabled "$PRD_FILE"; then
  RESEARCH_ON=1
  # THE VERDICT FOR THE MAP lives beside the DURABLE document, never in the worktree:
  # an approval a human already gave has to survive the worktree the driver rebuilds
  # on every run, or the checkpoint asks for it again and the guarantee is worthless.
  # Falls back to the worktree only on a standalone run that has no durable store.
  if [ -n "$RESEARCH_STORE" ]; then RESEARCH_VERDICT="${RESEARCH_STORE%.md}.review.json"
  else                              RESEARCH_VERDICT="${RESEARCH_DOC%.md}.review.json"; fi
  RESEARCH_FEEDBACK=""

  # THE PHASE, as one loop: produce (or reuse) a valid map, then put it in front of a
  # human IF this tasklist asked for review — and if they send it back, do it again.
  #
  # TWO BUDGETS, DELIBERATELY SEPARATE. $RESEARCH_MAX_ATTEMPTS bounds the turns spent
  # getting a MACHINE-VALID document (sections present and non-empty) and is reset for
  # each review round; $CHIEF_REVIEW_MAX_ROUNDS bounds how many times a HUMAN may send
  # a valid one back. They answer different questions — "can the model produce the
  # shape?" and "is this map right?" — and sharing one counter would make a reviewer's
  # first rejection eat the retry that exists for a truncated document. The phase is
  # still bounded: at most attempts x rounds turns, both documented knobs.
  while :; do
    # REUSE BEFORE REGENERATE. A valid persisted document (from a previous run, or from
    # a human's hand) short-circuits the whole phase.
    if [ -n "$RESEARCH_STORE" ] && [ -f "$RESEARCH_STORE" ]; then
      if research_validate "$RESEARCH_STORE"; then
        cp "$RESEARCH_STORE" "$RESEARCH_DOC" 2>/dev/null || true
        echo "Research: reusing the persisted document ($RESEARCH_STORE) — not re-running research."
        event_emit tasklist.research name="${CHIEF_TASKLIST:-}" state=running \
          detail="reused the persisted research document ($RESEARCH_STORE)"
      else
        echo "Research: the persisted document is incomplete (missing: $(research_missing "$RESEARCH_STORE" | tr '\n' ' ')) — regenerating." >&2
      fi
    fi

    if ! research_validate "$RESEARCH_DOC"; then
      ra=0
      while [ "$ra" -lt "$RESEARCH_MAX_ATTEMPTS" ]; do
        ra=$(( ra + 1 ))
        echo ""
        echo "==============================================================="
        echo "  Chief RESEARCH PHASE ($TOOL) — attempt $ra/$RESEARCH_MAX_ATTEMPTS"
        echo "==============================================================="
        live_set "$LIVE" phase=research iter=0 story= stall=0 waits="$waits" retry_at=0
        # The model is handed the WORKTREE-RELATIVE path: it is instructed to stay
        # inside its worktree, and $RESEARCH_STORE points outside it.
        research_prompt "$PRD_FILE" "${CHIEF_STATE_DIR:-.chief/state}/research.md" \
          "$(research_missing "$RESEARCH_DOC")" "$RESEARCH_FEEDBACK" > "$RESEARCH_PROMPT_FILE"
        TOOL_RC=0
        _beat_start
        OUTPUT=$(_run_provider < "$RESEARCH_PROMPT_FILE" 2>&1 | tee /dev/stderr; exit "${PIPESTATUS[0]}") || TOOL_RC=$?
        _beat_stop
        # A research turn is still a provider turn: it costs quota and belongs in the
        # spend ledger like any other. Reported as iteration 0 — the phase runs before
        # the story loop's counter starts.
        _emit_turn_event "research/$ra"
        if _is_rate_limit "$OUTPUT" "$TOOL_RC"; then
          if _rate_limit_wait "$OUTPUT"; then
            ra=$(( ra - 1 ))   # a blocked turn never reached the model — not charged
            continue
          fi
          exit 2
        fi
        research_validate "$RESEARCH_DOC" && break
        echo "Research attempt $ra produced no usable document (missing: $(research_missing "$RESEARCH_DOC" | tr '\n' ' '))."
      done
    fi

    if ! research_validate "$RESEARCH_DOC"; then
      # DISTINCT, ACTIONABLE FAILURE — never a fall-through into implementation.
      echo ""
      echo "Chief could not produce a valid research document in $RESEARCH_MAX_ATTEMPTS attempt(s). Stopping."
      echo "Missing required section(s): $(research_missing "$RESEARCH_DOC" | tr '\n' ' ')"
      echo "Exit 6 = RESEARCH FAILED — nothing was implemented. Write or repair${RESEARCH_STORE:+ $RESEARCH_STORE}, raise CHIEF_RESEARCH_MAX_ATTEMPTS, or set CHIEF_RESEARCH=0 to skip the phase."
      live_set "$LIVE" phase=research-failed iter=0 story= passing="$(_passes)" total="$(_total)"
      exit 6
    fi

    # PROMOTE IMMEDIATELY (see the persistence note above) — this is what "survives
    # process death" means in practice. A pre-existing store is left alone: it is
    # either the document we just copied down, or a human's edit, and neither wants
    # to be overwritten by a copy of itself.
    if [ -n "$RESEARCH_STORE" ] && [ ! -f "$RESEARCH_STORE" ]; then
      mkdir -p "$(dirname "$RESEARCH_STORE")" 2>/dev/null || true
      if cp "$RESEARCH_DOC" "$RESEARCH_STORE" 2>/dev/null; then
        echo "Research: document persisted to $RESEARCH_STORE (reused by every story, and by any resumed run)."
        event_emit tasklist.research name="${CHIEF_TASKLIST:-}" state=running \
          detail="research document produced and persisted ($RESEARCH_STORE)"
      else
        # Non-fatal: the map exists and this run can use it. But an unwritable store
        # means the NEXT run pays for research again, and that is worth saying out
        # loud rather than discovering from a duplicated bill.
        echo "WARNING: research document could not be persisted to $RESEARCH_STORE — this run uses it, a resumed run would regenerate it" >&2
      fi
    fi

    # HUMAN REVIEW OF THE MAP — a no-op returning 0 unless this tasklist already
    # opted into plan review, which is what keeps the two features independent.
    # It runs HERE, before the story loop, so it is structurally impossible for a
    # plan turn to be reviewed before the map it was reasoned from.
    RESEARCH_RC=0
    live_set "$LIVE" phase=review-wait iter=0 story= stall=0 waits="$waits" retry_at=0
    research_review_gate "$RESEARCH_DOC" "$RESEARCH_VERDICT" || RESEARCH_RC=$?
    [ "$RESEARCH_RC" = "0" ] && break
    if [ "$RESEARCH_RC" = "2" ]; then
      # The plan checkpoint's park, one rung further up the leverage hierarchy. Not a
      # failure: the map, the annotations and the branch are all kept, and a re-run
      # reads the verdict off disk rather than asking for it again.
      echo ""
      echo "Chief is stopping: this tasklist's research map has no human approval — and none can be obtained here."
      echo "The map and every annotation are kept${RESEARCH_STORE:+ ($RESEARCH_STORE)}; nothing was implemented."
      echo "Exit 5 = AWAITING-REVIEW — parked for a person, NOT a failed tasklist. Approve the map (or edit it by hand), then re-run."
      live_set "$LIVE" phase=awaiting-review iter=0 story= passing="$(_passes)" total="$(_total)"
      event_emit tasklist.awaiting-review name="${CHIEF_TASKLIST:-}" state=awaiting-review \
        detail="the research map is unapproved and no reviewer could be reached"
      exit 5
    fi
    # SENT BACK. Drop the map from BOTH locations — the gate removed the worktree copy,
    # and leaving the durable one would make the reuse branch at the top of this loop
    # hand the next round the very document the reviewer just rejected. Their words
    # brief the re-research; the attempts budget starts over for it (see TWO BUDGETS).
    rm -f "$RESEARCH_DOC" 2>/dev/null || true
    [ -n "$RESEARCH_STORE" ] && { rm -f "$RESEARCH_STORE" 2>/dev/null || true; }
    RESEARCH_FEEDBACK="$(research_review_feedback "$RESEARCH_VERDICT")"
  done

  # The map is valid, banked and (where asked for) approved. Fold it into the prompt
  # every turn from here on is composed from.
  _research_refresh
fi

prev_pass=$(_passes); prev_head=$(_head)
while :; do
  # DRAIN CHECKPOINT (see OPERATOR PAUSE above). Asked here and nowhere else: the
  # previous iteration is fully accounted for (its commits are on the branch, its
  # boundary hook has run) and the next one has not started, so stopping now costs
  # nothing and strands nothing. Checked before the counter so `iter` records the
  # iterations actually spent.
  if _op_paused; then
    echo ""
    echo "Chief is stopping: an OPERATOR PAUSE is armed ($PAUSE_FILE) — no further iteration will start."
    echo "$(_passes)/$(_total) stories pass; everything committed so far is kept on the branch."
    echo "Exit 3 = drained on an operator pause — resumable with 'chief resume', NOT a failed tasklist."
    live_set "$LIVE" phase=operator-paused iter="$i" story="$(_story)" \
      passing="$(_passes)" total="$(_total)" stall="$stall" waits="$waits" retry_at=0
    exit 3
  fi
  i=$((i+1))
  # A TURN THAT HAS BEGUN IS NOT THE LAST ONE'S VERDICT. The boundary below publishes
  # phase=stalled when an iteration advanced neither a passing story nor HEAD; that is
  # true of the iteration that just ENDED and false from this line onward. So this is
  # the iteration's FIRST write, ahead of everything that can take time (the research
  # re-read, the review gate, the prompt compose) — nothing between here and the turn
  # can still be read as 'stalled', which is the word chief uses for "give up on this".
  # Measured 2026-08-17: tasklist 98 displayed `stalled` with a 2-second heartbeat
  # while it was working. The COUNT is untouched — it stays in `$stall`, it is still
  # published (with the budget it is measured against), and it still ends the run at
  # $STALL_LIMIT below. Only the claim about what is happening NOW is corrected.
  # $TURN_PHASE refines this a few lines down for a plan turn; agent-turn is the right
  # answer for every iteration until that is known.
  live_set "$LIVE" phase=agent-turn iter="$i" stall="$stall" stall_limit="$STALL_LIMIT"
  # THE HUMAN-CORRECTION WINDOW. Re-read the durable research document and rebuild
  # this turn's prompt around it, EVERY iteration. A person who opened the map
  # between stories and fixed it has their correction in the very next story's
  # context, with no re-run and no research turn spent — which is the leverage the
  # phase exists for: a map corrected here is a map that never becomes wrong code.
  # A no-op when research is off.
  _research_refresh
  # TURN MODE — what this iteration is FOR. Decided here, at the top, from state on
  # disk only (the PRD's review field + whether this story's plan artifact already
  # exists and parses), so it survives a restart: a resumed run re-derives the same
  # answer instead of needing a remembered position in the loop.
  TURN_MODE=implement; TURN_PHASE=agent-turn; TURN_LABEL=""; ACTIVE_PROMPT="$PROMPT_FILE"
  TURN_STORY="$(_story)"
  # The artifact path for this story. The id is a schema-controlled slug ("US-1"), but
  # it reaches us from a JSON file an agent edits, so anything not filename-safe is
  # folded to '_' rather than trusted into a path.
  TURN_PLAN="$PLAN_DIR/${TURN_STORY//[^A-Za-z0-9._-]/_}.plan.json"
  # THE REVIEW GATE (engine/review.sh). Asked only when a well-formed plan already
  # exists — there is nothing to approve before that — and answered entirely from
  # disk, so a resumed run reads the verdict it was already given instead of asking
  # a human the same question twice. Three answers, and the two that are not
  # "implement" both land back in the plan/park machinery below rather than starting
  # a second state machine:
  #   0  approved  — fall through to the implement turn.
  #   1  re-plan   — the reviewer sent it back; review_gate has ALREADY removed the
  #                  plan artifact and recorded the annotations, so the very next
  #                  check re-derives "plan turn" and _plan_prompt briefs it with
  #                  the feedback. Bounded by $CHIEF_REVIEW_MAX_ROUNDS.
  #   2  park      — no approval, and none obtainable here. Exit 5, below.
  REVIEW_RC=0
  if [ "$REVIEW_MODE" = plan ] && [ -n "$TURN_STORY" ] && _plan_valid "$TURN_PLAN" "$TURN_STORY"; then
    # No review.sh in this install = no reviewer, which is a park and not a stub that
    # waves the plan through. Same answer as an absent plannotator, said differently.
    [ -n "${REVIEW_LIB_MISSING:-}" ] && echo "Plan review: this install has no engine/review.sh — nothing here can approve a plan."
    review_gate "$TURN_STORY" "$TURN_PLAN" || REVIEW_RC=$?
  fi
  # AWAITING REVIEW. The park, and the whole reason the gate can be trusted: every
  # way of failing to reach a reviewer ends HERE and not in an implement turn. It is
  # the operator-pause drain in a different colour — branch, worktree, plan and
  # annotations all kept, nothing half-done, and `chief run` picks it back up.
  if [ "$REVIEW_RC" = "2" ]; then
    echo ""
    echo "Chief is stopping: $TURN_STORY has a plan, but no human approval — and none can be obtained here."
    echo "$(_passes)/$(_total) stories pass; everything committed so far is kept on the branch, and the plan + annotations are kept for a reviewer."
    echo "Exit 5 = AWAITING-REVIEW — parked for a person, NOT a failed tasklist. Approve the plan (or fix the story), then re-run."
    live_set "$LIVE" phase=awaiting-review iter="$i" story="$TURN_STORY" \
      passing="$(_passes)" total="$(_total)" stall="$stall" waits="$waits" retry_at=0
    # STORY scope; the driver emits the tasklist-scope terminal when it sees exit 5 —
    # the same two-scope split as plan-invalid, so nothing is double-counted.
    event_emit story.awaiting-review name="${CHIEF_TASKLIST:-}" story="$TURN_STORY" \
      state=awaiting-review detail="the plan is unapproved and no reviewer could be reached"
    exit 5
  fi
  # A plan already on disk and valid is never re-bought — that is what makes the phase
  # idempotent across a restart, a usage-limit stop, or a rebuilt worktree.
  if [ "$REVIEW_MODE" = plan ] && [ -n "$TURN_STORY" ] && ! _plan_valid "$TURN_PLAN" "$TURN_STORY"; then
    TURN_MODE=plan; TURN_PHASE=plan-turn; TURN_LABEL=" — PLAN turn for $TURN_STORY"
    _plan_prompt "$TURN_STORY" "$TURN_PLAN"
    ACTIVE_PROMPT="$PLAN_PROMPT_FILE"
  fi
  echo ""
  echo "==============================================================="
  echo "  Chief Iteration $i ($TOOL)$TURN_LABEL — budget $MAX_ITERATIONS · cap $HARD_MAX · $(_passes)/$(_total) passing"
  echo "==============================================================="
  live_set "$LIVE" phase="$TURN_PHASE" iter="$i" story="$(_story)" \
    passing="$(_passes)" total="$(_total)" stall="$stall" stall_limit="$STALL_LIMIT" \
    waits="$waits" retry_at=0

  # Run the selected provider with the composed Chief prompt. The provider's own
  # exit status is preserved (PIPESTATUS, not tee's) for limit classification.
  TOOL_RC=0
  live_set "$LIVE" phase=provider-waiting
  # CHIEF_VERBOSE traces the exact provider invocation into the log — which provider,
  # which model, and the composed prompt it's being handed — so a misconfigured
  # provider/model shows up plainly instead of as a silent stall.
  # The account DESIGNATION is traced with it — the label and the env-file path, so a
  # run pinned to the wrong account is as visible as a misconfigured model. Values are
  # never traced (see _apply_account_env); an undesignated run prints nothing extra.
  [ -n "${CHIEF_VERBOSE:-}" ] && printf '>> [verbose] provider=%s%s%s · prompt=%s (%s lines)\n' \
    "$PROVIDER" "${MODEL:+ model=$MODEL}" \
    "${CHIEF_ACCOUNT_ENV_FILE:+ account=${CHIEF_ACCOUNT_LABEL:-$(basename "$CHIEF_ACCOUNT_ENV_FILE")} env=$CHIEF_ACCOUNT_ENV_FILE}" \
    "$ACTIVE_PROMPT" \
    "$(wc -l < "$ACTIVE_PROMPT" 2>/dev/null | tr -d ' ')" >&2
  _beat_start
  OUTPUT=$(_run_provider < "$ACTIVE_PROMPT" 2>&1 | tee /dev/stderr; exit "${PIPESTATUS[0]}") || TOOL_RC=$?
  _beat_stop
  live_set "$LIVE" phase="$TURN_PHASE" story="$(_story)" passing="$(_passes)" total="$(_total)"
  _emit_story_events "$i"
  _emit_turn_event "$i"

  # Completion signal — the token MUST be on a line by itself (optionally fenced in
  # backticks). Matching it ANYWHERE let an agent that merely QUOTED the token while
  # explaining it was NOT done ("I'm not reporting `<promise>COMPLETE</promise>` — it
  # stays passes:false") trip a false completion after one iteration; the driver then
  # force-passed every story and the merge only failed at the coverage gate. Anchoring
  # to a standalone line accepts a real emission and rejects a prose mention. Bias is
  # deliberate: a false negative just costs one extra iteration, a false positive
  # short-circuits the whole tasklist.
  #
  # NEVER honoured on a PLAN turn. That turn is instructed to write one file and stop,
  # so a COMPLETE from it cannot be true — and honouring it would hand the driver an
  # exit 0 with no commits, which is the exact false-complete the no-work guard exists
  # to catch. Said out loud rather than swallowed: a plan turn emitting it means the
  # plan prompt is being misread, and that is worth seeing in the log.
  if printf '%s\n' "$OUTPUT" | grep -qE '^[[:space:]]*`?<promise>COMPLETE</promise>`?[[:space:]]*$'; then
    if [ "$TURN_MODE" = plan ]; then
      echo "!! the PLAN turn emitted the completion token — IGNORED (a plan turn writes a plan, it never completes a tasklist)."
    else
      echo ""
      echo "Chief completed all tasks! (iteration $i)"
      live_set "$LIVE" phase=complete passing="$(_passes)" total="$(_total)" story=
      exit 0
    fi
  fi

  # Session/usage limit -> sleep until reset and resume (a blocked turn is free).
  # Checked BEFORE the progress/stall accounting below so a limit can never be
  # counted as a no-progress iteration.
  if _is_rate_limit "$OUTPUT" "$TOOL_RC"; then
    if _rate_limit_wait "$OUTPUT"; then
      i=$((i-1))   # the blocked turn doesn't consume the budget
      continue
    fi
    exit 2
  fi

  # PLAN TURN OUTCOME. Placed AFTER the limit check on purpose — a plan turn blocked
  # by a usage limit produced no artifact for a reason that has nothing to do with the
  # plan, and calling that PLAN-INVALID would burn an actionable state on a quota
  # window. Two outcomes, no third:
  #
  #   valid   — the artifact is on disk and parses. The plan is progress, so the stall
  #             counter resets, and the loop restarts at the top: the same story now
  #             reads plan-ready and the NEXT turn implements it. (The iteration
  #             boundary hook is skipped for this one turn — it re-integrates base
  #             under a branch a plan turn did not touch, so there is nothing to
  #             re-integrate and one turn of drift costs nothing.)
  #   invalid — exit 4, ONE plan turn per story, no retry-until-it-parses. Falling
  #             through to implementation is the one thing this phase must never do.
  if [ "$TURN_MODE" = plan ]; then
    if _plan_valid "$TURN_PLAN" "$TURN_STORY"; then
      echo ""
      echo "Iteration $i: PLAN ready for $TURN_STORY -> $TURN_PLAN"
      live_set "$LIVE" phase=plan-ready stall=0 story="$TURN_STORY"
      event_emit story.plan-ready name="${CHIEF_TASKLIST:-}" story="$TURN_STORY" \
        state=running detail="iteration $i — plan artifact written and schema-valid"
      stall=0
      # Re-baseline: a plan turn is not a code turn, and the next iteration's progress
      # check must not read anything it happened to touch as implementation progress.
      prev_pass=$(_passes); prev_head=$(_head)
      continue
    fi
    echo ""
    echo "Chief's PLAN turn did not produce a well-formed plan for $TURN_STORY."
    echo "Expected (schema in docs/plan-review.md): $TURN_PLAN"
    if [ -s "$TURN_PLAN" ]; then
      echo "The file exists but fails the schema check — story/summary/changes[]/verification[] must all be present and non-empty, and .story must equal $TURN_STORY."
    else
      echo "No artifact was written at that path."
    fi
    echo "Exit 4 = PLAN-INVALID — an actionable stop, NOT a stall: the branch is untouched and re-running asks for the plan again."
    live_set "$LIVE" phase=plan-invalid iter="$i" story="$TURN_STORY" \
      passing="$(_passes)" total="$(_total)"
    # STORY scope here; the driver emits the TASKLIST-scope terminal event when it
    # sees exit 4. Two scopes, one transition — same split as story.passed vs the
    # tasklist.* terminals, so a consumer counting tasklist outcomes never double-counts.
    event_emit story.plan-invalid name="${CHIEF_TASKLIST:-}" story="$TURN_STORY" \
      state=failed detail="the plan turn wrote no well-formed artifact at $TURN_PLAN"
    exit 4
  fi

  # THE EVIDENCE RULE, AT THE BOUNDARY (_measure_boundary above). Runs BEFORE the
  # progress accounting so the numbers this iteration reports — and the liveliness
  # record built from them — are the ones that survived the check, and so a story
  # demoted here is genuinely missing progress rather than progress already banked.
  _measure_boundary "$i"

  # Progress check: did a story pass, or a new commit land?
  now_pass=$(_passes); now_head=$(_head)
  if [ "$now_pass" -gt "$prev_pass" ] || [ "$now_head" != "$prev_head" ]; then
    stall=0
    echo "Iteration $i: progress ($now_pass/$(_total) passing). Continuing..."
    live_set "$LIVE" phase=agent-turn stall=0 stall_limit="$STALL_LIMIT" \
      passing="$now_pass" total="$(_total)" story="$(_story)"
  else
    stall=$((stall+1))
    echo "Iteration $i: no progress (stall $stall/$STALL_LIMIT)."
    # BETWEEN iterations, and only here: the phase is the verdict on the boundary just
    # reached, and the next iteration's first write (top of the loop) takes it back.
    # The budget travels with the count so a reader can tell "1 of 2" from "2 of 2"
    # without knowing this run's $STALL_LIMIT.
    live_set "$LIVE" phase=stalled stall="$stall" stall_limit="$STALL_LIMIT"
  fi
  prev_pass=$now_pass; prev_head=$now_head

  # ITERATION-BOUNDARY HOOK. $CHIEF_ITER_HOOK is a command the driver wants run
  # BETWEEN iterations — today, re-integrating the base branch that sibling merges
  # keep advancing under this branch (engine/driver.sh --integrate-base). It runs
  # only here, so it can never touch the tree while a turn is in flight, and its
  # failure is never fatal: integration is best-effort, the merge phase is the floor.
  if [ -n "${CHIEF_ITER_HOOK:-}" ]; then
    # ITS OWN PHASE, because this is the stretch that made `stalled` a lie in the
    # field: the hook re-enters driver.sh --integrate-base, which fetches, rebases and
    # queues behind the merge lock a sibling worker may hold for the length of a verify
    # gate. On 2026-08-17 tasklist 99 spent ~25 minutes in exactly this window and
    # displayed the previous boundary's `stalled` for all of it.
    live_set "$LIVE" phase=integrating
    eval "$CHIEF_ITER_HOOK" || true
    # A hook may rewrite HEAD (a clean rebase does). Re-baseline, or the NEXT
    # iteration would read the hook's rewrite as the agent having made progress.
    prev_head=$(_head)
  fi

  # Give up only after spending the budget AND stalling, or at the hard ceiling.
  if [ "$stall" -ge "$STALL_LIMIT" ] && [ "$i" -ge "$MAX_ITERATIONS" ]; then
    echo ""
    echo "Chief stalled $stall iterations after its $MAX_ITERATIONS-iter budget without completing. Stopping."
    echo "Check $PROGRESS_FILE for status."
    # The one place `stalled` is a statement about now: the loop is over BECAUSE it
    # stalled. Published explicitly so the record does not exit carrying whatever the
    # boundary hook above left behind.
    live_set "$LIVE" phase=stalled iter="$i" stall="$stall" stall_limit="$STALL_LIMIT" \
      passing="$(_passes)" total="$(_total)"
    exit 1
  fi
  if [ "$i" -ge "$HARD_MAX" ]; then
    echo ""
    echo "Chief hit the hard iteration ceiling ($HARD_MAX) without completing. Stopping."
    echo "Check $PROGRESS_FILE for status."
    exit 1
  fi
  sleep 2
done
