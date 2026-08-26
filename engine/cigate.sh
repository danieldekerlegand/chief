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
# is still scanned.
cigate_scan() {
  local repo="$1" sha="${2:-}" name slug runs wfs wf label path rec verdict tab
  tab="$(printf '\t')"
  name="$(basename "$repo")"
  wfs="$(cigate_workflows "$repo")"
  if [ -z "$wfs" ]; then
    printf '%s\t%s\t-\tno %s/ in this repository — nothing is declared, so nothing is missing\n' \
      "$CIGATE_NONE" "$name" "$CIGATE_WORKFLOW_DIR"
    return 0
  fi
  if ! slug="$(cigate_slug "$repo")"; then
    cigate_unknown_rows "$name" "no GitHub remote on this checkout — cannot ask what ran" "$wfs"
    return 0
  fi
  if ! runs="$(cigate_run_records "$slug")"; then
    if command -v gh >/dev/null 2>&1; then
      cigate_unknown_rows "$name" "GitHub could not be reached for $slug — offline, unauthenticated, or the API refused" "$wfs"
    else
      cigate_unknown_rows "$name" "gh is not installed — chief cannot ask GitHub what ran (this is NOT a pass)" "$wfs"
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
    printf '%s\t%s\t%s\t%s\n' "${verdict%%"$tab"*}" "$name" "$label" "${verdict#*"$tab"}"
  done <<EOF
$wfs
EOF
}

# cigate_unknown_rows NAME REASON WORKFLOWS — one UNKNOWN row per declared
# workflow, all naming the same reason. Shared by every could-not-measure arm so
# that "we did not find out" always renders identically to "it passed" being absent.
cigate_unknown_rows() {
  local name="$1" reason="$2" wf
  while IFS= read -r wf; do
    [ -n "$wf" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$CIGATE_UNKNOWN" "$name" "$(cigate_workflow_name "$wf")" "$reason"
  done <<EOF
$3
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
  local counts dead failed passed unknown none wf
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
