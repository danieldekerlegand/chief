#!/usr/bin/env bash
# engine/review.sh — the HUMAN half of the plan checkpoint (docs/plan-review.md).
#
# US-1 gave the plan phase an artifact. This is the gate that artifact has to clear
# before a single line of code is written: a person reads the plan, and only an
# APPROVED plan reaches implementation.
#
# THE REVIEW SURFACE IS ADOPTED, NOT BUILT. plannotator (Apache-2.0 OR MIT,
# github.com/backnotprop/plannotator) is a local browser annotation surface that
# already ships a one-shot APPROVAL GATE of exactly this shape:
#
#     plannotator annotate <file.md> --gate --json --require-approval \
#                 --result-file <out.json>
#
#   · --result-file (and stdout) carry ONE line of JSON:
#       {"decision":"approved"}  ·  {"decision":"approved","feedback":"…"}
#       {"decision":"annotated","feedback":"…"}  ·  {"decision":"dismissed"}
#   · exit 0 = approval granted, 1 = annotations submitted or dismissed,
#     2 = bad flags / startup failure / result publication failure.
#
# NOTHING OF IT IS VENDORED OR REIMPLEMENTED HERE. Chief renders its plan artifact
# to markdown, invokes that documented command, and reads that documented JSON.
# $CHIEF_REVIEWER may name a different binary — but the contract is the one above:
# a reviewer chief can talk to is a program that speaks plannotator's annotate gate.
# That is also what makes the gate testable without a browser (test/plan-review.sh
# scripts a fake reviewer against the same five flags).
#
# WHAT CHIEF ADDS, AND WHY IT IS ONLY THIS:
#
#   · ABSENCE IS DETECTED, NEVER ASSUMED. No reviewer on PATH, a host that has
#     nobody in front of it, or a review window that elapses is not an error and is
#     emphatically not an approval — it PARKS the tasklist (agent.sh exit 5 ->
#     AWAITING-REVIEW), reusing the operator-pause drain semantics: branch and
#     worktree kept, scheduler free to run its siblings, `chief run` resumes it.
#     Chief's unattended character survives because the DEFAULT path — plan review
#     off — never reaches this file at all, and the enabled path degrades to a park
#     rather than to a block or a silent proceed.
#
#   · THE VERDICT IS A FILE, next to the plan, under $STATE_DIR/plans/. An approval
#     given once is never asked for twice — across process death, a usage-limit
#     sleep, an operator pause, or a rebuilt worktree (driver.sh's plan_sync mirrors
#     *.json in both directions, which is why the verdict is JSON and not markdown).
#
#   · THE VERDICT IS BOUND TO THE PLAN IT APPROVED, by checksum. A story re-planned
#     after annotations cannot inherit the approval of the plan it replaced — the
#     one way a "resume without re-asking" optimisation could wave through code
#     nobody agreed to.
#
# Bash 3.2 only: no associative arrays, no `declare -A`, no ${var^^}.

# --- knobs (all optional; every default is the unattended-safe one) -----------
#   CHIEF_REVIEWER            the reviewer program            (default: plannotator)
#   CHIEF_REVIEW_TIMEOUT      seconds to wait for a verdict   (default: 900)
#                             0 parks WITHOUT launching a reviewer — the pure-CI
#                             setting, and the honest way to say "nobody is here".
#   CHIEF_REVIEW_MAX_ROUNDS   annotate -> re-plan rounds per story (default: 3)
#   CHIEF_REVIEW_NONINTERACTIVE=1  treat the host as having no reviewer, same as $CI
CHIEF_REVIEWER="${CHIEF_REVIEWER:-plannotator}"
CHIEF_REVIEW_TIMEOUT="${CHIEF_REVIEW_TIMEOUT:-900}"
CHIEF_REVIEW_MAX_ROUNDS="${CHIEF_REVIEW_MAX_ROUNDS:-3}"

# review_file_for PLAN -> the verdict artifact that goes with a plan artifact.
# One derivation, used by agent.sh and by every function below, so the two files
# can never be paired by two different rules.
review_file_for() { printf '%s' "${1%.plan.json}.review.json"; }

# review_plan_id PLAN -> a short change-detector for the plan's bytes.
# cksum is POSIX and everywhere; this is a staleness guard, not a security boundary.
review_plan_id() { cksum < "$1" 2>/dev/null | tr -s ' ' '-' | tr -d ' \n'; }

# review_unavailable_reason -> a human sentence when no reviewer can be reached,
# empty when one can be launched. Checked BEFORE anything is rendered or spawned:
# the whole point is that an absent reviewer costs a run nothing.
review_unavailable_reason() {
  case "$CHIEF_REVIEW_TIMEOUT" in
    ''|*[!0-9]*) printf 'CHIEF_REVIEW_TIMEOUT is not a whole number of seconds'; return 0 ;;
    0) printf 'CHIEF_REVIEW_TIMEOUT=0 — this host is configured to never wait for a reviewer'; return 0 ;;
  esac
  if [ -n "${CHIEF_REVIEW_NONINTERACTIVE:-}" ] || [ -n "${CI:-}" ]; then
    printf 'the host is non-interactive (%s) — a browser review surface has nobody in front of it' \
      "$([ -n "${CHIEF_REVIEW_NONINTERACTIVE:-}" ] && printf 'CHIEF_REVIEW_NONINTERACTIVE' || printf 'CI')"
    return 0
  fi
  command -v "$CHIEF_REVIEWER" >/dev/null 2>&1 && return 0
  printf "'%s' is not on PATH — install it (https://plannotator.ai) or set \$CHIEF_REVIEWER" "$CHIEF_REVIEWER"
}

# review_approved REVIEW PLAN — is there an approval, and is it for THIS plan?
# Silent. Both halves matter: the decision must be `approved`, and the plan id it
# was given for must still be the plan on disk.
review_approved() {
  [ -s "${1:-}" ] && [ -s "${2:-}" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e --arg id "$(review_plan_id "$2")" \
    '(.decision == "approved") and (.plan == $id)' "$1" >/dev/null 2>&1
}

# review_rounds REVIEW -> how many annotate -> re-plan rounds this story has spent.
review_rounds() {
  [ -s "${1:-}" ] || { printf '0'; return 0; }
  jq -r '[(.rounds // [])[] | select(.decision == "annotated")] | length' "$1" 2>/dev/null || printf '0'
}

# review_markdown PLAN REVIEW OUT — render the plan as the document a human reads.
#
# plannotator annotates MARKDOWN; chief's artifact is JSON. Rendering here (rather
# than handing over raw JSON) is what makes the annotation land on a sentence a
# person can argue with. Every round of prior feedback is rendered with it, so a
# reviewer looking at round 2 can see what they asked for in round 1 and whether
# the re-plan actually answered it.
review_markdown() {
  local plan="$1" rev="$2" out="$3" prior='[]'
  [ -s "$rev" ] && prior="$(jq -c '.rounds // []' "$rev" 2>/dev/null || echo '[]')"
  jq -r --argjson prior "$prior" '
    def cell: (tostring | gsub("\\|"; "\\|") | gsub("\n"; " "));
    def block: if type == "string" then .
               elif type == "array" then (map("- " + (if type == "string" then . else tojson end)) | join("\n"))
               else "```json\n" + (tojson) + "\n```" end;
    "# Plan for " + .story + " — " + .summary,
    "",
    "Approve to let the agent implement exactly this. Annotate to send it back:",
    "your notes become the brief for the next plan, and no code is written until a",
    "plan is approved.",
    "",
    "## Changes",
    "",
    "| file | action | what the change is |",
    "|---|---|---|",
    (.changes[] | "| `" + (.path | cell) + "` | " + (.action | cell) + " | " + (.change | cell) + " |"),
    "",
    "## Verification the agent commits to running",
    "",
    (.verification[] | "- **" + (.phase | cell) + "** — `" + (.command | cell) + "`"),
    "",
    (del(.story, .summary, .changes, .verification) | to_entries[]
      | "## " + .key, "", (.value | block), ""),
    ($prior | to_entries[]
      | "## Previous round " + ((.key + 1) | tostring) + " — " + .value.decision, "",
        (.value.feedback // "(no notes)"), "")
  ' "$plan" > "$out" 2>/dev/null
}

# review_record REVIEW STORY PLAN_ID DECISION FEEDBACK — persist a verdict.
# APPEND-ONLY on `rounds`: the annotation history is the reviewer's side of the
# conversation and is what the next plan turn is briefed with, so nothing is ever
# overwritten. `.decision`/`.plan` carry the LATEST verdict, which is what
# review_approved() reads.
review_record() {
  local rev="$1" tmp old='{}'
  tmp="$rev.tmp.$$"
  [ -s "$rev" ] && old="$(jq -c '.' "$rev" 2>/dev/null || echo '{}')"
  jq -n --argjson old "$old" \
        --arg story "$2" --arg plan "$3" --arg decision "$4" --arg feedback "$5" \
        --arg reviewer "$CHIEF_REVIEWER" --arg at "$(date +%s)" '
    $old as $o
    | { story: $story, reviewer: $reviewer, decision: $decision, plan: $plan,
        at: ($at | tonumber),
        rounds: (($o.rounds // []) + [{ round: ((($o.rounds // []) | length) + 1),
                                        decision: $decision, plan: $plan,
                                        feedback: $feedback, at: ($at | tonumber) }]) }
  ' > "$tmp" 2>/dev/null && mv "$tmp" "$rev" || rm -f "$tmp"
  return 0
}

# review_feedback PLAN -> the annotations to brief the next plan turn with, as
# markdown. Empty when there are none. Takes the PLAN path (not the verdict's) so
# the caller — _plan_prompt, which only ever knows where the plan goes — never has
# to know how the two files are paired.
review_feedback() {
  set -- "$(review_file_for "${1:-}")"
  [ -s "$1" ] || return 0
  jq -r '[(.rounds // [])[] | select(.decision == "annotated" and ((.feedback // "") | length) > 0)]
         | to_entries[]
         | "### Round " + ((.key + 1) | tostring) + "\n\n" + .value.feedback' "$1" 2>/dev/null
}

# review_ask MD RESULT -> the reviewer's decision word on stdout; non-zero when no
# decision was reached at all.
#
# BOUNDED IN WALL-CLOCK BY US, not by the reviewer. plannotator's own gate is
# deliberately long-running (its shipped hooks use a 4-day timeout) because a human
# review is; chief cannot hold a worker slot on that, and bash 3.2 on macOS has no
# `timeout(1)`. So: run it in the background, poll, and TERM it when the window is
# spent. A killed reviewer is a park, never an approval.
review_ask() {
  local md="$1" result="$2" rpid rc=0 waited=0 dec="" had_m=""
  rm -f "$result" 2>/dev/null || true
  # JOB CONTROL, on for exactly one spawn. A reviewer is a PROCESS TREE — plannotator
  # runs a local server and opens a browser — and a background job in a script shares
  # the shell's process group, so killing $! on timeout would leave the tree behind
  # holding a port. `set -m` gives this one child its own process group, which is
  # what makes `kill -- -$rpid` reach all of it. Restored immediately either way.
  case "$-" in *m*) had_m=1 ;; esac
  set -m
  "$CHIEF_REVIEWER" annotate "$md" --gate --json --require-approval \
    --result-file "$result" >"$result.log" 2>&1 &
  rpid=$!
  [ -n "$had_m" ] || set +m
  while kill -0 "$rpid" 2>/dev/null; do
    if [ "$waited" -ge "$CHIEF_REVIEW_TIMEOUT" ]; then
      kill -TERM -- "-$rpid" 2>/dev/null || kill -TERM "$rpid" 2>/dev/null || true
      sleep 1
      kill -KILL -- "-$rpid" 2>/dev/null || kill -KILL "$rpid" 2>/dev/null || true
      wait "$rpid" 2>/dev/null || true
      return 2
    fi
    live_set "${LIVE:-}" phase=review-wait
    sleep 2; waited=$(( waited + 2 ))
  done
  wait "$rpid" 2>/dev/null || rc=$?
  # The RESULT FILE is the contract; the exit code is only the tie-breaker for a
  # reviewer that produced no file. --require-approval makes 0 mean "approved"
  # unambiguously, which is the one thing worth trusting a bare status for.
  dec="$(jq -r '.decision // empty' "$result" 2>/dev/null || echo)"
  [ -z "$dec" ] && dec="$(jq -r '.decision // empty' "$result.log" 2>/dev/null || echo)"
  if [ -z "$dec" ]; then
    [ "$rc" = "0" ] || return 2
    dec=approved
  fi
  printf '%s' "$dec"
}

# review_verdict_feedback RESULT -> the annotation text the reviewer submitted.
review_verdict_feedback() {
  jq -r '.feedback // .reason // empty' "$1" 2>/dev/null || echo
}

# review_gate STORY PLAN -> what this iteration must do next. THE ONE ENTRY POINT
# agent.sh calls; everything above it is a part of this decision.
#
#   0  APPROVED — implement exactly this plan.
#   1  RE-PLAN  — the reviewer sent it back; the annotations are recorded, the plan
#                 artifact is gone, and the next turn writes a new one briefed with
#                 them. Bounded by $CHIEF_REVIEW_MAX_ROUNDS.
#   2  PARK     — no approval is obtainable here (agent.sh exits 5 -> AWAITING-REVIEW).
#
# ALL THREE ARE DERIVED FROM DISK, exactly like the plan/implement choice in US-1:
# the plan artifact's bytes and the verdict file beside it. A resumed run re-derives
# the same answer, which is the whole of AC-4 — an approval already given is read,
# never re-asked.
review_gate() {
  local story="$1" plan="$2" rev md result why dec fb rounds pid
  rev="$(review_file_for "$plan")"
  pid="$(review_plan_id "$plan")"
  if review_approved "$rev" "$plan"; then
    echo "Plan review: $story was already APPROVED ($rev) — implementing that plan, not re-asking."
    return 0
  fi
  # ABSENCE, checked before anything is rendered or spawned. Nothing is recorded:
  # no one reviewed anything, and a run that keeps finding no reviewer must not
  # grow an audit trail of its own absence.
  why="$(review_unavailable_reason)"
  if [ -n "$why" ]; then
    echo "Plan review: no reviewer for $story — $why"
    return 2
  fi
  rounds="$(review_rounds "$rev")"
  md="${plan%.plan.json}.plan.md"
  result="${plan%.plan.json}.verdict.raw.json"
  review_markdown "$plan" "$rev" "$md"
  echo "Plan review: handing $md to '$CHIEF_REVIEWER' — round $(( rounds + 1 ))/$CHIEF_REVIEW_MAX_ROUNDS, waiting up to ${CHIEF_REVIEW_TIMEOUT}s."
  dec="$(review_ask "$md" "$result")" || dec=""
  fb="$(review_verdict_feedback "$result")"
  case "$dec" in
    approved)
      review_record "$rev" "$story" "$pid" approved "$fb"
      echo "Plan review: APPROVED${fb:+ — \"$fb\"}. Implementing."
      return 0
      ;;
    annotated|block|deny|denied|rejected)
      # The plan is REMOVED with the annotations recorded, so the next iteration's
      # turn-mode check (which asks only "is a valid plan on disk?") re-derives
      # "plan turn" by itself — one state machine, not two.
      review_record "$rev" "$story" "$pid" annotated "$fb"
      rm -f "$plan" 2>/dev/null || true
      rounds="$(review_rounds "$rev")"
      if [ "$rounds" -ge "$CHIEF_REVIEW_MAX_ROUNDS" ]; then
        echo "Plan review: sent back again, and the retry budget is spent ($rounds/$CHIEF_REVIEW_MAX_ROUNDS rounds)."
        echo "Plan review: parking rather than spending another turn on a plan the reviewer keeps rejecting — the story text is the thing to fix."
        return 2
      fi
      echo "Plan review: SENT BACK with annotations (round $rounds/$CHIEF_REVIEW_MAX_ROUNDS) — re-planning with them in context."
      return 1
      ;;
    *)
      review_record "$rev" "$story" "$pid" "${dec:-no-verdict}" "$fb"
      echo "Plan review: no approval for $story — the reviewer returned '${dec:-nothing within ${CHIEF_REVIEW_TIMEOUT}s}'. The plan is kept; a re-run asks again."
      return 2
      ;;
  esac
}
