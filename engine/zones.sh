#!/usr/bin/env bash
# engine/zones.sh — the OVERLAP ZONE REGISTRY: a policy layer ABOVE the merge floor.
#
# WHAT THE MERGE FLOOR DOES NOT CATCH. Chief's correctness guarantee is the merge
# phase — rebase onto the latest base, re-verify, merge --no-ff — and it is a real
# guarantee for the risk it was built for: TEXTUAL interference between parallel
# branches surfaces as a rebase conflict, staleness as a verify failure. It says
# nothing at all about the second risk parallel agents carry: each holds a different
# slice of context, so two branches can produce individually correct code whose
# DESIGNS disagree. Both rebase clean. Both verify green. Nothing collides, and the
# result is still wrong. No automated gate chief could add detects that — the
# disagreement is at the level of intent, which is where a person has standing and a
# test does not.
#
# So this file adds the one mechanism that helps: a repo declares the domains where
# a green gate is NOT sufficient authority to merge, and a branch that changed one
# of them waits for a human YES. It is deliberately small:
#
#   · IT NEVER WEAKENS THE FLOOR. The approval is asked AFTER the rebase and AFTER
#     a green verify, never instead of them, so a person is never asked to bless a
#     branch that has not already cleared every automated bar. A no-op registry (no
#     file, or no zone matched) leaves the merge phase byte-for-byte as it was.
#   · IT MATCHES ON THE BRANCH'S REAL CHANGED FILES, not on the tasklist's `touches`
#     tags. That is the measured failure this exists to survive: a tasklist whose
#     `touches` are CONCEPTUAL TAGS (`cuneiform-engine`, `render-goldens` — the 280
#     case) matches nothing lexically, so anything keyed on tags alone is invisible
#     exactly where it is needed. A `touches:<domain>` matcher is offered as a
#     SECONDARY key for repos whose tags really are domains; the path matchers are
#     the load-bearing half and are checked against `git diff --name-only base...HEAD`.
#   · THE VERDICT IS A FILE, under the driver's state dir — not the worktree, which
#     is deleted and rebuilt by every run. An approval given once is never asked for
#     twice, across process death, an operator pause, or a rebuilt worktree.
#   · THE VERDICT IS BOUND TO WHAT IT APPROVED, by checksum over the changed-file
#     list AND the zones it matched (`zones_digest`). Approving a branch does not
#     pre-approve the next thing it does, and widening the registry re-asks.
#
# THE OTHER RULE IN THE SAME LAYER. `zones_merge_gate` below is the merge phase's ONE
# policy question, and it asks two rules: the declared zones here, and the per-story
# DIFF-SIZE BUDGET in engine/budget.sh (which reports on every branch and, under
# CHIEF_DIFF_BUDGET=block, contributes hold lines in this file's own zone shape).
# They are unified at the gate rather than stacked as two checkpoints because they
# are the same question — "this branch is green and still needs a person" — and a
# branch that trips both must be asked about ONCE. A plan approval (docs/plan-review.md)
# is the genuinely different decision: it is asked BEFORE any code exists, about
# intent; this one is asked AFTER the floor has run, about a finished, verified diff.
#
# REGISTRY FORMAT (docs/reference/overlap-zones.md). One zone per line, in
# `.chief/zones.conf` (override with $CHIEF_ZONES); `#` starts a comment:
#
#     <policy>   <matcher>            [reason…]
#     review     path:engine/*.sh     the scheduler is where a design split is fatal
#     review     touches:engine
#     serialize  path:docs/
#
#   policy   `serialize` — today's behaviour exactly: the scheduler already
#            serializes on `touches`, and nothing in the merge phase changes.
#            Declaring one documents the domain and makes it visible in the log.
#            `review`    — serialize AND require an explicit human approval before
#            the merge, no matter how green the gate came back.
#   matcher  `path:<glob>`      a shell glob matched against each repo-relative
#                               changed path. `*` crosses `/` (so `engine/*.sh`
#                               covers `engine/x/y.sh`); a trailing `/` means
#                               "everything beneath this directory".
#            `touches:<domain>` an exact tasklist `touches` domain name.
#
# Bash 3.2 only: no associative arrays, no `declare -A`, no process substitution.

# zones_file [REPO] -> the registry path, or nothing when the repo declares none.
# Absence is the DEFAULT and is never an error: a repo with no zones.conf gets the
# merge phase it had before this file existed.
zones_file() {
  local f="${CHIEF_ZONES:-.chief/zones.conf}"
  case "$f" in /*) ;; *) f="${1:-.}/$f" ;; esac
  [ -f "$f" ] || return 0
  printf '%s' "$f"
}

# zones_path_match PATTERN PATH — glob semantics for the `path:` matcher, in one
# place so the driver, `chief approve` and the docs cannot drift apart.
zones_path_match() {
  local pat="$1" f="$2"
  case "$pat" in
    */) case "$f" in "$pat"*) return 0 ;; esac; return 1 ;;
  esac
  # Intentionally unquoted: $pat IS the glob (operator-authored, from the registry).
  # shellcheck disable=SC2254
  case "$f" in $pat) return 0 ;; esac
  return 1
}

# zones_match POLICY CONF FILES TOUCHES -> one TAB-separated line per MATCHED zone:
#     <policy> <TAB> <matcher> <TAB> <what matched it> <TAB> <reason>
# POLICY filters ('review', 'serialize', or empty for every policy). FILES is the
# branch's changed paths, one per line; TOUCHES is the tasklist's domains, space
# separated. Silent on a malformed line — a registry typo must not take down a run —
# except for a note on stderr, which lands in the worker log next to the decision.
zones_match() {
  local want="$1" conf="$2" files="$3" touches="$4"
  local line policy matcher reason kind pat f t hit had_f=""
  [ -n "$conf" ] && [ -f "$conf" ] || return 0
  case "$-" in *f*) had_f=1 ;; esac
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    # NOGLOB for the split: a `path:engine/*.sh` field must survive word splitting
    # as the literal pattern, not be expanded against the cwd.
    set -f
    # shellcheck disable=SC2086
    set -- $line
    policy="${1:-}"; matcher="${2:-}"; shift 2 2>/dev/null || set --
    reason="$*"
    [ -n "$had_f" ] || set +f
    case "$policy" in
      serialize|review) ;;
      *) echo "zones: ignoring '$conf' line with unknown policy '${policy}' (expected serialize|review)" >&2; continue ;;
    esac
    kind="${matcher%%:*}"; pat="${matcher#*:}"
    [ -n "$pat" ] && [ "$pat" != "$matcher" ] || {
      echo "zones: ignoring '$conf' matcher '${matcher}' (expected path:<glob> or touches:<domain>)" >&2; continue; }
    [ -z "$want" ] || [ "$want" = "$policy" ] || continue
    hit=""
    case "$kind" in
      path)
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          zones_path_match "$pat" "$f" && { hit="$f"; break; }
        done <<EOF
$files
EOF
        ;;
      touches)
        for t in $touches; do
          [ "$t" = "$pat" ] && { hit="touches:$t"; break; }
        done
        ;;
      *) echo "zones: ignoring '$conf' matcher '${matcher}' (expected path:<glob> or touches:<domain>)" >&2; continue ;;
    esac
    [ -n "$hit" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$policy" "$matcher" "$hit" "$reason"
  done < "$conf"
  return 0
}

# zones_digest FILES ZONES -> the short id an approval is BOUND to. Over both halves
# on purpose: re-approving is required when the branch changes what it touches AND
# when the registry widens onto it. cksum is POSIX and everywhere; this is a change
# detector, not a security boundary (same rule as engine/review.sh's plan id).
zones_digest() {
  { printf '%s\n' "${1:-}" | LC_ALL=C sort
    printf '%s\n' "${2:-}" | LC_ALL=C sort
  } | cksum | tr -s ' ' '-' | tr -d ' \n'
}

# The two durable artifacts, named in ONE place. Both live in the driver's state dir
# ($STATE = <state>/parallel), which outlives the worktree and the process.
zones_request_file()  { printf '%s/%s.zone-request.json' "$1" "$2"; }
zones_approval_file() { printf '%s/%s.zone-approval.json' "$1" "$2"; }

# zones_write_request STATE NAME BRANCH BASE SHA DIGEST ZONES FILES — what is being
# asked, written where a human (and `chief approve`) can read it without the run.
zones_write_request() {
  local out tmp
  out="$(zones_request_file "$1" "$2")"; tmp="$out.tmp.$$"
  jq -n --arg name "$2" --arg branch "$3" --arg base "$4" --arg sha "$5" \
        --arg change "$6" --arg zones "$7" --arg files "$8" --arg at "$(date +%s)" '
    { name: $name, branch: $branch, base: $base, sha: $sha, change: $change,
      at: ($at | tonumber),
      zones: ($zones | split("\n") | map(select(length > 0)) | map(split("\t"))
              | map({ policy: .[0], zone: .[1], matched: .[2], reason: (.[3] // "") })),
      files: ($files | split("\n") | map(select(length > 0))) }
  ' > "$tmp" 2>/dev/null && mv "$tmp" "$out" || { rm -f "$tmp"; return 1; }
  return 0
}

# zones_approved APPROVAL DIGEST — is there a YES, and is it for THIS change?
# Silent; both halves matter, exactly as review_approved()'s do.
zones_approved() {
  [ -s "${1:-}" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e --arg c "${2:-}" '(.decision == "approved") and (.change == $c)' "$1" >/dev/null 2>&1
}

# zones_record_approval APPROVAL REQUEST BY NOTE — grant the request.
# DERIVED FROM THE REQUEST FILE, so the digest an approval carries is the one the
# driver computed and can never be a human's transcription of it.
zones_record_approval() {
  local out="$1" req="$2" tmp="$1.tmp.$$"
  [ -s "$req" ] || return 1
  jq --arg by "$3" --arg note "$4" --arg at "$(date +%s)" '
    { name, branch, sha, change, base,
      zones: [ (.zones // [])[] | select(.policy == "review") ],
      decision: "approved", by: $by, note: $note, at: ($at | tonumber) }
  ' "$req" > "$tmp" 2>/dev/null && mv "$tmp" "$out" || { rm -f "$tmp"; return 1; }
  return 0
}

# zones_render ZONES — the matched-zone lines as something a human reads, one per
# line. Used by the worker log, the run summary and `chief approve --list`.
zones_render() {
  printf '%s\n' "${1:-}" | LC_ALL=C awk -F'\t' 'NF >= 3 {
    printf "     %s  %s  (matched: %s)%s\n", $1, $2, $3, ($4 == "" ? "" : "  — " $4)
  }'
  return 0
}

# zones_merge_gate NAME BRANCH WORK_REPO BASE STATE TOUCHES [SCOPE_BASE] — the
# decision the merge phase asks for, and the only entry point driver.sh calls.
#
#   0  MERGE — no zone with policy `review` matched what this branch changed, or one
#      did and this exact change is already approved.
#   1  HOLD  — a `review` zone matched and nobody has said yes to THIS change. The
#      request is on disk; the caller parks the tasklist (`awaiting-approval`).
#
# Called at the very END of the merge phase, so everything it can report is already
# true: the branch is rebased onto the latest base and its verify came back green.
# $live is the caller's liveliness record, by dynamic scope (the same idiom as
# driver.sh's worker_park) — absent, live_set is a no-op and nothing else changes.
#
# SCOPE_BASE is what "this branch's own changes" is measured FROM, and it defaults to
# BASE — which is the same thing on the serialized floor, where HEAD carries nothing
# but this branch. It exists for the opt-in merge queue (engine/mergequeue.sh), where
# a member has been STACKED on its predecessors: there `base...HEAD` is the whole
# batch, so the caller passes the predecessor's tip and both rules below stay per
# BRANCH — a batch can neither dilute an oversized diff into an aggregate nor charge a
# member for a zone one of its peers changed.
zones_merge_gate() {
  local name="$1" branch="$2" repo="$3" base="$4" state="$5" touches="${6:-}" scope="${7:-}"
  local conf files zmatch digest sha
  [ -n "$scope" ] || scope="$base"
  conf="${ZONES_CONF:-$(zones_file "${CHIEF_PROJECT:-.}")}"
  live_set "${live:-}" phase=zone-check
  files="$(git -C "$repo" diff --name-only "$scope"...HEAD 2>/dev/null)"
  # THE POLICY LAYER'S SECOND RULE, evaluated here rather than beside here: the
  # per-story DIFF-SIZE BUDGET (engine/budget.sh, sourced by the driver alongside
  # this file). It measures every branch, records the sizes into the story records,
  # and — only under CHIEF_DIFF_BUDGET=block — contributes zone-shaped hold lines to
  # the match below. Folding it in at this point is what keeps the two rules from
  # DOUBLE-PROMPTING: one checksum, one request file, one `chief approve`, whether a
  # branch tripped a declared zone, an oversized story, or both at once.
  budget_evaluate "$name" "$repo" "$scope" "$state"
  budget_annotate "${SNAP:-}/$name.json" "$state" "$name"
  budget_note "$state" "$name"
  zmatch="$( [ -n "$conf" ] && zones_match review "$conf" "$files" "$touches"
             budget_holds "$state" "$name" )"
  [ -n "$zmatch" ] || return 0                    # nothing in the policy layer matched
  # Bound to WHAT it approved: the changed-file list plus the zones it matched. An
  # approval for a previous change of this branch does not carry over, and widening
  # the registry onto it re-asks.
  digest="$(zones_digest "$files" "$zmatch")"
  if zones_approved "$(zones_approval_file "$state" "$name")" "$digest"; then
    echo ">> $name: the policy layer matched, and this exact change is APPROVED ($digest) — merging"
    zones_render "$zmatch"
    return 0
  fi
  sha="$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo)"
  zones_write_request "$state" "$name" "$branch" "$base" "$sha" "$digest" "$zmatch" "$files" \
    || echo "  !! $name: could not write the approval request under $state — approve with the branch in hand"
  # The whole explanation is printed HERE, where the facts are, so the caller only has
  # to record the park: what was held, which zone held it, and what is actually being
  # asked — which is never "is this green" (it is), but "does this design agree".
  echo "!! $name HELD BY THE MERGE POLICY LAYER — it is rebased onto $base and its verify came back GREEN;"
  echo "   it is not merged because it changed something this repo declared needs a human first:"
  zones_render "$zmatch"
  echo "   The merge floor already ran. What is being asked is the thing no gate can check: whether this"
  echo "   branch's design agrees with what else landed. The request: $(zones_request_file "$state" "$name")"
  return 1
}

# ── the operator's side: reporting a hold, and granting it ───────────────────
# Both are `chief approve`'s work, and both live here rather than in bin/chief so the
# CLI never has to know how a request or a verdict is spelled — the same reason the
# driver calls zones_merge_gate() instead of assembling the decision itself.
zones_show() {   # $1 = <state>/parallel, $2 = tasklist name
  local req app change n
  req="$(zones_request_file "$1" "$2")"; app="$(zones_approval_file "$1" "$2")"
  [ -s "$req" ] || return 0
  change="$(jq -r '.change // empty' "$req" 2>/dev/null || echo)"
  n="$(cat "$1/$2.state" 2>/dev/null || echo)"
  if zones_approved "$app" "$change"; then
    printf '  ✓ %-28s APPROVED (%s) — the next run merges it\n' "$2" "$change"
  else
    printf '  ⏸ %-28s awaiting approval%s\n' "$2" "${n:+ · state $n}"
  fi
  printf '       branch %s · %s changed file(s) · rebased onto %s and verified GREEN\n' \
    "$(jq -r '.branch // "?"' "$req" 2>/dev/null || echo '?')" \
    "$(jq -r '(.files // []) | length' "$req" 2>/dev/null || echo '?')" \
    "$(jq -r '.base // "?"' "$req" 2>/dev/null || echo '?')"
  zones_render "$(jq -r '(.zones // [])[] | [.policy, .zone, .matched, .reason] | @tsv' "$req" 2>/dev/null || echo)"
  return 0
}

zones_approve() {  # $1 = <state>/parallel, $2 = name, $3 = note
  local req app change
  req="$(zones_request_file "$1" "$2")"; app="$(zones_approval_file "$1" "$2")"
  if [ ! -s "$req" ]; then
    echo "chief approve: '$2' is not awaiting approval — no $req" >&2
    echo "  (the run writes the request itself, once the branch has rebased and verified green:" >&2
    echo "   there is nothing to approve until then, and 'chief approve' never pre-approves)" >&2
    return 1
  fi
  change="$(jq -r '.change // empty' "$req" 2>/dev/null || echo)"
  if zones_approved "$app" "$change"; then
    echo "  = $2 is already approved for this exact change ($change) — nothing to do"
    return 0
  fi
  zones_record_approval "$app" "$req" "${USER:-$(id -un 2>/dev/null || echo unknown)}" "${3:-}" \
    || { echo "chief approve: could not write $app" >&2; return 1; }
  echo "  ✓ $2 APPROVED for $change — $(jq -r '[(.zones // [])[] | .zone] | join(", ")' "$req" 2>/dev/null || echo 'its overlap zones')"
  # Re-arm the scheduler state, the same way `chief resume` re-arms a park: the next
  # `chief run` re-dispatches it, finds the verdict on disk and merges without asking
  # again. Harmless when the run is still live — it re-pends every name at launch.
  if [ "$(cat "$1/$2.state" 2>/dev/null || echo)" = awaiting-approval ]; then
    printf 'pending' > "$1/$2.state" 2>/dev/null || true
    command -v live_set >/dev/null 2>&1 && live_set "$1/$2.live.json" name="$2" state=pending phase=approved
  fi
  echo "    merge it:  chief run $2"
  return 0
}
