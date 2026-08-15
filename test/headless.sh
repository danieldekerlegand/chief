#!/usr/bin/env bash
# test/headless.sh — pin the HEADLESS EMBEDDING CONTRACT (docs/guides/headless-invocation.md).
#
# A host app embedding chief drives it non-interactively and reads the outcome from
# the exit code + the machine-readable summary — never by scraping the human block.
# That is a promise, so it is asserted here rather than left to inspection:
#
#   · `chief run --headless` announces `chief: run-id=<id>` before the loop, and the
#     id is the one recorded in the run's registry entry.
#   · the exit code names the outcome: 0 merged · 3 nothing runnable · 4 verify-failed
#     (the rest of the table is the same mechanism — see the doc).
#   · `chief: summary=<json>` is one line of VALID JSON carrying the run id and every
#     requested tasklist with its terminal state.
#   · a NON-headless run is byte-identical to what it always was: zero `chief: ` lines
#     and its historical exit code.
#
# Hermetic: a scripted fake `claude` on PATH, temp prefixes ($CHIEF_PREFIX included,
# so worktrees land in the temp dir), never touches the real ~/.chief. Drives
# bin/chief straight out of this checkout, so it tests uncommitted work.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=hl GIT_AUTHOR_EMAIL=hl@test GIT_COMMITTER_NAME=hl GIT_COMMITTER_EMAIL=hl@test
export CHIEF_PREFIX="$WORK/ch" CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
# One attempt per tasklist: the retry budget would re-run a VERIFY-FAILED tasklist
# three times for the same terminal state, and this test is about the state, not the
# budget (test/retry-on-failure.sh owns that).
export RETRY_MAX=1
CHIEF="$ROOT/bin/chief"
LOG=""
fail() { echo "HEADLESS FAIL: $*" >&2; [ -n "$LOG" ] && [ -f "$LOG" ] && tail -60 "$LOG" >&2; exit 1; }
command -v jq  >/dev/null || fail "jq required"
command -v git >/dev/null || fail "git required"

# ── the fake agent: one story per call, commit included, promise when done ────
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null
PRD=".chief/state/prd.json"                       # cwd = the worktree
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"; TRACKED="tasks/chief/$name.json"
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  mkdir -p out; echo "impl $id" > "out/$id.txt"
  for f in "$PRD" "$TRACKED"; do
    [ -f "$f" ] || continue
    t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id).passes)=true' "$f" > "$t" && mv "$t" "$f"
  done
  git add -A >/dev/null 2>&1 || true; git commit -q -m "feat: $id - scripted" >/dev/null 2>&1 || true
fi
[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── scaffold a repo with ONE one-story tasklist and a verify hook we can flip ──
REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null || fail "chief init failed"
rm -f tasks/chief/example.json
cat > tasks/chief/hl.json <<'JSON'
{ "project":"hl","branchName":"chief/hl","description":"headless contract",
  "iters":2,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":["out/US-1.txt"],"passes":false,"notes":""}] }
JSON
printf '#!/usr/bin/env bash\nset -eu\nexit "${HL_VERIFY_RC:-0}"\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "hl setup"

run_headless() {   # $1 = log file; rest = args. Echoes the exit code, never fails.
  local log="$1"; shift
  local rc=0
  PATH="$WORK/fakebin:$PATH" "$CHIEF" run --headless "$@" >"$log" 2>&1 || rc=$?
  printf '%s' "$rc"
}
summary_of() { sed -n 's/^chief: summary=//p' "$1" | tail -1; }

# ── 1. MERGED run → exit 0, a parseable run-id, a valid JSON summary ──────────
LOG="$WORK/merged.log"
rc="$(run_headless "$LOG")"
[ "$rc" = "0" ] || fail "merged run exited $rc, expected 0"

run_id="$(sed -n 's/^chief: run-id=//p' "$LOG" | head -1)"
[ -n "$run_id" ] || fail "no 'chief: run-id=' line on stdout"
run_file="$(sed -n 's/^chief: run-file=//p' "$LOG" | head -1)"
[ -n "$run_file" ] || fail "no 'chief: run-file=' line on stdout"
# The announced id must point AT that registry entry — the correlation IS the
# contract. The run file itself is removed at teardown (it exists only while the run
# is live, for `chief ps`), so what is asserted here is the durable half: the entry
# is $CHIEF_RUNS/<pid>.run and the id's trailing field is that same pid.
[ "$(dirname "$run_file")" = "$WORK/runs" ] || fail "run-file '$run_file' is not in \$CHIEF_RUNS"
[ "$(basename "$run_file" .run)" = "${run_id##*-}" ] || fail "run-file '$run_file' does not match run-id '$run_id'"
state_dir="$(sed -n 's/^chief: state=//p' "$LOG" | head -1)"
[ -d "$state_dir" ] || fail "announced state dir '$state_dir' does not exist"

sum="$(summary_of "$LOG")"
[ -n "$sum" ] || fail "no 'chief: summary=' line on stdout"
printf '%s' "$sum" | jq -e . >/dev/null 2>&1 || fail "summary is not valid JSON: $sum"
[ "$(printf '%s' "$sum" | jq -r '.runId')"   = "$run_id" ] || fail "summary runId != announced run-id"
[ "$(printf '%s' "$sum" | jq -r '.outcome')" = "merged"  ] || fail "summary outcome != merged: $sum"
[ "$(printf '%s' "$sum" | jq -r '.exit')"    = "0"       ] || fail "summary exit != 0: $sum"
[ "$(printf '%s' "$sum" | jq -r '.ok')"      = "true"    ] || fail "summary ok != true: $sum"
[ "$(printf '%s' "$sum" | jq -r '.tasklists|length')" = "1" ] || fail "summary names no tasklist: $sum"
[ "$(printf '%s' "$sum" | jq -r '.tasklists[0].name')"    = "hl"     ] || fail "wrong tasklist name: $sum"
[ "$(printf '%s' "$sum" | jq -r '.tasklists[0].outcome')" = "merged" ] || fail "tasklist outcome != merged: $sum"
case "$(printf '%s' "$sum" | jq -r '.tasklists[0].status')" in MERGED*) ;; *) fail "status not the driver's own MERGED line: $sum" ;; esac
git checkout -q main
[ -f out/US-1.txt ] || fail "the merged run did not actually merge the work"

# ── 2. Nothing runnable → the distinct no-work code, and still a full summary ──
# The tasklist retired to completed/ in step 1, so this run has nothing to schedule.
LOG="$WORK/nowork.log"
rc="$(run_headless "$LOG")"
[ "$rc" = "3" ] || fail "no-runnable run exited $rc, expected 3"
sum="$(summary_of "$LOG")"
printf '%s' "$sum" | jq -e . >/dev/null 2>&1 || fail "no-work summary is not valid JSON: $sum"
[ "$(printf '%s' "$sum" | jq -r '.outcome')" = "no-work" ] || fail "no-work summary outcome: $sum"
[ "$(printf '%s' "$sum" | jq -r '.exit')"    = "3"       ] || fail "no-work summary exit: $sum"
[ "$(printf '%s' "$sum" | jq -r '.ok')"      = "false"   ] || fail "no-work summary ok != false: $sum"
[ "$(printf '%s' "$sum" | jq -r '.tasklists|length')" = "0" ] || fail "no-work summary should name no tasklist: $sum"
[ -n "$(sed -n 's/^chief: run-id=//p' "$LOG" | head -1)" ] || fail "no run-id on the no-work path"

# ── 3. VERIFY-FAILED → its own code, and the tasklist says so by name ─────────
cat > tasks/chief/hl2.json <<'JSON'
{ "project":"hl2","branchName":"chief/hl2","description":"headless contract — verify fails",
  "iters":2,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[{"id":"US-2","title":"two","description":"","acceptanceCriteria":["out/US-2.txt"],"passes":false,"notes":""}] }
JSON
git add -A && git commit -q -m "hl2 tasklist"
LOG="$WORK/verify.log"
rc="$(HL_VERIFY_RC=1 run_headless "$LOG")"
[ "$rc" = "4" ] || fail "verify-failed run exited $rc, expected 4"
sum="$(summary_of "$LOG")"
printf '%s' "$sum" | jq -e . >/dev/null 2>&1 || fail "verify-failed summary is not valid JSON: $sum"
[ "$(printf '%s' "$sum" | jq -r '.outcome')" = "verify-failed" ] || fail "summary outcome != verify-failed: $sum"
[ "$(printf '%s' "$sum" | jq -r '.exit')"    = "4"             ] || fail "summary exit != 4: $sum"
[ "$(printf '%s' "$sum" | jq -r '.tasklists[0].outcome')" = "verify-failed" ] || fail "tasklist outcome: $sum"
git checkout -q main
if [ -f out/US-2.txt ]; then fail "a verify-failed branch was merged into $(git rev-parse --abbrev-ref HEAD)"; fi

# ── 4. A NON-headless run is untouched: no contract lines, historical exit ────
LOG="$WORK/human.log"
rc=0
PATH="$WORK/fakebin:$PATH" "$CHIEF" run >"$LOG" 2>&1 || rc=$?
[ "$rc" = "0" ] || fail "non-headless run exited $rc, expected the historical 0"
if grep -q '^chief: ' "$LOG"; then fail "a non-headless run emitted machine-readable 'chief: ' lines"; fi

echo "HEADLESS PASS — run-id announced · exit codes 0/3/4 · valid JSON summary · non-headless unchanged"
