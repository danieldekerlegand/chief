#!/usr/bin/env bash
# engine/retire.sh — RETIRING A TASKLIST WHOSE ANSWER WAS NO.
#
# THE ASK, in the words of the agent that needed it. cuneiform
# `283-nixos-bare-metal-vpn-topology-target` ended its 59th iteration with the note
# "this tasklist can NEVER report all-stories-true and no further iteration can change
# that. It needs MANUAL RETIREMENT." There was no command for that, so the ask had
# nowhere to land: the operator's only route was to hand-edit JSON, move a file into
# completed/ and hope they got `mergedToMain` right.
#
# WHAT THIS RETIRES, and it is a narrow thing on purpose: a tasklist whose DELIVERED
# stories passed and whose remaining story TERMINATED FALSE — declared `terminalFalse`
# (engine/terminal.sh) and carrying the measurement behind the answer. Every story
# settled, at least one of them settled NO. That is a tasklist that finished and found
# something.
#
# WHAT IT REFUSES, which is the whole safety argument. A tasklist whose stories are
# merely UNFINISHED is not this, and a command that could not tell the two apart would
# be a way to bury incomplete work — the exact failure `terminalFalse` is inert without
# evidence to prevent. So:
#   · an ordinary open story (no declaration)            -> REFUSED, story named
#   · a declared story with NO measurement recorded      -> REFUSED, story named
#   · no story terminated negative at all                -> REFUSED (a tasklist that
#     merely finished retires itself when it MERGES; this command is not that path)
# and the refusal always names the story that caused it, because "refused" without a
# name is what sends an operator back to hand-editing JSON.
#
# WHERE THE ANSWER IS READ FROM. The DECLARATION and the FINDING live in different
# files once a run has happened, and both are needed:
#   · the authored tasklist  tasks/chief/<name>.json      — `terminalFalse`, written by
#     hand (often only AFTER a run stopped and told the operator to write it)
#   · the run's record       .chief/state/snapshots/<name>.json, else the tasklist as
#     committed ON the branch — `passes` and `notes` as the agent last recorded them
# So the two are UNIONED per story id: a story is declared if either says so, its
# finding is the run's when the run recorded one, and it passes if either recorded a
# pass. Which file supplied the measurement is REPORTED, because an operator about to
# retire work needs to know what they are retiring.
#
# THE FINDING TRAVELS. A story that terminates false usually names the thing to do
# instead, and that closing action is the most valuable output the tasklist produced —
# `283`'s was "no file under core/ services/ apps/ calls a MaaS API at all". It must
# survive somewhere a SUCCESSOR TASKLIST CAN CITE rather than only in a run log that is
# rotated away, so the completed/ record carries it twice: on the story (`passes:false`
# + `terminalFalse` + `notes`, untouched) and again in a `retiredOnNegative` block that
# names the story, its title and its finding without a reader having to know the
# predicate.
#
# THE RETIREMENT TRAP, and why this command can refuse for a second reason. A
# completed/ record satisfies a `dependsOn` edge only if it carries `mergedToMain` (see
# engine/deps.sh's `retired` verdict and engine/counterpart.sh). A tasklist retired on
# a negative usually never merged — so filing it while something still depends on it
# blocks that dependent FOREVER, on a record that can never be stamped. When the work
# IS in the base branch the sha is stamped and there is no trap; when it is not, live
# dependents are named and the retirement is refused until they are repointed. The same
# rule `chief decide --retire` already applies, for the same reason.
#
# bash 3.2 · jq + git.
set -uo pipefail

RETIRE_ENGINE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=engine/terminal.sh
. "$RETIRE_ENGINE/terminal.sh"

PROJECT="${CHIEF_PROJECT:-$PWD}"
TASKS_REL="${CHIEF_TASKS_DIR:-tasks/chief}"
SRC="$PROJECT/$TASKS_REL"
COMPLETED="$SRC/completed"
STATE_REL="${CHIEF_STATE_DIR:-.chief/state}"
SNAP="$PROJECT/$STATE_REL/snapshots"
PSTATE="$PROJECT/$STATE_REL/parallel"
BASE="${CHIEF_BASE_BRANCH:-main}"

retire_usage() {
  cat <<'EOF'
usage: chief retire --negative NAME [NAME…] [-n|--dry-run] [--no-commit]

  Retire a tasklist whose delivered stories PASSED and whose remaining story
  TERMINATED FALSE — declared "terminalFalse" and carrying the measurement behind
  the answer (docs/reference/tasklist-schema.md). The completed/ record keeps the
  negative as `false` with its finding, plus a `retiredOnNegative` block a successor
  tasklist can cite, and the tasklist stops being scheduled.

  It REFUSES a tasklist whose stories are merely unfinished, and one whose declared
  story recorded no measurement. --negative is required: this command retires work
  that FOUND something, and there is no other kind of retirement here.
EOF
}

_r_say()  { printf '%s\n' "$*"; }
_r_ref()  { printf '!! %s\n' "$*" >&2; }

# ── the record the verdict is read from ──────────────────────────────────────
# retire_record NAME AUTHORED OUT — write the UNION of the authored tasklist and the
# run's record to OUT, and set RETIRE_FROM to a readable account of where the
# measurement came from. Never fails on a missing run record: with no run behind it the
# authored file is the whole truth (the hand-authored case, which is legitimate — the
# operator may have written the finding into the tasklist themselves).
RETIRE_FROM=""
retire_record() {
  local name="$1" auth="$2" out="$3" meas="" branch tmp
  branch="$(jq -r '.branchName // empty' "$auth" 2>/dev/null)"
  if [ -f "$SNAP/$name.json" ] && jq -e . "$SNAP/$name.json" >/dev/null 2>&1; then
    meas="$SNAP/$name.json"; RETIRE_FROM="the run's snapshot $STATE_REL/snapshots/$name.json"
  elif [ -n "$branch" ] && git -C "$PROJECT" rev-parse --verify "$branch" >/dev/null 2>&1; then
    tmp="$out.branch"
    if git -C "$PROJECT" show "$branch:$TASKS_REL/$name.json" > "$tmp" 2>/dev/null \
       && jq -e . "$tmp" >/dev/null 2>&1; then
      meas="$tmp"; RETIRE_FROM="the tasklist as committed on $branch"
    fi
  fi
  if [ -z "$meas" ]; then
    RETIRE_FROM="the authored tasklist alone (no run record found)"
    cp "$auth" "$out"; return 0
  fi
  # The union, per story id. Declared if EITHER says so; the finding is the run's when
  # the run recorded one; passing if either recorded a pass. A story the run knows and
  # the tasklist does not is appended rather than dropped — losing a story here would be
  # losing the very evidence this command exists to preserve.
  jq -n --slurpfile a "$auth" --slurpfile m "$meas" '
    def pick($ms; $id): ($ms | map(select(.id == $id)) | first);
    ($a[0]) as $auth | (($m[0].userStories) // []) as $ms
    | $auth
    | .userStories =
        [ (($auth.userStories) // [])[]
          | . as $s | ((pick($ms; $s.id)) // {}) as $r
          | $s
            + { passes: (($s.passes == true) or ($r.passes == true)),
                notes:  (if ((($r.notes // "") | tostring) | test("\\S"))
                         then ($r.notes) else ($s.notes // "") end) }
            + (if ($s.terminalFalse == true) or ($r.terminalFalse == true)
               then {terminalFalse: true} else {} end) ]
        + [ $ms[] | select(.id as $i
              | ((($auth.userStories) // []) | map(.id) | index($i)) == null) ]' \
    > "$out" 2>/dev/null || cp "$auth" "$out"
  rm -f "$out.branch"
}

# retire_open_report PRD — the OPEN stories carrying no declaration: ordinary
# unfinished work, and the first reason this command refuses. terminal.sh reports the
# INERT ones (declared, never measured); these are the other half and they get their
# own sentence, because the fix is a different one.
retire_open_report() {
  jq -r "$(_terminal_prog '
    (.userStories // [])[]
    | select((settled | not) and (declared | not))
    | "   ○ \(.id // "?") — \(.title // "(untitled)")\n"
      + "       passes:false, no `terminalFalse` declaration — ordinary unfinished work"')" \
    "$1" 2>/dev/null
}

# retire_dependents NAME — live tasklists in THIS repo whose dependsOn names NAME.
# Local only, and the report says so: a cross-repo dependent lives in a repo this
# command does not read, so it is named as a limit rather than claimed as checked.
retire_dependents() {
  local name="$1" f out=""
  for f in "$SRC"/*.json; do
    [ -f "$f" ] || continue
    [ "$(basename "$f" .json)" = "$name" ] && continue
    jq -e --arg d "$name" '(.dependsOn // []) | any(. == $d)' "$f" >/dev/null 2>&1 \
      && out="$out $(basename "$f" .json)"
  done
  printf '%s' "${out# }"
}

# retire_merged_sha BRANCH — the sha of BRANCH when its tip is already contained in the
# base branch, empty otherwise. This is the whole `mergedToMain` decision: chief stamps
# what it can VERIFY is in the base, and never a sha it merely hopes is.
retire_merged_sha() {
  local branch="$1"
  [ -n "$branch" ] || return 0
  git -C "$PROJECT" rev-parse --verify "$branch" >/dev/null 2>&1 || return 0
  git -C "$PROJECT" merge-base --is-ancestor "$branch" "$BASE" 2>/dev/null || return 0
  git -C "$PROJECT" rev-parse "$branch" 2>/dev/null
}

# ── one tasklist ─────────────────────────────────────────────────────────────
# 0 when it retired (or would, under --dry-run); 1 on a refusal.
retire_one() {
  local name="$1" dry="$2" commit="$3"
  local auth="$SRC/$name.json" rec="$COMPLETED/$name.json" tmp branch sha deps ids
  if [ -f "$rec" ] && [ ! -f "$auth" ]; then
    _r_say ">> $name is already retired — $TASKS_REL/completed/$name.json"; return 0
  fi
  [ -f "$auth" ] || { _r_ref "$name: no live tasklist $TASKS_REL/$name.json in $(basename "$PROJECT")"; return 1; }
  jq -e . "$auth" >/dev/null 2>&1 || { _r_ref "$name: $TASKS_REL/$name.json is not valid JSON"; return 1; }

  tmp="$(mktemp "${TMPDIR:-/tmp}/chief-retire.XXXXXX")" || return 1
  retire_record "$name" "$auth" "$tmp"
  terminal_counts "$tmp"
  branch="$(jq -r '.branchName // empty' "$tmp" 2>/dev/null)"

  # REFUSAL 1 — anything still open. Both halves are reported, because the fix differs:
  # an ordinary story is unfinished work; a declared-and-unmeasured one is work that was
  # skipped behind a declaration.
  if [ "${TERMINAL_OPEN:-?}" != "0" ]; then
    _r_ref "$name: REFUSED — this tasklist is not finished. ${TERMINAL_OPEN} of ${TERMINAL_TOTAL} stories are still OPEN:"
    { retire_open_report "$tmp"; terminal_inert_report "$tmp"; } >&2
    cat >&2 <<'EOF'
   Retiring this would bury unfinished work, which is the one thing this command must
   not do. Either finish the story, or — if `false` IS the honest answer — record the
   measurement and declare it: "terminalFalse": true on that story
   (docs/reference/tasklist-schema.md). A declaration with nothing measured settles
   nothing, deliberately.
EOF
    rm -f "$tmp"; return 1
  fi

  # REFUSAL 2 — nothing terminated negative. Every story passed, so this is an ordinary
  # completion and `chief run` retires it when the branch merges. Filing it here would
  # record work as done that never went through the gate.
  if [ "${TERMINAL_NEGATIVE:-0}" = "0" ]; then
    _r_ref "$name: REFUSED — no story here terminated on a measured NEGATIVE (all ${TERMINAL_TOTAL} passed)."
    {
      echo "   This command retires a tasklist that FOUND something. One whose stories all pass"
      echo "   is retired by \`chief run\` when its branch merges — that path runs the verify gate;"
      echo "   this one does not."
    } >&2
    rm -f "$tmp"; return 1
  fi

  ids="$(terminal_negative_ids "$tmp")"
  sha="$(retire_merged_sha "$branch")"
  deps="$(retire_dependents "$name")"

  # REFUSAL 3 — the retirement trap. A record with no `mergedToMain` satisfies no
  # dependency edge, so filing one under a live dependent blocks that dependent forever,
  # on a record that can never be stamped (engine/deps.sh's `retired` verdict).
  if [ -z "$sha" ] && [ -n "$deps" ]; then
    _r_ref "$name: REFUSED — its work is not in $BASE, and these tasklists still depend on it: $deps"
    cat >&2 <<'EOF'
   A completed/ record with no "mergedToMain" satisfies no dependency edge, so filing
   this one would block each of those FOREVER, on a record that can never be stamped.
   Repoint their "dependsOn" first — at the successor tasklist that will carry the work
   — then retire this one. (Dependents in OTHER repos are not read here.)
EOF
    rm -f "$tmp"; return 1
  fi

  _r_say ">> $name — every story settled; ${TERMINAL_NEGATIVE} of ${TERMINAL_TOTAL} terminated on a NEGATIVE answer ($ids)."
  _r_say "   measurement read from: $RETIRE_FROM"
  terminal_negative_report "$tmp"
  if [ -n "$sha" ]; then
    _r_say "   its work is in $BASE — recording mergedToMain=$sha"
  else
    _r_say "   its work is NOT in $BASE — the record carries no \"mergedToMain\" and satisfies no dependency edge."
    _r_say "   Nothing depends on it here; anything that comes to must point at a successor, not at this record."
  fi
  if [ "$dry" = 1 ]; then
    _r_say "   (dry run — nothing written; drop -n to file it)"
    rm -f "$tmp"; return 0
  fi

  mkdir -p "$COMPLETED"
  # The record. The negative keeps `passes:false` and its notes — rewriting it to true
  # would leave completed/ asserting the opposite of what the tasklist found — and the
  # finding is lifted into `retiredOnNegative` as well, so a successor can cite it
  # without knowing the predicate.
  if ! jq --arg sha "$sha" --arg from "$RETIRE_FROM" "$(_terminal_prog '
        . as $d
        | .retiredOnNegative = {
            at: (now | todateiso8601),
            by: "chief retire --negative",
            branch: ($d.branchName // null),
            merged: ($sha != ""),
            source: $from,
            stories: [ ($d.userStories // [])[] | select(negative)
                       | {id: .id, title: (.title // null), finding: ((.notes // "") | tostring)} ] }
        | if $sha != "" then .mergedToMain = $sha else . end')" \
        "$tmp" > "$rec" 2>/dev/null; then
    _r_ref "$name: could not write $TASKS_REL/completed/$name.json"; rm -f "$tmp" "$rec"; return 1
  fi
  rm -f "$tmp"
  rm -f "$auth"
  # State that would otherwise keep describing a tasklist that no longer exists. The
  # `.cannot-complete` diagnosis is what this retirement ANSWERS, so it goes with it.
  if [ -d "$PSTATE" ]; then
    rm -f "$PSTATE/$name.cannot-complete" 2>/dev/null || true
    printf 'RETIRED-NEGATIVE %s\n' "$ids" > "$PSTATE/$name.status" 2>/dev/null || true
  fi
  _r_say "   filed $TASKS_REL/completed/$name.json and removed $TASKS_REL/$name.json — it will not be scheduled again"

  if [ "$commit" = 1 ] && git -C "$PROJECT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$PROJECT" add -- "$TASKS_REL/completed/$name.json" "$TASKS_REL/$name.json" >/dev/null 2>&1 || true
    if git -C "$PROJECT" commit -q -m "chore(chief): $name retired on a NEGATIVE finding — $ids answered NO" \
         -- "$TASKS_REL/completed/$name.json" "$TASKS_REL/$name.json" >/dev/null 2>&1; then
      _r_say "   committed $(git -C "$PROJECT" rev-parse --short HEAD 2>/dev/null)"
    else
      _r_say "   (not committed — commit $TASKS_REL/ yourself)"
    fi
  fi

  if [ -f "$RETIRE_ENGINE/events.sh" ]; then
    # shellcheck source=engine/events.sh
    . "$RETIRE_ENGINE/events.sh"
    CHIEF_EVENTS_FILE="${CHIEF_RUNS:-$PROJECT/$STATE_REL}/retirements.events.jsonl" \
    CHIEF_EVENT_REPO="$PROJECT" \
      event_emit tasklist.terminal-negative name="$name" state=retired \
        detail="retired on a negative: $ids${sha:+ @$sha}" 2>/dev/null || true
  fi
  return 0
}

retire_main() {
  local dry=0 commit=1 negative=0 names="" n rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --negative)     negative=1; shift ;;
      -n|--dry-run)   dry=1; shift ;;
      --no-commit)    commit=0; shift ;;
      -h|--help)      retire_usage; return 0 ;;
      -*)             echo "chief retire: unknown option $1" >&2; retire_usage >&2; return 2 ;;
      *)              names="$names ${1%.json}"; shift ;;
    esac
  done
  if [ "$negative" != 1 ]; then
    {
      echo "chief retire: --negative is required."
      echo "  Chief retires a FINISHED tasklist by MERGING it (\`chief run\`). The only"
      echo "  retirement an operator makes by hand is on a NEGATIVE finding."
      retire_usage
    } >&2
    return 2
  fi
  [ -n "$names" ] || { { echo "chief retire: name a tasklist to retire"; retire_usage; } >&2; return 2; }
  command -v jq >/dev/null 2>&1 || { echo "chief retire: jq is required" >&2; return 2; }
  for n in $names; do retire_one "$n" "$dry" "$commit" || rc=1; done
  return "$rc"
}

# Sourced as `. retire.sh lib` it defines functions only; run, it is the command.
if [ "${1:-}" = lib ]; then
  return 0 2>/dev/null || exit 0
fi
retire_main "$@"
