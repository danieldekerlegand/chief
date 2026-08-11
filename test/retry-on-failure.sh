#!/usr/bin/env bash
# test/retry-on-failure.sh — bounded retry of a FAILED tasklist.
#
# WHAT THIS PINS. A tasklist that fails used to sit failed until an operator noticed, and
# it decayed while it waited: every sibling that merged put it further behind its base.
# Seen in production 2026-08-10 — a tasklist failed a flaky 5s test timeout, sat ~7 hours
# while 8 others merged, and turned from "re-run it" into a 23-commit rebase with real
# conflicts. The failure was transient; the cost of not retrying was not.
#
# Three properties, each with its own tasklist in ONE run so they are proven together:
#
#   transient  — verify fails once, then passes. Must RETRY and end 'done'.
#   permanent  — verify always fails. Must stop at exactly RETRY_MAX attempts, no more.
#   fatal      — a non-retryable status (BAD-REPO: the repo does not exist). Must NOT be
#                retried at all, because no agent run can fix a configuration fault.
#
# Fully offline; deterministic fake agent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=rty GIT_AUTHOR_EMAIL=rty@test GIT_COMMITTER_NAME=rty GIT_COMMITTER_EMAIL=rty@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
fail() {
  echo "RETRY FAIL: $*" >&2
  [ -f "$WORK/run.log" ] && { echo "--- run.log ---" >&2; tail -60 "$WORK/run.log" >&2; }
  exit 1
}
command -v jq >/dev/null || fail "jq required"; command -v git >/dev/null || fail "git required"

PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# Fake agent: always does the story so the branch has real work; the VERIFY hook is what
# decides pass/fail, which is the seam this test is about.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null
PRD=".chief/state/prd.json"
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  mkdir -p src; date +%s%N > "src/$id.txt"
  t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id).passes)=true' "$PRD" > "$t" && mv "$t" "$PRD"
  git add -A >/dev/null 2>&1 || true
  git commit -q -m "feat: $id - work" >/dev/null 2>&1 || true
fi
[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null || fail "chief init failed"
rm -f tasks/chief/example.json

for n in transient permanent; do
  cat > "tasks/chief/$n.json" <<JSON
{ "project":"$n","branchName":"chief/$n","repo":".","description":"retry probe",
  "iters":2,"dependsOn":[],"touches":["$n"],"warmup":[],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":["src/US-1.txt"],"passes":false,"notes":""}] }
JSON
done
# A non-retryable fault: the declared repo is not a git repo under the project → BAD-REPO.
cat > tasks/chief/fatal.json <<'JSON'
{ "project":"fatal","branchName":"chief/fatal","repo":"no-such-submodule","description":"non-retryable probe",
  "iters":2,"dependsOn":[],"touches":["fatal"],"warmup":[],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":["x"],"passes":false,"notes":""}] }
JSON

# The verify hook: `transient` fails only its FIRST attempt, `permanent` fails always.
# The counter is a file outside the worktree, so it survives between attempts.
cat > .chief/verify.sh <<SH
#!/usr/bin/env bash
name="\$(basename "\${CHIEF_PROJECT:-\$PWD}")"
b="\$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo)"
case "\$b" in
  chief/transient)
    c="$WORK/transient.count"; n=\$(( \$(cat "\$c" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "\$c"
    [ "\$n" -ge 2 ] && exit 0
    echo "verify: deliberate first-attempt failure"; exit 1 ;;
  chief/permanent)
    c="$WORK/permanent.count"; echo \$(( \$(cat "\$c" 2>/dev/null || echo 0) + 1 )) > "\$c"
    echo "verify: deliberate permanent failure"; exit 1 ;;
esac
exit 0
SH
chmod +x .chief/verify.sh
git add -A; git commit -q -m "chief scaffolding"

PATH="$WORK/fakebin:$PATH" RETRY_MAX=3 "$CHIEF" run -p 1 transient permanent fatal \
  > "$WORK/run.log" 2>&1 || true

SD="$REPO/.chief/state/parallel"
att() { cat "$SD/$1.attempts" 2>/dev/null || echo 1; }
stt() { cat "$SD/$1.state" 2>/dev/null || echo "?"; }

# ── transient: retried once, then recovered ──────────────────────────────────
[ "$(stt transient)" = "done" ] || fail "transient ended '$(stt transient)', want done"
[ "$(att transient)" = "2" ]    || fail "transient took $(att transient) attempt(s), want 2"
grep -q "↻ retrying transient (attempt 2/3)" "$WORK/run.log" \
  || fail "the retry was not announced for transient"

# ── permanent: stopped at the cap, and not one attempt more ──────────────────
[ "$(stt permanent)" = "failed" ] || fail "permanent ended '$(stt permanent)', want failed"
[ "$(att permanent)" = "3" ]      || fail "permanent took $(att permanent) attempt(s), want exactly 3"
[ "$(cat "$WORK/permanent.count")" = "3" ] \
  || fail "verify ran $(cat "$WORK/permanent.count") time(s) for permanent, want exactly 3 — the cap did not hold"
grep -q "exhausted its retries (3/3)" "$WORK/run.log" \
  || fail "exhaustion was not reported for permanent"

# ── fatal: a configuration fault is never retried ────────────────────────────
[ "$(att fatal)" = "1" ] || fail "fatal was retried ($(att fatal) attempts) — a non-retryable status must not spend the budget"
grep -q "↻ retrying fatal" "$WORK/run.log" && fail "fatal must never be retried"

# ── the summary distinguishes recovered from still-failing ───────────────────
grep -q "retried after failing:" "$WORK/run.log" || fail "the summary did not report retries"
grep -qE "transient +attempt 2/3 — recovered" "$WORK/run.log" || fail "summary did not mark transient recovered"
grep -qE "permanent +attempt 3/3 — still failing" "$WORK/run.log" || fail "summary did not mark permanent still-failing"

echo "RETRY PASS — a transient failure recovers, a permanent one stops at the cap, and a config fault is never retried"
