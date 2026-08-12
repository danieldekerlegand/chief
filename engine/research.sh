#!/usr/bin/env bash
# engine/research.sh — the RESEARCH PHASE: one bounded, up-front mapping of the code
# a tasklist is about to change, persisted as a structured document every story then
# READS instead of re-deriving.
#
# WHY THIS FILE EXISTS. Chief's agent starts each story cold: it gets the tasklist's
# acceptance criteria and whatever it greps during that iteration. So a five-story
# tasklist re-derives the same mental model of the codebase five times — and can
# mis-derive it five different ways. A wrong model is the most expensive error an
# agent makes, because it is made BEFORE a line is written and every line after it
# inherits the mistake. Running the mapping ONCE, up front, and reviewing it is the
# highest-leverage checkpoint available: correcting research is orders of magnitude
# cheaper than correcting the code it produced.
#
# It is also a COMPACTION artifact. Rediscovery is what fills an iteration's context
# window with greps and file dumps; a story that opens with a validated map spends
# its window on the change instead.
#
# FOUR RULES IT WILL NOT BREAK.
#   1. A MAP, NOT PROSE. The document has REQUIRED SECTIONS (research_sections) and is
#      machine-validated against them. An essay that answers none of them is a failed
#      research phase, not a research phase with a weak document.
#   2. STRUCTURED SUMMARIES, NEVER RAW TOOL OUTPUT. The searching happens in SUB-AGENT
#      contexts; what comes back to the parent is a summary in a fixed shape. The greps
#      and file dumps that produced it stay in the sub-agent's window — that isolation
#      is the entire point, and getting a sub-agent to honour it is the part that needs
#      saying explicitly, so the prompt says it explicitly.
#   3. BOUNDED, AND LOUD WHEN IT FAILS. The phase costs at most
#      $CHIEF_RESEARCH_MAX_ATTEMPTS provider turns (default 2). Exhausting them is a
#      DISTINCT, actionable state (agent.sh exits 4 -> the driver's RESEARCH-FAILED),
#      never a silent fall-through into implementation on a map that isn't there.
#   4. PRODUCED ONCE, REUSED THEREAFTER. A valid document at the durable path is never
#      regenerated — not by the next story, not by a resumed run. A human may edit it,
#      and the edit is what subsequent stories consume.
#
# CONSUMED BY. engine/agent.sh (dispatch + validation + promotion to the durable path)
# and engine/driver.sh (the durable path itself, and the RESEARCH-FAILED status).
#
# bash 3.2: no associative arrays, no mapfile, no ${var^^}, no process substitution.

# Stamped in the document header. Bump only when the REQUIRED SECTIONS change — a
# consumer (or a human re-reading a stale document) needs to know which contract it
# was written against.
CHIEF_RESEARCH_SCHEMA="chief.research/1"

# research_sections -> the REQUIRED section headings, one per line, in document order.
#
# This list IS the contract. Each answers a question a cold story would otherwise
# answer for itself, badly:
#   Target files       — what to open, and WHY each one matters (not just a file list)
#   Data flow          — how control/data actually moves through them
#   Point of insertion — the root-cause hypothesis, or where the new code goes
#   Conventions        — the local idiom the implementation has to match
research_sections() {
  printf '## Target files\n## Data flow\n## Point of insertion\n## Conventions\n'
}

# _research_body FILE HEADING -> the section's body on stdout (empty if absent).
#
# Heading match is a case-insensitive PREFIX on the line, not equality: a model that
# writes "## Target files (engine/)" has satisfied the contract, and failing it for
# a parenthetical would burn a whole research turn on formatting. Compared with
# substr()/tolower() rather than a regex so a heading is never read as a pattern.
#
# LC_ALL=C IS LOAD-BEARING, not tidiness. A research document is prose about code and
# is full of em-dashes and arrows; BSD awk (macOS) aborts with "illegal byte sequence"
# the moment tolower()/substr() meet a multi-byte character in a UTF-8 locale. Byte
# semantics make that impossible, and cost nothing here because every heading we
# compare against is ASCII. Without it, validation fails on exactly the documents
# that are worth keeping.
_research_body() {
  LC_ALL=C awk -v h="$2" '
    BEGIN { n = length(h); lh = tolower(h) }
    tolower(substr($0, 1, n)) == lh { inx = 1; next }
    substr($0, 1, 3) == "## " { inx = 0 }
    inx { print }
  ' "$1" 2>/dev/null
}

# research_missing FILE -> the required headings the document does NOT satisfy, one
# per line (empty output = valid). A heading that is present but has an EMPTY body
# counts as missing: a skeleton of four headings is the exact failure mode a
# section-presence check invites, and it is worse than no document at all because it
# passes validation while telling a story nothing.
#
# A missing/unreadable file is "everything is missing" — which is also what makes
# this the right thing to feed back into a retry prompt.
research_missing() {
  local f="${1:-}" h
  if [ -z "$f" ] || [ ! -r "$f" ]; then research_sections; return 0; fi
  research_sections | while IFS= read -r h; do
    [ -n "$h" ] || continue
    _research_body "$f" "$h" | LC_ALL=C grep -q '[^[:space:]]' || printf '%s\n' "$h"
  done
  return 0
}

# research_validate FILE — 0 when the document satisfies every required section.
research_validate() {
  [ -z "$(research_missing "${1:-}")" ]
}

# research_enabled PRD_JSON — 0 when this tasklist should pay for a research phase.
#
# OPT-IN, AND DELIBERATELY SO. Roughly two in five tasklists are one-shots — a doc
# fix, a version bump, a one-line guard — whose whole cost is smaller than the
# research turn that would precede it. Making the phase universal would tax exactly
# the tasklists that have nothing to learn. Precedence, most specific first:
#   $CHIEF_RESEARCH=1|0    the operator's override for this run, both directions
#   "research": true|false in the tasklist — the author's per-tasklist choice
#   (neither)              off
research_enabled() {
  local prd="${1:-}" flag
  case "${CHIEF_RESEARCH:-}" in
    0|off|no|false)  return 1 ;;
    1|on|yes|true)   return 0 ;;
  esac
  [ -n "$prd" ] && [ -r "$prd" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  flag="$(jq -r 'if has("research") then (.research | tostring) else "" end' "$prd" 2>/dev/null || echo "")"
  case "$flag" in
    true)  return 0 ;;
    *)     return 1 ;;
  esac
}

# research_prompt PRD_JSON DOC_REL [MISSING] -> the research turn's prompt on stdout.
#
# DOC_REL is the document's path RELATIVE TO THE WORKTREE — the model is told to stay
# inside its worktree, so it must never be handed the absolute durable path (agent.sh
# promotes the file there afterwards).
#
# MISSING, when non-empty, is the newline-separated output of research_missing from a
# previous attempt. A retry that just repeats the original instructions tends to
# reproduce the original omission; naming the sections that came back empty is what
# makes the second attempt worth its cost.
research_prompt() {
  local prd="${1:-}" doc="${2:-.chief/state/research.md}" missing="${3:-}"
  local name stories
  name="$(jq -r '.branchName // .project // "this tasklist"' "$prd" 2>/dev/null || echo "this tasklist")"
  stories="$(jq -r '
      (.description // "") as $d
      | "TASKLIST GOAL\n" + $d + "\n\nUSER STORIES THIS RESEARCH MUST SERVE\n"
      + ([ .userStories[]? | "- [\(.id)] \(.title)\n" + ([ .acceptanceCriteria[]? | "    · \(.)" ] | join("\n")) ] | join("\n"))
    ' "$prd" 2>/dev/null || echo "")"

  cat <<PROMPT_HEAD
# RESEARCH PHASE — map the code before anything is written

You are NOT implementing anything this turn. You are producing ONE artifact: a
structured research document at \`$doc\` that every subsequent story in this
tasklist will read INSTEAD of rediscovering the codebase for itself.

Write no source code. Change no source file. Make no commit. The only file you
create or modify is \`$doc\`.

$stories

## How to do the research: delegate, then synthesize

Do the searching in SUB-AGENT contexts, not in your own. Split the question into a
few independent angles (for example: where the change lands · how the surrounding
data/control flow works · what conventions and tests already exist around it) and
dispatch one sub-agent per angle.

Require each sub-agent to return a STRUCTURED SUMMARY and nothing else:

    FILES:       path — one line on why it matters (repeat)
    FLOW:        the call/data path it observed, as ordered steps
    CONVENTIONS: the local idioms it saw (naming, error handling, test shape)
    UNKNOWNS:    what it could not determine, stated plainly

A sub-agent must NOT return raw tool output — no pasted grep results, no file
dumps, no directory listings. Those belong in the sub-agent's own context; only
the summary comes back to you. If a sub-agent returns raw output anyway, summarize
it yourself before it enters the document.

Then SYNTHESIZE the summaries into the document below. The document is a map a
future reader can act on, not a transcript of how you searched.

## Required document format

Write \`$doc\` with EXACTLY these H2 sections, in this order. Every section must
have real content — an empty or placeholder section fails this phase and costs
another turn.

    # Research — $name
    <!-- $CHIEF_RESEARCH_SCHEMA -->

    ## Target files
    Each file the implementation will touch or must understand, one per line, with
    WHY it is relevant. A bare file list is not enough.

    ## Data flow
    How control and data actually move through those files — entry points, the
    ordered call path, what state is read and written, where the seams are.

    ## Point of insertion
    For a fix: the root-cause hypothesis, stated as a claim that could be wrong.
    For a feature: exactly where the new code attaches, and what it must not
    disturb. Name the function/line where it belongs.

    ## Conventions
    The existing idioms the implementation MUST follow — naming, error handling,
    logging, the shape of nearby tests, portability constraints. Cite the file you
    learned each one from.

Be concrete and cite paths. Prefer what you verified over what you assumed, and
say which is which. If something stayed unknown after the sub-agents reported,
write it down as unknown rather than guessing — a named gap is useful, an
invented answer is not.
PROMPT_HEAD

  if [ -n "$missing" ]; then
    printf '\n## Retry — the previous attempt left these sections missing or empty\n\n'
    printf '%s\n' "$missing" | sed 's/^/    /'
    printf '\nFill them in. Keep whatever the previous attempt got right.\n'
  fi
  return 0
}
