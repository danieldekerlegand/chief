#!/usr/bin/env bash
# test/status-categories.sh — `chief status` reports categories WITHOUT adopting a
# vocabulary.
#
# THE POINT OF THIS TEST. `category` is not chief's concept. It is a convention of the
# repos this host happens to build, and chief has users beyond this host: the moment a
# fix/unblock/replace/feature enum is hard-coded anywhere in the engine, somebody
# else's backlog becomes unreportable, and this host's own report starts making a
# claim ("this is the order") that no project asked it to make. So the assertions here
# are about what chief REFUSES to know:
#
#   opacity        invented category strings — banana, zebra, a value with a space and
#                  a non-ASCII letter — must render exactly like any other, and an
#                  ABSENT category must read as (uncategorized) rather than as an error.
#   no ordering    given the four canonical words and NO declared vocabulary, the rows
#                  must come out in COUNT order, which the fixture arranges to be
#                  nothing like the canonical one. A hard-coded enum fails this.
#   the project's  a project that declares CHIEF_CATEGORIES in .chief/config gets its
#   ordering       order, and the ordering rule made visible: how much live work
#                  precedes the last category. A category outside the vocabulary is
#                  still reported, marked, never dropped.
#   never fatal    `chief status` exits 0 whatever the backlog looks like. Only the
#                  opt-in --enforce-order exits non-zero, and only on the PROJECT'S
#                  own declared ordering — never on the absence of one.
#
# Arithmetic is asserted, not prose: the live and parked columns of the breakdown must
# sum to the live and parked totals of the report they break down. A category that
# leaks or vanishes moves one of those sums.
#
# Hermetic: scaffolded git repos in a temp dir, its own CHIEF_PREFIX/CHIEF_REPOS.
# No agent runs — counting and rendering only.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=cats GIT_AUTHOR_EMAIL=cats@test \
       GIT_COMMITTER_NAME=cats GIT_COMMITTER_EMAIL=cats@test
export CHIEF_PREFIX="$WORK/prefix" CHIEF_REPOS="$WORK/prefix/repos"
mkdir -p "$CHIEF_PREFIX"
# The environment must not speak for the projects under test.
unset CHIEF_CATEGORIES
CHIEF="$ROOT/bin/chief"
fail() { echo "CATEGORIES FAIL: $*" >&2; exit 1; }
has()  { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

command -v jq >/dev/null || fail "jq is required"

mkrepo() {   # $1 = path — a chief-initialized git repo with no tasklists
  mkdir -p "$1" || fail "mkdir $1"
  ( cd "$1" || exit 1
    export CHIEF_REPOS="$WORK/scratch-repos"
    git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
    git commit -q --allow-empty -m init
    "$CHIEF" init >/dev/null 2>&1 || exit 1
    rm -f tasks/chief/example.json ) || fail "could not scaffold $1"
}
tasklist() {   # $1 = repo, $2 = name, $3 = extra JSON merged in
  jq -n --arg n "$2" --argjson x "$3" \
    '{project:"t",branchName:("chief/"+$n),description:"x",iters:1,dependsOn:[],touches:[],warmup:[],
      userStories:[{id:"US-1",title:"t",description:"",acceptanceCriteria:["x"],passes:false,notes:""}]} + $x' \
    > "$1/tasks/chief/$2.json" || fail "could not write $2 in $1"
}
cat_of() { printf '{"category":%s}' "$(printf '%s' "$1" | jq -Rs 'rtrimstr("\n")')"; }

status() { ( cd "$1" && shift && "$CHIEF" status "$@" 2>/dev/null ); }

# The breakdown, read back as "<live>\t<parked>\t<name>" in RENDERED ORDER. A category
# may contain spaces, so the name is everything left of the two trailing counts (and of
# the trailing * that marks a value outside the declared vocabulary).
cat_tab() {
  printf '%s\n' "$1" | awk '
    /^ +category +live +parked$/ { t = 1; next }
    t && /^ +ordering/           { t = 0 }
    t && /^ +\*/                 { next }
    t && NF >= 3 {
      if ($NF == "*") { live = $(NF-2); parked = $(NF-1); n = NF - 3 }
      else            { live = $(NF-1); parked = $NF;     n = NF - 2 }
      name = $1; for (i = 2; i <= n; i++) name = name " " $i
      print live "\t" parked "\t" name }'
}
names_in_order() { cat_tab "$1" | cut -f3 | tr '\n' '|'; }
col_sum()        { cat_tab "$1" | awk -F'\t' -v f="$2" '{ s += $f } END { print s + 0 }'; }
total_of()       { printf '%s\n' "$1" | awk '$1 == "remaining" { print $2; exit }'; }
live_of()        { printf '%s\n' "$1" | awk '$1 == "remaining" { print $4; exit }'; }
parked_of()      { printf '%s\n' "$1" | awk '$1 == "remaining" { print $7; exit }'; }

# ── fixture 1: opacity ───────────────────────────────────────────────────────
# Invented values, a value with a space and a non-ASCII letter, an absent one, and an
# unparseable tasklist — the whole point being that none of them is special to chief.
OPAQUE="$WORK/opaque"
mkrepo "$OPAQUE"
tasklist "$OPAQUE" 10-a "$(cat_of banana)"
tasklist "$OPAQUE" 11-b "$(cat_of banana)"
tasklist "$OPAQUE" 12-c "$(cat_of zebra)"
tasklist "$OPAQUE" 13-d '{"category":"zebra","parked":true}'
tasklist "$OPAQUE" 14-e '{"category":"aardvark","parked":true}'
tasklist "$OPAQUE" 15-f '{}'                                   # no category at all
tasklist "$OPAQUE" 16-g "$(cat_of 'réview needed')"            # space + multi-byte
printf 'this is not json {{{\n' > "$OPAQUE/tasks/chief/17-broken.json"

OUT="$(status "$OPAQUE")"; rc=$?
[ "$rc" = 0 ] || fail "chief status exited $rc on a backlog full of invented categories:
$OUT"
has "categories" "$OUT" || fail "no category breakdown despite categories on disk:
$OUT"
for c in banana zebra aardvark; do
  cat_tab "$OUT" | cut -f3 | grep -qx "$c" || fail "the invented category '$c' did not render:
$OUT"
done
cat_tab "$OUT" | cut -f3 | grep -qx 'réview needed' \
  || fail "a category with a space and a multi-byte letter was mangled or dropped:
$OUT"
cat_tab "$OUT" | cut -f3 | grep -qx '(uncategorized)' \
  || fail "a tasklist with no category was not reported as uncategorized:
$OUT"
has "problems" "$OUT" || fail "the unparseable tasklist stopped being a problem:
$OUT"

# THE ARITHMETIC: the breakdown must account for every remaining tasklist, exactly once.
[ "$(live_of "$OUT")"   = "$(col_sum "$OUT" 1)" ] \
  || fail "the live column sums to $(col_sum "$OUT" 1) but $(live_of "$OUT") tasklists are live:
$OUT"
[ "$(parked_of "$OUT")" = "$(col_sum "$OUT" 2)" ] \
  || fail "the parked column sums to $(col_sum "$OUT" 2) but $(parked_of "$OUT") are parked:
$OUT"
[ "$(total_of "$OUT")" = 8 ] || fail "the fixture should have 8 remaining, got $(total_of "$OUT"):
$OUT"

# Live and parked are SEPARATE: zebra is one of each, and neither column may absorb the other.
z="$(cat_tab "$OUT" | awk -F'\t' '$3 == "zebra" { print $1 "/" $2 }')"
[ "$z" = "1/1" ] || fail "zebra should read 1 live / 1 parked, got '$z':
$OUT"
a="$(cat_tab "$OUT" | awk -F'\t' '$3 == "aardvark" { print $1 "/" $2 }')"
[ "$a" = "0/1" ] || fail "a category with only parked work should read 0 live, got '$a':
$OUT"

# ── fixture 2: THE DISCRIMINATOR — no vocabulary means no ordering claim ─────
# The four words this host's repos happen to use, in counts whose descending order is
# nothing like the order those repos work them in. If any chief source file knows that
# ordering, this renders in it and the test fails.
CANON="$WORK/canonical"
mkrepo "$CANON"
for n in 10 11 12; do tasklist "$CANON" "$n-f" "$(cat_of feature)"; done
for n in 20 21;    do tasklist "$CANON" "$n-r" "$(cat_of replace)"; done
tasklist "$CANON" 30-u "$(cat_of unblock)"
tasklist "$CANON" 40-x "$(cat_of fix)"

OUT="$(status "$CANON")"; rc=$?
[ "$rc" = 0 ] || fail "chief status exited $rc:
$OUT"
ORDER="$(names_in_order "$OUT")"
[ "$ORDER" = "feature|replace|fix|unblock|" ] \
  || fail "with NO declared vocabulary the rows must be ordered by count then name
  (feature 3, replace 2, then the two ties by name) — got '$ORDER'.
  If this reads 'fix|unblock|replace|feature|', chief has adopted a vocabulary:
$OUT"
has "none declared" "$OUT" \
  || fail "chief claimed an ordering nobody declared:
$OUT"

# ── fixture 3: the project declares its own ordering ────────────────────────
printf '\nCHIEF_CATEGORIES="fix unblock replace feature"   # this project works in this order\n' \
  >> "$CANON/.chief/config"
tasklist "$CANON" 50-c "$(cat_of chore)"          # outside the declared vocabulary
tasklist "$CANON" 51-n '{}'                       # and one with none at all

OUT="$(status "$CANON")"; rc=$?
[ "$rc" = 0 ] || fail "chief status exited $rc with a declared vocabulary:
$OUT"
ORDER="$(names_in_order "$OUT")"
case "$ORDER" in
  "fix|unblock|replace|feature|"*) ;;
  *) fail "a declared vocabulary must be rendered in its declared order, got '$ORDER':
$OUT" ;;
esac
has "chore" "$OUT" \
  || fail "a category outside the declared vocabulary was DROPPED rather than reported:
$OUT"
has "(uncategorized)" "$OUT" \
  || fail "an absent category stopped being reported once a vocabulary was declared:
$OUT"
has ".chief/config" "$OUT" \
  || fail "the report does not say where the ordering came from:
$OUT"
# THE ORDERING RULE MADE VISIBLE: fix 1 + unblock 1 + replace 2 = 4 live tasklists
# precede "feature", the last category. Two more (chore, uncategorized) are unranked.
has 'precede "feature"' "$OUT" \
  || fail "the report does not state how much work precedes the last category:
$OUT"
p="$(printf '%s\n' "$OUT" | awk '/precede "feature"/ { print $1; exit }')"
[ "$p" = 4 ] || fail "4 live tasklists precede \"feature\" (fix 1 + unblock 1 + replace 2), report says '$p':
$OUT"
u="$(printf '%s\n' "$OUT" | awk '/the ordering does not name/ { print $1; exit }')"
[ "$u" = 2 ] || fail "chore + uncategorized are 2 unranked live tasklists, report says '$u':
$OUT"
# ...and the three numbers account for every live tasklist. Nothing is quietly ranked
# out of existence: 4 preceding + 3 in "feature" + 2 unranked = 9 live.
[ "$(live_of "$OUT")" = 9 ] || fail "expected 9 live, got $(live_of "$OUT"):
$OUT"
[ "$(live_of "$OUT")" = "$(col_sum "$OUT" 1)" ] \
  || fail "the breakdown no longer accounts for every live tasklist:
$OUT"

# ── the opt-in enforcement, and ONLY the opt-in ─────────────────────────────
# Plain status over the very same backlog still exits 0. Chief never fails over a
# category; the decision to run one out of order is the operator's.
( cd "$CANON" && "$CHIEF" status >/dev/null 2>&1 ) \
  || fail "plain chief status exited non-zero over a category-ordering violation"

OUT="$( cd "$CANON" && "$CHIEF" status --enforce-order 2>/dev/null )"; rc=$?
[ "$rc" != 0 ] || fail "--enforce-order passed a backlog with 4 tasklists preceding live work in the last category:
$OUT"
has "order check FAIL" "$OUT" || fail "--enforce-order failed without saying why:
$OUT"

# Drained: no live work in the last category, so there is nothing out of order.
DRAINED="$WORK/drained"
mkrepo "$DRAINED"
printf '\nCHIEF_CATEGORIES="fix unblock replace feature"\n' >> "$DRAINED/.chief/config"
tasklist "$DRAINED" 10-x "$(cat_of fix)"
tasklist "$DRAINED" 11-y "$(cat_of unblock)"
tasklist "$DRAINED" 12-z '{"category":"feature","parked":true}'   # parked is not live work
OUT="$( cd "$DRAINED" && "$CHIEF" status --enforce-order 2>/dev/null )"; rc=$?
[ "$rc" = 0 ] || fail "--enforce-order failed a backlog with no LIVE work in the last category:
$OUT"
has "order check PASS" "$OUT" || fail "--enforce-order did not report the check it ran:
$OUT"

# No vocabulary: there is no ordering to enforce, which is said out loud on stderr and
# is not an error. Chief refusing to hold a vocabulary must not become a CI failure.
ERR="$( cd "$OPAQUE" && "$CHIEF" status --enforce-order 2>&1 >/dev/null )"; rc=$?
[ "$rc" = 0 ] || fail "--enforce-order exited $rc on a project that declares no vocabulary — that is chief grading a category"
has "no category vocabulary" "$ERR" \
  || fail "--enforce-order passed silently with nothing to enforce:
$ERR"

# ── the portfolio: one repo's declaration is not the portfolio's ordering ───
DEV="$WORK/dev"
mkrepo "$DEV/one"; mkrepo "$DEV/two"
printf '\nCHIEF_CATEGORIES="fix feature"\n' >> "$DEV/one/.chief/config"
printf '\nCHIEF_CATEGORIES="fix feature"\n' >> "$DEV/two/.chief/config"
tasklist "$DEV/one" 10-a "$(cat_of fix)"
tasklist "$DEV/one" 11-b "$(cat_of feature)"
tasklist "$DEV/two" 20-a "$(cat_of feature)"
: > "$CHIEF_REPOS"

OUT="$(status "$DEV")"; rc=$?
[ "$rc" = 0 ] || fail "chief status exited $rc over a portfolio:
$OUT"
[ "$(names_in_order "$OUT")" = "fix|feature|" ] \
  || fail "two repos agreeing on one vocabulary should render in it, got '$(names_in_order "$OUT")':
$OUT"
f="$(cat_tab "$OUT" | awk -F'\t' '$3 == "feature" { print $1 }')"
[ "$f" = 2 ] || fail "the portfolio breakdown must SUM across repos (1 + 1 = 2 feature), got '$f':
$OUT"

# ...and when they disagree, no ordering is in force. Picking a winner would render a
# table in an order no project asked for — adopting a vocabulary, arrived at sideways.
printf '\nCHIEF_CATEGORIES="feature fix"\n' >> "$DEV/two/.chief/config"
OUT="$(status "$DEV")"; rc=$?
[ "$rc" = 0 ] || fail "chief status exited $rc on conflicting vocabularies:
$OUT"
has "none in force" "$OUT" \
  || fail "chief chose between two projects' declared orderings instead of reporting the conflict:
$OUT"
ERR="$( cd "$DEV" && "$CHIEF" status --enforce-order 2>&1 >/dev/null )"; rc=$?
[ "$rc" = 0 ] || fail "--enforce-order exited $rc with no single ordering to enforce"

# ── the source discipline the whole story rests on ──────────────────────────
# Prose may discuss this host's categories; CODE may not know them. "unblock" is the
# one of the four words that is never ordinary English in this engine, so any
# non-comment line mentioning it is a vocabulary chief has quietly adopted.
OFFENDERS="$(grep -n 'unblock' "$ROOT/bin/chief" "$ROOT"/engine/*.sh 2>/dev/null \
             | grep -v ':[0-9]*:[[:space:]]*#' || true)"
[ -z "$OFFENDERS" ] || fail "chief source code names a category vocabulary:
$OFFENDERS"

echo "CATEGORIES PASS — opaque strings, the project's ordering or none, and only --enforce-order can fail"
