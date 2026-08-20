#!/usr/bin/env bash
# engine/status.sh — `chief status`: what is LEFT, and what can START NOW.
#
# `chief list` prints one line per tasklist with a story count. It answers "how far
# along is each one", which is a different question from "what is the state of the
# backlog": no totals, no live/parked split, and no notion of what is runnable
# versus waiting on an unmerged dependency. This is that second question, and it is
# answered by running the SCHEDULER'S OWN GATE in report mode.
#
# THE ONE INVARIANT. Runnable here means exactly what runnable means to the driver:
# every dependsOn edge resolves to a completed/ record carrying mergedToMain. The
# verdict is computed by engine/deps.sh — the module driver.sh sources for the same
# decision — and never by a private copy. A report that used its own merge
# resolution would drift from the scheduler and become worse than no report: it
# would name work as startable that a run would then refuse to start.
#
# DEGRADE, NEVER ABORT. A backlog is exactly where malformed input accumulates —
# an unparseable tasklist, a dependency naming a repo that no longer exists. Each
# is counted, named in the `problems` section, and the rest of the report still
# renders. A status command that dies on one bad file is a status command that
# cannot be used on the backlog it exists to describe.
#
# SCOPE IS STATED, NEVER ASSUMED. A portfolio number whose coverage is unstated is
# a number nobody can check, so every render names the scope that produced it and
# how that scope was resolved. Three scopes:
#
#   this repo   cwd is at or below a chief-initialized repo — that repo alone
#   walk        cwd is not, so the tree BENEATH it is walked, reconciled with the
#               registry entries that live under it
#   registry    --all: every repo in $CHIEF_REPOS, regardless of cwd
#
# and four ways the walk is kept from lying about the count, each one a trap that
# was hit for real on this host rather than a hypothetical:
#
#   nesting     a repo is one whose ROOT the walk finds. A tasks/chief BELOW an
#               already-matched root is that repo's own business — a fixture, an
#               example, a vendored sample — and is not a second repo.
#   worktrees   a worktree is a full copy of a repo, .chief/config and all. They
#               normally live outside the scanned tree (CHIEF_WORKTREE_ROOT), so
#               the walk is normally safe — but an operator who relocates that root
#               under the tree would otherwise see every in-flight tasklist counted
#               TWICE, in a report whose entire purpose is arithmetic. The guard is
#               therefore explicit rather than incidental.
#   identity    walk and registry are reconciled by RESOLVED ABSOLUTE PATH, so a
#               symlink or a trailing slash cannot mint a phantom second repo, and
#               a repo found both ways is counted ONCE (its source says "both").
#   exclusion   an operator excludes a subtree with the ignore file, without
#               editing this walk — and an excluded repo is REPORTED as excluded,
#               because a repo that silently vanishes reads as a repo with no work.
#
# CATEGORIES ARE OPAQUE STRINGS. A tasklist may carry a `category`, and the report
# breaks its totals down by one — live and parked separately. Chief does not know
# what a category means and holds NO vocabulary of its own: whatever string is there
# renders, an absent one reads as (uncategorized), and no value is special. A project
# that works its backlog in a declared order says so ITSELF, in its own .chief/config
# (CHIEF_CATEGORIES); chief then renders in that order and states how much work
# precedes the last category — the project's rule, made visible.
#
# Making it visible is as far as chief goes. `chief status` exits 0 whatever the
# backlog looks like, and only the opt-in --enforce-order turns a violation into a
# non-zero exit, for a CI job that asked for one. The distinction is deliberate: a
# category is a statement ABOUT a tasklist, and the decision to run one out of order
# is the operator's. A harness with users beyond one host cannot make it for them,
# and a hard-coded enum would make somebody else's backlog unreportable.
#
# TWO OUTPUTS, ONE PASS. `--json` emits the whole report as a single JSON document
# on stdout and pushes every human-facing note to stderr, so it pipes to jq cleanly
# — the stdout-is-data discipline `chief events` already keeps. It is the same
# numbers rendered twice, never a second scan with its own arithmetic.
#
# AND THE COST OF ASKING. A portfolio is ~1,000 records, so a fork per record is the
# difference between a command an operator runs casually and one they stop running.
# Each record is read ONCE, by one jq per directory rather than one per file
# (read_records below, and crossrepo.sh's completed/ index behind is_recorded_done),
# which is what keeps the whole-tree run in the low seconds. test/status-perf.sh
# guards it, and guards it by counting jq invocations as well as by the clock:
# the fork count is the thing that regresses, and it is the half of the assertion
# that does not depend on how loaded the machine is.
#
# Exit status is therefore 0 whatever the backlog looks like, unless --enforce-order
# was asked for and the project's own declared ordering is violated. This reports
# state; it does not grade it. Full reference: docs/reference/status.md
set -uo pipefail

TAB="$(printf '\t')"
# The record reader's field separator is US (0x1f), NOT a tab. Tab is IFS WHITESPACE:
# `IFS=$'\t' read` collapses a run of tabs into one delimiter, so an empty middle
# field — a tasklist with no category, or with no dependencies — silently shifts every
# field after it left. US is not whitespace, so empty fields survive `read` intact.
US="$(printf '\037')"
ENGINE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=engine/paths.sh
. "$ENGINE/paths.sh"
# shellcheck source=engine/deps.sh
. "$ENGINE/deps.sh"
# A ONE-SHOT READER may cache the merge verdict; the scheduler may not (crossrepo.sh).
# This is the whole reason a portfolio scan is not a jq fork per dependency edge.
chief_merged_index_on
CHIEF_VERSION="$(cat "$ENGINE/../VERSION" 2>/dev/null || echo unknown)"

: "${CHIEF_REPOS:=}"
: "${CHIEF_CATEGORIES:=}"
REPO=""; TASKS_REL=""; SRC=""; COMPLETED=""     # deps.sh's contract; set by deps_scope

# How deep beneath the walk base a repo ROOT may sit. Bounded because the walk runs
# from wherever the operator happens to stand, and an unbounded find from a home
# directory is a report that never finishes.
DEPTH="${CHIEF_STATUS_DEPTH:-4}"

BLOCKED_ONLY=0
ALL=0
ENFORCE_ORDER=0
JSON=0
# How many blockers get the CASCADE computed (see blocker_table). Bounded because
# the closure is quadratic in the blocked set and the rows past the top of the list
# are not a plan anybody acts on — and the cap is REPORTED when it bites, never
# silently applied.
CASCADE_CAP="${CHIEF_STATUS_CASCADE_CAP:-25}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --blocked)        BLOCKED_ONLY=1; shift ;;
    --all)            ALL=1; shift ;;
    --enforce-order)  ENFORCE_ORDER=1; shift ;;
    --json)           JSON=1; shift ;;
    -h|--help)
      cat <<'USAGE'
chief status — what is left in the backlog, and what can start now.

  chief status              totals for this repo: remaining (live/parked),
                            runnable vs blocked, completed, and any problems
  chief status --blocked    only what is waiting, naming the edge that holds it —
                            and, aggregated the other way round, which merges would
                            release the most: a plan rather than a number
  chief status --all        every repo in the known-repos registry, regardless of cwd
  chief status --json       the whole report as ONE JSON document on stdout, notes and
                            warnings on stderr, so it pipes to jq cleanly
  chief status --enforce-order
                            exit non-zero if the project's OWN declared category
                            ordering is violated — for a CI job that asked for it

Run from a directory that is NOT a chief project, it walks the tree beneath you and
reports every chief-initialized repo it finds, per repo and in total. The header
always states which scope produced the numbers.

Environment:
  CHIEF_STATUS_DEPTH   how deep beneath the walk base a repo root may sit (default 4)
  CHIEF_STATUS_CASCADE_CAP
                       how many blockers get the release CASCADE computed (default 25)
  CHIEF_IGNORE         ignore-list file; an entry excludes that path and everything
                       beneath it (default $CHIEF_PREFIX/ignore)
  CHIEF_CATEGORIES     the ordered category vocabulary for this report, overriding
                       what the repos in scope declare in their .chief/config

Categories are reported as OPAQUE STRINGS — chief holds no vocabulary of its own,
any set of values renders, and a tasklist with no category reads as (uncategorized).
A project declares its own ordering with CHIEF_CATEGORIES in .chief/config; without
one, categories are ordered by count and no ordering is claimed.

Runnable means what it means to the scheduler: every dependsOn edge resolves to a
completed record carrying mergedToMain. Exits 0 whatever the backlog looks like —
this reports state. Only --enforce-order can make it exit non-zero.
USAGE
      exit 0 ;;
    *) echo "chief status: unknown flag: $1" >&2; exit 2 ;;
  esac
done

# ── identity, membership, and the tree walk ──────────────────────────────────
# Every path that reaches a count goes through abspath() first. That is the whole
# of the de-duplication argument: `cd -P` resolves symlinks and normalizes trailing
# slashes and `.`/`..`, so two spellings of one repo become one string, and string
# equality is then a sound test for "same repo".
abspath()      { ( cd -P "${1:-/nonexistent}" 2>/dev/null && pwd ); }
is_chief_repo() { [ -f "$1/.chief/config" ]; }

# The same normalization for a path that need NOT exist — an ignore-list entry naming
# a directory the operator has not created yet, or a registry entry whose repo has
# been deleted. Without it, a registry or ignore file written as /var/… never matches
# a walk base resolved to /private/var/… and the entry silently does nothing, which is
# the worst possible failure for an exclusion mechanism.
abspath_like() {
  local p="$1" a
  a="$(abspath "$p")";              [ -n "$a" ] && { printf '%s' "$a"; return 0; }
  a="$(abspath "$(dirname "$p")")"; [ -n "$a" ] && { printf '%s/%s' "$a" "$(basename "$p")"; return 0; }
  printf '%s' "$p"
}

in_list() {   # $1 = value, $2 = newline-delimited list (trailing newline required)
  case "
$2" in *"
$1
"*) return 0 ;; esac
  return 1
}

# Directories the walk never descends into: dot-directories (except .chief itself,
# which is what we are looking for) and the toolchain artifact trees that make an
# unbounded find slow without ever containing a repo root.
walk_repos() {   # $1 = base -> absolute repo roots beneath it, one per line, sorted
  local base="$1" c root abs
  find "$base" -mindepth 1 -maxdepth "$((DEPTH + 1))" \
       \( -type d \( \( -name '.*' ! -name '.chief' \) -o -name node_modules \
                     -o -name vendor -o -name target -o -name dist -o -name build \) -prune \) -o \
       \( -type d -name '.chief' -print \) 2>/dev/null \
  | while IFS= read -r c; do
      root="${c%/.chief}"
      is_chief_repo "$root" || continue
      abs="$(abspath "$root")"
      [ -n "$abs" ] && printf '%s\n' "$abs"
    done | sort -u
}

# A repo is one whose ROOT we found. Sorted input puts a parent before every child
# (a parent path is a prefix of its children), so one pass suffices: drop any root
# that lives beneath a root already accepted. This is what keeps a repo's own
# fixture — examples/minimal/tasks/chief here — from joining the portfolio as a
# second backlog and double-counting nothing into a total.
prune_nested() {
  local accepted="" r k keep
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    keep=1
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      case "$r" in "$k"/*) keep=0; break ;; esac
    done <<INNER
$accepted
INNER
    if [ "$keep" = 1 ]; then accepted="$accepted$r
"; printf '%s\n' "$r"; fi
  done
}

registry_entries() {   # raw registry lines, trailing slash stripped, deduped
  local p
  [ -n "$CHIEF_REPOS" ] && [ -f "$CHIEF_REPOS" ] || return 0
  while IFS= read -r p; do
    p="${p%/}"; [ -n "$p" ] || continue
    printf '%s\n' "$p"
  done < "$CHIEF_REPOS" | sort -u
}

# ── the ignore list ──────────────────────────────────────────────────────────
IGNORES=""
load_ignores() {
  local f line
  f="$(chief_ignore_file)"
  IGNORE_FILE="$f"
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$line" ] || continue
    case "$line" in
      "~/"*) [ -n "${HOME:-}" ] && line="$HOME/${line#\~/}" ;;
      /*)    ;;
      *)     line="$PWD/$line" ;;    # relative entries resolve against cwd
    esac
    line="${line%/}"
    IGNORES="$IGNORES$line
"
    # Both spellings, because either may be the one that matches (see abspath_like).
    case "$line" in *[*?[]*) ;; *) IGNORES="$IGNORES$(abspath_like "$line")
" ;; esac
  done < "$f"
}

is_ignored() {   # $1 = absolute repo path
  local p="$1" e
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    case "$e" in
      *[*?[]*)
        # shellcheck disable=SC2254   # deliberate: an entry may be a glob
        case "$p" in $e) return 0 ;; esac ;;
      *)
        [ "$p" = "$e" ] && return 0
        case "$p" in "$e"/*) return 0 ;; esac ;;
    esac
  done <<EOF
$IGNORES
EOF
  return 1
}

# ── the category vocabulary (opt-in, declared by the project) ────────────────
# READ AS A LINE, NEVER SOURCED. `.chief/config` is bash and load_project sources it,
# which is right for `run` — one project, chosen by the operator standing in it. This
# command reports a PORTFOLIO of repos it discovered rather than chose, and sourcing
# every one of their configs would both execute arbitrary shell from each of them
# inside the reporting process and leak one repo's settings into the next repo's
# scan. So the declaration is read as a literal line and nothing else happens. The
# cost is that only a literal value is honoured — no $VAR, no command substitution —
# which is the documented deal (docs/reference/status.md).
#
# The value is a LIST, not a set of known names: chief neither validates the entries
# nor requires a tasklist to use one. It is an ORDERING, supplied by the project, and
# that is the only meaning chief assigns to it.
VOCAB=""            # the ordering in force for this report, space-separated
VOCAB_SRC=""        # where it came from — named in the render, never assumed
VOCAB_DECLS=""      # "<label>\t<vocab>" per declaring repo; reconciled after the scan
VOCAB_CONFLICT=0

normalize_vocab() { printf '%s' "$1" | LC_ALL=C tr ',' ' ' | LC_ALL=C tr -s '[:space:]' ' ' | LC_ALL=C sed 's/^ //; s/ $//'; }

vocab_of() {   # $1 = repo root -> its declared vocabulary, or nothing
  local f="$1/.chief/config" line
  [ -f "$f" ] || return 0
  line="$(LC_ALL=C sed -n 's/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}CHIEF_CATEGORIES=//p' "$f" 2>/dev/null | tail -1)"
  [ -n "$line" ] || return 0
  # One layer of quoting, then whatever follows it (a trailing comment) is not ours.
  case "$line" in
    \"*) line="${line#\"}"; line="${line%%\"*}" ;;
    \'*) line="${line#\'}"; line="${line%%\'*}" ;;
    *)   line="${line%%#*}" ;;
  esac
  normalize_vocab "$line"
}

if [ -n "$CHIEF_CATEGORIES" ]; then
  VOCAB="$(normalize_vocab "$CHIEF_CATEGORIES")"
  VOCAB_SRC="the environment (CHIEF_CATEGORIES)"
fi

# ── scope resolution ─────────────────────────────────────────────────────────
# Deliberately NOT load_project: that hard-exits with "no .chief/config found"
# (bin/chief), which is the right answer for `run` and the wrong one for a report.
find_repo_up() {
  local d="$PWD"
  while [ "$d" != "/" ]; do
    [ -f "$d/.chief/config" ] && { (cd -P "$d" && pwd); return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

BASE="$(abspath "$PWD")"; BASE="${BASE:-$PWD}"
WT_ROOT="$(abspath "$(chief_worktree_root)")"      # empty when it does not exist yet
load_ignores

MODE=""; SCOPE_LINE=""; MULTI=0
WALKED=""; REGISTERED=""; CANDIDATES=""
REPOS=""            # "<abs path>\t<source>" — the repos actually reported
EXCLUDED=""; STALE=""; WT_SKIPPED=""

if [ "$ALL" = 1 ]; then
  MODE=registry; MULTI=1
  REGISTERED="$(registry_entries)
"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    a="$(abspath "$p")"
    if [ -z "$a" ] || ! is_chief_repo "$a"; then STALE="$STALE$p
"; continue; fi
    CANDIDATES="$CANDIDATES$a
"
  done <<EOF
$REGISTERED
EOF
  CANDIDATES="$(printf '%s' "$CANDIDATES" | sort -u | prune_nested)
"
  SCOPE_LINE="the known-repos registry ($CHIEF_REPOS), regardless of cwd"
elif ROOT="$(find_repo_up)"; then
  MODE=repo; MULTI=0
  CANDIDATES="$ROOT
"
  SCOPE_LINE="this repo"
else
  MODE=walk; MULTI=1
  WALKED="$(walk_repos "$BASE")
"
  # Reconciliation, explicit: the walk, PLUS the registry entries that live under
  # the same base. Both sides are resolved absolute paths, so the union is a set.
  # RESOLVE FIRST, then ask whether it is under the base. The other order is the bug:
  # a registry written as /var/... and a base resolved to /private/var/... are the same
  # directory on this platform, and comparing the raw spellings silently drops the repo.
  reg_under=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    a="$(abspath "$p")"
    if [ -z "$a" ] || ! is_chief_repo "$a"; then
      case "$(abspath_like "$p")" in "$BASE"|"$BASE"/*) STALE="$STALE$p
" ;; esac
      continue
    fi
    case "$a" in "$BASE"|"$BASE"/*) reg_under="$reg_under$a
" ;; esac
  done <<EOF
$(registry_entries)
EOF
  REGISTERED="$reg_under"
  CANDIDATES="$(printf '%s%s' "$WALKED" "$REGISTERED" | sort -u | prune_nested)
"
  SCOPE_LINE="the tree beneath $BASE (depth $DEPTH), reconciled with the registry"
fi

# The two filters every scope pays, in order. Both REPORT what they removed, because
# a repo that vanishes from a portfolio total reads exactly like a repo with no work.
under_wt() { [ -n "$WT_ROOT" ] || return 1; [ "$1" = "$WT_ROOT" ] && return 0; case "$1" in "$WT_ROOT"/*) return 0 ;; esac; return 1; }
while IFS= read -r p; do
  [ -n "$p" ] || continue
  # Both filters are about a SCOPE THAT WAS INFERRED. An operator standing in a repo
  # named it, and neither "that is a worktree" nor "that is on the ignore list" is an
  # answer to a direct question — `chief status` there reports there, as US-1 does.
  if [ "$MODE" != repo ]; then
    if under_wt "$p"; then WT_SKIPPED="$WT_SKIPPED$p
"; continue; fi
    if is_ignored "$p"; then EXCLUDED="$EXCLUDED$p
"; continue; fi
  fi
  case "$MODE" in
    registry) src=registry ;;
    repo)     src=cwd ;;
    *)        if in_list "$p" "$WALKED"; then
                src=walk; in_list "$p" "$REGISTERED" && src=both
              else src=registry; fi ;;
  esac
  REPOS="$REPOS$p	$src
"
done <<EOF
$CANDIDATES
EOF

# ── the pass over one repo's records ─────────────────────────────────────────
# Accumulated in newline-delimited strings rather than arrays: bash 3.2 is the
# compatibility floor and has no associative arrays (see driver.sh's header).
runnable=""      # names, one per line
blocked=""       # "name<TAB>dep<TAB>class<TAB>detail", one per line — first unmet edge
edges=""         # EVERY unmet edge: "name<TAB>selfkey<TAB>dep<TAB>depkey<TAB>class<TAB>detail".
                 # The first-edge line above is what a reader wants per tasklist; this is
                 # the same information keyed the other way round, which is what makes the
                 # "merge this and N others start" aggregation possible. Both keys are
                 # RECORD PATHS — the completed/ file a tasklist would have once merged is
                 # exactly what its dependents' edges resolve to — so the join is sound
                 # across repos, where a bare stem would collide.
parked=""        # names
unreadable=""    # names — counted as remaining, but no verdict is honest
problems=""      # "name<TAB>message"
rows=""          # "label<TAB>remaining<TAB>live<TAB>parked<TAB>runnable<TAB>blocked<TAB>completed<TAB>source<TAB>path"
# The category breakdown, accumulated RAW — one "<category><TAB>live|parked" line per
# counted tasklist, aggregated once at render time. Raw rather than a counter per
# category because the set of categories is not known in advance and bash 3.2 has no
# associative arrays: rewriting a "<cat> <n>" string per tasklist is quadratic, and a
# fixed set of counters would be exactly the hard-coded vocabulary this must not have.
cats=""
CAT_NONE='(uncategorized)'        # chief's label for an ABSENT category, not a value
CAT_UNREADABLE='(unreadable)'     # ...and for one that cannot be read at all
n_categorized=0  # tasklists that actually carried a category — the breakdown's trigger
n_live=0 n_parked=0 n_runnable=0 n_blocked=0 n_unreadable=0 n_completed=0 n_repos=0

add_problem() { problems="$problems$1	$2
"; }

# ── reading a directory of records ───────────────────────────────────────────
# ONE jq for the whole directory, not one per file. The fields are exactly what the
# splits and the verdict need, read in a single pass over each record: chief status
# on a portfolio asks this of ~1,000 files, and at a fork apiece the report costs
# more than the question is worth.
#
# `category` is an OPAQUE STRING (US-3) — flattened so that whatever an author wrote
# cannot break the record separator, and otherwise untouched. `dependsOn` is read
# defensively: a non-array there is not an array of edges, and reading it as one
# would abort the whole directory over a single malformed field.
RECORD_JQ='
  def flat: tostring | gsub("[\t\n\r\u001f]"; " ") | sub("^ +"; "") | sub(" +$"; "");
  input_filename as $p
  | ($p | split("/") | last | sub("\\.json$"; "")) as $n
  | if type == "object" then
      [$p, $n, "object", ((.parked // false) | tostring), ((.category // "") | flat),
       (has("dependsOn") | tostring),
       (if (.dependsOn | type) == "array" then (.dependsOn | map(flat)) else [] end | join(" "))]
    else
      [$p, $n, "other", "false", "", "false", ""]
    end
  | join("\u001f")'

# read_records DIR -> one US-separated line per record, in filename order.
#
# A record jq cannot parse aborts the read at that file, having already emitted a
# line for every file before it. That is enough to NAME the culprit — it is the next
# file in the list — so the reader reports it and resumes after it. The cost of a
# malformed record is therefore one extra fork, not a fallback to one fork per
# record; and it is reported rather than dropped, which is US-1's rule.
read_records() {
  local dir="$1" out rc n i f
  local files=() rest=()
  for f in "$dir"/*.json; do [ -e "$f" ] && files+=("$f"); done
  while [ "${#files[@]}" -gt 0 ]; do
    out="$(jq -r "$RECORD_JQ" "${files[@]}" 2>/dev/null)"; rc=$?
    [ -n "$out" ] && printf '%s\n' "$out"
    [ "$rc" = 0 ] && return 0
    n="$(printf '%s' "$out" | LC_ALL=C cut -d"$US" -f1 | LC_ALL=C sort -u | grep -c .)"
    [ "$n" -ge "${#files[@]}" ] && return 0        # no progress possible; stop rather than spin
    f="${files[$n]}"
    printf '%s%s%s%sbad%sfalse%s%sfalse%s\n' \
      "$f" "$US" "$(basename "$f" .json)" "$US" "$US" "$US" "$US" "$US"
    rest=(); i=$((n + 1))
    while [ "$i" -lt "${#files[@]}" ]; do rest+=("${files[$i]}"); i=$((i + 1)); done
    files=(); [ "${#rest[@]}" -gt 0 ] && files=("${rest[@]}")
  done
}

# scan_repo ROOT LABEL — one repo's records, folded into the totals above. The body
# is US-1's pass, unchanged except that deps_scope() is re-pointed per repo (which
# is exactly what deps.sh's four-globals contract exists for) and names are
# qualified with the repo label whenever more than one repo is in scope.
scan_repo() {
  local root="$1" label="$2" source="$3" f name q d voc
  local fpath kind parkedv catv hasdeps deplist prev="" selfkey depkey unmet ucls udet
  local r_live=0 r_parked=0 r_runnable=0 r_blocked=0 r_completed=0
  deps_scope "$root"

  # A vocabulary is the PROJECT's, so it is read per repo, from the repo. The env
  # override wins outright and skips the read entirely.
  if [ -z "$CHIEF_CATEGORIES" ]; then
    voc="$(vocab_of "$root")"
    [ -n "$voc" ] && VOCAB_DECLS="$VOCAB_DECLS$label$TAB$voc
"
  fi

  while IFS="$US" read -r fpath name kind parkedv catv hasdeps deplist; do
    [ -n "$name" ] || continue
    q="$name"; [ "$MULTI" = 1 ] && q="$label/$name"

    # jq applies the filter to every JSON VALUE in a file, so a file holding two of
    # them would be counted twice. They arrive adjacent (jq reads a file through
    # before moving on), so only the first is counted — and the file is named,
    # because a record silently counted once out of two is arithmetic nobody can check.
    if [ "$fpath" = "$prev" ]; then
      add_problem "$q" "more than one JSON document in the file — only the first is counted"
      continue
    fi
    prev="$fpath"

    if [ "$kind" = bad ]; then
      # No verdict is possible and inventing one would be the lie this file exists to
      # avoid — it is remaining work, it is a problem, and it is neither runnable nor
      # blocked. The driver, whose jq also fails here, treats it as dependency-free and
      # would launch it; that divergence is deliberate and reported rather than hidden.
      r_live=$((r_live + 1)); n_unreadable=$((n_unreadable + 1))
      unreadable="$unreadable$q
"
      cats="$cats$CAT_UNREADABLE${TAB}live
"
      add_problem "$q" "not valid JSON (jq cannot parse it) — no runnable/blocked verdict is possible"
      continue
    fi
    [ "$kind" = other ] && \
      add_problem "$q" "not a JSON object at the top level — read as carrying no dependencies"

    # Nothing here knows any category name; the only value chief recognizes is the
    # ABSENCE of one.
    if [ -n "$catv" ]; then n_categorized=$((n_categorized + 1)); else catv="$CAT_NONE"; fi

    if [ "$parkedv" = "true" ]; then
      r_parked=$((r_parked + 1)); parked="$parked$q
"
      cats="$cats$catv${TAB}parked
"
      continue
    fi
    r_live=$((r_live + 1))
    cats="$cats$catv${TAB}live
"

    [ "$hasdeps" = "true" ] || \
      add_problem "$q" "no \"dependsOn\" field — read as no dependencies (the schema expects the key, even empty)"

    # THE VERDICT. deps_of + is_recorded_done are the scheduler's, unmodified — the
    # record just read is handed to deps.sh's memo rather than re-read, so the answer
    # is still deps.sh's and the fork is not paid twice.
    deps_memo "$name" "$deplist"
    selfkey="$COMPLETED/$name.json"
    unmet="" ucls="" udet=""
    deps_of_set "$name"
    for d in $DEPS_LIST; do
      is_recorded_done "$d" && continue
      dep_record_set "$d"; depkey="$DEP_RECORD"
      [ -n "$depkey" ] || depkey="unresolved:$d"
      dep_verdict_set "$d"
      edges="$edges$q	$selfkey	$d	$depkey	$DEP_CLASS	$DEP_DETAIL
"
      # The FIRST unmet edge is what the per-tasklist line reports; the rest are
      # collected because "what would this merge release" cannot be answered from
      # one edge per tasklist.
      if [ -z "$unmet" ]; then
        unmet="$d"; ucls="$DEP_CLASS"; udet="$DEP_DETAIL"
      fi
    done

    if [ -z "$unmet" ]; then
      r_runnable=$((r_runnable + 1)); runnable="$runnable$q
"
    else
      r_blocked=$((r_blocked + 1))
      blocked="$blocked$q	$unmet	$ucls	$udet
"
      case "$ucls" in
        norepo)  add_problem "$q" "dependsOn \"$unmet\": $udet" ;;
        retired) add_problem "$q" "dependsOn \"$unmet\" is PERMANENTLY unsatisfiable: $udet" ;;
      esac
    fi
  done <<EOF
$(read_records "$SRC")
EOF

  for f in "$COMPLETED"/*.json; do [ -e "$f" ] || continue; r_completed=$((r_completed + 1)); done

  n_live=$((n_live + r_live)); n_parked=$((n_parked + r_parked))
  n_runnable=$((n_runnable + r_runnable)); n_blocked=$((n_blocked + r_blocked))
  n_completed=$((n_completed + r_completed)); n_repos=$((n_repos + 1))
  rows="$rows$label	$((r_live + r_parked))	$r_live	$r_parked	$r_runnable	$r_blocked	$r_completed	$source	$root
"
}

# LABEL: the shortest spelling that stays unambiguous. Under a walk that is the path
# relative to the base; elsewhere the ~-shortened absolute path. Never the basename —
# two repos may share one, and this report's job is arithmetic nobody has to re-check.
label_for() {
  local p="$1"
  case "$MODE" in
    walk) case "$p" in "$BASE"/*) printf '%s' "${p#"$BASE"/}"; return 0 ;; esac ;;
  esac
  case "${HOME:-}" in
    "") printf '%s' "$p" ;;
    *)  case "$p" in "$HOME"/*) printf '~/%s' "${p#"$HOME"/}" ;; *) printf '%s' "$p" ;; esac ;;
  esac
}

while IFS='	' read -r p src; do
  [ -n "$p" ] || continue
  scan_repo "$p" "$(label_for "$p")" "$src"
done <<EOF
$REPOS
EOF

n_remaining=$((n_live + n_parked))

# ── the ordering in force, reconciled across the repos in scope ──────────────
# One repo's declaration is that repo's. A PORTFOLIO has as many declarations as it
# has repos, and they need not agree — so the only honest answers are "they all say
# the same thing, and that is the ordering" or "they disagree, so no ordering is in
# force here". Guessing a winner would render a table in an order no project asked
# for, which is precisely the failure of adopting a vocabulary, arrived at sideways.
if [ -z "$VOCAB" ] && [ -n "$VOCAB_DECLS" ]; then
  vocab_distinct="$(printf '%s' "$VOCAB_DECLS" | cut -f2- | LC_ALL=C sort -u | grep -c .)"
  if [ "$vocab_distinct" = 1 ]; then
    VOCAB="$(printf '%s' "$VOCAB_DECLS" | cut -f2- | LC_ALL=C sort -u | grep .)"
    VOCAB_SRC=".chief/config (CHIEF_CATEGORIES)"
  else
    VOCAB_CONFLICT="$vocab_distinct"
  fi
fi

# THE ORDERING RULE, made visible: how much LIVE work precedes the last category in
# the declared ordering. It is the project's rule, so chief computes the number and
# prints it; only --enforce-order attaches a consequence to it.
cat_counts() {   # -> "<live><TAB><parked><TAB><category>" per category, aggregated
  printf '%s' "$cats" | LC_ALL=C awk -F'\t' '
    $1 == "" { next }
    { if ($2 == "parked") p[$1]++; else l[$1]++; seen[$1] = 1 }
    END { for (k in seen) printf "%d\t%d\t%s\n", l[k] + 0, p[k] + 0, k }'
}
cat_cell() {   # $1 = counts, $2 = category, $3 = 1 live | 2 parked -> a number, always
  printf '%s' "$1" | LC_ALL=C awk -F'\t' -v c="$2" -v f="$3" \
    '$3 == c { print $f; hit = 1 } END { if (!hit) print 0 }'
}

COUNTS="$(cat_counts)"
ORD_LAST=""; ORD_PRECEDE=0; ORD_LAST_LIVE=0
if [ -n "$VOCAB" ]; then
  set -f                        # a category is an opaque string; never a glob
  vocab_n=0; for c in $VOCAB; do vocab_n=$((vocab_n + 1)); done
  vocab_i=0
  for c in $VOCAB; do
    vocab_i=$((vocab_i + 1))
    if [ "$vocab_i" -lt "$vocab_n" ]; then
      ORD_PRECEDE=$((ORD_PRECEDE + $(cat_cell "$COUNTS" "$c" 1)))
    else
      ORD_LAST="$c"; ORD_LAST_LIVE="$(cat_cell "$COUNTS" "$c" 1)"
    fi
  done
  set +f
fi

# ── render ───────────────────────────────────────────────────────────────────
list_names() { printf '%s' "$1" | while IFS= read -r n; do [ -n "$n" ] && printf '      %s\n' "$n"; done; }
count_of()   { printf '%s' "$1" | grep -c . ; }

# One blocked line: the tasklist, the edge, and — for the retirement trap — the fact
# that the edge is permanently dead rather than merely early.
render_blocked() {
  printf '%s' "$blocked" | while IFS='	' read -r n d cls det; do
    [ -n "$n" ] || continue
    case "$cls" in
      retired) printf '      %-28s needs %s — PERMANENTLY BLOCKED: %s\n' "$n" "$d" "$det" ;;
      norepo)  printf '      %-28s needs %s — UNRESOLVABLE: %s\n'        "$n" "$d" "$det" ;;
      *)       printf '      %-28s needs %s — %s\n'                      "$n" "$d" "$det" ;;
    esac
  done
}

# ── the aggregation that turns a number into a plan ──────────────────────────
# "82 blocked" is a number. "these 9 merges release 82" is a plan, and only the
# second is something an operator can act on — so the blocked set is also keyed by
# the EDGE rather than by the waiter, and the edges are ranked by what merging each
# one would start.
#
# Three counts, because they answer three different questions and conflating them
# would overstate every row:
#
#   holds     how many blocked tasklists name this edge at all. The widest number,
#             and on its own the misleading one: a tasklist with two unmet edges is
#             not released by merging either one.
#   releases  how many become runnable THE MOMENT this merges — those for which
#             this is the only unmet edge. This is the honest direct answer.
#   cascade   ...and how many in total, if each tasklist so released is then worked
#             and merged in its turn. That is the chain an operator is actually
#             planning, and it is stated as a separate number rather than folded
#             into the first, because it assumes work that has not happened.
#
# The join key is the RECORD PATH on both sides (see `edges`), so a chain that
# crosses a repo boundary is followed exactly like one inside a repo.
#
# The cascade closure is quadratic in the blocked set, so it is computed for the
# top CASCADE_CAP rows only — and when that bites, the render says so. A silent cap
# in a report about totals reads as "this is all of it".
blocker_table() {   # -> "releases<TAB>cascade<TAB>holds<TAB>dep<TAB>class<TAB>depkey", best first
  printf '%s' "$edges" | LC_ALL=C awk -F'\t' -v CAP="$CASCADE_CAP" '
    $1 == "" { next }
    {
      t = $1; k = $4
      if (!((t SUBSEP k) in seen)) {
        seen[t SUBSEP k] = 1
        unmet[t] = unmet[t] k "\n"; n[t]++
        holds[k]++
      }
      selfk[t] = $2; label[k] = $3; cls[k] = $5
    }
    END {
      T = 0; for (t in n) tl[++T] = t
      D = 0; for (k in holds) { dl[++D] = k
        direct[k] = 0 }
      for (j = 1; j <= T; j++) {
        t = tl[j]
        if (n[t] == 1) { split(unmet[t], one, "\n"); direct[one[1]]++ }
      }
      # Insertion sort: releases desc, then holds desc, then the edge name. D is the
      # number of distinct unmerged edges in the backlog — small, and sorting it here
      # keeps the whole aggregation to ONE fork.
      for (i = 2; i <= D; i++) {
        v = dl[i]
        for (j = i - 1; j >= 1 && worse(dl[j], v); j--) dl[j + 1] = dl[j]
        dl[j + 1] = v
      }
      for (i = 1; i <= D; i++) {
        k = dl[i]
        casc = (i <= CAP) ? cascade(k) : -1
        printf "%d\t%d\t%d\t%s\t%s\t%s\n", direct[k], casc, holds[k], label[k], cls[k], k
      }
    }
    function worse(a, b) {
      if (direct[a] != direct[b]) return direct[a] < direct[b]
      if (holds[a]  != holds[b])  return holds[a]  < holds[b]
      return a > b
    }
    # Merge k, then keep merging whatever that releases, until nothing more moves.
    function cascade(k,   M, R, prog, j, t, m, parts, i2, ok, rel) {
      split("", M); split("", R); rel = 0
      M[k] = 1
      do {
        prog = 0
        for (j = 1; j <= T; j++) {
          t = tl[j]
          if (t in R) continue
          m = split(unmet[t], parts, "\n")
          ok = 1
          for (i2 = 1; i2 <= m; i2++) {
            if (parts[i2] == "") continue
            if (!(parts[i2] in M)) { ok = 0; break }
          }
          if (ok) { R[t] = 1; rel++; prog = 1; if (selfk[t] != "") M[selfk[t]] = 1 }
        }
      } while (prog)
      return rel
    }'
}

# The plan, rendered. Printed under --blocked (and carried whole in --json), because
# that is the view whose entire purpose is "what do I do about it". Named for what it
# RELEASES rather than for the obvious verb: `unblock` is a category word on this
# host, and test/status-categories.sh reads any non-comment line naming one as chief
# having quietly adopted a vocabulary.
render_release_plan() {
  local tbl rel casc holds dep cls key total plan rows hidden
  tbl="$(blocker_table)"
  [ -n "$tbl" ] || return 0
  rows="$(printf '%s' "$tbl" | grep -c .)"
  total="$(printf '%s' "$tbl" | LC_ALL=C awk -F"$TAB" '{ s += $1 } END { print s + 0 }')"
  plan="$(printf '%s'  "$tbl" | LC_ALL=C awk -F"$TAB" '$1 > 0 { c++ } END { print c + 0 }')"
  printf '\n  release   — merge these first; each row is what merging it starts\n'
  printf '      %-28s %8s %9s %6s  %s\n' edge releases cascade holds state
  printf '%s\n' "$tbl" | head -n "$CASCADE_CAP" | while IFS="$TAB" read -r rel casc holds dep cls key; do
    [ -n "$dep" ] || continue
    printf '      %-28s %8s %9s %6s  %s\n' "$dep" "$rel" "$casc" "$holds" "$cls"
  done
  if [ "$plan" -gt 0 ]; then
    printf '      %d merge(s) would release %d of the %d blocked tasklist(s) the moment they land\n' \
      "$plan" "$total" "$n_blocked"
  else
    printf '      no single merge releases anything on its own — every blocked tasklist waits on more than one edge\n'
  fi
  # The cap is the same one the cascade is computed under, and it is REPORTED: a
  # truncated table in a report about totals otherwise reads as the whole of it.
  hidden=$((rows - CASCADE_CAP))
  [ "$hidden" -gt 0 ] && \
    printf '      %d further edge(s) not shown, ranked below these (CHIEF_STATUS_CASCADE_CAP=%s; --json carries all %d)\n' \
      "$hidden" "$CASCADE_CAP" "$rows"
  return 0
}

# What the walk deliberately did NOT count. Printed in every render, including
# --blocked: a repo that is missing from a portfolio total for a good reason must
# say so, or "no work here" and "not looked at" become the same output.
render_scope_notes() {
  if [ -n "$WT_SKIPPED" ]; then
    printf '  worktrees   %4d    skipped: inside CHIEF_WORKTREE_ROOT (%s) — counting them would double every in-flight tasklist\n' \
      "$(count_of "$WT_SKIPPED")" "$WT_ROOT"
    list_names "$WT_SKIPPED"
  fi
  if [ -n "$EXCLUDED" ]; then
    printf '  excluded    %4d    listed in %s\n' "$(count_of "$EXCLUDED")" "$IGNORE_FILE"
    list_names "$EXCLUDED"
  fi
  if [ -n "$STALE" ]; then
    printf '  stale       %4d    in the registry (%s) but no longer a chief repo on disk\n' \
      "$(count_of "$STALE")" "$CHIEF_REPOS"
    list_names "$STALE"
  fi
}

# ── the category breakdown ───────────────────────────────────────────────────
# Rendered only when there is something to break down: a tasklist that carried a
# category, or a vocabulary declared to render against. An all-(uncategorized) table
# tells a project that does not use categories nothing it did not already know.
#
# ORDER is the whole subtlety. With a declared vocabulary: that order, every declared
# category shown even at zero, because the ordering is what is being made visible.
# Without one: count then name — STABLE, and pointedly not a claim. A category the
# vocabulary does not name is marked and kept; dropping it would silently delete work
# from a report whose purpose is that the numbers add up.
render_ordering() {
  local arrows unranked
  if [ -n "$VOCAB" ]; then
    arrows="$(printf '%s' "$VOCAB" | LC_ALL=C sed 's/ / › /g')"
    printf '      ordering  %s   — declared in %s\n' "$arrows" "$VOCAB_SRC"
    printf '                %d live tasklist(s) precede "%s", the last category\n' "$ORD_PRECEDE" "$ORD_LAST"
    unranked=$((n_live - ORD_PRECEDE - ORD_LAST_LIVE))
    [ "$unranked" -gt 0 ] && \
      printf '                %d live tasklist(s) carry a category the ordering does not name — unranked, not dropped\n' "$unranked"
  elif [ "$VOCAB_CONFLICT" != 0 ]; then
    printf '      ordering  none in force — the repos in scope declare %d different vocabularies\n' "$VOCAB_CONFLICT"
    printf '                rows are ordered by count; no ordering is claimed\n'
  else
    printf '      ordering  none declared — rows are ordered by count, not by any rule chief holds\n'
    printf '                a project declares its own with CHIEF_CATEGORIES in .chief/config\n'
  fi
  return 0
}

render_categories() {
  [ "$n_categorized" -gt 0 ] || [ -n "$VOCAB" ] || return 0
  local c rest known=""
  printf '\n  categories  %4d    tasklist(s) carry one; the value is theirs, and chief holds no vocabulary of its own\n' "$n_categorized"
  printf '      %-24s %6s %7s\n' category live parked
  if [ -n "$VOCAB" ]; then
    set -f                      # a category is an opaque string; never a glob
    for c in $VOCAB; do
      printf '      %-24s %6s %7s\n' "$c" "$(cat_cell "$COUNTS" "$c" 1)" "$(cat_cell "$COUNTS" "$c" 2)"
      known="$known$c
"
    done
    set +f
  fi
  # The membership test is done in SHELL, not by handing the vocabulary to awk in a
  # -v assignment: the list is newline-delimited and BSD awk rejects a newline inside
  # one ("awk: newline in string"), silently costing exactly the rows it selects.
  rest=""
  while IFS="$TAB" read -r c_live c_parked c; do
    [ -n "$c" ] || continue
    in_list "$c" "$known" && continue
    rest="$rest$((c_live + c_parked))$TAB$c_live$TAB$c_parked$TAB$c
"
  done <<EOF
$COUNTS
EOF
  rest="$(printf '%s' "$rest" | LC_ALL=C sort -t"$TAB" -k1,1nr -k4,4 | cut -f2-)"
  # printf with a trailing newline, not without: a command substitution strips the
  # final one, and `read` returns non-zero on an unterminated last line — which drops
  # exactly one category from the bottom of the table.
  printf '%s\n' "$rest" | while IFS="$TAB" read -r c_live c_parked c; do
    [ -n "$c" ] || continue
    if [ -n "$VOCAB" ]; then printf '      %-24s %6s %7s   *\n' "$c" "$c_live" "$c_parked"
    else                     printf '      %-24s %6s %7s\n'     "$c" "$c_live" "$c_parked"
    fi
  done
  [ -n "$VOCAB" ] && [ -n "$rest" ] && \
    printf '      * outside the declared vocabulary — reported, never dropped\n'
  render_ordering
}

# ── the machine feed ─────────────────────────────────────────────────────────
# ONE JSON document on stdout and nothing else, so `chief status --json | jq ...`
# works without a filter to strip a header off first — the discipline `chief events`
# already keeps. Every human-facing note (the scope notes, the --enforce-order
# verdict) goes to stderr instead of being dropped: a warning that only exists in
# the text render is a warning the machine consumer never sees.
#
# It is the SAME numbers, rendered a second way. Nothing below re-scans, re-counts or
# re-decides anything; it serializes the accumulators the text render prints. A JSON
# feed computed by its own pass would be a second implementation of the report, and
# would disagree with it on the day one of them changed.
#
# Built by jq from the raw accumulators rather than by printf, so the escaping is
# jq's problem and not this file's — a tasklist name or a dependency detail carrying
# a quote cannot produce a document the consumer cannot parse.
# Shape: docs/reference/status.md.
json_report() {
  jq -n \
    --arg version "$CHIEF_VERSION" \
    --arg mode "$MODE" --arg scope "$SCOPE_LINE" --arg base "$BASE" \
    --argjson depth "$DEPTH" --argjson multi "$MULTI" \
    --arg rows "$rows" --arg runnable "$runnable" --arg parkedl "$parked" \
    --arg unreadable "$unreadable" --arg blocked "$blocked" --arg edges "$edges" \
    --arg blockers "$(blocker_table)" --arg counts "$COUNTS" --arg problems "$problems" \
    --arg excluded "$EXCLUDED" --arg stale "$STALE" --arg wt "$WT_SKIPPED" \
    --arg vocab "$VOCAB" --arg vocabsrc "$VOCAB_SRC" --argjson vocabconflict "$VOCAB_CONFLICT" \
    --argjson ordprecede "$ORD_PRECEDE" --arg ordlast "$ORD_LAST" --argjson ordlastlive "${ORD_LAST_LIVE:-0}" \
    --argjson enforce "$ENFORCE_ORDER" --arg ordercheck "$1" \
    --argjson repos "$n_repos" --argjson remaining "$n_remaining" --argjson live "$n_live" \
    --argjson parkedn "$n_parked" --argjson runnablen "$n_runnable" --argjson blockedn "$n_blocked" \
    --argjson unreadablen "$n_unreadable" --argjson completed "$n_completed" \
    --argjson categorized "$n_categorized" \
    '
    def lines($s): $s | split("\n") | map(select(length > 0));
    def cols($s):  lines($s) | map(split("\t"));
    def num: if . == null or . == "" then 0 else tonumber end;
    {
      chief: $version,
      report: "chief status",
      scope: { mode: $mode, description: $scope, base: $base, depth: $depth,
               multi_repo: ($multi == 1), repos: $repos },
      totals: { repos: $repos, remaining: $remaining, live: $live, parked: $parkedn,
                runnable: $runnablen, blocked: $blockedn, unreadable: $unreadablen,
                completed: $completed },
      repos: (cols($rows) | map({ label: .[0], remaining: (.[1]|num), live: (.[2]|num),
                                  parked: (.[3]|num), runnable: (.[4]|num), blocked: (.[5]|num),
                                  completed: (.[6]|num), source: .[7], path: .[8] })),
      runnable: lines($runnable),
      parked:   lines($parkedl),
      unreadable: lines($unreadable),
      blocked: (cols($blocked) | map({ tasklist: .[0], blocked_by: .[1], class: .[2], detail: .[3] })),
      edges:   (cols($edges)   | map({ tasklist: .[0], record: .[1], dep: .[2],
                                       dep_record: .[3], class: .[4], detail: .[5] })),
      blockers: (cols($blockers) | map({ dep: .[3], dep_record: .[5], class: .[4],
                                         holds: (.[2]|num), releases: (.[0]|num),
                                         releases_with_cascade: (if (.[1]|num) < 0 then null else (.[1]|num) end) })),
      categories: {
        tasklists_with_category: $categorized,
        vocabulary: ($vocab | split(" ") | map(select(length > 0))),
        vocabulary_source: (if $vocabsrc == "" then null else $vocabsrc end),
        vocabulary_conflict: $vocabconflict,
        breakdown: (cols($counts) | map({ category: .[2], live: (.[0]|num), parked: (.[1]|num) })
                    | sort_by(-(.live + .parked), .category)),
        ordering: (if ($vocab | length) > 0
                   then { declared: true, last: $ordlast, live_preceding: $ordprecede,
                          live_in_last: $ordlastlive }
                   else { declared: false, last: null, live_preceding: null, live_in_last: null }
                   end)
      },
      problems: (cols($problems) | map({ tasklist: .[0], message: .[1] })),
      excluded: lines($excluded),
      stale:    lines($stale),
      worktrees_skipped: lines($wt),
      order_check: { enforced: ($enforce == 1), result: $ordercheck }
    }'
}

# --enforce-order — the only thing in this file that can produce a non-zero exit, and
# it enforces the PROJECT'S rule, not one of chief's: work in the last declared
# category while work in earlier ones remains. With no vocabulary in scope there is
# nothing to enforce, which is said out loud on stderr rather than passing quietly.
ORDER_RC=0
ORDER_RESULT=not-enforced     # ...and the same verdict as a token, for --json
order_check() {
  [ "$ENFORCE_ORDER" = 1 ] || return 0
  if [ -z "$VOCAB" ]; then
    if [ "$VOCAB_CONFLICT" != 0 ]; then
      ORDER_RESULT=conflict
      echo "chief status --enforce-order: the repos in scope declare $VOCAB_CONFLICT different category vocabularies — there is no single ordering to enforce." >&2
    else
      ORDER_RESULT=no-vocabulary
      echo "chief status --enforce-order: no category vocabulary is declared in scope (CHIEF_CATEGORIES in .chief/config) — there is no ordering to enforce." >&2
    fi
    return 0
  fi
  if [ "$ORD_LAST_LIVE" -gt 0 ] && [ "$ORD_PRECEDE" -gt 0 ]; then
    printf '\n  order check FAIL — %d live tasklist(s) in earlier categories precede the %d in "%s", the last category in the declared ordering\n' \
      "$ORD_PRECEDE" "$ORD_LAST_LIVE" "$ORD_LAST"
    ORDER_RESULT=fail; ORDER_RC=1
  elif [ "$ORD_LAST_LIVE" = 0 ]; then
    ORDER_RESULT=pass
    printf '\n  order check PASS — no live work in "%s", the last category in the declared ordering\n' "$ORD_LAST"
  else
    ORDER_RESULT=pass
    printf '\n  order check PASS — nothing precedes "%s", the last category in the declared ordering\n' "$ORD_LAST"
  fi
  return 0
}

# Every render path leaves through here, so the enforcement verdict is printed once
# and the exit status is decided in exactly one place. Under --json the verdict is a
# FIELD of the document and its prose goes to stderr, so stdout stays parseable — the
# exit status is the same either way, since it is the report's answer and not its
# rendering.
finish() {
  if [ "$JSON" = 1 ]; then
    order_check >&2
    json_report "$ORDER_RESULT"
    exit "$ORDER_RC"
  fi
  order_check
  exit "$ORDER_RC"
}

render_problems() {
  [ -n "$problems" ] || return 0
  printf '\n  problems    %4d\n' "$(count_of "$problems")"
  printf '%s' "$problems" | while IFS='	' read -r n msg; do
    [ -n "$n" ] && printf '      ✗ %-26s %s\n' "$n" "$msg"
  done
}

if [ "$MULTI" = 1 ]; then
  header="portfolio — $n_repos repo(s)"
else
  header="$(printf '%s' "$REPOS" | cut -f1 | head -1)"
fi

# --json leaves HERE, before any human render: every note the text report would have
# printed goes to stderr, and stdout carries the document and nothing else. Placed
# after the totals and before the first printf, so the two renders cannot disagree.
if [ "$JSON" = 1 ]; then
  { render_scope_notes; render_problems; } >&2
  finish
fi

if [ "$BLOCKED_ONLY" = 1 ]; then
  printf 'chief status --blocked — %s (scope: %s)\n\n' "$header" "$SCOPE_LINE"
  if [ "$n_repos" = 0 ]; then
    echo "  no chief-initialized repo in scope."
  elif [ "$n_blocked" = 0 ]; then
    echo "  nothing is blocked — all $n_runnable live tasklist(s) can start now."
  else
    printf '  blocked  %d of %d live\n' "$n_blocked" "$n_live"
    render_blocked
    render_release_plan
  fi
  render_scope_notes
  finish
fi

printf 'chief status — %s (scope: %s)\n\n' "$header" "$SCOPE_LINE"

if [ "$n_repos" = 0 ]; then
  case "$MODE" in
    registry) echo "  the known-repos registry is empty — run 'chief init' or 'chief run' in a repo once to register it." ;;
    *)        echo "  no chief-initialized repo at, above or beneath $BASE (depth $DEPTH)."
              echo "  Run it inside a repo that has been through 'chief init', or from a directory above several." ;;
  esac
  render_scope_notes
  finish
fi

if [ "$MULTI" = 1 ]; then
  # The per-repo table: one row per repo, then the portfolio totals it sums to.
  # The `source` column is the reconciliation, made visible: `walk` was found on disk
  # beneath the base, `registry` is a known repo the walk did not reach (pruned, or
  # deeper than CHIEF_STATUS_DEPTH), `both` is one repo the two agreed on — counted
  # once, because the union was taken over RESOLVED ABSOLUTE PATHS.
  printf '  %-32s %9s %5s %6s %8s %7s %9s  %s\n' repo remaining live parked runnable blocked completed source
  printf '%s' "$rows" | while IFS='	' read -r l rem lv pk rn bl cp sc _path; do
    [ -n "$l" ] && printf '  %-32s %9s %5s %6s %8s %7s %9s  %s\n' "$l" "$rem" "$lv" "$pk" "$rn" "$bl" "$cp" "$sc"
  done
  printf '  %-32s %9s %5s %6s %8s %7s %9s\n' '' --------- ----- ------ -------- ------- ---------
  printf '  %-32s %9d %5d %6d %8d %7d %9d\n' TOTAL "$n_remaining" "$n_live" "$n_parked" "$n_runnable" "$n_blocked" "$n_completed"
  printf '\n'
  if [ "$n_unreadable" -gt 0 ]; then
    printf '  unreadable  %4d    counted as remaining; no verdict possible\n' "$n_unreadable"
    list_names "$unreadable"
  fi
  render_categories
  render_scope_notes
  render_problems
  finish
fi

printf '  remaining   %4d    live %d · parked %d\n' "$n_remaining" "$n_live" "$n_parked"
printf '    runnable  %4d\n' "$n_runnable"
list_names "$runnable"
printf '    blocked   %4d\n' "$n_blocked"
render_blocked
if [ "$n_unreadable" -gt 0 ]; then
  printf '    unreadable %3d    counted as remaining; no verdict possible\n' "$n_unreadable"
  list_names "$unreadable"
fi
if [ "$n_parked" -gt 0 ]; then
  printf '  parked      %4d    never scheduled until the flag is dropped\n' "$n_parked"
  list_names "$parked"
fi
printf '  completed   %4d    history, not backlog (%s/completed)\n' "$n_completed" "$TASKS_REL"
render_categories
render_scope_notes
render_problems
finish
