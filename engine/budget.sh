#!/usr/bin/env bash
# engine/budget.sh — the DIFF-SIZE BUDGET: how large one STORY's change was allowed
# to get, measured on the branch chief is about to merge.
#
# WHY THERE IS A BUDGET AT ALL. The overlap-zone registry next door (engine/zones.sh)
# answers "which domains need a human regardless of the gate". This file answers the
# other half of the same research finding: the AgenticFlict dataset reports that
# larger diffs correlate with higher merge-conflict probability, which makes CHANGE
# SIZE the lever an orchestrator actually controls. Chief had no size budget of any
# kind — a story could grow to two thousand lines and nothing anywhere said so.
#
# WHY THE DEFAULT IS A WARNING. A hard block by default would be wrong, and wrong in
# the expensive direction: a rename sweep, a generated file, a codemod and a genuine
# large refactor are all legitimately big, and a gate that stops them is a gate an
# operator switches off — at which point it stops reporting the case it was built
# for too. So the default makes oversize VISIBLE (worker log · the story's own record
# · `chief ps`/`monitor`) and merges anyway; a repo that wants teeth sets
# CHIEF_DIFF_BUDGET=block, and then an oversized branch waits for the same
# `chief approve` an overlap zone waits for. See docs/reference/diff-budget.md.
#
# WHAT IT MEASURES, AND IN WHAT UNITS. The branch's real diff against
# $CHIEF_BASE_BRANCH — the same scope the verify hook is given — DECOMPOSED BY STORY.
# The story is chief's unit of work and of review (one iteration, one story, one
# `feat: [US-x] - Title` commit), so it is the unit a size budget has to be in: a
# tasklist of six small end-to-end stories is exactly the shape the budget is trying
# to encourage, and judging it on its total would punish it for being right.
# Commits whose subject carries no `[US-x]` id are grouped under `-` and reported the
# same way, so nothing measured goes missing.
#
# THE SWEEP DISTINCTION. "12 files" means two very different things, and the message
# has to tell them apart or it is noise: a rename/move sweep (git's own -M rename
# detection counts them) and a wide-but-shallow edit are BREADTH, while a few files
# gaining hundreds of lines each is unbounded GROWTH. budget_shape() names which one
# it is looking at, on the evidence, and never guesses beyond it.
#
# SETTINGS — per repo in .chief/config, environment wins (documented defaults):
#   CHIEF_DIFF_BUDGET_LINES=400   changed lines (added + deleted) per story; 0 = off
#   CHIEF_DIFF_BUDGET_FILES=20    changed files per story;                   0 = off
#   CHIEF_DIFF_BUDGET=warn        warn (default) · block (hold for approval) · off
#
# Bash 3.2 only: no associative arrays, no process substitution. Every awk that
# touches a commit subject runs under LC_ALL=C — subjects here are full of em-dashes,
# and BSD awk aborts on a multi-byte character the moment tolower()/substr() sees one.

BUDGET_DEFAULT_LINES=400
BUDGET_DEFAULT_FILES=20

# budget_num VALUE DEFAULT -> a non-negative integer. A malformed setting falls back
# to the default rather than taking down a merge phase over a typo in a config file.
budget_num() {
  case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}

# budget_mode -> warn | block | off  (anything unrecognised reads as the default)
budget_mode() {
  case "${CHIEF_DIFF_BUDGET:-warn}" in
    block) printf 'block' ;;
    off|none|0) printf 'off' ;;
    *) printf 'warn' ;;
  esac
}

# The durable record, named in ONE place. Lives in the driver's state dir ($STATE =
# <state>/parallel), which outlives the worktree — `chief ps` reads it from another
# process entirely, and it is what carries the finding past the merge.
budget_file() { printf '%s/%s.budget.json' "$1" "$2"; }

# budget_rows REPO BASE -> one TAB-separated line per story, in commit order:
#     <story> <TAB> <files> <TAB> <lines> <TAB> <renames> <TAB> <commits> <TAB> <subject>
# One `git log` pass carries both the commit headers (\001<sha> <TAB> <subject>) and
# each commit's numstat rows, so the whole decomposition costs a single git call.
budget_rows() {
  git -C "$1" log --no-merges --reverse -M --numstat --format='%x01%H%x09%s' "$2..HEAD" 2>/dev/null \
  | LC_ALL=C awk -F'\t' '
      /^\001/ {
        subj = $2; story = "-"
        if (match(subj, /\[[^]]+\]/)) story = substr(subj, RSTART + 1, RLENGTH - 2)
        if (!(story in seen)) { seen[story] = 1; order[++n] = story; subject[story] = subj }
        commits[story]++
        next
      }
      NF >= 3 {
        # A binary file reports "-" for both counts: it has a size, but not one
        # measured in lines. Counted as a changed FILE, contributing no lines.
        add = ($1 == "-") ? 0 : $1; del = ($2 == "-") ? 0 : $2
        lines[story] += add + del
        # git -M spells a rename in the path field, either "old => new" or
        # "dir/{old => new}/file". Both contain the arrow; nothing else does.
        if (index($3, "=>") > 0) renames[story]++
        if (!((story SUBSEP $3) in path)) { path[story SUBSEP $3] = 1; files[story]++ }
      }
      END {
        for (i = 1; i <= n; i++) { s = order[i]
          printf "%s\t%d\t%d\t%d\t%d\t%s\n", s, files[s], lines[s], renames[s], commits[s], subject[s] }
      }'
  return 0
}

# budget_total REPO BASE -> "<files> <lines> <renames>" for the WHOLE branch diff —
# the same `<base>...HEAD` scope the verify hook measured, reported for context. It
# is never the thing that trips the budget (that is per story, above).
budget_total() {
  git -C "$1" diff --numstat -M "$2"...HEAD 2>/dev/null \
  | LC_ALL=C awk -F'\t' 'NF >= 3 {
      f++; if ($1 != "-") l += $1; if ($2 != "-") l += $2; if (index($3, "=>") > 0) r++
    } END { printf "%d %d %d", f, l, r }'
  return 0
}

# budget_shape FILES LINES RENAMES -> the one phrase that distinguishes BREADTH from
# unbounded GROWTH. Stated as evidence ("7 of 12 files are renames"), never as a
# verdict on whether the change was justified — that judgement is the reader's.
budget_shape() {
  local f="$1" l="$2" r="$3" per=0
  [ "$f" -gt 0 ] && per=$(( l / f ))
  if [ "$r" -gt 0 ] && [ $(( r * 5 )) -ge $(( f * 2 )) ]; then
    printf 'a rename/move sweep — %s of %s file(s) are renames git detected, so this is breadth, not growth' "$r" "$f"
  elif [ "$f" -gt 1 ] && [ "$per" -lt 20 ]; then
    printf 'wide but shallow — ~%s line(s) per file across %s file(s): a sweep, not one file growing unbounded' "$per" "$f"
  else
    printf 'concentrated — ~%s line(s) per file across %s file(s): this is growth, and it is the shape a smaller story would have avoided' "$per" "$f"
  fi
}

# budget_evaluate NAME REPO BASE STATE — measure, and write the durable record.
# Always returns 0: measuring never blocks (the same rule engine/quality.sh states —
# what blocks is the gate that CONSUMES the record). With the budget off, any stale
# record is removed so nothing downstream reports a finding nobody is measuring for.
budget_evaluate() {
  local name="$1" repo="$2" base="$3" state="$4"
  local out tmp rows lim_l lim_f mode sha tf tl tr
  out="$(budget_file "$state" "$name")"
  mode="$(budget_mode)"
  [ "$mode" = off ] && { rm -f "$out" 2>/dev/null; return 0; }
  command -v jq >/dev/null 2>&1 || return 0
  lim_l="$(budget_num "${CHIEF_DIFF_BUDGET_LINES:-}" "$BUDGET_DEFAULT_LINES")"
  lim_f="$(budget_num "${CHIEF_DIFF_BUDGET_FILES:-}" "$BUDGET_DEFAULT_FILES")"
  rows="$(budget_rows "$repo" "$base")"
  sha="$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo)"
  tmp="$out.tmp.$$"
  # The branch totals, read rather than split with `set --`: this function still has
  # its own arguments to protect, and a heredoc is the bash 3.2 way to feed `read`
  # without a subshell swallowing the values.
  tf=0; tl=0; tr=0
  read -r tf tl tr <<EOF
$(budget_total "$repo" "$base")
EOF
  jq -n --arg name "$name" --arg base "$base" --arg sha "$sha" --arg mode "$mode" \
        --arg rows "$rows" --arg at "$(date +%s)" \
        --argjson liml "$lim_l" --argjson limf "$lim_f" \
        --argjson tf "$(budget_num "$tf" 0)" --argjson tl "$(budget_num "$tl" 0)" \
        --argjson tr "$(budget_num "$tr" 0)" '
    def row: split("\t")
      | { story: .[0], files: (.[1] | tonumber), lines: (.[2] | tonumber),
          renames: (.[3] | tonumber), commits: (.[4] | tonumber), subject: (.[5] // "") };
    ( $rows | split("\n") | map(select(length > 0) | row)
            | map(. + { over: ((($liml > 0) and (.lines > $liml))
                            or (($limf > 0) and (.files > $limf))) }) ) as $s
    | { name: $name, base: $base, sha: $sha, at: ($at | tonumber), mode: $mode,
        limit: { lines: $liml, files: $limf },
        total: { files: $tf, lines: $tl, renames: $tr },
        stories: $s,
        over: ([ $s[] | select(.over) ] | length > 0) }
  ' > "$tmp" 2>/dev/null && mv "$tmp" "$out" || { rm -f "$tmp"; return 0; }
  return 0
}

# budget_over STATE NAME — is there a record, and does it report an over-budget
# story? Silent; the single question every caller here asks.
budget_over() {
  [ -s "$(budget_file "$1" "$2")" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e '.over == true' "$(budget_file "$1" "$2")" >/dev/null 2>&1
}

# budget_note STATE NAME — the human paragraph, printed into the worker log at the
# merge phase. One line always (the measurement is worth having even when it passes),
# then a block per over-budget story naming the shape of the excess and what the
# configured enforcement is about to do about it.
budget_note() {
  local rec mode liml limf tf tl row story files lines ren
  rec="$(budget_file "$1" "$2")"
  [ -s "$rec" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  mode="$(jq -r '.mode // "warn"' "$rec" 2>/dev/null)"
  liml="$(jq -r '.limit.lines // 0' "$rec" 2>/dev/null)"
  limf="$(jq -r '.limit.files // 0' "$rec" 2>/dev/null)"
  tf="$(jq -r '.total.files // 0' "$rec" 2>/dev/null)"
  tl="$(jq -r '.total.lines // 0' "$rec" 2>/dev/null)"
  echo "   diff-size budget: branch total $tl line(s) across $tf file(s); budget is ${liml:-0} line(s) / ${limf:-0} file(s) PER STORY (mode $mode)"
  budget_over "$1" "$2" || return 0
  while IFS=$'\t' read -r story files lines ren; do
    [ -n "$story" ] || continue
    echo "   !! $story is OVER the per-story diff budget: $lines line(s), $files file(s)"
    echo "      $(budget_shape "$files" "$lines" "$ren")"
  done <<EOF
$(jq -r '(.stories // [])[] | select(.over) | [.story, .files, .lines, .renames] | @tsv' "$rec" 2>/dev/null)
EOF
  if [ "$mode" = block ]; then
    echo "      CHIEF_DIFF_BUDGET=block — this branch is held for approval (chief approve $2)"
  else
    echo "      CHIEF_DIFF_BUDGET=warn — reported, not blocked; the merge continues. Guidance: docs/reference/diff-budget.md"
  fi
  return 0
}

# budget_holds STATE NAME -> the over-budget stories as ZONE-SHAPED lines
#     <policy> <TAB> <matcher> <TAB> <what matched it> <TAB> <reason>
# and nothing at all under `warn`/`off`. Shaped like a zone on purpose: an oversized
# diff and a declared overlap zone are the SAME question — "this branch is green and
# still needs a person" — so they share one request file, one checksum-bound verdict
# and one `chief approve`, and a branch that trips both is asked about once.
budget_holds() {
  [ "$(budget_mode)" = block ] || return 0
  budget_over "$1" "$2" || return 0
  jq -r '(.limit.lines) as $l | (.limit.files) as $f
         | (.stories // [])[] | select(.over)
         | [ "review",
             (if ($l > 0 and .lines > $l) then "budget:lines" else "budget:files" end),
             (.story + ": " + (.lines | tostring) + " line(s), " + (.files | tostring) + " file(s)"),
             ("the per-story diff-size budget (" + ($l | tostring) + " line(s) / " + ($f | tostring)
              + " file(s)) — larger diffs carry higher conflict probability")
           ] | @tsv' "$(budget_file "$1" "$2")" 2>/dev/null
  return 0
}

# budget_annotate TASKLIST_JSON STATE NAME — write each story's measured size into
# THE STORY'S OWN RECORD, in the run's tasklist snapshot. That snapshot is what
# finalize_merged() copies into completed/, so the size a story shipped at outlives
# the run's state dir and lands in the permanent record next to its passes/notes.
# Never destructive: any failure leaves the tasklist exactly as it was.
budget_annotate() {
  local tl="$1" rec tmp
  rec="$(budget_file "$2" "$3")"
  [ -n "$tl" ] && [ -f "$tl" ] && [ -s "$rec" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  tmp="$tl.budget.$$"
  # `first([...])` and not `$s[] as $m`: a story with no matching commit yields ZERO
  # results from an iterating binding, which would silently DROP it from the array.
  jq --slurpfile b "$rec" '
      ($b[0].stories // []) as $s
      | .userStories |= map(
          . as $st
          | ([ $s[] | select(.story == $st.id) ] | first) as $m
          | if $m == null then .
            else . + { diffSize: { files: $m.files, lines: $m.lines, renames: $m.renames,
                                   budget: ($b[0].limit), overBudget: $m.over } }
            end)
    ' "$tl" > "$tmp" 2>/dev/null && mv "$tmp" "$tl" || rm -f "$tmp"
  return 0
}
