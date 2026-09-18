#!/usr/bin/env bash
# engine/admit.sh — MID-RUN ADMISSION: widening a LIVE run's work set on request.
#
# WHY THIS EXISTS. A run's work set is frozen at launch, so new work used to cost an
# operator the run they had. Reported 2026-09-16, and the sequence is the point: a run
# was working through seven tasklists, four more were authored while it ran, there was
# no way to add them, and `driver.lock` is one driver per repo — so a second
# `chief run` is refused. The operator killed a live run, discarding an in-flight
# agent turn, purely to widen the set. That is a bad trade the TOOL offered, not a
# mistake somebody made.
#
# WHAT IT IS NOT.
#   · Not a second driver. driver.lock stays one-per-repo: the merge phase serialises
#     against a moving base branch and two drivers would race it.
#   · Not a filesystem watcher. A run that silently absorbed whatever appeared in
#     tasks/chief/ would make `chief run 310 311` mean something other than what the
#     operator typed. The request is EXPLICIT, always.
#   · Not a re-prioritisation. A newcomer takes its place under the UNCHANGED
#     dependency and conflict-domain rules and never jumps a wave, and nothing here
#     reads or writes `-p N` or the machine budget — admitting work never raises a
#     ceiling.
#
# THE ADMISSION RULES ARE THE WHOLE FEATURE (admit_check). A tasklist may join only
# if it would have been LEGAL AT LAUNCH: the file exists, it is not parked (unless
# named the way `--parked` already allows), it is not already in this run, it is not
# already recorded done, it passes the same lint `chief lint` applies, and its
# dependencies can be satisfied — by something merged, or by something in the widened
# run. Everything else is refused WITH THE REASON.
#
# TWO ASKINGS, ONE RULE. `chief offer` checks a name before it records the request,
# so an operator is told NO at the keyboard rather than minutes later in a log; the
# driver checks it AGAIN at admission, because the gap between the two is a gap in
# which the tasklist file can change — it can be parked, edited, or merged by a
# sibling run. Both askings call THIS function. A second copy of these rules would
# drift, and the first thing it would drift into is admitting work the run refuses.
#
# TIMING. Admission happens at a WAVE BOUNDARY — the point the scheduler already
# decides what to launch — never inside the merge phase and never while a worker is
# mid-iteration. In-flight work is untouched by construction: nothing in this file
# reads or writes a running worker's branch, worktree or iteration counter. And the
# window SHUTS when the scheduler leaves its loop, so a request arriving once the run
# has begun computing its outcome is refused with that reason rather than half-joining
# a finished run.
#
# CONTRACT. Functions over globals the CALLER owns, not over an environment this file
# establishes (engine/deps.sh's discipline, and its four globals are among them):
#   REPO · TASKS_REL · SRC · COMPLETED   the repo whose tasklists are being resolved
#   STATE_ROOT                           where the durable request queue lives
# It also needs engine/deps.sh sourced (deps_of · is_recorded_done · dep_key ·
# dep_verdict_set) and engine/reap.sh's chief_ns_token / chief_pid_alive — the pid
# discipline below is theirs and is deliberately not re-spelled here.
#
# DURABILITY. The queue lives under $STATE_ROOT, never in the tasklist JSON and never
# inside a worktree: `run_worker` does `rm -rf "$wt"` at the top of every run, and
# operator-authored state in a tasklist file is either discarded by the isolation
# guard or collides at rebase with the branch's own pass-flag edit (see the
# durable-state invariant in CLAUDE.md). $STATE_ROOT is gitignored and survives both.
#
# bash 3.2 only: no associative arrays, no ${var^^}.

# The CLI, resolved at source time from this file's own directory — before any caller
# has had a chance to cd. `chief lint` is the authoring gate, and running it as the
# operator would run it is what keeps "passes lint" from becoming a second, thinner
# opinion about what a valid tasklist is.
ADMIT_CLI="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/chief"

# The field separator of admit_take_requests' output, spelled ONCE so the writer's
# printf and the driver's `IFS=… read` cannot disagree about it.
ADMIT_TAB="$(printf '\t')"

ADMIT_DIR=""
ADMIT_OPEN=""
# The queue's two paths, from $STATE_ROOT. Reads nothing and creates nothing. Returns
# non-zero when there is no state root to hang them off, so every caller below is
# spared having to wonder whether "$ADMIT_DIR/x" is a path or the filesystem root.
admit_paths() {
  [ -n "${STATE_ROOT:-}" ] || return 1
  ADMIT_DIR="$STATE_ROOT/admit"
  ADMIT_OPEN="$ADMIT_DIR/open"
  return 0
}

# ── the DRIVER's half: the window, and taking what arrived in it ──────────────

# admit_open NAMES — declare this run OPEN to admission, and publish the set it is
# already carrying. Called when the scheduler enters its loop and AGAIN on every
# admission, because the published set is what the next request gets checked against.
# Replaced atomically: a reader that caught a half-written marker would read a live
# run as absent, which is a refusal an operator cannot tell from a real one.
admit_open() {
  admit_paths || return 0
  mkdir -p "$ADMIT_DIR" 2>/dev/null || return 0
  {
    echo "pid=$$"
    echo "ns=$(chief_ns_token)"      # which PID namespace `pid` is numbered in
    echo "repo=${REPO:-}"
    echo "runid=${CHIEF_RUN_ID:-}"
    echo "events=${CHIEF_EVENTS_FILE:-}"
    echo "opened=$(date +%s)"
    echo "names=$(printf '%s' "${1:-}" | xargs)"
  } > "$ADMIT_OPEN.tmp.$$" 2>/dev/null || return 0
  mv -f "$ADMIT_OPEN.tmp.$$" "$ADMIT_OPEN" 2>/dev/null || true
  return 0
}

# admit_close — the window shuts. Called where the scheduler leaves its loop (from
# there the run is computing its outcome, and a request that half-joined a finished
# run is the one thing the timing rule forbids) and again in the teardown that
# releases the run records, so a killed run leaves no marker inviting offers.
admit_close() {
  admit_paths || return 0
  rm -f "$ADMIT_OPEN" 2>/dev/null || true
  return 0
}

# admit_take_requests — consume the queue and print one line per request:
#   <verdict>\t<name>\t<by>\t<at>\t<parked>       verdict = take | stale
# TAKING IS REMOVING. A request chief has ANSWERED — admitted or refused — must never
# be answered again at the next poll, so the file goes before the verdict is reached.
# A request addressed to a pid that is not ours is STALE by construction (one driver
# per repo, and driver.lock enforces it): it was made of a run that has since ended,
# and widening THIS run with it would be the silent-auto-scan refusal wearing a
# different hat. It is dropped and REPORTED, never acted on.
# Every field carries a default, deliberately: tab is IFS whitespace, so a run of two
# tabs is ONE delimiter and an empty middle field would shift every field after it
# left in the caller's `read` (the US-vs-tab note in CLAUDE.md).
admit_take_requests() {
  local f n p by at pk verdict
  admit_paths || return 0
  for f in "$ADMIT_DIR"/*.req; do
    [ -e "$f" ] || continue
    n="$(basename "$f" .req)"
    p="$(sed -n 's/^pid=//p'     "$f" 2>/dev/null | head -1)"
    by="$(sed -n 's/^by=//p'     "$f" 2>/dev/null | head -1)"
    at="$(sed -n 's/^at=//p'     "$f" 2>/dev/null | head -1)"
    pk="$(sed -n 's/^parked=//p' "$f" 2>/dev/null | head -1)"
    rm -f "$f" 2>/dev/null || true
    verdict=stale; [ "$p" = "$$" ] && verdict=take
    printf '%s\t%s\t%s\t%s\t%s\n' "$verdict" "$n" "${by:-?}" "${at:-0}" "${pk:-0}"
  done
  return 0
}

# ── the OPERATOR's half: is there a run to offer work to at all? ──────────────

ADMIT_RUN_PID=""; ADMIT_RUN_ID=""; ADMIT_RUN_EVENTS=""; ADMIT_RUN_NAMES=""
ADMIT_REASON=""

# admit_run_read — find the live run that is open to admission, or refuse with the
# reason. READ-ONLY and cheap by contract: refusing this must write nothing and touch
# no state, because "there is no run" is the commonest thing an operator will hear and
# it would be absurd for it to leave litter behind.
admit_run_read() {
  local ns
  ADMIT_RUN_PID=""; ADMIT_RUN_ID=""; ADMIT_RUN_EVENTS=""; ADMIT_RUN_NAMES=""
  if ! admit_paths; then
    ADMIT_REASON="no chief state directory resolved for this repo"
    return 1
  fi
  if [ ! -f "$ADMIT_OPEN" ]; then
    ADMIT_REASON="no run in this repo is scheduling. A set may only be widened while the scheduler is deciding what to launch — before the first launch and after the last there is nothing to widen"
    return 1
  fi
  ADMIT_RUN_PID="$(sed -n 's/^pid=//p'      "$ADMIT_OPEN" 2>/dev/null | head -1)"
  ADMIT_RUN_ID="$(sed -n 's/^runid=//p'     "$ADMIT_OPEN" 2>/dev/null | head -1)"
  ADMIT_RUN_EVENTS="$(sed -n 's/^events=//p' "$ADMIT_OPEN" 2>/dev/null | head -1)"
  ADMIT_RUN_NAMES="$(sed -n 's/^names=//p'  "$ADMIT_OPEN" 2>/dev/null | head -1)"
  ns="$(sed -n 's/^ns=//p' "$ADMIT_OPEN" 2>/dev/null | head -1)"
  # A pid means nothing without the namespace it was numbered in (engine/reap.sh). With
  # a state prefix shared across containers, `kill -0` on a foreign pid answers about
  # whatever LOCAL process wears that number — so an unanswerable question refuses
  # instead of being guessed at. Both sides of the comparison go through the one
  # function that owns the token; a second spelling of it does not degrade, it inverts.
  if [ "$ns" != "$(chief_ns_token)" ]; then
    ADMIT_REASON="the run holding this repo was numbered in another PID namespace ($ns) — whether pid $ADMIT_RUN_PID is alive is not a question this side can ask, and it will not guess"
    return 1
  fi
  if ! chief_pid_alive "$ADMIT_RUN_PID"; then
    ADMIT_REASON="pid $ADMIT_RUN_PID opened admission and is gone — its marker outlived it ($ADMIT_OPEN)"
    return 1
  fi
  return 0
}

# admit_request NAME — record the offer DURABLY, addressed to the run that is open.
# Durable because the answer is not due yet: admission is at the next wave boundary,
# and the request has to survive the gap. It carries WHO asked, WHEN, WHICH run it was
# made of, and whether a park was waived — never the verdict, which is re-earned at
# admission against the tasklist as it then stands.
admit_request() {
  local tmp
  if ! admit_paths || ! mkdir -p "$ADMIT_DIR" 2>/dev/null; then
    ADMIT_REASON="cannot write the request queue under ${STATE_ROOT:-(no state root)}"
    return 1
  fi
  tmp="$ADMIT_DIR/$1.req.tmp.$$"
  {
    echo "name=$1"
    echo "pid=$ADMIT_RUN_PID"
    echo "runid=$ADMIT_RUN_ID"
    echo "by=${USER:-${LOGNAME:-unknown}}"
    echo "at=$(date +%s)"
    echo "parked=${ADMIT_PARKED_OK:-0}"
  } > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$ADMIT_DIR/$1.req" 2>/dev/null && return 0
  rm -f "$tmp" 2>/dev/null || true
  ADMIT_REASON="cannot write the request $ADMIT_DIR/$1.req"
  return 1
}

# ── THE RULES ─────────────────────────────────────────────────────────────────
#
# admit_check NAME SET — would this tasklist have been legal at launch? 0 = yes;
# non-zero sets ADMIT_REASON to the refusal, which is the only thing either caller
# reports. SET is the rest of the WIDENED run: the names already in it plus the other
# names in the same offer, so a newcomer may depend on a newcomer.
# ADMIT_PARKED_OK=1 waives the park exactly as `chief run --parked` does.
admit_check() {
  local n="$1" have="${2:-}" d dk out
  ADMIT_REASON=""
  case " $have " in *" $n "*) ADMIT_REASON="already in this run"; return 1 ;; esac
  # MERGED BEFORE EXISTS, in that order, and the order is the whole of the second
  # reason being reachable: a tasklist that merged has no live JSON left — it IS the
  # record in completed/ — so asking about the file first answers "no such tasklist"
  # for every already-merged name and the refusal an operator needs is never spoken.
  # (This is also the order the driver derives $NAMES in: is_recorded_done, then the
  # file.) is_recorded_done leaves the record it consulted in DEP_RECORD
  # (engine/crossrepo.sh's set-a-global/print-it pair), so naming it costs no fork.
  if is_recorded_done "$n"; then
    ADMIT_REASON="already recorded done — $DEP_RECORD carries mergedToMain"
    return 1
  fi
  if [ ! -f "$SRC/$n.json" ]; then
    ADMIT_REASON="no such tasklist: $TASKS_REL/$n.json, and no merged record either"
    return 1
  fi
  if [ "$(jq -r '.parked // false' "$SRC/$n.json" 2>/dev/null)" = "true" ] \
     && [ "${ADMIT_PARKED_OK:-0}" != 1 ]; then
    out="$(jq -r '((.parkedReason // "") | tostring) | gsub("[\n\r\t]"; " ")' "$SRC/$n.json" 2>/dev/null)"
    [ -n "$out" ] || out="the tasklist does not say why"
    ADMIT_REASON="parked: $out — a park is a decision, not a failure. Offer it with --parked to run it once anyway"
    return 1
  fi
  # THE SAME LINT, run the way an operator runs it. In a subshell and from $REPO,
  # because `chief lint` resolves its project from the cwd upward and this may be
  # called from anywhere.
  if ! out="$(cd "$REPO" 2>/dev/null && bash "$ADMIT_CLI" lint "$n" 2>&1)"; then
    ADMIT_REASON="failed lint: $(printf '%s' "$out" | grep '✗' | head -1 | sed 's/^ *//')"
    return 1
  fi
  for d in $(deps_of "$n"); do
    is_recorded_done "$d" && continue
    dk="$(dep_key "$d")"
    case " $have $n " in *" $dk "*) continue ;; esac
    dep_verdict_set "$d"
    # An unmerged LOCAL dependency that exists as a live tasklist is the one refusal
    # with an obvious fix, so it gets the fix rather than the classification: offer
    # both in one breath and the newcomer waits for its own dependency.
    if [ "$DEP_CLASS" = unmerged ] && [ -z "$(dep_repo "$d")" ] && [ -f "$SRC/$d.json" ]; then
      ADMIT_REASON="dependency \"$d\" is neither merged nor in this run — offer them together: chief offer $d $n"
    else
      ADMIT_REASON="dependency \"$d\" cannot be satisfied in this run: $DEP_DETAIL"
    fi
    return 1
  done
  return 0
}
