#!/usr/bin/env bash
# test/resolution-deletions.sh — engine/resolution.sh against the incident it exists
# for, and against the four ways a detector like it goes wrong.
#
# THE INCIDENT, reduced to its mechanism: a branch forks, the base gains a line in a
# shared file, the branch's own edit to that file conflicts, and the resolution keeps
# the BRANCH's stale copy of the whole file. The base's line is gone; every gate is
# green, because a deleted test cannot fail and an undeclared module is not compiled.
#
# A detector that flags everything is as useless as one that flags nothing, so half
# this file is negative control — the field sweep of ~1,300 chief merges across 28
# repositories (2026-09-11) found ONE confirmed casualty and 100 benign flags:
#   • a line the branch's OWN pre-rebase diff removes is intent, not loss,
#   • a clean rebase yields nothing at all,
#   • a base line the resolution only MOVED within its file is still present,
#   • a line removed by a commit made AFTER the resolution has no pre-rebase
#     counterpart, and is excluded by the replay window rather than flagged.
#
# NO DRIVER: the module is sourced directly and run against temp repos, so the whole
# file is under a second. Hermetic — its own temp dir, its own git identity, and it
# never reads or writes ~/.chief. Needs git + jq.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=res GIT_AUTHOR_EMAIL=res@test \
       GIT_COMMITTER_NAME=res GIT_COMMITTER_EMAIL=res@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"   # hermetic: never touch ~/.chief
fail() { echo "RESOLUTION FAIL: $*" >&2; exit 1; }
has()  { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
hasnt(){ case "$2" in *"$1"*) return 1 ;; *) return 0 ;; esac; }

command -v jq >/dev/null || fail "jq is required"
# shellcheck source=engine/resolution.sh
. "$ROOT/engine/resolution.sh"

N=0; P=0
ok()  { N=$((N+1)); P=$((P+1)); echo "  ok   $*"; }
bad() { N=$((N+1)); echo "  FAIL $*" >&2; FAILED=1; }
FAILED=0
check() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2"; fi; }

# A repo with a shared file, a base that moves under it, and a branch that forks
# before it does. $R is the repo, $STATE the driver's state dir (outside it).
new_repo() {   # $1 = name
  R="$WORK/$1"; STATE="$WORK/$1-state"; mkdir -p "$R" "$STATE"
  git -C "$R" init -q -b main 2>/dev/null || { git -C "$R" init -q; git -C "$R" checkout -q -b main; }
  printf 'alpha\nbeta\ngamma\n' > "$R/shared.txt"
  printf 'one\n' > "$R/other.txt"
  printf '\000\001\002original\n' > "$R/blob.bin"
  git -C "$R" add -A; git -C "$R" commit -q -m "base: initial"
  git -C "$R" checkout -q -b work
}
# The sibling tasklist's merge, spelled exactly as the driver spells it, so the
# attribution half is exercised and not just asserted around.
land_on_base() {   # $1 = repo, $2 = tasklist stem, $3 = file, $4 = new content (stdin-less)
  git -C "$1" checkout -q main
  git -C "$1" checkout -q -b "chief/$2"
  printf '%s\n' "$4" > "$1/$3"
  git -C "$1" add -A; git -C "$1" commit -q -m "feat: [US-1] - $2"
  git -C "$1" checkout -q main
  git -C "$1" merge -q --no-ff "chief/$2" -m "Merge chief/$2 (chief, auto-verified)"
  git -C "$1" checkout -q work
}

echo "== A. the incident: the resolution keeps the branch's stale copy of the file =="
new_repo incident
# The branch's own work on the shared file — this is what will conflict.
printf 'alpha\nbeta\ngamma\nBRANCH_TAIL\n' > "$R/shared.txt"
git -C "$R" commit -q -am "feat: [US-1] - branch edits the shared file"
# The sibling lands a line the branch has never seen, at the same end of the same
# file — so the rebase really conflicts and a resolution really happens.
land_on_base "$R" "77-register-commands" shared.txt "$(printf 'alpha\nbeta\ngamma\nREGISTERED_COMMAND_delta\n')"
# Chief records the handoff here — integrate_base's conflict arm does exactly this.
resolution_record "$STATE" incident "$R" work main
[ -s "$(resolution_record_file "$STATE" incident)" ] \
  && check 0 "the handoff is recorded under the driver's state dir" \
  || check 1 "the handoff is recorded under the driver's state dir"
PRE="$(jq -r .preTip "$(resolution_record_file "$STATE" incident)")"
FORK="$(jq -r .fork "$(resolution_record_file "$STATE" incident)")"
[ "$PRE" = "$(git -C "$R" rev-parse work)" ] && check 0 "preTip is the branch tip before the rebase" \
                                             || check 1 "preTip is the branch tip before the rebase"
[ "$FORK" = "$(git -C "$R" rev-parse main~1)" ] && check 0 "fork is the ORIGINAL fork point, not the new base" \
                                                || check 1 "fork is the ORIGINAL fork point, not the new base"
# THE RESOLUTION, as the agent performed it: rebase, and at the stop take the
# branch's whole file. --theirs is the branch's replayed commit in a rebase.
git -C "$R" rebase main >/dev/null 2>&1 || {
  git -C "$R" checkout -q --theirs -- shared.txt
  git -C "$R" add shared.txt
  GIT_EDITOR=true git -C "$R" rebase --continue >/dev/null 2>&1; }
hasnt REGISTERED_COMMAND_delta "$(cat "$R/shared.txt")" \
  && check 0 "the fixture really erased the sibling's line (the incident reproduced)" \
  || check 1 "the fixture really erased the sibling's line (the incident reproduced)"

OUT="$(resolution_deletions "$R" "$STATE" incident main work)"
has REGISTERED_COMMAND_delta "$OUT" && check 0 "the erased line is FLAGGED" || check 1 "the erased line is FLAGGED: <$OUT>"
has shared.txt "$OUT" && check 0 "the finding names the file" || check 1 "the finding names the file: <$OUT>"
has 77-register-commands "$OUT" \
  && check 0 "the finding names the sibling tasklist whose auto-merge landed it" \
  || check 1 "the finding names the sibling tasklist: <$OUT>"
SHA="$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="LINE"{print $3; exit}')"
git -C "$R" cat-file -e "$SHA^{commit}" 2>/dev/null \
  && check 0 "the finding names a real base commit ($SHA)" \
  || check 1 "the finding names a real base commit: <$SHA>"
hasnt 'other.txt' "$OUT" && check 0 "a file nobody touched is not in the finding" \
                         || check 1 "a file nobody touched is not in the finding"
has "$(git -C "$R" rev-parse --short "$SHA")" "$(resolution_render "$OUT")" \
  && check 0 "resolution_render puts the file, the commit and the text on one line" \
  || check 1 "resolution_render puts the file, the commit and the text on one line"

echo
echo "== B. negative control: a line the branch's OWN pre-rebase diff removes =="
new_repo intent
# The branch deliberately deletes 'beta' — its intent, recorded before any conflict.
printf 'alpha\ngamma\nbranch-added\n' > "$R/shared.txt"
git -C "$R" commit -q -am "feat: [US-1] - the branch removes beta on purpose"
land_on_base "$R" "80-sibling" shared.txt "$(printf 'alpha\nbeta\ngamma\nSIBLING_LINE\n')"
resolution_record "$STATE" intent "$R" work main
git -C "$R" rebase main >/dev/null 2>&1 || {
  # Resolved CORRECTLY: both sides' intent — beta gone (the branch meant that),
  # SIBLING_LINE kept (already-merged work).
  printf 'alpha\ngamma\nSIBLING_LINE\nbranch-added\n' > "$R/shared.txt"
  git -C "$R" add shared.txt
  GIT_EDITOR=true git -C "$R" rebase --continue >/dev/null 2>&1; }
OUT="$(resolution_deletions "$R" "$STATE" intent main work)"
hasnt 'beta' "$OUT" && check 0 "a line the branch's own pre-rebase diff removed is NOT flagged" \
                    || check 1 "a line the branch's own pre-rebase diff removed is NOT flagged: <$OUT>"
[ -z "$OUT" ] && check 0 "a correct resolution yields nothing at all" \
              || check 1 "a correct resolution yields nothing at all: <$OUT>"

echo
echo "== C. negative control: a clean rebase =="
new_repo clean
printf 'alpha\nbeta\ngamma\nbranch-added\n' > "$R/shared.txt"
git -C "$R" commit -q -am "feat: [US-1] - branch appends"
land_on_base "$R" "81-elsewhere" other.txt "$(printf 'one\ntwo\n')"
resolution_record "$STATE" clean "$R" work main
git -C "$R" rebase main >/dev/null 2>&1 || fail "fixture C was supposed to rebase cleanly"
OUT="$(resolution_deletions "$R" "$STATE" clean main work)"
[ -z "$OUT" ] && check 0 "a clean rebase yields nothing" || check 1 "a clean rebase yields nothing: <$OUT>"

echo
echo "== D. negative control: a base line the resolution only MOVED =="
new_repo moved
printf 'alpha\nbeta\ngamma\nBRANCH_TAIL\n' > "$R/shared.txt"
git -C "$R" commit -q -am "feat: [US-1] - branch edits the shared file"
land_on_base "$R" "82-sibling" shared.txt "$(printf 'alpha\nbeta\ngamma\nMOVED_LINE\n')"
resolution_record "$STATE" moved "$R" work main
git -C "$R" rebase main >/dev/null 2>&1 && fail "fixture D was supposed to conflict" || {
  # Keeps the base's line, at the TOP of the file instead of the bottom.
  printf 'MOVED_LINE\nalpha\nbeta\ngamma\nBRANCH_TAIL\n' > "$R/shared.txt"
  git -C "$R" add shared.txt
  GIT_EDITOR=true git -C "$R" rebase --continue >/dev/null 2>&1; }
OUT="$(resolution_deletions "$R" "$STATE" moved main work)"
hasnt MOVED_LINE "$OUT" && check 0 "a base line only MOVED within its file is not a loss" \
                        || check 1 "a base line only MOVED within its file is not a loss: <$OUT>"

echo
echo "== E. the post-resolution-commit edge: EXCLUDED, not flagged =="
# THE CHOICE THIS TEST PINS. After resolving, the agent implements its story in the
# SAME iteration — the common case — and that story legitimately removes a line the
# base added. That commit has no pre-rebase counterpart, so the measured window stops
# at the newest REPLAYED commit and the later deletion is excluded precisely. Without
# the window the same fixture flags it, which is the false positive the exclusion
# exists to prevent.
new_repo later
printf 'alpha\nbeta\ngamma\nBRANCH_TAIL\n' > "$R/shared.txt"
git -C "$R" commit -q -am "feat: [US-1] - branch edits the shared file"
land_on_base "$R" "83-sibling" shared.txt "$(printf 'alpha\nbeta\ngamma\nLATER_REMOVED\n')"
resolution_record "$STATE" later "$R" work main
git -C "$R" rebase main >/dev/null 2>&1 && fail "fixture E was supposed to conflict" || {
  printf 'alpha\nbeta\ngamma\nLATER_REMOVED\nBRANCH_TAIL\n' > "$R/shared.txt"   # correct
  git -C "$R" add shared.txt
  GIT_EDITOR=true git -C "$R" rebase --continue >/dev/null 2>&1; }
OUT="$(resolution_deletions "$R" "$STATE" later main work)"
[ -z "$OUT" ] && check 0 "the correct resolution itself is clean" || check 1 "the correct resolution itself is clean: <$OUT>"
# ... and NOW the story turn removes it, on purpose.
printf 'alpha\nbeta\ngamma\nBRANCH_TAIL\n' > "$R/shared.txt"
git -C "$R" commit -q -am "feat: [US-2] - the story retires LATER_REMOVED"
OUT="$(resolution_deletions "$R" "$STATE" later main work)"
hasnt LATER_REMOVED "$OUT" \
  && check 0 "a deletion by a commit made AFTER the resolution is excluded, not flagged" \
  || check 1 "a deletion by a commit made AFTER the resolution is excluded: <$OUT>"
# The exclusion is a WINDOW, and this proves the window is what does it: measured from
# the branch tip instead of the replay tip, the very same tree flags the line.
WIDE="$(resolution_removed_lines "$R" "$(git -C "$R" merge-base work main)" "$(git -C "$R" rev-parse work)" shared.txt)"
has LATER_REMOVED "$WIDE" \
  && check 0 "…and the unwindowed diff DOES remove it, so the window is what excluded it" \
  || check 1 "…and the unwindowed diff DOES remove it"

echo
echo "== F. the record: it freezes at the resolution, and it survives a run ending =="
new_repo frozen
printf 'alpha\nbeta\ngamma\nBRANCH_TAIL\n' > "$R/shared.txt"
git -C "$R" commit -q -am "feat: [US-1] - branch edits the shared file"
land_on_base "$R" "84-sibling" shared.txt "$(printf 'alpha\nbeta\ngamma\nFROZEN_LINE\n')"
resolution_record "$STATE" frozen "$R" work main
FIRST="$(jq -r .preTip "$(resolution_record_file "$STATE" frozen)")"
# A SECOND handoff before any rebase (the base moved again): the branch has only
# grown, so preTip advances and the fork stays put.
printf 'alpha\nbeta\ngamma\nBRANCH_TAIL\nmore\n' > "$R/shared.txt"
git -C "$R" commit -q -am "feat: [US-1] - more branch work"
resolution_record "$STATE" frozen "$R" work main
SECOND="$(jq -r .preTip "$(resolution_record_file "$STATE" frozen)")"
[ "$SECOND" != "$FIRST" ] && [ "$SECOND" = "$(git -C "$R" rev-parse work)" ] \
  && check 0 "a second handoff before any rebase advances preTip" \
  || check 1 "a second handoff before any rebase advances preTip"
FORK2="$(jq -r .fork "$(resolution_record_file "$STATE" frozen)")"
git -C "$R" rebase main >/dev/null 2>&1 || {
  git -C "$R" checkout -q --theirs -- shared.txt; git -C "$R" add shared.txt
  GIT_EDITOR=true git -C "$R" rebase --continue >/dev/null 2>&1; }
# The pin is why this is still answerable: after the rebase those commits are
# unreachable from any ref, and an unreachable object is gc's to take.
git -C "$R" rev-parse --verify --quiet "$(resolution_pin_ref frozen)" >/dev/null \
  && check 0 "the pre-rebase tip is pinned by a ref, so gc cannot take the evidence" \
  || check 1 "the pre-rebase tip is pinned by a ref"
resolution_record "$STATE" frozen "$R" work main       # the next run's handoff attempt
[ "$(jq -r .preTip "$(resolution_record_file "$STATE" frozen)")" = "$SECOND" ] \
  && check 0 "the record FREEZES once the branch has been rewritten" \
  || check 1 "the record FREEZES once the branch has been rewritten"
[ "$(jq -r .fork "$(resolution_record_file "$STATE" frozen)")" = "$FORK2" ] \
  && check 0 "…and the original fork point is never overwritten" \
  || check 1 "…and the original fork point is never overwritten"
OUT="$(resolution_deletions "$R" "$STATE" frozen main work)"
has FROZEN_LINE "$OUT" && check 0 "the frozen record still catches the erasure" \
                       || check 1 "the frozen record still catches the erasure: <$OUT>"
resolution_clear_record "$STATE" frozen "$R"
[ ! -e "$(resolution_record_file "$STATE" frozen)" ] \
  && [ -z "$(git -C "$R" rev-parse --verify --quiet "$(resolution_pin_ref frozen)" || echo)" ] \
  && check 0 "clearing takes the record AND its pin, the way a merge does" \
  || check 1 "clearing takes the record AND its pin"

echo
echo "== G. no record is the free path, and the unreadable case is UNCHECKED =="
OUT="$(resolution_deletions "$R" "$STATE" never-recorded main work)"
[ -z "$OUT" ] && check 0 "a branch with no recorded resolution reports nothing" \
              || check 1 "a branch with no recorded resolution reports nothing: <$OUT>"
jq -n '{name:"gone",branch:"work",base:"main",fork:"0000000000000000000000000000000000000000",preTip:"1111111111111111111111111111111111111111",at:0}' \
  > "$(resolution_record_file "$STATE" gone)"
OUT="$(resolution_deletions "$R" "$STATE" gone main work)"
has UNCHECKED "$OUT" \
  && check 0 "a pre-rebase tip git can no longer read is UNCHECKED, never silently clean" \
  || check 1 "a pre-rebase tip git can no longer read is UNCHECKED: <$OUT>"

echo
echo "== H. a line removed and re-added identically is not a deletion =="
# THE SHAPE THAT MAKES THIS NOT A REFINEMENT. A file whose last line carries no
# trailing newline gains one the moment anything is appended, so git rewrites that
# final line — removing it and adding the identical text back in the same hunk. The
# removal half alone flags the last line of every such file on every branch that
# appends to it, and the tip check HIDES it wherever the line is still at the tip, so
# the false positive would only ever surface on branches that also edit it later.
new_repo readded
printf 'alpha\nbeta\ngamma\nBRANCH_TAIL\n' > "$R/shared.txt"
git -C "$R" commit -q -am "feat: [US-1] - branch edits the shared file"
git -C "$R" checkout -q main
printf 'alpha\nbeta\ngamma\nNO_TRAILING_NEWLINE' > "$R/shared.txt"      # deliberately unterminated
git -C "$R" commit -q -am "base: a last line with no trailing newline"
git -C "$R" checkout -q work
resolution_record "$STATE" readded "$R" work main
git -C "$R" rebase main >/dev/null 2>&1 && fail "fixture I was supposed to conflict" || {
  printf 'alpha\nbeta\ngamma\nNO_TRAILING_NEWLINE\nBRANCH_TAIL\n' > "$R/shared.txt"   # keeps it
  git -C "$R" add shared.txt
  GIT_EDITOR=true git -C "$R" rebase --continue >/dev/null 2>&1; }
has 'NO_TRAILING_NEWLINE' "$(resolution_diff_lines "$R" "$(git -C "$R" merge-base work main)" "$(git -C "$R" rev-parse work)" shared.txt -)" \
  && check 0 "the raw diff really does report the re-terminated line as removed" \
  || check 1 "the raw diff really does report the re-terminated line as removed"
OUT="$(resolution_deletions "$R" "$STATE" readded main work)"
hasnt 'NO_TRAILING_NEWLINE' "$OUT" \
  && check 0 "…and the NET removal subtracts the re-add, so nothing is flagged" \
  || check 1 "…and the NET removal subtracts the re-add: <$OUT>"

echo
echo "== I. binary and renamed paths are reported, never silently skipped =="
# Both shapes are in the BRANCH'S OWN commit, so they fall inside the measured
# window. A path a line comparison cannot cross must say so: "I did not check this"
# and "I checked this and it is clean" are different answers, and only one of them
# is honest here.
new_repo binren
git -C "$R" mv shared.txt renamed.txt
printf 'alpha\nbeta\ngamma\nBRANCH_TAIL\n' > "$R/renamed.txt"
printf '\000\377\376branch\n' > "$R/blob.bin"
git -C "$R" add -A; git -C "$R" commit -q -m "feat: [US-1] - rename the file and rewrite the blob"
git -C "$R" checkout -q main
printf 'alpha\nbeta\ngamma\nBIN_SIBLING\n' > "$R/shared.txt"
printf '\000\001\002base\n' > "$R/blob.bin"
git -C "$R" add -A; git -C "$R" commit -q -m "base: a line and a different blob"
git -C "$R" checkout -q work
resolution_record "$STATE" binren "$R" work main
git -C "$R" rebase main >/dev/null 2>&1 && fail "fixture H was supposed to conflict" || {
  git -C "$R" rm -q --cached shared.txt >/dev/null 2>&1 || true
  rm -f "$R/shared.txt"
  printf 'alpha\nbeta\ngamma\nBRANCH_TAIL\n' > "$R/renamed.txt"
  printf '\000\377\376branch\n' > "$R/blob.bin"
  git -C "$R" add -A
  GIT_EDITOR=true git -C "$R" rebase --continue >/dev/null 2>&1; }
OUT="$(resolution_deletions "$R" "$STATE" binren main work)"
has 'UNCHECKED' "$OUT" && check 0 "a path the line comparison cannot cross is reported UNCHECKED" \
                       || check 1 "a path the line comparison cannot cross is reported UNCHECKED: <$OUT>"
has 'blob.bin' "$OUT" && check 0 "…and the binary path is named" \
                      || check 1 "…and the binary path is named: <$OUT>"
has 'binary' "$(resolution_render "$OUT")" \
  && check 0 "resolution_render renders the UNCHECKED record with its reason" \
  || check 1 "resolution_render renders the UNCHECKED record with its reason: <$OUT>"

echo
echo "resolution-deletions: $P/$N assertion(s) passed"
[ "$FAILED" = 0 ] || exit 1
exit 0
