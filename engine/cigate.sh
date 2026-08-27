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

# cigate_config REPO KEY DEFAULT — one setting out of a repo's .chief/config.
# READ as a line, never sourced — a report must not execute another repository's
# bash (engine/status.sh's config_list keeps the same rule, for the same reason).
cigate_config() {
  local f="$1/.chief/config" v=""
  [ -f "$f" ] && v="$(LC_ALL=C awk -v k="$2" '
      index($0, k "=") { i = index($0, "="); pre = substr($0, 1, i - 1)
                         gsub(/^[ \t]*(export[ \t]+)?/, "", pre)
                         if (pre == k) v = substr($0, i + 1) }
      END { print v }' "$f" 2>/dev/null)"
  v="${v%%#*}"
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s\n' "${v:-$3}"
}

# cigate_base_branch REPO — the branch chief pushes: the repo's declared
# CHIEF_BASE_BRANCH, else main.
cigate_base_branch() { cigate_config "$1" CHIEF_BASE_BRANCH main; }

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
  local branch="$2" k e kind val inc=0 hit=0 tags=0 tab
  tab="$(printf '\t')"
  printf '%s\n' "$1" | LC_ALL=C awk -F'\t' \
    '$1 == "event" && $2 == "push" { f = 1 } END { exit f ? 0 : 1 }' || return 1
  while IFS="$tab" read -r k e kind val; do
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

# cigate_render RECORDS [MODE] — the scan rendered for a human, one line each.
# By default only what needs acting on: DID NOT RUN and UNKNOWN. "all" adds the
# healthy and the no-CI rows, which is what a per-repo report wants; "dead" keeps
# only DID NOT RUN, for a reader whose UNKNOWNs are the NORMAL case and would bury
# the finding — every merge record written before chief recorded gates is one, and
# those are counted and named in the summary line instead of listed.
cigate_render() {
  local all="${2:-}" tok name wf detail tab
  # HOISTED: `while IFS="$(printf '\t')" read` re-runs that substitution — a FORK —
  # on every iteration, and this loop is now fed one row per (merge record, workflow).
  tab="$(printf '\t')"
  printf '%s\n' "$1" | while IFS="$tab" read -r tok name wf detail; do
    [ -n "$tok" ] || continue
    case "$all" in
      all)  ;;
      dead) [ "$tok" = "$CIGATE_DEAD" ] || continue ;;
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

# --- the MERGE RECORD: which gates actually executed --------------------------
#
# The third surface, and the only one that can be asked AFTERWARDS. Four tasklists
# in this portfolio merged as `auto-verified` against a gate that had never
# executed — `vita`'s `72` against a workflow no event chief produces could start,
# and three in `amphora` against a `.chief/verify.sh` that ran one unrelated check
# and then `exit 0`. Every one of them was found BY HAND, long after the fact,
# because the completed record said `mergedToMain` and nothing else. A record that
# names which gates ran is the difference between finding the next one by hand and
# reading it off the file.
#
# OFFLINE, and AFTER the merge. `finalize_merged` calls this once the merge commit
# already exists, and nothing in it touches the network — so it cannot slow, fail
# or block a merge, which is the scope rule this whole module is built under. The
# CI half is therefore the TRIGGER check ONLY: "could anything chief does have
# started this gate", which is a pure function of the file. Whether a run then
# happened is UNKNOWN in the record and is written down as unknown — `chief cigate`
# is the command that asks GitHub, and it is deliberately not on this path.
#
# The vocabulary is the one stated at the top of this file. A record carries the
# TOKENS (passed/failed/dead/unknown); `cigate_label` turns them into RAN AND
# PASSED / RAN AND FAILED / DID NOT RUN at read time, so there is exactly one
# place a state is named and a record written by an older chief still renders.

# cigate_stamp_merge_record RECORD REPO SHA [HOOK] [NO_VERIFY] — add `gates` to a
# completed/ record. Never fails, never writes a partial file: the whole document
# is rebuilt through a temp file and moved into place, or the record is left
# exactly as it was.
#
# THE LOCAL HALF IS THE `amphora` CHECK. A merge only happens after the gate came
# back green, so "it passed" is knowable here without re-running anything — but so
# is the case that has no gate at all. No hook, no per-tasklist `verify` commands,
# or `NO_VERIFY=1`: green for the same reason an empty test suite is green, and
# recorded as DID NOT RUN rather than as a pass.
cigate_stamp_merge_record() {
  local rec="$1" repo="$2" sha="$3" hook="${4:-}" noverify="${5:-0}"
  local state detail branch rows="" wf label mm rc tmp cmds tab
  [ -f "$rec" ] || return 0
  tab="$(printf '\t')"
  cmds="$(jq -r '(.verify // [])[] ' "$rec" 2>/dev/null | head -1)"
  if [ "$noverify" = 1 ]; then
    state="$CIGATE_DEAD"
    detail="the local merge gate was SKIPPED by NO_VERIFY=1 — nothing verified this merge"
  elif [ -n "$cmds" ]; then
    state="$CIGATE_PASSED"; detail="this tasklist's own \"verify\" commands ran and exited 0"
  elif [ -n "$hook" ] && [ -x "$hook" ]; then
    state="$CIGATE_PASSED"; detail="the project verify hook ($(basename "$hook")) ran and exited 0"
  else
    state="$CIGATE_DEAD"
    detail="no verify hook is configured and this tasklist declares no \"verify\" commands — NOTHING checked this merge"
  fi
  branch="$(cigate_base_branch "$repo")"
  while IFS= read -r wf; do
    [ -n "$wf" ] || continue
    label="$(cigate_workflow_name "$wf")"
    mm="$(cigate_trigger_check "$wf" "$branch")"; rc=$?
    case "$rc" in
      1) rows="$rows$CIGATE_DEAD$tab$label$tab$CIGATE_MISMATCH_TAG$mm" ;;
      2) rows="$rows$CIGATE_UNKNOWN$tab$label${tab}its \`on:\` block could not be read, so whether anything chief does can start it is unknown" ;;
      *) rows="$rows$CIGATE_UNKNOWN$tab$label${tab}a push of $branch can start it; whether it RAN for $sha is not recorded here — chief makes no network call on the merge path. \`chief cigate\` is what asks GitHub." ;;
    esac
    rows="$rows
"
  done <<EOF
$(cigate_workflows "$repo")
EOF
  tmp="$rec.gates.$$"
  printf '%s' "$rows" | jq -R -s --slurpfile r "$rec" --arg s "$state" --arg d "$detail" '
      $r[0] + { gates: {
        "local": { "state": $s, "detail": $d },
        "ci": [ split("\n")[] | select(length > 0) | split("\t")
                | { "workflow": .[1], "state": .[0], "detail": .[2] } ] } }' > "$tmp" 2>/dev/null \
    && [ -s "$tmp" ] && mv "$tmp" "$rec"
  rm -f "$tmp" 2>/dev/null
  return 0
}

# cigate_tree_verdicts_set REPO TREE BRANCH -> CIGATE_TREE_ROWS — the trigger
# verdict for every workflow in one `.github/workflows` TREE, as
# "token<TAB>file<TAB>prose" lines.
#
# Keyed by the TREE, not by the commit, because that is what the answer actually
# depends on: a repo's `.github/workflows` changes a few dozen times across
# hundreds of merges, so the same handful of trees is asked about over and over.
# cuneiform: 378 records, 4,155 (record, workflow) questions — and 31 distinct
# trees behind them.
#
# The memo holds ALL of them, not one. deps.sh's one-entry memo is a full cache
# because its caller asks about each record immediately after reading it; this
# caller reads records in NAME order while trees change in MERGE order, and
# measured on cuneiform that is 189 hits and 189 misses — half a cache, and the
# misses are the expensive half. 31 entries is nothing to hold, and the memo is
# bounded by the distinct trees of one report.
#
# SET-A-GLOBAL, not print-it, and its callers are the same all the way up to the
# accumulator in cigate_records_report — `$( )` is a subshell, and a memo written
# inside one dies with it. That is not a slow memo, it is NO memo, and it is silent.
CIGATE_TREE_ROWS=""
_CIGATE_TREE_KEYS=()
_CIGATE_TREE_VALS=()
cigate_tree_verdicts_set() {
  local repo="$1" tree="$2" branch="$3" b mm rc tab out="" i=0 n
  n="${#_CIGATE_TREE_KEYS[@]}"
  while [ "$i" -lt "$n" ]; do
    if [ "${_CIGATE_TREE_KEYS[$i]}" = "$tree" ]; then CIGATE_TREE_ROWS="${_CIGATE_TREE_VALS[$i]}"; return 0; fi
    i=$((i + 1))
  done
  tab="$(printf '\t')"
  while IFS= read -r b; do
    case "$b" in *.yml|*.yaml) ;; *) continue ;; esac
    mm="$(git -C "$repo" show "$tree:$b" 2>/dev/null | cigate_trigger_check - "$branch")"; rc=$?
    case "$rc" in
      1) out="$out$CIGATE_DEAD$tab$b$tab$mm
" ;;
      *) out="$out$CIGATE_UNKNOWN$tab$b$tab-
" ;;
    esac
  done <<EOF
$(git -C "$repo" ls-tree --name-only "$tree" 2>/dev/null)
EOF
  _CIGATE_TREE_KEYS[$n]="$tree"; _CIGATE_TREE_VALS[$n]="$out"
  CIGATE_TREE_ROWS="$out"
}

# cigate_reconstruct_set REPO SHA NAME BRANCH -> CIGATE_REC_ROWS — the CI half of
# a record that carries no `gates` field, rebuilt from the workflow files AS THEY
# STOOD at the merge commit. Offline, textual, and historical: the four merges this
# module exists because of all predate the field, and this is what lets them be
# answered off the record instead of by hand.
#
# It answers the TRIGGER question only, which is the one still answerable. A
# workflow chief's push could have started is UNKNOWN, never a pass — whether it
# actually ran was never recorded, and that gap is the whole point.
#
# `rev-parse` is asked with `--verify -q` deliberately: plain `rev-parse` PRINTS an
# argument it could not resolve and exits non-zero, so testing its output for
# emptiness reads "no such tree" as a tree named `<sha>:.github/workflows` — which
# silently dropped every merge made before the repo had CI at all, the one case
# that most needs saying out loud.
CIGATE_REC_ROWS=""
cigate_reconstruct_set() {
  local repo="$1" sha="$2" name="$3" branch="$4" tree tok b prose
  CIGATE_REC_ROWS=""
  if ! git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null; then
    CIGATE_REC_ROWS="$(printf '%s\t%s\t-\tmerged at %s, which is not a commit in this checkout — the gates of this merge cannot be reconstructed\n' \
      "$CIGATE_UNKNOWN" "$name" "${sha:-(no mergedToMain recorded)}")
"
    return 0
  fi
  tree="$(git -C "$repo" rev-parse --verify -q "$sha:$CIGATE_WORKFLOW_DIR" 2>/dev/null)" || tree=""
  if [ -z "$tree" ]; then
    CIGATE_REC_ROWS="$(printf '%s\t%s\t-\tthe repository declared no CI at %s — nothing was missing\n' "$CIGATE_NONE" "$name" "$sha")
"
    return 0
  fi
  cigate_tree_verdicts_set "$repo" "$tree" "$branch"
  # `printf -v`, not `$( )`: this is the innermost loop of the whole report — one
  # pass per (record, workflow) — and a command substitution here is a FORK per
  # row. On cuneiform that alone was 4,155 of them.
  local line tab
  tab="$(printf '\t')"
  while IFS="$tab" read -r tok b prose; do
    [ -n "$tok" ] || continue
    case "$tok" in
      "$CIGATE_DEAD")
        printf -v line '%s\t%s\t%s\t%s%s (reconstructed from the file at %s; this merge predates chief recording gates)\n' \
          "$tok" "$name" "$b" "$CIGATE_MISMATCH_TAG" "$prose" "$sha" ;;
      *)
        printf -v line '%s\t%s\t%s\ta push of %s could have started it at %s, but this merge predates chief recording gates — whether it RAN was never written down\n' \
          "$tok" "$name" "$b" "$branch" "$sha" ;;
    esac
    CIGATE_REC_ROWS="$CIGATE_REC_ROWS$line"
  done <<EOF
$CIGATE_TREE_ROWS
EOF
}

# cigate_records_report REPO [VERBOSE] — read the merge records BACK: for every
# merged tasklist in this repo, which gates executed for it. Findings only by
# default; VERBOSE=1 shows the healthy records too.
#
# ONE jq for the whole directory, not one per record (the rule engine/status.sh
# established when 1,040 records cost 2,576 forks): the pass below emits the
# stamped rows directly and marks the unstamped ones for reconstruction, which is
# the only per-record work left and only happens for records written before the
# field existed.
cigate_records_report() {
  local repo="$1" verbose="${2:-0}" completed rows="" branch name kind sha tok wf detail us line
  us="$(printf '\037')"
  repo="$(cd -P "$repo" 2>/dev/null && pwd)" || return 0
  completed="$repo/$(cigate_config "$repo" CHIEF_TASKS_DIR tasks/chief)/completed"
  branch="$(cigate_base_branch "$repo")"
  if [ ! -d "$completed" ]; then
    printf 'chief cigate --records: %s keeps no completed/ records (looked in %s)\n' "$(basename "$repo")" "$completed"
    return 0
  fi
  # US-delimited, not TAB: a detail field is prose and an empty middle field would
  # collapse a run of tabs (see CLAUDE.md). Reading is by the same delimiter.
  while IFS="$us" read -r name kind sha tok wf detail; do
    [ -n "$name" ] || continue
    case "$kind" in
      stamped) printf -v line '%s\t%s\t%s\t%s\n' "$tok" "$name" "$wf" "$detail"
               rows="$rows$line" ;;
      *)       cigate_reconstruct_set "$repo" "$sha" "$name" "$branch"
               rows="$rows$CIGATE_REC_ROWS" ;;
    esac
  done <<EOF
$(jq -rn --arg us "$us" '
    inputs as $r
    | (input_filename | sub("^.*/"; "") | sub("\\.json$"; "")) as $n
    | ($r.mergedToMain // "" | tostring) as $sha
    | if ($r.gates | type) == "object" then
        ([{workflow: "the local verify gate", state: ($r.gates["local"].state // "unknown"),
           detail: ($r.gates["local"].detail // "no detail recorded")}]
         + ($r.gates.ci // []))[]
        | [$n, "stamped", $sha, (.state // "unknown"), (.workflow // "-"), (.detail // "-")]
      else [$n, "unstamped", $sha, "", "", ""] end
    | join($us)' "$completed"/*.json 2>/dev/null)
EOF
  if [ -z "$rows" ]; then
    printf 'chief cigate --records: %s has no merged tasklists to read.\n' "$(basename "$repo")"
    return 0
  fi
  case "$verbose" in 1) cigate_render "$rows" all ;; *) cigate_render "$rows" dead ;; esac
  printf '%s\n' "$rows" | LC_ALL=C awk -F'\t' -v repo="$(basename "$repo")" \
      -v d="$CIGATE_DEAD" -v p="$CIGATE_PASSED" -v u="$CIGATE_UNKNOWN" '
      NF { t[$1]++; seen[$2] = 1; if ($1 == d) bad[$2] = 1 }
      END {
        n = 0; for (k in seen) n++
        b = 0; for (k in bad) b++
        printf "%d merged tasklist(s) in %s: %d gate(s) DID NOT RUN across %d of them · %d RAN AND PASSED · %d UNKNOWN\n",
               n, repo, t[d]+0, b, t[p]+0, t[u]+0
        if (b > 0) print "  ↳ those tasklists merged with a declared gate that never executed. A merge record is\n    evidence of a merge, not of a check — that is the whole distinction this reports."
        if (t[u]+0 > 0) print "  ↳ UNKNOWN is not a pass, and it is not silence either — those merges are counted\n    above. A record written before chief recorded gates keeps only what is still\n    reconstructable from the workflow files at the merge commit (-v lists them);\n    `chief cigate` is what asks GitHub what ran now."
      }'
  return 0
}
