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


# ── the HOLD (US-2): the finding joins the merge policy layer ────────────────
# Still no driver — zones.sh's gate is asked directly, against the same temp repos.
# live.sh only defines functions (zones_merge_gate keeps a liveliness record); budget.sh
# is the layer's second rule and the gate calls it unconditionally.
# shellcheck source=engine/live.sh
. "$ROOT/engine/live.sh"
# shellcheck source=engine/budget.sh
. "$ROOT/engine/budget.sh"
# shellcheck source=engine/zones.sh
. "$ROOT/engine/zones.sh"

# The incident as a REUSABLE fixture: a branch whose resolution keeps its own stale
# copy of the shared file, with the handoff recorded. Leaves $R rebased and resolved,
# $STATE holding the record, and CHIEF_PROJECT pointing at the repo (the gate resolves
# .chief/zones.conf relative to it, and must never reach chief's own).
incident_repo() {   # $1 = name, $2… = the sibling's lines to land on the base
  new_repo "$1"
  local nm="$1"; shift          # $@ is now the sibling's lines and nothing else
  printf 'alpha\nbeta\ngamma\nBRANCH_TAIL\n' > "$R/shared.txt"
  git -C "$R" commit -q -am "feat: [US-1] - branch edits the shared file"
  land_on_base "$R" "77-register-commands" shared.txt "$(printf 'alpha\nbeta\ngamma\n'; printf '%s\n' "$@")"
  resolution_record "$STATE" "$nm" "$R" work main
  git -C "$R" rebase main >/dev/null 2>&1 && fail "fixture $nm was supposed to conflict"
  git -C "$R" checkout -q --theirs -- shared.txt     # the incident: OUR whole file wins
  git -C "$R" add shared.txt
  GIT_EDITOR=true git -C "$R" rebase --continue >/dev/null 2>&1
  export CHIEF_PROJECT="$R"
  unset ZONES_CONF
}
gate() {   # $1 = name -> the gate's own log; sets GATE_RC
  GATE_RC=0
  zones_merge_gate "$1" work "$R" main "$STATE" "" 2>&1 || GATE_RC=$?
}
req_of() { jq -r '(.zones // [])[] | [.policy, .zone, .matched, .reason] | @tsv' \
             "$(zones_request_file "$STATE" "$1")" 2>/dev/null; }

echo
echo "== J. the hold is ALWAYS ARMED — it is not a declared zone and not the budget =="
# The rule this file exists for is the only one in the policy layer that a repo cannot
# be missing. A `review` zone is opt-in; CHIEF_DIFF_BUDGET=block is opt-in; the
# incident happened in a repo with neither. Each arm below is one of the ways a repo
# can have the policy layer switched all the way off.
incident_repo armed REGISTERED_COMMAND_delta
unset CHIEF_DIFF_BUDGET
gate armed
[ "$GATE_RC" = 1 ] && check 0 "with NO .chief/zones.conf at all, the merge is HELD" \
                   || check 1 "with no zones.conf the gate returned $GATE_RC (want 1)"
printf 'serialize\tpath:*\n' > "$R/zones.conf"; ZONES_CONF="$R/zones.conf"
gate armed
[ "$GATE_RC" = 1 ] && check 0 "with every declared zone set to 'serialize', still HELD" \
                   || check 1 "with a serialize-only registry the gate returned $GATE_RC (want 1)"
unset ZONES_CONF; rm -f "$R/zones.conf"
CHIEF_DIFF_BUDGET=warn gate armed
[ "$GATE_RC" = 1 ] && check 0 "under CHIEF_DIFF_BUDGET=warn, still HELD" \
                   || check 1 "under CHIEF_DIFF_BUDGET=warn the gate returned $GATE_RC (want 1)"
CHIEF_DIFF_BUDGET=off gate armed
[ "$GATE_RC" = 1 ] && check 0 "under CHIEF_DIFF_BUDGET=off, still HELD" \
                   || check 1 "under CHIEF_DIFF_BUDGET=off the gate returned $GATE_RC (want 1)"

echo
echo "== K. the hold NAMES the loss, in all four places a person reads it =="
LOG="$(gate armed; :)"
has REGISTERED_COMMAND_delta "$LOG" && check 0 "the worker log carries the erased line" \
                                    || check 1 "the worker log carries the erased line: <$LOG>"
has shared.txt "$LOG" && check 0 "…and the file" || check 1 "…and the file: <$LOG>"
has 77-register-commands "$LOG" && check 0 "…and the sibling tasklist whose work it was" \
                                || check 1 "…and the sibling tasklist: <$LOG>"
has 'would ERASE 1 line' "$LOG" && check 0 "…and says plainly what is about to happen" \
                                || check 1 "…and says plainly what is about to happen: <$LOG>"
REQ="$(req_of armed)"
has 'resolution:deleted' "$REQ" && check 0 "the approval request carries the finding as a review zone" \
                                || check 1 "the approval request carries the finding: <$REQ>"
has REGISTERED_COMMAND_delta "$REQ" && check 0 "…with the erased line in it" \
                                    || check 1 "…with the erased line in it: <$REQ>"
has 77-register-commands "$REQ" && check 0 "…and the sibling tasklist" \
                                || check 1 "…and the sibling tasklist: <$REQ>"
# The run summary's awaiting-approval block renders exactly this (driver.sh), and
# `chief approve --list` is zones_show. Both read the request file, so both are pinned
# here rather than assumed from the fact that the file is correct.
has REGISTERED_COMMAND_delta "$(zones_render "$REQ")" \
  && check 0 "the run summary's awaiting-approval block names the erased line" \
  || check 1 "the run summary's awaiting-approval block names the erased line"
has REGISTERED_COMMAND_delta "$(zones_show "$STATE" armed)" \
  && check 0 "chief approve --list names the erased line" \
  || check 1 "chief approve --list names the erased line: <$(zones_show "$STATE" armed)>"

echo
echo "== L. the override, and what it is BOUND to =="
# The binding is the whole point: approving THIS loss must not pre-approve a
# re-resolution that loses something else. Both fixtures below change the same one
# file, so the changed-file half of the digest is identical and only the flagged
# lines can move it.
incident_repo bound DELTA_ONE DELTA_TWO
# A resolution that keeps DELTA_ONE and erases only DELTA_TWO.
printf 'alpha\nbeta\ngamma\nDELTA_ONE\nBRANCH_TAIL\n' > "$R/shared.txt"
git -C "$R" commit -q --amend --no-edit -a
gate bound
[ "$GATE_RC" = 1 ] && check 0 "a resolution that erases one of the two base lines is HELD" \
                   || check 1 "a resolution that erases one base line returned $GATE_RC (want 1)"
CHANGE1="$(jq -r .change "$(zones_request_file "$STATE" bound)")"
zones_approve "$STATE" bound "we meant to drop it" >/dev/null 2>&1
gate bound
[ "$GATE_RC" = 0 ] && check 0 "chief approve <name> -m <reason> releases exactly that loss" \
                   || check 1 "the approved branch is still held ($GATE_RC)"
# The re-resolution: same file, same story, a DIFFERENT line erased.
printf 'alpha\nbeta\ngamma\nBRANCH_TAIL\n' > "$R/shared.txt"
git -C "$R" commit -q --amend --no-edit -a
gate bound
[ "$GATE_RC" = 1 ] && check 0 "a re-resolution that erases something DIFFERENT asks again" \
                   || check 1 "a re-resolution that erases more was let through ($GATE_RC)"
CHANGE2="$(jq -r .change "$(zones_request_file "$STATE" bound)")"
[ "$CHANGE1" != "$CHANGE2" ] && check 0 "…because the approval id is over the flagged lines ($CHANGE1 -> $CHANGE2)" \
                             || check 1 "the approval id did not move: $CHANGE1"
# The approval outlives the merge in completed/, because zones_clear_record deletes
# the file. finalize_merged stamps it there first.
zones_approve "$STATE" bound "the second loss too" >/dev/null 2>&1
printf '{"project":"t","userStories":[]}\n' > "$WORK/bound-completed.json"
zones_stamp_record "$WORK/bound-completed.json" "$STATE" bound
[ "$(jq -r '.approval.note' "$WORK/bound-completed.json")" = "the second loss too" ] \
  && check 0 "the completed record carries the approval's note" \
  || check 1 "the completed record carries the approval's note: $(cat "$WORK/bound-completed.json")"
[ -n "$(jq -r '.approval.by' "$WORK/bound-completed.json")" ] \
  && check 0 "…and who gave it" || check 1 "…and who gave it"
[ "$(jq -r '.approval.at' "$WORK/bound-completed.json")" -gt 0 ] \
  && check 0 "…and when" || check 1 "…and when"
has DELTA_ONE "$(jq -r '(.approval.zones // [])[] | .matched' "$WORK/bound-completed.json")" \
  && check 0 "…and the lines it covered" \
  || check 1 "…and the lines it covered: $(jq -c '.approval.zones' "$WORK/bound-completed.json")"
zones_clear_record "$STATE" bound
[ -n "$(jq -r '.approval.zones[0].zone' "$WORK/bound-completed.json")" ] \
  && check 0 "…and it survives zones_clear_record, which deletes the file on merge" \
  || check 1 "the record did not survive the clear"

echo
echo "== M. a long list is truncated WITH A COUNT, never silently =="
RESOLUTION_RECORDS="$(resolution_deletions "$R" "$STATE" bound main work)"
HOLDS="$(resolution_holds 1)"
has 'and 1 more erased line(s) (2 in total)' "$HOLDS" \
  && check 0 "the truncated hold states how many it is not showing, and the total" \
  || check 1 "the truncated hold does not state the count: <$HOLDS>"
[ "$(printf '%s\n' "$HOLDS" | LC_ALL=C awk -F'\t' '$2 == "resolution:deleted"' | wc -l | tr -d ' ')" = 3 ] \
  && check 0 "…and the summary line is still there above it (summary + 1 + truncation)" \
  || check 1 "…truncation produced $(printf '%s\n' "$HOLDS" | wc -l) line(s)"
has 'id ' "$(printf '%s\n' "$HOLDS" | head -1)" \
  && check 0 "the summary line carries the id of the WHOLE finding, so truncation cannot loosen the binding" \
  || check 1 "the summary line carries no full-set id: <$HOLDS>"

echo
echo "== N. the run condition: the branch that never had a conflict pays no git =="
# This is why the check is asked on EVERY merge rather than behind a condition. A
# branch with no recorded resolution must cost a file-existence test and nothing else,
# so the count asserted here is git INVOCATIONS, not wall time (which is load-bearing
# on nobody's machine but measurable on everybody's).
new_repo free
mkdir -p "$WORK/shim"
REAL_GIT="$(command -v git)"
cat > "$WORK/shim/git" <<EOS
#!/bin/sh
printf 'x' >> "\$GITCOUNT"
exec "$REAL_GIT" "\$@"
EOS
chmod +x "$WORK/shim/git"
export GITCOUNT="$WORK/gitcount"; : > "$GITCOUNT"
OLDPATH="$PATH"; PATH="$WORK/shim:$PATH"
resolution_deletions "$R" "$STATE" free main work >/dev/null 2>&1
NGIT="$(wc -c < "$GITCOUNT" | tr -d ' ')"
: > "$GITCOUNT"
resolution_deletions "$R" "$STATE" bound main work >/dev/null 2>&1   # no record in THIS state dir either
PATH="$OLDPATH"
[ "$NGIT" = 0 ] && check 0 "no recorded resolution: ZERO git invocations (one stat, then nothing)" \
                || check 1 "the free path spent $NGIT git invocation(s)"
: > "$GITCOUNT"
PATH="$WORK/shim:$PATH"
incident_repo cost REGISTERED_COMMAND_delta
: > "$GITCOUNT"
resolution_deletions "$R" "$STATE" cost main work >/dev/null 2>&1
NGIT2="$(wc -c < "$GITCOUNT" | tr -d ' ')"
PATH="$OLDPATH"
echo "  note the recorded path spent $NGIT2 git invocation(s) on a one-file finding"
[ "$NGIT2" -gt 0 ] && check 0 "…and the recorded path really does run the comparison" \
                   || check 1 "the recorded path ran no git at all"
echo
echo "== O. the merge queue: the comparison is per BRANCH, not per batch tip =="
# Both merge paths call the same gate, and the batch path differs in exactly one
# argument: SCOPE, the tip this member was STACKED ON. It is what the resolution rule
# is measured from, and the assertion below is why — with the scope honoured, a member
# is not charged with a line a PEER earlier in the batch legitimately removed; measured
# from the base instead, it is. The negative half is the whole point: it fails on the
# engine that passes $base here, so the plumbing cannot rot back silently.
new_repo queue
printf 'one\ntwo\n' > "$R/other.txt"
git -C "$R" commit -q -am "feat: [US-1] - the member's own story, nowhere near shared.txt"
land_on_base "$R" "77-register-commands" shared.txt "$(printf 'alpha\nbeta\ngamma\nDELTA\n')"
resolution_record "$STATE" queue "$R" work main
git -C "$R" rebase main >/dev/null 2>&1 || fail "fixture queue was supposed to rebase cleanly"
# The batch tip: a PEER, stacked on the base, that legitimately removes a base line.
git -C "$R" checkout -q -b peer main
printf 'alpha\ngamma\nDELTA\n' > "$R/shared.txt"
git -C "$R" commit -q -am "feat: [US-1] - the peer drops beta on purpose"
PEER="$(git -C "$R" rev-parse peer)"
git -C "$R" checkout -q work
git -C "$R" rebase "$PEER" >/dev/null 2>&1 || fail "fixture queue was supposed to stack cleanly"
export CHIEF_PROJECT="$R"; unset ZONES_CONF CHIEF_DIFF_BUDGET
GATE_RC=0; zones_merge_gate queue work "$R" main "$STATE" "" "$PEER" >/dev/null 2>&1 || GATE_RC=$?
[ "$GATE_RC" = 0 ] && check 0 "stacked on a peer that removed a base line, the member is NOT held" \
                   || check 1 "the member was charged with its peer's removal (gate returned $GATE_RC)"
GATE_RC=0; zones_merge_gate queue work "$R" main "$STATE" "" main >/dev/null 2>&1 || GATE_RC=$?
[ "$GATE_RC" = 1 ] && check 0 "…and measured from the base instead it WOULD be — the scope is load-bearing" \
                   || check 1 "the scope makes no difference here, so the fixture proves nothing ($GATE_RC)"

echo
echo "resolution-deletions: $P/$N assertion(s) passed"
[ "$FAILED" = 0 ] || exit 1
exit 0
