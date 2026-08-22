#!/usr/bin/env bash
# test/park-reasons.sh — a park carries a REASON, and chief reports it without owning
# the vocabulary.
#
# THE POINT OF THIS TEST. `"parked": true` says a tasklist is not scheduled. It has
# never said WHY, so the reason lived in prose nobody reads at the moment it matters —
# which is the moment you try to run one. `"parkedReason"` is that reason, in a field,
# and everything asserted here is about what chief REFUSES to know about its value:
#
#   compatibility  a repo that adopts nothing sees exactly the old behaviour. `parked`
#                  alone still parks, and renders as a park that does not say why.
#   opacity        invented reason strings — a value with a space, a multi-byte letter,
#                  a value no vocabulary names — all render, and an absent one reads as
#                  (no reason given) rather than as an error.
#   the project's  a project that declares CHIEF_PARK_REASONS in .chief/config gets its
#   vocabulary     order, zeros included; a reason outside it is MARKED and kept. Same
#                  code path as CHIEF_CATEGORIES, so this also pins that the two do not
#                  interfere: one repo may declare either, both, or neither.
#   met where it   naming a parked tasklist in `chief run` prints its reason and
#   is met         schedules nothing — and says how to run it anyway. A bare run in an
#                  all-parked repo names the parks instead of reading as an empty
#                  backlog. Neither is a failure: both exit 0 interactively.
#   never fatal    `chief status` still exits 0 over any of it.
#
# NO VOCABULARY IS PINNED HERE, deliberately: every reason this fixture uses is a
# nonsense string invented by the fixture. Pinning `owned-elsewhere` (or any of this
# host's other three) as a value a test expects is the exact failure the story exists
# to avoid — so the only assertion about those words is that chief's own source code
# does NOT contain them.
#
# Hermetic: scaffolded git repos in a temp dir, its own CHIEF_PREFIX/CHIEF_REPOS.
# No agent runs — `chief run` is only ever reached as a dry run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=park GIT_AUTHOR_EMAIL=park@test \
       GIT_COMMITTER_NAME=park GIT_COMMITTER_EMAIL=park@test
export CHIEF_PREFIX="$WORK/prefix" CHIEF_REPOS="$WORK/prefix/repos"
mkdir -p "$CHIEF_PREFIX"
# The environment must not speak for the projects under test.
unset CHIEF_PARK_REASONS CHIEF_CATEGORIES CHIEF_RUN_PARKED
CHIEF="$ROOT/bin/chief"
fail() { echo "PARK FAIL: $*" >&2; exit 1; }
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
# A PARKED tasklist carrying an arbitrary reason string — built through jq so a value
# with a space, a quote or a multi-byte letter reaches the file intact.
park() {   # $1 = repo, $2 = name, $3 = reason ("" = parked with no reason at all)
  local extra
  if [ -z "$3" ]; then extra='{"parked":true}'
  else extra="$(jq -nc --arg r "$3" '{parked:true,parkedReason:$r}')"; fi
  tasklist "$1" "$2" "$extra"
}

status() { ( cd "$1" && shift && "$CHIEF" status "$@" 2>/dev/null ); }
dryrun() { ( cd "$1" && shift && "$CHIEF" run -n "$@" 2>&1 ); }

# The park breakdown, read back as "<parked>\t<reason>" in RENDERED ORDER. A reason may
# contain spaces, so the name is everything left of the trailing count (and of the
# trailing * that marks a value outside the declared vocabulary).
park_tab() {
  printf '%s\n' "$1" | awk '
    /^ +reason +parked$/ { t = 1; next }
    t && /^ +declared/   { t = 0 }
    t && /^ +\*/         { next }
    t && NF >= 2 {
      if ($NF == "*") { n = $(NF-1); k = NF - 2 }
      else            { n = $NF;     k = NF - 1 }
      name = $1; for (i = 2; i <= k; i++) name = name " " $i
      print n "\t" name }'
}
reasons_in_order() { park_tab "$1" | cut -f2 | tr '\n' '|'; }
park_sum()         { park_tab "$1" | awk -F'\t' '{ s += $1 } END { print s + 0 }'; }
parked_of()        { printf '%s\n' "$1" | awk '$1 == "remaining" { print $7; exit }'; }

# ── fixture 1: a repo that adopts nothing ───────────────────────────────────
# The compatibility claim, asserted rather than assumed: `parked: true` alone still
# parks, still counts as remaining, still gets no runnable/blocked verdict, and the
# report says out loud that none of them says why.
PLAIN="$WORK/plain"
mkrepo "$PLAIN"
tasklist "$PLAIN" 10-live '{}'
park "$PLAIN" 20-p ''
park "$PLAIN" 21-q ''

OUT="$(status "$PLAIN")"; rc=$?
[ "$rc" = 0 ] || fail "chief status exited $rc on a repo with plain parks:
$OUT"
[ "$(parked_of "$OUT")" = 2 ] || fail "two plain parks should still count as parked, report says '$(parked_of "$OUT")':
$OUT"
grep -qx "      20-p" <<<"$OUT" \
  || fail "a park with no reason no longer renders as a bare name — the old behaviour changed:
$OUT"
has "none of the 2 parked tasklist(s) says why" "$OUT" \
  || fail "a repo where nothing declares a reason is not told so:
$OUT"
# ...and no table is rendered for a repo with nothing to break down.
[ -z "$(park_tab "$OUT")" ] || fail "a breakdown was rendered with no reasons anywhere:
$OUT"

# ── fixture 2: opacity ───────────────────────────────────────────────────────
# Invented values, one with a space and a multi-byte letter, one absent. None of them
# is special to chief, and the counts must account for every parked tasklist exactly once.
OPAQUE="$WORK/opaque"
mkrepo "$OPAQUE"
tasklist "$OPAQUE" 10-live '{}'
park "$OPAQUE" 20-a 'wibble'
park "$OPAQUE" 21-b 'wibble'
park "$OPAQUE" 22-c 'flim flam'
park "$OPAQUE" 23-d 'déjà parked'
park "$OPAQUE" 24-e ''

OUT="$(status "$OPAQUE")"; rc=$?
[ "$rc" = 0 ] || fail "chief status exited $rc on a backlog full of invented park reasons:
$OUT"
for r in wibble 'flim flam' 'déjà parked' '(no reason given)'; do
  park_tab "$OUT" | cut -f2 | grep -qxF "$r" \
    || fail "the park reason '$r' did not render:
$OUT"
done
w="$(park_tab "$OUT" | awk -F'\t' '$2 == "wibble" { print $1 }')"
[ "$w" = 2 ] || fail "two tasklists parked for 'wibble' should read 2, got '$w':
$OUT"
# THE ARITHMETIC: the breakdown accounts for every parked tasklist, exactly once.
[ "$(parked_of "$OUT")" = 5 ] || fail "the fixture has 5 parked, report says $(parked_of "$OUT"):
$OUT"
[ "$(park_sum "$OUT")" = 5 ] \
  || fail "the park breakdown sums to $(park_sum "$OUT") over 5 parked tasklists:
$OUT"
# The LIVE tasklist is not in it: this breaks down the parked total, not the backlog.
has "of 5 parked tasklist(s) say why" "$OUT" \
  || fail "the section does not state how many of the parks carry a reason:
$OUT"
# With no vocabulary declared, rows are ordered by count then name — stable, and
# pointedly not a claim about which reason matters more.
[ "$(reasons_in_order "$OUT")" = "wibble|(no reason given)|déjà parked|flim flam|" ] \
  || fail "with no declared vocabulary the rows must be ordered by count then name,
  got '$(reasons_in_order "$OUT")':
$OUT"
has "declared  none" "$OUT" \
  || fail "chief claimed a park vocabulary nobody declared:
$OUT"

# ── fixture 3: the project declares its own vocabulary ──────────────────────
# Declared order, zeros included, and a reason outside it MARKED and kept. Declared
# alongside CHIEF_CATEGORIES, because the two share one reader and must not interfere.
# The declaration is a list of WHITESPACE- OR COMMA-SEPARATED TOKENS, exactly as
# CHIEF_CATEGORIES is, so a multi-word reason can be REPORTED but not DECLARED. That
# is the deal docs/reference/status.md states, and it is pinned here: 'flim flam' and
# 'déjà parked' still render, marked, below the declared rows.
printf '\nCHIEF_CATEGORIES="banana zebra"\nCHIEF_PARK_REASONS="wibble, never-used"\n' \
  >> "$OPAQUE/.chief/config"
OUT="$(status "$OPAQUE")"; rc=$?
[ "$rc" = 0 ] || fail "chief status exited $rc with a declared park vocabulary:
$OUT"
case "$(reasons_in_order "$OUT")" in
  "wibble|never-used|"*) ;;
  *) fail "a declared vocabulary must render in its declared order, got '$(reasons_in_order "$OUT")':
$OUT" ;;
esac
park_tab "$OUT" | cut -f2 | grep -qxF 'flim flam' \
  || fail "a multi-word reason must still be REPORTED once a vocabulary is declared:
$OUT"
n="$(park_tab "$OUT" | awk -F'\t' '$2 == "never-used" { print $1 }')"
[ "$n" = 0 ] || fail "a declared reason nothing uses must still render, at 0 — got '$n':
$OUT"
park_tab "$OUT" | cut -f2 | grep -qxF 'déjà parked' \
  || fail "a reason outside the declared vocabulary was DROPPED rather than reported:
$OUT"
has "outside the declared vocabulary" "$OUT" \
  || fail "an out-of-vocabulary reason rendered with no note saying so:
$OUT"
has "CHIEF_PARK_REASONS" "$OUT" \
  || fail "the report does not say where the park vocabulary came from:
$OUT"
[ "$(park_sum "$OUT")" = 5 ] \
  || fail "declaring a vocabulary changed the arithmetic — sums to $(park_sum "$OUT"), not 5:
$OUT"
# The category breakdown is still the category breakdown: one reader, two fields.
has "banana" "$OUT" || fail "declaring CHIEF_PARK_REASONS broke the category vocabulary:
$OUT"

# ── the machine feed carries all of it ──────────────────────────────────────
J="$( cd "$OPAQUE" && "$CHIEF" status --json 2>/dev/null )"
printf '%s' "$J" | jq -e . >/dev/null || fail "chief status --json is not parseable:
$J"
jnum() { printf '%s' "$J" | jq -r "$1"; }
[ "$(jnum '.parks.parked')"       = 5 ] || fail "json .parks.parked: $(jnum '.parks.parked')"
[ "$(jnum '.parks.with_reason')"  = 4 ] || fail "json .parks.with_reason: $(jnum '.parks.with_reason')"
[ "$(jnum '.parks.breakdown | map(.parked) | add')" = 5 ] \
  || fail "the json breakdown does not sum to the parked total:
$J"
[ "$(jnum '.parks.tasklists | map(select(.reason == null)) | length')" = 1 ] \
  || fail "the park with no reason should carry a null reason in json:
$J"
[ "$(jnum '.parks.vocabulary | length')" = 2 ] || fail "json .parks.vocabulary: $(jnum '.parks.vocabulary')"
# ...and `parked` is still the array of names it has always been.
[ "$(jnum '.parked | length')" = 5 ] || fail "json .parked changed shape: $(jnum '.parked')"
[ "$(jnum '.parked[0]')" = "20-a" ] || fail "json .parked is no longer a list of names: $(jnum '.parked[0]')"

# ── the park, met where an operator actually meets it ───────────────────────
# Naming one prints the reason it carries and schedules NOTHING. Exit 0: a park is a
# decision somebody made, not a failure.
D="$(dryrun "$OPAQUE" 20-a)"; rc=$?
[ "$rc" = 0 ] || fail "naming a parked tasklist exited $rc — a park is not a failure:
$D"
has "wibble" "$D" || fail "chief run on a parked tasklist did not print its reason:
$D"
has "chief run --parked" "$D" || fail "the park message does not say how to run it anyway:
$D"
has "DRY RUN" "$D" && fail "a parked tasklist was SCHEDULED despite being parked:
$D"
# A park with no reason says that, rather than saying nothing.
D="$(dryrun "$OPAQUE" 24-e)"
has "does not say why" "$D" \
  || fail "naming a park that carries no reason printed no explanation at all:
$D"
# The override runs it, which is the capability that used to be the silent default.
D="$(dryrun "$OPAQUE" --parked 20-a)"; rc=$?
[ "$rc" = 0 ] || fail "chief run --parked exited $rc:
$D"
has "wave 1 (1/" "$D" || fail "--parked did not schedule the parked tasklist it named:
$D"
# A live tasklist is unaffected — the stop is about the park, not about naming.
D="$(dryrun "$OPAQUE" 10-live)"
has "wave 1 (1/" "$D" || fail "naming a LIVE tasklist stopped the run:
$D"

# A bare run where everything is parked names the parks, instead of reading like an
# empty backlog. This is the sentence the story is written against.
ALLPARKED="$WORK/allparked"
mkrepo "$ALLPARKED"
park "$ALLPARKED" 20-a 'wibble'
park "$ALLPARKED" 21-b ''
D="$(dryrun "$ALLPARKED")"; rc=$?
[ "$rc" = 0 ] || fail "a bare run in an all-parked repo exited $rc:
$D"
has "wibble"    "$D" || fail "the all-parked message does not name the reason a park carries:
$D"
has "20-a"      "$D" || fail "the all-parked message does not name the parked tasklists:
$D"
has "does not say why" "$D" \
  || fail "the all-parked message hides a park that records no reason:
$D"

# `chief list` says it too, and a park with no reason renders exactly as it always did.
L="$( cd "$ALLPARKED" && "$CHIEF" list 2>&1 )"
has "(parked: wibble)" "$L" || fail "chief list does not report the reason a park carries:
$L"
grep -q '21-b  (parked)$' <<<"$L" \
  || fail "a park with no reason changed shape in chief list:
$L"

# ── the portfolio: one repo's declaration is not the portfolio's ────────────
DEV="$WORK/dev"
mkrepo "$DEV/one"; mkrepo "$DEV/two"
printf '\nCHIEF_PARK_REASONS="wibble flonk"\n' >> "$DEV/one/.chief/config"
printf '\nCHIEF_PARK_REASONS="wibble flonk"\n' >> "$DEV/two/.chief/config"
park "$DEV/one" 20-a wibble
park "$DEV/two" 20-b wibble
: > "$CHIEF_REPOS"

OUT="$(status "$DEV")"; rc=$?
[ "$rc" = 0 ] || fail "chief status exited $rc over a portfolio:
$OUT"
w="$(park_tab "$OUT" | awk -F'\t' '$2 == "wibble" { print $1 }')"
[ "$w" = 2 ] || fail "the portfolio breakdown must SUM across repos (1 + 1 = 2), got '$w':
$OUT"

# ...and when they disagree, none is in force. Picking a winner would render a table in
# an order no project asked for — adopting a vocabulary, arrived at sideways.
printf '\nCHIEF_PARK_REASONS="flonk wibble"\n' >> "$DEV/two/.chief/config"
OUT="$(status "$DEV")"; rc=$?
[ "$rc" = 0 ] || fail "chief status exited $rc on conflicting park vocabularies:
$OUT"
has "none in force" "$OUT" \
  || fail "chief chose between two projects' declared park vocabularies:
$OUT"
[ "$(park_sum "$OUT")" = 2 ] || fail "a vocabulary conflict changed the counts:
$OUT"

# ── a reason with no park is a park that never happened ─────────────────────
STRAY="$WORK/stray"
mkrepo "$STRAY"
tasklist "$STRAY" 10-x '{"parkedReason":"wibble"}'      # no "parked": true
OUT="$(status "$STRAY")"; rc=$?
[ "$rc" = 0 ] || fail "chief status exited $rc on a stray parkedReason:
$OUT"
[ "$(parked_of "$OUT")" = 0 ] \
  || fail "a parkedReason with no \"parked\": true was treated as a park — the SCHEDULER reads
  the flag, so reporting it as parked would disagree with what a run does:
$OUT"
has "problems" "$OUT" || fail "a stray parkedReason was silently ignored:
$OUT"
D="$(dryrun "$STRAY" 10-x)"
has "wave 1 (1/" "$D" || fail "a stray parkedReason stopped a run the scheduler would launch:
$D"

# ── the source discipline the whole story rests on ─────────────────────────
# Prose may discuss the reasons this host's repos use; CODE may not know them. These
# three are what THIS host needs, and a general harness that blessed them would make
# somebody else's backlog unreportable. Comment lines are exempt; code is not.
OFFENDERS="$(grep -n 'owned-elsewhere\|awaiting-evidence' \
              "$ROOT/bin/chief" "$ROOT"/engine/*.sh 2>/dev/null \
             | grep -v ':[0-9]*:[[:space:]]*#' || true)"
[ -z "$OFFENDERS" ] || fail "chief source code names a park vocabulary:
$OFFENDERS"

echo "PARK PASS — an opaque reason, the project's vocabulary or none, and a park met where it is met"
