#!/usr/bin/env bash
# test/activity-line.sh — the ACTIVITY LINE of a running row says something, or it
# says nothing.
#
# MEASURED 2026-09-15, on a live run: a tasklist sat at `provider-waiting for 16m`
# and the dim third line of its row — the one an operator actually scans — read
# ``` for seventeen minutes. The old rule (`NF && !/^#/ && !/^---/`, monitor.sh)
# skipped blanks, headings and the seed rule and nothing else, and a progress note
# is MARKDOWN: the agent's last write was a fenced block, the closing fence is
# non-empty, so the fence won. A line that renders a fence is strictly worse than
# no line at all — it spends the row's one line and carries no information.
#
# So this file asserts on SHAPE, in both directions, because a filter that is merely
# stricter is as broken as the one it replaces: ordinary prose must still render,
# and a file with nothing informative in it must render NOTHING rather than reach
# further back for a fence it skipped.
#
# REPRODUCES FIRST. PART A runs the OLD rule over the same fixture and pins that it
# picks the fence, so the fixture is proven to discriminate — otherwise every
# assertion below could be restating behaviour that always worked.
#
# Two levels, because a helper's return value and a row's rendered line are
# different claims: PART B calls activity_of directly (whole-string equality), PART
# C drives `monitor.sh once` against a synthetic run registry and asserts the WHOLE
# rendered row line. No driver, no agent, no git — fast, and with none of the timing
# sensitivity that keeps test/monitor.sh out of the merge gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; . "$ROOT/test/lib.sh"
WORK="$(mktemp -d)"
holder=""
cleanup() {
  if [ -n "$holder" ]; then kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap 'rc=$?; cleanup; exit "$rc"' EXIT
note() { printf '  %s\n' "$*"; }
fail() { echo "ACTIVITY FAIL: $*" >&2; exit 1; }

# The renderer, as the row reaches it: sourced in `lib` mode so nothing is drawn.
# shellcheck source=/dev/null
. "$ROOT/engine/monitor.sh" lib || fail "could not source engine/monitor.sh lib"
command -v activity_of >/dev/null || fail "engine/monitor.sh lib does not define activity_of"

# Whole-line equality, never a substring: a fragment like `test/monitor.sh` is
# emitted by half a dozen other surfaces and would pass against the wrong line.
eq() { # $1 = label, $2 = expected, $3 = actual
  [ "$2" = "$3" ] && { note "ok   $1"; return 0; }
  printf 'ACTIVITY FAIL: %s\n  expected [%s]\n  actual   [%s]\n' "$1" "$2" "$3" >&2; exit 1
}

# ── PART A · the incident's own file, and proof the fixture discriminates ─────
# A note in the style of a real one: seed header, rule, heading, blank lines, a
# fenced block with a command in it, and the trailing fence that won last time.
REAL="$WORK/real.txt"
cat > "$REAL" <<'EOF'
# Chief Progress — 126-a-row-says-what-the-agent-is-doing
Started: Tue Sep 15 22:04:11 CDT 2026
---

## Iteration 1 — US-1

Rewrote `activity_of` in **engine/monitor.sh** so the row picks a line by shape.

Ran:

```bash
bash test/monitor.sh
```
EOF

old="$(awk 'NF && $0 !~ /^#/ && $0 !~ /^---/ {last=$0} END{if(last)print last}' "$REAL" | cut -c1-76)"
eq "PART A · the OLD rule picks the fence (the fixture discriminates)" '```' "$old"

eq "PART A · the new rule picks the command inside the block" \
   'bash test/monitor.sh' "$(activity_of "$REAL")"

# ── PART B · shape, in both directions ───────────────────────────────────────
# B1 — ordinary prose renders, with the markdown markers off and `_` LEFT ALONE.
# Stripping `_` as an emphasis marker would render `live_set` as `liveset`, and
# this codebase's prose is almost entirely snake_case identifiers.
cat > "$WORK/prose.txt" <<'EOF'
## Iteration 4
- Wired `live_set` into **_beat_start** — the observer  publishes the tool name.
EOF
eq "PART B1 · prose renders, markers stripped, whitespace collapsed, _ intact" \
   'Wired live_set into _beat_start — the observer publishes the tool name.' \
   "$(activity_of "$WORK/prose.txt")"

# B2 — a file with nothing informative in it renders NOTHING. Every uninformative
# shape the row can meet is here at once: both fence styles, a bare heading marker,
# three flavours of horizontal rule, a whitespace-only line, pure punctuation.
printf '%s\n' '# Chief Progress' '---' '' '```' '' '```' '~~~' '***' '___' '   ' '...' '   ###   ' \
  > "$WORK/empty.txt"
eq "PART B2 · a file of pure structure renders nothing at all" '' "$(activity_of "$WORK/empty.txt")"

# B3 — a missing file is silent, as it was before (a worktree without a note yet).
eq "PART B3 · no file, no line" '' "$(activity_of "$WORK/does-not-exist.txt")"

# B4 — truncation is VISIBLE. 76 columns is the row's budget; the cut backs off to
# a word boundary, which is also what keeps a byte-wise cut out of the middle of a
# multi-byte character (LC_ALL=C makes substr() count bytes, and the agent's prose
# is full of em-dashes).
printf '%s\n' \
  'aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk llll mmmm nnnn oo — pp qq' \
  > "$WORK/long.txt"
long="$(activity_of "$WORK/long.txt")"
eq "PART B4 · truncated at a word boundary, with the cut visible" \
   'aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk llll mmmm nnnn oo…' "$long"
case "$long" in *$'\n'*) fail "PART B4 · the activity line is not one line" ;; esac
# …and the em-dash did not get sawn in half on the way out.
printf '%s' "$long" | LC_ALL=en_US.UTF-8 grep -q '[^ -~…]' && fail "PART B4 · truncation split a character"

# B5 — a line that is only ALMOST a rule is prose, and renders. `--- the base moved`
# would have been skipped by the old `/^---/` rule, which matched a prefix.
printf '%s\n' '--- the base moved under us, so the rebase replayed 3 commits' > "$WORK/near.txt"
eq "PART B5 · a rule marker with text after it is prose" \
   '--- the base moved under us, so the rebase replayed 3 commits' \
   "$(activity_of "$WORK/near.txt")"

# ── PART C · the ROW, rendered ───────────────────────────────────────────────
# A helper's return value is not a rendered line. This is `chief ps` (monitor.sh
# once) over a synthetic registry, exactly as test/limitmonitor.sh stages one.
STATE="$WORK/state"; PAR="$STATE/parallel"; RUNS="$WORK/runs"; WT="$WORK/wt"
mkdir -p "$PAR" "$RUNS" "$WORK/repo" "$WORK/tasks" "$WT"
sleep 60 & holder=$!                       # a live pid: the monitor prunes dead run files

echo running > "$PAR/act-real.state"
echo running > "$PAR/act-blank.state"
mkdir -p "$WT/act-real/.chief/state" "$WT/act-blank/.chief/state"
cp "$REAL" "$WT/act-real/.chief/state/progress.txt"
cp "$WORK/empty.txt" "$WT/act-blank/.chief/state/progress.txt"

cat > "$RUNS/$holder.run" <<EOF
pid=$holder
repo=$WORK/repo
base=main
parallel=2
tool=claude
automerge=1
started=$(date +%s)
state=$STATE
staterel=.chief/state
tasks=$WORK/tasks
wt=$WT
names=act-real act-blank
EOF

out="$(CHIEF_RUNS="$RUNS" bash "$ROOT/engine/monitor.sh" once)" || fail "monitor.sh once exited non-zero"
printf -- '--- chief ps (synthetic running run) ---\n%s\n' "$out"

# SCOPED to this run's own section. monitor.sh also reports UNREGISTERED drivers it
# finds in the host's process table — a real run on the developer's machine lands in
# the same capture (test/bystander.sh's lesson: hermetic in state is not hermetic in
# processes), and a negative assertion read over the whole view would be answering
# for somebody else's rows.
mine="$(printf '%s\n' "$out" | awk -v pid="$holder" '$0 ~ ("\\(pid " pid " ") {on=1} on && /^⚠/ {on=0} on')"
[ -n "$mine" ] || fail "PART C · this run's section is missing from the view entirely"

# The whole line, prefix included — this is what the operator sees.
printf '%s\n' "$mine" | grep -qxF '       ↳ bash test/monitor.sh' \
  || fail "PART C · the row's activity line is not the chosen line (see the dump above)"
# …and no row in it renders a fence, which is the incident.
printf '%s\n' "$mine" | grep -qE '↳[[:space:]]*(```|~~~)' \
  && fail "PART C · a row still renders a bare fence"
# The all-structure tasklist is PRESENT as a row and simply has no activity line —
# `act-blank` must not have been dropped, or "no fence" would be true for free.
printf '%s\n' "$mine" | grep -q 'act-blank' || fail "PART C · act-blank lost its row entirely"
[ "$(printf '%s\n' "$mine" | grep -c '↳')" = 1 ] \
  || fail "PART C · expected exactly one activity line across the two rows"

echo "ACTIVITY OK — the row says something or says nothing (A: reproduce · B: shape · C: rendered)"
