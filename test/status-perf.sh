#!/usr/bin/env bash
# test/status-perf.sh — the whole-portfolio report is cheap enough to run casually.
#
# THE REGRESSION THIS GUARDS is a fork per record. `chief list` runs jq once per
# tasklist, which is fine for one repo's listing and does not survive a portfolio:
# this host's tree is ~1,000 records across 16 repos, and at a process apiece the
# report costs more than the question is worth and stops being asked. `chief status`
# therefore reads each DIRECTORY in one jq (engine/status.sh's read_records, and the
# completed/ index behind crossrepo.sh's is_recorded_done) and resolves edges without
# a subshell per edge.
#
# ASSERTED TWO WAYS, because only one of them is trustworthy on a loaded machine:
#
#   forks   the number of jq invocations, counted exactly by a wrapper on PATH. This
#           is deterministic and it is the thing that actually regresses — a
#           per-record jq would blow the bound by an order of magnitude, whatever the
#           machine is doing at the time.
#   clock   wall time under CHIEF_STATUS_BUDGET (default 5s), the story's number.
#
# NOT in the merge gate, and in test/all.sh + CI only — the clock half is
# timing-sensitive under the parallel bystander block, which is exactly why
# test/monitor.sh is out of that gate too. The fork bound is what makes the file
# worth running anywhere.
#
# Hermetic: generated fixture in a temp dir, its own CHIEF_RUNS/CHIEF_REPOS.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"   # hermetic: never touch ~/.chief
: > "$CHIEF_REPOS"
CHIEF="$ROOT/bin/chief"
fail() { echo "PERF FAIL: $*" >&2; exit 1; }

command -v jq >/dev/null || fail "jq is required"
REAL_JQ="$(command -v jq)"

REPOS=16 LIVE=40 DONE=25
BUDGET="${CHIEF_STATUS_BUDGET:-5}"
# One jq for the live records, one for the completed index, and headroom for the
# handful the render itself uses. A per-record read lands near LIVE + DONE per repo
# — 65x this — so the bound does not need to be tight to be decisive.
FORK_BUDGET=$(( REPOS * 4 + 12 ))

DEV="$WORK/dev"
mkdir -p "$DEV"
i=1
while [ "$i" -le "$REPOS" ]; do
  d="$DEV/repo$i"
  mkdir -p "$d/.chief" "$d/tasks/chief/completed"
  printf 'CHIEF_TASKS_DIR=tasks/chief\n' > "$d/.chief/config"
  j=1
  while [ "$j" -le "$DONE" ]; do
    printf '{"mergedToMain":"deadbee%s"}\n' "$j" > "$d/tasks/chief/completed/$(printf '%03d' "$j")-done.json"
    j=$((j + 1))
  done
  j=1
  while [ "$j" -le "$LIVE" ]; do
    # A chain per repo: every tasklist waits on the one before it, and the first waits
    # on a record that HAS merged. So exactly one tasklist per repo is runnable, and
    # every other edge is a real unsatisfied one the report must classify.
    if [ "$j" = 1 ]; then dep="001-done"; else dep="$(printf '%03d' $((j - 1)))-live"; fi
    printf '{"project":"p%s","category":"feature","branchName":"chief/x","description":"d","iters":1,"dependsOn":["%s"],"touches":[],"warmup":[],"userStories":[]}\n' \
      "$i" "$dep" > "$d/tasks/chief/$(printf '%03d' "$j")-live.json"
    j=$((j + 1))
  done
  i=$((i + 1))
done
RECORDS="$(find "$DEV" -name '*.json' | grep -c .)"
[ "$RECORDS" = "$(( REPOS * (LIVE + DONE) ))" ] || fail "fixture generated $RECORDS records"

# The jq counter: a wrapper that appends a byte per invocation and execs the real one.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/jq" <<EOF
#!/usr/bin/env bash
printf 'x' >> "$WORK/jq.count"
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$WORK/bin/jq"

measure() {   # $1 = output file, $2… = chief status flags -> ELAPSED / FORKS
  local out="$1"; shift
  : > "$WORK/jq.count"
  local t0=$SECONDS
  ( cd "$DEV" && PATH="$WORK/bin:$PATH" "$CHIEF" status "$@" ) > "$out" 2>"$WORK/err"
  RC=$?
  ELAPSED=$((SECONDS - t0))
  FORKS="$(wc -c < "$WORK/jq.count" | tr -d ' ')"
}

measure "$WORK/report.txt"
[ "$RC" = 0 ] || fail "chief status exited $RC over $RECORDS records:\n$(head -5 "$WORK/err")"

# The report is CORRECT at this scale, not merely fast: one runnable per repo, every
# other live tasklist blocked, and the completed records counted as history apart.
tot() { LC_ALL=C awk '$1 == "TOTAL" { print $'"$1"'; exit }' "$WORK/report.txt"; }
[ "$(tot 2)" = "$(( REPOS * LIVE ))" ]  || fail "remaining is $(tot 2), expected $(( REPOS * LIVE ))"
[ "$(tot 5)" = "$REPOS" ]               || fail "runnable is $(tot 5), expected $REPOS (one per chain)"
[ "$(tot 6)" = "$(( REPOS * (LIVE - 1) ))" ] || fail "blocked is $(tot 6), expected $(( REPOS * (LIVE - 1) ))"
[ "$(tot 7)" = "$(( REPOS * DONE ))" ]  || fail "completed is $(tot 7), expected $(( REPOS * DONE ))"

[ "$FORKS" -le "$FORK_BUDGET" ] \
  || fail "$FORKS jq invocations for $RECORDS records (budget $FORK_BUDGET) — the report is forking per record again"
FORKS_TEXT="$FORKS"; ELAPSED_TEXT="$ELAPSED"

# --json reads the same scan; it must not double the cost by scanning twice.
measure "$WORK/report.json" --json
[ "$RC" = 0 ] || fail "chief status --json exited $RC"
"$REAL_JQ" -e . "$WORK/report.json" >/dev/null 2>&1 || fail "--json did not emit a parseable document at scale"
[ "$FORKS" -le "$FORK_BUDGET" ] \
  || fail "--json used $FORKS jq invocations (budget $FORK_BUDGET) — it is re-scanning rather than serializing"

[ "$ELAPSED_TEXT" -le "$BUDGET" ] \
  || fail "the text report took ${ELAPSED_TEXT}s over $RECORDS records in $REPOS repos (budget ${BUDGET}s)"
[ "$ELAPSED" -le "$BUDGET" ] \
  || fail "--json took ${ELAPSED}s over $RECORDS records in $REPOS repos (budget ${BUDGET}s)"

echo "PERF PASS — $RECORDS records in $REPOS repos: ${ELAPSED_TEXT}s / $FORKS_TEXT jq invocations (budget ${BUDGET}s / $FORK_BUDGET), --json ${ELAPSED}s / $FORKS"
