#!/usr/bin/env bash
# engine/cigate.sh — A GATE THAT DID NOT RUN IS NOT A GATE THAT PASSED.
#
# Measured 2026-08-25 across this portfolio:
#
#   praxis      PUBLIC    success  2026-08-15
#   pinakes     PUBLIC    success  2026-08-25
#   talos       PRIVATE   failure  2026-08-24
#   cuneiform   PRIVATE   failure  2026-08-25
#   vita        PRIVATE   failure  2026-08-25
#
# Every private repo was dead, and none of the three failures was a code problem —
# all were byte-identical: "The job was not started because recent account payments
# have failed or your spending limit needs to be increased." GitHub Actions minutes
# are FREE for public repositories and BILLED for private ones, so an account-level
# block killed CI on every private repo while the public ones kept working and kept
# looking normal. Nothing anywhere said so, for an unknown period.
#
# This is the generalized form of two failures already recorded here. `amphora`
# merged three tasklists against a `.chief/verify.sh` that ran one unrelated check
# and then `exit 0`. `145-forge-harness-gate` was written because "a green gate that
# cannot go red is worse than no gate." Both concern a gate that CANNOT FAIL. This
# one is worse: a gate that never EXECUTES is, from every surface chief offers,
# indistinguishable from one that ran and passed.
#
# SCOPE. chief does not become a CI client. Nothing here is on the merge critical
# path, nothing here fails a merge, and nothing here fails because a third-party
# service is down. What it does is refuse to let ABSENCE read as SUCCESS — the same
# distinction `.chief/verify.sh` already draws locally between a skipped check and a
# passing one, pointed at the gate a repo DECLARES but does not run.
#
# THE LOUD-SKIP DISCIPLINE is the whole safety argument. A run that could not
# measure — no `gh`, no remote, no network, an auth failure — is UNKNOWN, and
# UNKNOWN is stated as unknown. It is never rounded to a pass, because rounding an
# unmeasured gate up to green is the exact mistake this module exists to end.
#
# bash 3.2: no associative arrays, no mapfile. `jq` is required; `gh` is optional
# and its absence is a verdict, not an error.

# --- the vocabulary, stated once ---------------------------------------------
# Three states for a gate, and two non-findings. Every surface that reports a gate
# uses these labels — a second vocabulary elsewhere would let the same repo be
# described two ways. Tokens (no spaces) travel in records; labels are what a human
# reads.
CIGATE_PASSED=passed        # RAN AND PASSED
CIGATE_FAILED=failed        # RAN AND FAILED
CIGATE_DEAD=dead            # DID NOT RUN   — absent, never started, or not covering HEAD
CIGATE_UNKNOWN=unknown      # could not measure. NOT a pass.
CIGATE_NONE=none            # no CI declared at all. NOT a finding.

# The one DID-NOT-RUN reason that is a different conversation, so the report has to
# be able to find it again: a trigger mismatch is fixed in the workflow file, and
# every other dead gate here is fixed somewhere else entirely (usually billing).
# A leading tag on the detail, written in exactly one place (cigate_row).
CIGATE_MISMATCH_TAG="trigger mismatch: "

CIGATE_WORKFLOW_DIR=".github/workflows"
CIGATE_RUN_LIMIT="${CIGATE_RUN_LIMIT:-100}"   # how far back one `gh run list` looks

# cigate_label TOKEN — the operator-facing name of a state.
cigate_label() {
  case "$1" in
    "$CIGATE_PASSED")  printf 'RAN AND PASSED\n' ;;
    "$CIGATE_FAILED")  printf 'RAN AND FAILED\n' ;;
    "$CIGATE_DEAD")    printf 'DID NOT RUN\n' ;;
    "$CIGATE_UNKNOWN") printf 'UNKNOWN\n' ;;
    "$CIGATE_NONE")    printf 'NO GATE DECLARED\n' ;;
    *)                 printf 'UNKNOWN\n' ;;
  esac
}

# --- what the repo DECLARES (offline, textual) -------------------------------

# cigate_workflows REPO — the workflow files this repo declares, one per line.
# Empty output = no CI declared, which is a legitimate state and never a finding.
cigate_workflows() {
  local f
  for f in "$1/$CIGATE_WORKFLOW_DIR"/*.yml "$1/$CIGATE_WORKFLOW_DIR"/*.yaml; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

# cigate_workflow_name FILE — the name GitHub will show for this workflow: its
# top-level `name:` if it has one, else the repo-relative path (which is what the
# API reports for an unnamed workflow). Textual, because a YAML dependency in the
# engine to read one scalar is a dependency chief would carry forever.
cigate_workflow_name() {
  local n
  n="$(LC_ALL=C sed -n 's/^name:[[:space:]]*//p' "$1" 2>/dev/null | head -1)"
  n="${n%\"}"; n="${n#\"}"; n="${n%\'}"; n="${n#\'}"
  n="${n%"${n##*[![:space:]]}"}"
  if [ -n "$n" ]; then printf '%s\n' "$n"
  else printf '%s/%s\n' "$CIGATE_WORKFLOW_DIR" "$(basename "$1")"; fi
}

# cigate_slug REPO — "owner/name" from the origin remote, or empty. No remote and
# no GitHub remote both mean the same thing here: nothing to ask.
cigate_slug() {
  local url
  url="$(git -C "$1" config --get remote.origin.url 2>/dev/null)"
  [ -n "$url" ] || return 1
  url="${url%.git}"
  case "$url" in
    *github.com[:/]*) url="${url#*github.com}"; printf '%s\n' "${url#[:/]}" ;;
    *) return 1 ;;
  esac
}

# --- what actually happened (one network call, off every critical path) -------

# cigate_run_records SLUG — the recent runs as TSV, NEWEST FIRST:
#   workflowName<TAB>runId<TAB>status<TAB>conclusion<TAB>headSha<TAB>createdAt
# Non-zero = COULD NOT MEASURE. The caller turns that into UNKNOWN and says so.
cigate_run_records() {
  local raw
  command -v gh >/dev/null 2>&1 || return 1
  raw="$(gh run list --repo "$1" --limit "$CIGATE_RUN_LIMIT" \
           --json workflowName,databaseId,status,conclusion,headSha,createdAt 2>/dev/null)" || return 1
  [ -n "$raw" ] || return 1
  printf '%s' "$raw" | jq -r '.[] | [.workflowName, (.databaseId|tostring), (.status // "-"),
                                     (.conclusion // "-"), (.headSha // "-"), (.createdAt // "-")]
                              | @tsv' 2>/dev/null || return 1
}

# cigate_started SLUG RUN_ID — did this run EXECUTE anything?
#
# The discriminator, and it is not a guess: a billing-blocked run completes in ~4
# seconds with jobs present, `conclusion: failure`, and `steps: []` on every one of
# them (measured on cuneiform run 32944778403). A run that really executed has a
# populated `steps` array (pinakes run 32827758461: 10). So "at least one step
# recorded anywhere in the run" separates a gate that ran and went red from a gate
# that never started.
#
# 0 = it ran · 1 = it never started · 2 = could not measure.
cigate_started() {
  local n
  command -v gh >/dev/null 2>&1 || return 2
  n="$(gh run view "$2" --repo "$1" --json jobs 2>/dev/null | jq '[.jobs[]?.steps[]?] | length' 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) return 2 ;; esac
  [ "$n" -gt 0 ] && return 0
  return 1
}

# --- the TRIGGER MISMATCH: a gate nothing chief does can start ---------------
#
# The SECOND, independent version of the same fault, and the one no amount of
# asking GitHub would find. `vita`'s workflow triggers only on `pull_request` and
# `workflow_dispatch`. chief merges a finished branch into the base LOCALLY with
# `--no-ff`, and the base branch is what gets pushed — it never opens a pull
# request, and nobody clicks Run workflow on its behalf. So no event chief
# generates could ever start that workflow: its CI had not run once in the
# repository's history, and a tasklist (`72`) was unparked and merged as
# `auto-verified` on the premise that it had.
#
# Nothing about the file looks wrong. It is a valid workflow, it would work
# perfectly in a repository worked through pull requests, and every surface — the
# file, the Actions tab, the run list above — is silent. `gh` cannot answer this
# one: "no runs" is what a dead gate and a brand-new gate both look like, and only
# the trigger says which. That is why this is a CHECK and not a note in a doc.
#
# TEXTUAL AND OFFLINE, on purpose. `on:` is a two-or-three-line mapping in every
# real workflow, and a YAML dependency in the engine to read one mapping is a
# dependency chief would carry forever. Nothing here makes a network call, so the
# mismatch is measurable in a repo with no remote, no `gh` and no network — which
# is exactly the shape every UNKNOWN arm above otherwise leaves unanswered.
#
# It errs toward "it would fire". Reporting a live gate as dead spends an
# operator's attention on nothing; the failure being fixed here is the other
# direction, and only the other direction is silent.

# cigate_on_block FILE — the workflow's `on:` mapping, normalized to lines:
#
#   event<TAB><event-name>
#   filter<TAB><event-name><TAB><branches|branches-ignore|tags|tags-ignore><TAB><pattern>
#
# Handles the three forms GitHub accepts — `on: push`, `on: [push, pull_request]`
# and the indented block — plus `"on":`/`'on':` (YAML 1.1 reads a bare `on` as a
# boolean, so some authors quote it). Comments are stripped; the block ends at the
# first line back at column 0. Empty output means no `on:` could be read at all,
# which is a could-not-measure and never a pass.
cigate_on_block() {
  LC_ALL=C awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function unq(s) { s = trim(s); gsub(/^["\047]|["\047]$/, "", s); return trim(s) }
    function emit_ev(v,  x) { x = unq(v); sub(/:$/, "", x); if (x != "") print "event\t" x }
    function emit_f(v,  x)  { x = unq(v); if (x != "" && ev != "" && fk != "") print "filter\t" ev "\t" fk "\t" x }
    function each(s, isev,  n, a, i) {
      s = trim(s)
      if (s ~ /^\[/) { sub(/^\[/, "", s); sub(/\][ \t]*$/, "", s); n = split(s, a, ",") }
      else { n = 1; a[1] = s }
      for (i = 1; i <= n; i++) { if (isev) emit_ev(a[i]); else emit_f(a[i]) }
    }
    {
      line = $0
      sub(/[ \t]+#.*$/, "", line); sub(/^[ \t]*#.*$/, "", line)
      if (line ~ /^[ \t]*$/) next
      ind = match(line, /[^ \t]/) - 1
      body = substr(line, ind + 1)
      if (state == 0) {
        if (ind == 0 && body ~ /^("on"|\047on\047|on)[ \t]*:/) {
          state = 1; rest = body; sub(/^[^:]*:[ \t]*/, "", rest)
          if (rest != "") { each(rest, 1); exit }
        }
        next
      }
      if (ind == 0) exit
      if (bi == 0) bi = ind
      if (ind == bi) {                                  # an event: `push:` or `- push`
        fk = ""
        if (body ~ /^-[ \t]*/) { rest = body; sub(/^-[ \t]*/, "", rest); ev = unq(rest); emit_ev(rest) }
        else if (match(body, /^[A-Za-z_][A-Za-z0-9_.-]*[ \t]*:/)) { ev = body; sub(/[ \t]*:.*$/, "", ev); emit_ev(ev) }
        else ev = ""
        next
      }
      if (ev == "") next
      if (match(body, /^(branches|branches-ignore|tags|tags-ignore)[ \t]*:/)) {
        fk = body; sub(/[ \t]*:.*$/, "", fk); fi = ind
        rest = body; sub(/^[^:]*:[ \t]*/, "", rest)
        if (rest != "") { each(rest, 0); fk = "" }
        next
      }
      if (fk != "" && ind > fi && body ~ /^-[ \t]*/) { rest = body; sub(/^-[ \t]*/, "", rest); each(rest, 0); next }
      if (ind <= fi) fk = ""
    }
  ' "$1" 2>/dev/null
}

# cigate_base_branch REPO — the branch chief pushes: the repo's declared
# CHIEF_BASE_BRANCH, else main. READ as a line, never sourced — a report must not
# execute another repository's bash (engine/status.sh's config_list keeps the same
# rule, for the same reason).
cigate_base_branch() {
  local f="$1/.chief/config" v=""
  [ -f "$f" ] && v="$(LC_ALL=C awk '
      /^[ \t]*(export[ \t]+)?CHIEF_BASE_BRANCH=/ { sub(/^[^=]*=/, "", $0); v = $0 }
      END { print v }' "$f" 2>/dev/null)"
  v="${v%%#*}"
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s\n' "${v:-main}"
}

# cigate_branch_matches PATTERN BRANCH — GitHub's branch-filter glob against the
# branch chief pushes, evaluated by `case`. The one difference is that GitHub's
# `*` stops at `/` and `**` does not, while `case`'s `*` always crosses it — so
# this matches slightly MORE than GitHub would, which is the erring-toward-live
# direction stated above.
cigate_branch_matches() {
  # shellcheck disable=SC2254
  case "$2" in $1) return 0 ;; esac
  return 1
}

# cigate_push_fires BLOCK BRANCH — would chief pushing BRANCH start this workflow?
# 0 = yes · 1 = no. A `push:` with no branch filter fires on every branch; one
# limited to `tags:` never fires for a branch push, and chief creates no tags.
# `!pattern` inside `branches:` is GitHub's negation and excludes.
cigate_push_fires() {
  local branch="$2" k e kind val inc=0 hit=0 tags=0
  printf '%s\n' "$1" | LC_ALL=C awk -F'\t' \
    '$1 == "event" && $2 == "push" { f = 1 } END { exit f ? 0 : 1 }' || return 1
  while IFS="$(printf '\t')" read -r k e kind val; do
    [ "$k" = filter ] && [ "$e" = push ] || continue
    case "$kind" in
      tags|tags-ignore)  tags=1; continue ;;
      branches-ignore)   cigate_branch_matches "$val" "$branch" && return 1; continue ;;
    esac
    case "$val" in
      '!'*) cigate_branch_matches "${val#\!}" "$branch" && return 1 ;;
      *)    inc=1; cigate_branch_matches "$val" "$branch" && hit=1 ;;
    esac
  done <<EOF
$1
EOF
  [ "$inc" = 1 ] && { [ "$hit" = 1 ] && return 0; return 1; }
  [ "$tags" = 1 ] && return 1     # tag-only: a branch push is not covered
  return 0
}

# cigate_event_prose EVENT — what someone would have to DO to produce this event.
# The report has to say what the workflow is WAITING FOR: "your CI waits for a
# pull request; chief pushes to main" is actionable, and `on: pull_request` is
# the line that was already sitting there, unread, for the whole outage.
cigate_event_prose() {
  case "$1" in
    pull_request|pull_request_target|pull_request_review|pull_request_review_comment)
                           printf 'someone opening a pull request\n' ;;
    merge_group)           printf 'a merge queue\n' ;;
    workflow_dispatch)     printf 'someone clicking Run workflow by hand\n' ;;
    repository_dispatch)   printf 'an external API call\n' ;;
    schedule)              printf 'a cron clock rather than your change\n' ;;
    workflow_run)          printf 'another workflow finishing\n' ;;
    issue_comment|issues)  printf 'issue activity\n' ;;
    push)                  printf 'a push to a branch chief does not push\n' ;;
    *)                     printf 'a %s event chief does not produce\n' "$1" ;;
  esac
}

# cigate_trigger_prose BLOCK BRANCH — the finding, in the operator's terms. Two
# shapes, because they are two different fixes: a workflow with no `push` trigger
# at all is waiting for something chief never does, and one whose `push` is
# filtered is waiting for a branch chief never pushes.
cigate_trigger_prose() {
  local block="$1" branch="$2" ev evs="" prose="" filters
  while IFS= read -r ev; do
    [ -n "$ev" ] || continue
    case " $evs " in *" $ev "*) continue ;; esac
    evs="$evs $ev"
  done <<EOF
$(printf '%s\n' "$block" | LC_ALL=C awk -F'\t' '$1 == "event" { print $2 }')
EOF
  evs="${evs# }"
  case " $evs " in
    *" push "*)
      filters="$(printf '%s\n' "$block" | LC_ALL=C awk -F'\t' '
        $1 == "filter" && $2 == "push" { if (!($3 in v)) { o[++n] = $3 }
                                         v[$3] = ($3 in v) ? v[$3] ", " $4 : $4 }
        END { for (i = 1; i <= n; i++) printf "%s%s: %s", (i > 1 ? "; " : ""), o[i], v[o[i]] }')"
      case "$filters" in
        branches*) printf 'its push trigger is filtered to %s — chief merges the finished branch into %s locally and pushes %s, which no filter there accepts\n' \
                     "$filters" "$branch" "$branch" ;;
        *)         printf 'its push trigger fires only for %s — chief merges the finished branch into %s locally and pushes the %s BRANCH, and it never creates a tag\n' \
                     "${filters:-filters this check could not read}" "$branch" "$branch" ;;
      esac ;;
    *)
      for ev in $evs; do prose="$prose, $(cigate_event_prose "$ev")"; done
      printf 'it waits for %s (on: %s). chief merges the finished branch into %s locally and pushes %s — a push to %s is the ONLY event it produces, and this workflow does not listen for one, so nothing chief does can start it\n' \
        "${prose#, }" "${evs// /, }" "$branch" "$branch" "$branch" ;;
  esac
}

# cigate_trigger_check FILE BRANCH — can anything chief does start this workflow?
#   0 = yes, nothing printed · 1 = MISMATCH, the detail on stdout · 2 = unreadable
cigate_trigger_check() {
  local block
  block="$(cigate_on_block "$1")"
  [ -n "$block" ] || return 2
  cigate_push_fires "$block" "$2" && return 0
  cigate_trigger_prose "$block" "$2"
  return 1
}

# --- classification ----------------------------------------------------------

# cigate_classify SLUG RECORD SHA — one workflow's newest run -> "TOKEN<TAB>detail".
# RECORD is a cigate_run_records line, or empty when that workflow has no run at
# all. SHA (may be empty) is the commit the verdict is being asked about.
cigate_classify() {
  local slug="$1" rec="$2" sha="$3"
  local _wf id status concl head created
  if [ -z "$rec" ]; then
    printf '%s\tno run recorded in the last %s runs of this repository\n' \
      "$CIGATE_DEAD" "$CIGATE_RUN_LIMIT"
    return 0
  fi
  IFS="$(printf '\t')" read -r _wf id status concl head created <<EOF
$rec
EOF
  local when="${created%%T*}"
  case "$status" in
    completed) ;;
    *) printf '%s\ta run is still in flight (%s, %s) — no verdict yet\n' "$CIGATE_UNKNOWN" "$status" "$when"
       return 0 ;;
  esac
  case "$concl" in
    success)
      if [ -n "$sha" ] && [ "$head" != "$sha" ]; then
        printf '%s\tits most recent run passed on %s (%s) — the commit here (%s) has no run of its own\n' \
          "$CIGATE_DEAD" "${head:0:7}" "$when" "${sha:0:7}"
      else
        printf '%s\tits most recent run passed on %s (%s)\n' "$CIGATE_PASSED" "${head:0:7}" "$when"
      fi ;;
    failure|timed_out)
      cigate_started "$slug" "$id"
      case "$?" in
        0) printf '%s\tits most recent run executed and went red (%s, %s)\n' "$CIGATE_FAILED" "${head:0:7}" "$when" ;;
        1) printf '%s\tits most recent run (%s) completed without executing a single step — the job never started\n' \
             "$CIGATE_DEAD" "$when" ;;
        *) printf '%s\tits most recent run reported "%s" (%s) and whether it ever started could not be measured\n' \
             "$CIGATE_UNKNOWN" "$concl" "$when" ;;
      esac ;;
    startup_failure|skipped|cancelled|action_required|stale|neutral)
      printf '%s\tits most recent run never produced a verdict — GitHub reported "%s" (%s)\n' \
        "$CIGATE_DEAD" "$concl" "$when" ;;
    *)
      printf '%s\tits most recent run reported "%s" (%s), which chief does not interpret\n' \
        "$CIGATE_UNKNOWN" "$concl" "$when" ;;
  esac
}

# --- the scan ----------------------------------------------------------------

# cigate_scan REPO [SHA] — one TAB-separated record per DECLARED workflow:
#
#   <token><TAB><repo-name><TAB><workflow-name><TAB><detail>
#
# and exactly one `none` record for a repo that declares no CI at all. Every field
# is non-empty by construction, which is what makes a TAB delimiter safe here.
#
# It DEGRADES, never aborts: an unreachable network, an absent `gh`, a checkout with
# no GitHub remote all produce UNKNOWN records naming the reason, and the next repo
# is still scanned. Every one of those arms still runs the OFFLINE trigger check,
# because a workflow chief cannot start is a finding that needs no network — and a
# repo where nothing else could be measured is exactly where it is worth having.
cigate_scan() {
  local repo="$1" sha="${2:-}" name slug runs wfs wf label path rec verdict tab branch
  tab="$(printf '\t')"
  name="$(basename "$repo")"
  branch="$(cigate_base_branch "$repo")"
  wfs="$(cigate_workflows "$repo")"
  if [ -z "$wfs" ]; then
    printf '%s\t%s\t-\tno %s/ in this repository — nothing is declared, so nothing is missing\n' \
      "$CIGATE_NONE" "$name" "$CIGATE_WORKFLOW_DIR"
    return 0
  fi
  if ! slug="$(cigate_slug "$repo")"; then
    cigate_unknown_rows "$name" "$branch" "no GitHub remote on this checkout — cannot ask what ran" "$wfs"
    return 0
  fi
  if ! runs="$(cigate_run_records "$slug")"; then
    if command -v gh >/dev/null 2>&1; then
      cigate_unknown_rows "$name" "$branch" "GitHub could not be reached for $slug — offline, unauthenticated, or the API refused" "$wfs"
    else
      cigate_unknown_rows "$name" "$branch" "gh is not installed — chief cannot ask GitHub what ran (this is NOT a pass)" "$wfs"
    fi
    return 0
  fi
  while IFS= read -r wf; do
    [ -n "$wf" ] || continue
    label="$(cigate_workflow_name "$wf")"
    # Match on the declared name OR the file path, because GitHub reports BOTH:
    # a run whose workflow file it could not parse at that ref is reported under
    # ".github/workflows/ci.yml" even when the file says `name: ci` — which is
    # precisely the shape a dead gate has, so matching on the name alone would
    # report the dead workflow as having no runs at all and lose the reason.
    path="$CIGATE_WORKFLOW_DIR/$(basename "$wf")"
    rec="$(printf '%s\n' "$runs" | LC_ALL=C awk -F'\t' -v w="$label" -v p="$path" \
             '$1 == w || $1 == p { print; exit }')"
    verdict="$(cigate_classify "$slug" "$rec" "$sha")"
    cigate_row "$name" "$label" "$wf" "$branch" "${verdict%%"$tab"*}" "${verdict#*"$tab"}"
  done <<EOF
$wfs
EOF
}

# cigate_row NAME LABEL WORKFLOW_FILE BRANCH TOKEN DETAIL — one scan record, with
# the offline trigger check laid over whatever GitHub said.
#
# A MISMATCH WINS. If nothing chief does can start this workflow then the gate did
# not run for chief's merge whatever the Actions tab shows — a green run someone
# produced by hand is precisely the reassuring surface this tasklist exists to
# stop trusting — so the row is DID NOT RUN and the mismatch is the detail, with
# GitHub's own record kept alongside rather than thrown away.
#
# An UNREADABLE `on:` block (rc 2) changes nothing: no mismatch was detected, and
# the module errs toward reporting a gate as live. It is the run verdict above,
# not this check, that carries the loud-SKIP discipline.
cigate_row() {
  local mm rc aside
  mm="$(cigate_trigger_check "$3" "$4")"; rc=$?
  if [ "$rc" -eq 1 ]; then
    aside="what GitHub records for it: $6"
    [ "$5" = "$CIGATE_UNKNOWN" ] && aside="and what GitHub records for it was not measured — $6"
    printf '%s\t%s\t%s\t%s%s (%s)\n' "$CIGATE_DEAD" "$1" "$2" "$CIGATE_MISMATCH_TAG" "$mm" "$aside"
  else
    printf '%s\t%s\t%s\t%s\n' "$5" "$1" "$2" "$6"
  fi
}

# cigate_unknown_rows NAME BRANCH REASON WORKFLOWS — one UNKNOWN row per declared
# workflow, all naming the same reason. Shared by every could-not-measure arm so
# that "we did not find out" always renders identically to "it passed" being absent.
# Routed through cigate_row, so a trigger mismatch is still reported here: it is
# measured from the file, and none of these arms had a file problem.
cigate_unknown_rows() {
  local name="$1" branch="$2" reason="$3" wf
  while IFS= read -r wf; do
    [ -n "$wf" ] || continue
    cigate_row "$name" "$(cigate_workflow_name "$wf")" "$wf" "$branch" "$CIGATE_UNKNOWN" "$reason"
  done <<EOF
$4
EOF
}

# --- rendering ---------------------------------------------------------------

# cigate_symbol TOKEN — the one-glyph severity, matching the rest of the engine's
# report vocabulary (`⚑` a finding · `?` unmeasured · `✓` clean).
cigate_symbol() {
  case "$1" in
    "$CIGATE_DEAD")    printf '⚑\n' ;;
    "$CIGATE_FAILED")  printf '✗\n' ;;
    "$CIGATE_UNKNOWN") printf '?\n' ;;
    *)                 printf '✓\n' ;;
  esac
}

# cigate_render RECORDS [all] — the scan rendered for a human, one line each.
# By default only what needs acting on: DID NOT RUN and UNKNOWN. Pass "all" to
# include the healthy and the no-CI rows, which is what a per-repo report wants.
cigate_render() {
  local all="${2:-}" tok name wf detail
  printf '%s\n' "$1" | while IFS="$(printf '\t')" read -r tok name wf detail; do
    [ -n "$tok" ] || continue
    case "$all" in
      all) ;;
      *) case "$tok" in "$CIGATE_DEAD"|"$CIGATE_UNKNOWN") ;; *) continue ;; esac ;;
    esac
    if [ "$tok" = "$CIGATE_NONE" ]; then
      printf '  %s %s — %s\n' "$(cigate_symbol "$tok")" "$name" "$(cigate_label "$tok")"
    else
      printf '  %s %s [%s] — %s: %s\n' "$(cigate_symbol "$tok")" "$name" "$wf" "$(cigate_label "$tok")" "$detail"
    fi
  done
}

# cigate_summary ROWS NREPOS VERBOSE — the whole report, findings first and a
# counted line underneath. The count is the point: "3 RAN AND PASSED" beside "11
# DID NOT RUN" is the sentence nobody could say before this module, because the
# eleven were silent and the three were the only thing any surface reported.
#
# It always ends with what the report SAW, including the states it is not
# flagging, so a clean run reads as "measured, nothing wrong" rather than as
# "nothing was measured" — the two that this whole tasklist exists to separate.
cigate_summary() {
  local rows="$1" repos="$2" verbose="${3:-0}"
  local counts dead failed passed unknown none wf mism
  if [ -z "$rows" ]; then
    printf 'chief cigate: no repositories scanned.\n'
    return 0
  fi
  case "$verbose" in 1) cigate_render "$rows" all ;; *) cigate_render "$rows" ;; esac
  counts="$(printf '%s\n' "$rows" | LC_ALL=C awk -F'\t' -v d="$CIGATE_DEAD" -v f="$CIGATE_FAILED" \
      -v p="$CIGATE_PASSED" -v u="$CIGATE_UNKNOWN" -v n="$CIGATE_NONE" '
      NF { t[$1]++; if ($1 != n) w++ }
      END { printf "%d %d %d %d %d %d", t[d]+0, t[f]+0, t[p]+0, t[u]+0, t[n]+0, w+0 }')"
  read -r dead failed passed unknown none wf <<EOF
$counts
EOF
  printf '%s workflow(s) declared across %s repo(s): %s DID NOT RUN · %s RAN AND FAILED · %s RAN AND PASSED · %s UNKNOWN' \
    "$wf" "$repos" "$dead" "$failed" "$passed" "$unknown"
  [ "$none" -gt 0 ] && printf ' · %s repo(s) declare no CI (not a finding)' "$none"
  printf '\n'
  if [ "$dead" -gt 0 ]; then
    mism="$(printf '%s\n' "$rows" | LC_ALL=C awk -F'\t' -v t="$CIGATE_MISMATCH_TAG" \
              'index($4, t) == 1 { n++ } END { print n + 0 }')"
    [ "$mism" -gt 0 ] && cat <<NOTE
  ↳ $mism of those DID NOT RUN because of a TRIGGER MISMATCH, which is a different
    problem with a different fix. The workflow is waiting for an event chief never
    produces — a pull request, a manual dispatch, a push to a branch it does not
    push — so it has not stopped running; nothing chief does has ever started it.
    Fix that one in the workflow file, not in billing.
NOTE
    cat <<'NOTE'
  ↳ a gate that DID NOT RUN is not a gate that passed. GitHub Actions minutes are
    free for public repositories and billed for private ones, so an account-level
    billing block stops every private repo's CI while the public ones keep working
    and keep looking normal — check billing before reading any of these as a code
    problem. chief reports this and never blocks a merge on it.
NOTE
  fi
  [ "$unknown" -gt 0 ] && printf '  ↳ UNKNOWN is not a pass. Those gates were not measured, and chief will not round them up.\n'
  return 0
}
