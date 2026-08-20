#!/usr/bin/env bash
# test/status-json.sh — the MACHINE FEED and the view that names what to merge next.
#
# Two claims, and they are different in kind.
#
# 1. `--json` is a SINGLE JSON DOCUMENT ON STDOUT AND NOTHING ELSE. Every note the
#    text report would have printed — the scope notes, the problems, the
#    --enforce-order verdict — goes to stderr, so `chief status --json | jq` works
#    with no filter to strip a header first. The test asserts that against a fixture
#    that HAS notes to print, because a report with nothing to warn about would pass
#    this trivially. And it asserts the document carries the SAME NUMBERS as the text
#    render, since two renderings that can disagree are two reports.
#
# 2. `--blocked` aggregates the other way round. "4 blocked" is a number; "merge this
#    one and 2 start, 3 with the cascade" is a plan. The fixture is built so the three
#    counts are all DIFFERENT for the same edge — holds 3, releases 2, cascade 3 — so
#    a report that conflated any two of them fails here rather than reading plausibly.
#
# ...and `chief list` is unchanged, byte for byte, because it is a different tool and
# habits depend on its output.
#
# Hermetic: a scaffolded repo in a temp dir, its own CHIEF_RUNS/CHIEF_REPOS, no agent.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=status GIT_AUTHOR_EMAIL=status@test \
       GIT_COMMITTER_NAME=status GIT_COMMITTER_EMAIL=status@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"   # hermetic: never touch ~/.chief
CHIEF="$ROOT/bin/chief"
fail() { echo "JSON FAIL: $*" >&2; exit 1; }
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

command -v jq >/dev/null || fail "jq is required"

REPO="$WORK/alpha"
mkdir -p "$REPO"; ( cd "$REPO"
  git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
  git commit -q --allow-empty -m init
  "$CHIEF" init >/dev/null 2>&1 || exit 1
  rm -f tasks/chief/example.json ) || fail "scaffold failed"
: > "$CHIEF_REPOS"

tasklist() {   # $1 = name, $2 = extra JSON object, $3… = dependsOn entries
  local name="$1" extra="$2"; shift 2
  local deps; deps="$(printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(length>0))')"
  jq -n --arg n "$name" --argjson d "$deps" --argjson x "$extra" \
    '{project:"t",branchName:("chief/"+$n),description:"x",iters:1,dependsOn:$d,touches:[],warmup:[],
      userStories:[{id:"US-1",title:"t",description:"",acceptanceCriteria:["x"],passes:false,notes:""}]} + $x' \
    > "$REPO/tasks/chief/$name.json" || fail "could not write tasklist $name"
}
record() { jq -n --argjson x "$2" '$x' > "$REPO/tasks/chief/completed/$1.json"; }

mkdir -p "$REPO/tasks/chief/completed"
record 05-merged    '{"mergedToMain":"deadbee"}'
record 06-unstamped '{"note":"retired but never stamped"}'    # the retirement trap

# THE SHAPE THAT SEPARATES THE THREE COUNTS. 10-root is named by three blocked
# tasklists (holds 3); merging it starts two of them immediately (releases 2) because
# 13-c also waits on 11-a; and when 11-a is then worked and merged, 13-c starts too
# (cascade 3). Any report that reported one of those numbers as another is wrong here.
tasklist 10-root   '{"category":"feature"}'
tasklist 11-a      '{"category":"feature"}' 10-root
tasklist 12-b      '{"category":"fix"}'     10-root
tasklist 13-c      '{"category":"fix"}'     10-root 11-a
tasklist 14-trap   '{"category":"feature"}' 06-unstamped        # blocked FOREVER
tasklist 15-parked '{"parked":true,"category":"fix"}'
printf 'this is not json {{{\n' > "$REPO/tasks/chief/16-broken.json"   # notes to print

status() { ( cd "$REPO" && "$CHIEF" status "$@" ); }

# ── 1. stdout is DATA ────────────────────────────────────────────────────────
OUT="$WORK/out.json"; ERR="$WORK/out.err"
status --json > "$OUT" 2> "$ERR"; RC=$?
[ "$RC" = 0 ] || fail "chief status --json exited $RC"
jq -e . "$OUT" >/dev/null 2>&1 \
  || fail "stdout is not a single parseable JSON document:\n$(head -5 "$OUT")"
[ "$(head -c 1 "$OUT")" = "{" ] || fail "stdout does not begin with the document — a header leaked onto it"
# ...and the fixture DID have something to say, on the other stream.
[ -s "$ERR" ] || fail "nothing on stderr, yet the fixture has an unreadable tasklist to report"
has "16-broken" "$(cat "$ERR")" || fail "the unreadable tasklist was not reported on stderr:\n$(cat "$ERR")"

# ── 2. the document says what the text render says ───────────────────────────
TXT="$(status 2>&1)"
jnum() { jq -r "$1" "$OUT"; }
tnum() { printf '%s\n' "$TXT" | LC_ALL=C awk -v k="$1" '$1 == k { print $2; exit }'; }
for pair in "remaining .totals.remaining" "runnable .totals.runnable" "blocked .totals.blocked" \
            "completed .totals.completed" "parked .totals.parked"; do
  k="${pair%% *}"; path="${pair#* }"
  t="$(tnum "$k")"; j="$(jnum "$path")"
  [ -n "$t" ] || continue
  [ "$t" = "$j" ] || fail "the two renders disagree on $k: text says '$t', --json says '$j'"
done
# The arithmetic of the fixture itself, pinned: 6 live (one of them unreadable and so
# without a verdict), 1 parked, 1 runnable, 4 blocked, 2 completed records.
[ "$(jnum '.totals.live')"       = 6 ] || fail "live: $(jnum '.totals.live') (expected 6)"
[ "$(jnum '.totals.parked')"     = 1 ] || fail "parked: $(jnum '.totals.parked')"
[ "$(jnum '.totals.runnable')"   = 1 ] || fail "runnable: $(jnum '.totals.runnable')"
[ "$(jnum '.totals.blocked')"    = 4 ] || fail "blocked: $(jnum '.totals.blocked')"
[ "$(jnum '.totals.unreadable')" = 1 ] || fail "unreadable: $(jnum '.totals.unreadable')"
[ "$(jnum '.totals.completed')"  = 2 ] || fail "completed: $(jnum '.totals.completed')"

# ── 3. the documented shape is actually there ────────────────────────────────
# Per-repo rows, the category breakdown live/parked apart, the blocked edges, and the
# problems — the four things docs/reference/status.md promises a consumer.
[ "$(jnum '.repos | length')" = 1 ] || fail "no per-repo row in the document"
[ "$(jnum '.repos[0].blocked')" = 4 ] || fail "the per-repo row does not carry the same blocked count"
[ "$(jnum '.categories.breakdown | map(select(.category == "fix")) | .[0].live')"   = 2 ] \
  || fail "category fix is 2 live (12-b, 13-c), report says $(jnum '.categories.breakdown | map(select(.category == "fix")) | .[0].live')"
[ "$(jnum '.categories.breakdown | map(select(.category == "fix")) | .[0].parked')" = 1 ] \
  || fail "category fix should be 1 parked (15-parked)"
[ "$(jnum '.problems | length')" -ge 1 ] || fail "problems section empty despite an unreadable tasklist"
[ "$(jnum '.order_check.enforced')" = false ] || fail "order_check claims enforcement nobody asked for"
# The retirement trap survives into the feed AS a permanent stall, not as waiting.
[ "$(jnum '.edges | map(select(.tasklist == "14-trap")) | .[0].class')" = retired ] \
  || fail "the trap edge is not classed 'retired' in the document"

# ── 4. THE AGGREGATION — holds, releases, cascade are three numbers ──────────
[ "$(jnum '.blockers[0].dep')" = 10-root ] \
  || fail "blockers are not ranked highest-release first (top is $(jnum '.blockers[0].dep'))"
b() { jnum ".blockers | map(select(.dep == \"10-root\")) | .[0].$1"; }
[ "$(b holds)"    = 3 ] || fail "10-root is named by 3 blocked tasklists, report says $(b holds)"
[ "$(b releases)" = 2 ] || fail "merging 10-root starts 2 immediately (13-c also waits on 11-a), report says $(b releases)"
[ "$(b releases_with_cascade)" = 3 ] || fail "with the cascade it starts 3, report says $(b releases_with_cascade)"
# A blocker that releases nothing on its own is still reported, with its own numbers.
[ "$(jnum '.blockers | map(select(.dep == "06-unstamped")) | .[0].releases')" = 1 ] \
  || fail "the trap edge is missing from the aggregation"

BLK="$(status --blocked 2>&1)"
has "release" "$BLK"        || fail "--blocked prints no release plan:\n$BLK"
has "PERMANENTLY BLOCKED" "$BLK" || fail "--blocked stopped naming the retirement trap:\n$BLK"
# Highest first, in the text too: 10-root's row precedes every other edge's.
plan_order="$(printf '%s\n' "$BLK" | LC_ALL=C awk '/^ *release /{p=1;next} p && /^ {6}[0-9]/{print $1}')"
[ "$(printf '%s\n' "$plan_order" | head -1)" = "10-root" ] \
  || fail "the release plan is not ranked highest first:\n$plan_order"

# ── 5. `chief list` is a different tool, and it is untouched ─────────────────
LIST="$( cd "$REPO" && "$CHIEF" list 2>&1 )"; LRC=$?
[ "$LRC" = 0 ] || fail "chief list exited $LRC"
IFS= read -r -d '' EXPECT <<'EOF'
   0/1   10-root
   0/1   11-a
   0/1   12-b
   0/1   13-c
   0/1   14-trap
   0/1   15-parked  (parked)
   ?/?   16-broken
  done     05-merged
  done     06-unstamped
EOF
EXPECT="${EXPECT%$'\n'}"      # `read -d ''` keeps the heredoc's final newline; $( ) drops it
[ "$LIST" = "$EXPECT" ] || fail "chief list output changed — it is a different tool and scripts depend on it:
--- got ---
$LIST
--- expected ---
$EXPECT"
# ...and it is emphatically NOT the aggregate report.
has "remaining" "$LIST" && fail "chief list has grown totals — that is chief status's job"

echo "JSON PASS — one document on stdout, notes on stderr, the same numbers as the text render, and holds/releases/cascade kept apart"
