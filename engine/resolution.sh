#!/usr/bin/env bash
# engine/resolution.sh — WHAT A CONFLICT RESOLUTION DELETED, and whose work it was.
#
# THE SHAPE THE MERGE FLOOR CANNOT SEE. The floor (rebase onto the latest base,
# re-verify, merge --no-ff) catches exactly two risks: TEXTUAL interference, which
# surfaces as a rebase conflict, and STALENESS, which surfaces as a red gate. It
# never compares what a rebase REMOVED against what landed on the base while the
# branch was in flight — so a resolution that throws the base side away clears both.
#
# Measured, in a downstream repository: a branch eight days stale conflicted at the
# floor, and the agent resolving it kept the BRANCH's copy of two whole files. That
# erased what seven already-merged tasklists had put in them — a module declaration,
# ~two dozen command registrations, a validation check, a UI warning and several
# tests (registered commands went 68 -> 44). The agent fixed what the compiler
# flagged, the gate came back green, and chief merged. EVERY layer was blind by
# construction: a deleted test cannot fail, an undeclared module is not compiled so
# its errors vanish with it, and commands registered by string name are checked by no
# compiler. The gate was green because the evidence had been deleted with the work.
#
# CHIEF NEVER RESOLVES THE CONFLICT ITSELF — that stays true (ROADMAP's "No AI
# auto-conflict-resolution" row). It HANDS resolution off in two places, and both
# give the branch back ALREADY rebased, so the floor's own rebase takes the "strictly
# ahead of <base> — rebase is a no-op" arm and never sees the conflict it exists for:
#   (1) integrate_base's conflict arm (driver.sh), which writes INTEGRATE-BASE.md,
#   (2) conflict_report's "Resolve it" runbook, on a REBASE-CONFLICT stop in the
#       serialized floor and in the merge queue's mq_stack_member.
# So the check needs a record chief writes ITSELF, at each of those handoffs.
#
# THE RECORD. Nothing chief kept could answer it. The worktree is created with
# `git worktree add -b <branch> <base>` and the base sha is written nowhere;
# $INTEGRATED_SHA_REL is a THROTTLE key inside the worktree, which run_worker deletes
# at the top of every run; the merge phase's `pre_mb` is read AFTER the agent already
# rebased, so for exactly the branch this is about it is the NEW base, not the fork;
# and the branch reflog is not chief's to rely on (it expires, it can be disabled, and
# it goes when chief deletes the branch on merge). So: a JSON record under the
# driver's state dir — CLAUDE.md's durable-state invariant, the same place zones.sh
# keeps its request and verdict — plus a PIN REF (refs/chief/resolution/<name>) so the
# pre-rebase tip's objects survive the rewrite that makes them unreachable.
#
# THE CHECK. The branch's INTENT is its pre-rebase diff (fork..preTip). Its RESULT is
# its post-rebase diff (newFork..tip). A line is a resolution deletion when all four
# hold: the post-rebase diff removes it, the pre-rebase diff did NOT remove it, it is
# present in the new base, and it no longer appears in that file at the tip. The
# fourth clause is what settles the MOVE edge for free — a base line the resolution
# only relocated within its file is still there at the tip, and a relocation is not a
# loss.
#
# THE POST-RESOLUTION-COMMIT EDGE, SETTLED BY EXCLUSION. A commit made AFTER the
# resolution (the story the agent went on to implement in the same iteration, which is
# the COMMON case — integrate first, then work) also shows up in post-minus-pre. Those
# commits are excluded PRECISELY rather than flagged: a rebase replays the original
# commits preserving author identity, date and subject, so a post-rebase commit is a
# REPLAY when some pre-rebase commit shares its (author-date, author, subject) key,
# and a commit authored after the integration has no such counterpart. The measured
# window is therefore newFork..<newest replayed commit>, not newFork..tip. Commits
# interleaved after a replay stay inside that window and can only over-report, which
# is the cheap direction: a mistake in the permissive direction repeats the incident,
# a mistake in the strict direction costs one `chief approve`. (This depends on rebase
# preserving author dates. If chief ever resets them, this exclusion breaks and the
# window widens to the whole branch — over-reporting, never under-reporting.)
#
# WHAT IT DOES NOT SEE. Deleted LINES, not broken MEANING. A resolution that keeps
# every base line and changes what they do is still the verify gate's business.
#
# Bash 3.2 only: no associative arrays, no `declare -A`, no process substitution.

# The durable pair, named in ONE place — a record under the driver's state dir, and
# the ref that keeps its objects alive through the rewrite.
resolution_record_file() { printf '%s/%s.resolution.json' "$1" "$2"; }
resolution_pin_ref()     { printf 'refs/chief/resolution/%s' "$1"; }

# resolution_record STATE NAME REPO BRANCH BASE — called at every handoff, BEFORE the
# branch is handed to someone else to rebase.
#
# FIRST WRITE WINS on the fork, and the record FREEZES the moment the branch has been
# rewritten. The rule is one ancestry test: while the branch has only GROWN (the
# recorded preTip is still an ancestor of the tip) nothing has been replayed yet, so a
# second handoff is the same unresolved conflict seen again and preTip advances to the
# newer tip. Once the tip no longer descends from preTip the agent has rebased — that
# is the resolution this exists to check, and re-recording would replace the evidence
# with its own result. Silent and best-effort throughout: this is forensics, and a
# forensics write must never be able to fail a run.
resolution_record() {
  local state="$1" name="$2" repo="$3" branch="$4" base="$5"
  local rec tip fork old_fork old_tip tmp
  command -v jq >/dev/null 2>&1 || return 0
  [ -n "$state" ] && [ -n "$name" ] || return 0
  tip="$(git -C "$repo" rev-parse --verify --quiet "$branch^{commit}" 2>/dev/null)"
  [ -n "$tip" ] || return 0
  fork="$(git -C "$repo" merge-base "$branch" "$base" 2>/dev/null || echo)"
  [ -n "$fork" ] || return 0
  rec="$(resolution_record_file "$state" "$name")"
  if [ -s "$rec" ]; then
    old_tip="$(jq -r '.preTip // empty' "$rec" 2>/dev/null || echo)"
    old_fork="$(jq -r '.fork // empty' "$rec" 2>/dev/null || echo)"
    if [ -n "$old_tip" ]; then
      git -C "$repo" merge-base --is-ancestor "$old_tip" "$tip" 2>/dev/null || return 0
    fi
    [ -n "$old_fork" ] && fork="$old_fork"
  fi
  mkdir -p "$state" 2>/dev/null || true
  tmp="$rec.tmp.$$"
  jq -n --arg name "$name" --arg branch "$branch" --arg base "$base" \
        --arg fork "$fork" --arg preTip "$tip" --arg at "$(date +%s)" \
    '{name:$name, branch:$branch, base:$base, fork:$fork, preTip:$preTip, at:($at|tonumber)}' \
    > "$tmp" 2>/dev/null && mv "$tmp" "$rec" || { rm -f "$tmp" 2>/dev/null; return 0; }
  # Pin the pre-rebase tip. After the agent's rebase those commits are unreachable
  # from any ref, and an unreachable object is gc's to take — the evidence would
  # evaporate on a schedule nobody controls. The fork is an ancestor of the tip, so
  # one ref holds both.
  git -C "$repo" update-ref "$(resolution_pin_ref "$name")" "$tip" 2>/dev/null || true
  return 0
}

# resolution_clear_record STATE NAME [REPO] — the record and its pin go together, at
# the same sites the verify-failed log and the zone request are cleared: what they are
# about is now ON the base, and a fork record that outlived its branch can only
# mislead.
resolution_clear_record() {
  local state="$1" name="$2" repo="${3:-}"
  rm -f "$(resolution_record_file "$state" "$name")" 2>/dev/null || true
  [ -n "$repo" ] && git -C "$repo" update-ref -d "$(resolution_pin_ref "$name")" 2>/dev/null
  return 0
}

# resolution_diff_lines REPO FROM TO PATH SIGN — the lines this diff removes (SIGN
# `-`) or adds (SIGN `+`), one per line, verbatim.
#
# Parsed from the first `@@` on, never with `grep '^-' | grep -v '^---'`: a removed
# line whose own text starts with `--` renders as `---…` and that filter silently eats
# it. Everything before the first hunk header is the file header, and there is exactly
# one of those because the diff is scoped to one path.
resolution_diff_lines() {
  git -C "$1" diff --unified=0 --no-color --no-ext-diff --no-renames "$2" "$3" -- "$4" 2>/dev/null \
    | LC_ALL=C awk -v sign="$5" '
        substr($0,1,2) == "@@" { inhunk = 1; next }
        !inhunk { next }
        substr($0,1,1) == "\\" { next }
        substr($0,1,1) == sign { print substr($0, 2) }'
}

# resolution_removed_lines REPO FROM TO PATH — the NET removals: every line the diff
# removes that it does not also add back, verbatim.
#
# The subtraction is not a refinement, it is the correctness of the whole check. A
# hunk that removes a line and re-adds the identical text has removed nothing — and
# git produces exactly that, routinely, for the most ordinary reason there is: a file
# whose last line had NO trailing newline gains one, so the final line is rewritten
# rather than left alone. Counting the removal half alone flags that file's last line
# on every branch that appends to it, which is a false positive on a shape that is
# everywhere. (The tip check would hide it whenever the line is still at the tip, so
# the bug would surface only on the branches that also legitimately edit it later —
# the worst possible way to find out.)
resolution_removed_lines() {
  local add
  add="$(mktemp "${TMPDIR:-/tmp}/chief-res.XXXXXX")" || return 0
  resolution_diff_lines "$1" "$2" "$3" "$4" '+' > "$add" 2>/dev/null
  if [ -s "$add" ]; then
    resolution_diff_lines "$1" "$2" "$3" "$4" '-' | LC_ALL=C grep -vxF -f "$add"
  else
    resolution_diff_lines "$1" "$2" "$3" "$4" '-'
  fi
  rm -f "$add" 2>/dev/null || true
  return 0
}

# resolution_blame_map REPO REV PATH -> "<sha><TAB><text>" per line of the file at
# REV. `-C -w` because blame credits the LAST commit whose merge touched a line, not
# its author: copy/move detection and whitespace-insensitivity walk back to the commit
# that really introduced the text.
resolution_blame_map() {
  git -C "$1" blame --porcelain -C -w "$2" -- "$3" 2>/dev/null | LC_ALL=C awk '
    substr($0,1,1) == "\t" { if (sha != "") print sha "\t" substr($0,2); next }
    length($1) == 40 && $1 ~ /^[0-9a-f]+$/ { sha = $1 }'
}

# resolution_attribute REPO SHA BASE -> "<short><TAB><sibling><TAB><subject>".
# <sibling> is the tasklist stem when the commit reached the base through a chief
# auto-merge, and empty otherwise — the same reading, and the same sed, conflict_report
# already uses for a conflicted file's colliders. The merge that brought SHA in is the
# OLDEST merge on the ancestry path from it to the base, hence `| tail -1`.
resolution_attribute() {
  local repo="$1" sha="$2" base="$3" short subj mrg msubj sib=""
  short="$(git -C "$repo" rev-parse --short "$sha" 2>/dev/null || printf '%s' "$sha")"
  subj="$(git -C "$repo" log -1 --format=%s "$sha" 2>/dev/null || echo)"
  msubj="$subj"
  case "$msubj" in *"(chief, auto-verified)"*) ;; *)
    mrg="$(git -C "$repo" rev-list --ancestry-path --merges "$sha..$base" 2>/dev/null | tail -1)"
    [ -n "$mrg" ] && msubj="$(git -C "$repo" log -1 --format=%s "$mrg" 2>/dev/null || echo)" ;;
  esac
  case "$msubj" in
    *"(chief, auto-verified)"*)
      sib="$(printf '%s' "$msubj" | sed -e 's/ (chief, auto-verified).*$//' -e 's/^Merge //' -e 's|.*/||')" ;;
  esac
  printf '%s\t%s\t%s' "$short" "$sib" "$subj"
}

# resolution_replay_tip REPO FORK PRETIP NEWFORK TIP -> the newest commit in
# NEWFORK..TIP that is a REPLAY of a pre-rebase commit, or nothing.
#
# The key is author date + author + subject, all three preserved by a rebase and none
# of them by a fresh commit. `%at` and not `%H`: the sha is exactly what a rebase
# changes.
resolution_replay_tip() {
  local repo="$1" fork="$2" pre="$3" newfork="$4" tip="$5" keys line sha key
  keys="$(git -C "$repo" log --format='%at%x1f%an%x1f%s' "$fork..$pre" 2>/dev/null)"
  [ -n "$keys" ] || return 0
  git -C "$repo" log --format='%H%x1f%at%x1f%an%x1f%s' "$newfork..$tip" 2>/dev/null \
  | while IFS= read -r line; do
      sha="${line%%$'\x1f'*}"; key="${line#*$'\x1f'}"
      printf '%s\n' "$keys" | LC_ALL=C grep -qxF -- "$key" || continue
      printf '%s' "$sha"; break
    done
  return 0
}

# resolution_deletions REPO STATE NAME BASE [BRANCH] -> one record per line:
#
#   LINE      <TAB> <file> <TAB> <short sha> <TAB> <sibling|""> <TAB> <subject> <TAB> <text>
#   UNCHECKED <TAB> <file> <TAB> <why>
#
# Exit 0 always; an empty output means "nothing was deleted", which is the answer on
# every branch that never had a conflict handed to it. That fast path is ONE
# file-existence test — no git process at all — so the check can be asked on every
# merge.
#
# Tabs in a flagged line's text are rendered as spaces: the record is TSV (the shape
# zones.sh's hold lines already use) and a literal tab inside a field would split it.
resolution_deletions() {
  local repo="$1" state="$2" name="$3" base="$4" branch="${5:-}"
  local rec fork pre tip newfork window st f why blame pres cand ln sha
  rec="$(resolution_record_file "$state" "$name")"
  [ -s "$rec" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  fork="$(jq -r '.fork // empty' "$rec" 2>/dev/null || echo)"
  pre="$(jq -r '.preTip // empty' "$rec" 2>/dev/null || echo)"
  [ -n "$branch" ] || branch="$(jq -r '.branch // empty' "$rec" 2>/dev/null || echo)"
  [ -n "$fork" ] && [ -n "$pre" ] && [ -n "$branch" ] || return 0
  tip="$(git -C "$repo" rev-parse --verify --quiet "$branch^{commit}" 2>/dev/null)"
  [ -n "$tip" ] || return 0
  # The pinned objects, or an honest admission. A pre-rebase tip that git can no
  # longer read (a pruned pin, a shallow clone) makes the comparison impossible, and
  # "impossible" must never render as "clean".
  git -C "$repo" cat-file -e "$pre^{commit}" 2>/dev/null && git -C "$repo" cat-file -e "$fork^{commit}" 2>/dev/null || {
    printf 'UNCHECKED\t(record)\tthe pre-rebase tip %s is no longer readable in this repo\n' "$pre"; return 0; }
  newfork="$(git -C "$repo" merge-base "$branch" "$base" 2>/dev/null || echo)"
  [ -n "$newfork" ] || return 0
  window="$(resolution_replay_tip "$repo" "$fork" "$pre" "$newfork" "$tip")"
  [ -n "$window" ] || return 0          # nothing was replayed: no resolution to judge
  # core.quotePath=false: with it on (the default) git C-quotes any path with a
  # non-ASCII byte, and every later `-- "$f"` would then name a file that does not
  # exist — reported as nothing rather than as a problem.
  git -C "$repo" -c core.quotePath=false diff --name-status -M --no-color "$newfork" "$window" 2>/dev/null \
  | while IFS="$(printf '\t')" read -r st f why; do
      [ -n "$f" ] || continue
      case "$st" in
        R*) printf 'UNCHECKED\t%s\trenamed to %s by the resolution — line comparison does not cross a rename\n' "$f" "${why:-?}"; continue ;;
        A*) continue ;;                                  # added here: nothing of the base's to lose
      esac
      if git -C "$repo" diff --numstat --no-color "$newfork" "$window" -- "$f" 2>/dev/null | LC_ALL=C grep -q '^-	-	'; then
        printf 'UNCHECKED\t%s\tbinary — chief compares lines and this file has none\n' "$f"; continue
      fi
      pres="$(git -C "$repo" show "$base:$f" 2>/dev/null)"
      [ -n "$pres" ] || continue                          # not on the base: nothing merged to erase
      # post-removed MINUS pre-removed: what the RESOLUTION dropped, not what the
      # branch meant to drop. -x -F: whole line, literal, so regex metacharacters in
      # source lines cannot match each other.
      cand="$(resolution_removed_lines "$repo" "$newfork" "$window" "$f" | LC_ALL=C sort -u)"
      [ -n "$cand" ] || continue
      blame=""
      printf '%s\n' "$cand" | while IFS= read -r ln; do
        case "$ln" in *[![:space:]]*) ;; *) continue ;; esac   # a blank line is not work
        resolution_removed_lines "$repo" "$fork" "$pre" "$f" | LC_ALL=C grep -qxF -- "$ln" && continue
        printf '%s\n' "$pres" | LC_ALL=C grep -qxF -- "$ln" || continue
        git -C "$repo" show "$tip:$f" 2>/dev/null | LC_ALL=C grep -qxF -- "$ln" && continue   # moved, not lost
        [ -n "$blame" ] || blame="$(resolution_blame_map "$repo" "$base" "$f")"
        sha="$(printf '%s\n' "$blame" | LC_ALL=C awk -F'\t' -v t="$ln" '$0 ~ /\t/ && substr($0, index($0,"\t")+1) == t { print $1; exit }')"
        [ -n "$sha" ] || sha="$base"
        printf 'LINE\t%s\t%s\t%s\n' "$f" "$(resolution_attribute "$repo" "$sha" "$base")" \
          "$(printf '%s' "$ln" | tr '\t' ' ')"
      done
    done
  return 0
}

# resolution_render RECORDS [LIMIT] — the finding as something a person reads, in the
# worker log, the approval request and `chief approve --list`. A long list is
# TRUNCATED WITH A COUNT and never silently: the number of erased lines is the whole
# severity signal.
resolution_render() {
  printf '%s\n' "${1:-}" | LC_ALL=C awk -F'\t' -v lim="${2:-20}" '
    $1 == "LINE" {
      n++
      if (n <= lim)
        printf "     %s  %s%s  %s\n", $2, $3, ($4 == "" ? "" : "  (tasklist " $4 ")"), $6
      next
    }
    $1 == "UNCHECKED" { u++; printf "     %s  UNCHECKED — %s\n", $2, $3; next }
    END {
      if (n > lim) printf "     … and %d more erased line(s) (%d in total)\n", n - lim, n
    }'
  return 0
}
