#!/usr/bin/env bash
# test/limitstate.sh — a worker stopped by a Claude usage limit must be PAUSED,
# not FAILED, and must not take its dependents down with it.
#
# The failure this pins (observed in production): the agent loop exits 2 for
# "blocked on a usage limit, resumable" (engine/agent.sh's exit-code contract), but
# the driver funnelled every non-MERGED outcome into 'failed'. dep_broken() then
# turned that into 'blocked' for every dependent, so ONE limit halted the whole run
# — reported as a hard failure, with nothing to re-dispatch.
#
# Two tasklist chains run side by side through the real parallel driver, both with a
# fake `claude` that commits NOTHING, so the ONLY difference is the agent's exit code:
#   lim-a (agent exits 2, usage limit)  -> state 'rate-limited'; lim-b stays pending
#   st-a  (agent exits 1, genuine stall) -> state 'failed';       st-b goes 'blocked'
# The second chain is the no-regression half: a real failure must still block.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=ls GIT_AUTHOR_EMAIL=ls@test GIT_COMMITTER_NAME=ls GIT_COMMITTER_EMAIL=ls@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"   # hermetic: don't touch ~/.chief
fail() { echo "LIMITSTATE FAIL: $*" >&2; [ -f "$WORK/run.log" ] && tail -40 "$WORK/run.log" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

# ── install chief from this checkout ──────────────────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# ── fake `claude`: behaviour chosen by the tasklist under work, work never done ──
# lim-*: emit a real Claude limit line (with RATE_LIMIT_RETRY=0 the agent stops at
#        once -> exit 2).  st-*: ordinary prose, no progress -> the loop stalls and
#        exits 1 (iters=1 + STALL_LIMIT=1 makes that one turn).
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null
name="$(jq -r '.branchName' .chief/state/prd.json | sed 's#^chief/##')"
case "$name" in
  lim-*) echo "Claude AI usage limit reached|1795000000" ;;
  *)     echo "I read the code but could not finish this story yet." ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── scaffold a repo + two dependency chains ───────────────────────────────────
REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null
rm -f tasks/chief/example.json
mk() {   # <name> <dependsOn-json>
  cat > "tasks/chief/$1.json" <<JSON
{ "project":"ls","branchName":"chief/$1","description":"limit-state $1",
  "iters":1,"dependsOn":$2,"touches":[],"warmup":[],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":["out/US-1.txt"],"passes":false,"notes":""}] }
JSON
}
mk lim-a '[]'; mk lim-b '["lim-a"]'
mk st-a  '[]'; mk st-b  '["st-a"]'
printf '#!/usr/bin/env bash\nset -eu\necho "verify: (would pass)"\nexit 0\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "limitstate setup"

# ── run: no worker can finish, but for two different reasons ──────────────────
# RATE_LIMIT_REDISPATCH_MAX=0 pins this test on CLASSIFICATION only. The driver's
# reset-aware re-dispatch (test/limitresume.sh) would otherwise wait out the
# fixture's reset epoch — capped at 6h — and re-run lim-a three times.
PATH="$WORK/fakebin:$PATH" RATE_LIMIT_RETRY=0 STALL_LIMIT=1 RATE_LIMIT_REDISPATCH_MAX=0 \
  "$CHIEF" run -p 2 >"$WORK/run.log" 2>&1 || { cat "$WORK/run.log"; fail "run exited non-zero (a usage-limit pause is not a run failure)"; }

S="$REPO/.chief/state/parallel"
state()  { cat "$S/$1.state"  2>/dev/null || echo MISSING; }
status() { cat "$S/$1.status" 2>/dev/null || echo MISSING; }

# ── the limit chain: paused, not failed; dependent still schedulable ──────────
case "$(status lim-a)" in
  RATE-LIMITED*) ;;
  *) fail "lim-a status is '$(status lim-a)', want RATE-LIMITED* (a limit stop must not be read as EMPTY-NO-WORK/INCOMPLETE)" ;;
esac
[ "$(state lim-a)" = "rate-limited" ] || fail "lim-a state is '$(state lim-a)', want rate-limited"
[ "$(state lim-b)" != "blocked" ]     || fail "lim-b was BLOCKED by a dependency that is only paused on a usage limit"
[ ! -f "$S/lim-b.why" ]               || fail "lim-b got a block reason: $(cat "$S/lim-b.why")"
if grep -q 'lim-b BLOCKED' "$WORK/run.log"; then fail "the run announced lim-b as blocked"; fi
grep -q 'paused on a Claude usage limit' "$WORK/run.log" || fail "summary does not report the pause distinctly from a failure"

# ── the failure chain (no regression): still failed, still blocks ─────────────
[ "$(state st-a)" = "failed" ]  || fail "st-a state is '$(state st-a)', want failed (a genuine stall must still fail)"
[ "$(state st-b)" = "blocked" ] || fail "st-b state is '$(state st-b)', want blocked (a failed dep must still block)"
[ -f "$S/st-b.why" ]            || fail "st-b has no recorded block reason"

# ── nothing merged or retired either way ──────────────────────────────────────
git checkout -q main
for n in lim-a lim-b st-a st-b; do
  [ -f "tasks/chief/$n.json" ]           || fail "$n was retired without completing"
  [ ! -f "tasks/chief/completed/$n.json" ] || fail "a completed record was written for $n"
done
# The paused branch is kept intact so a re-run resumes it (rather than rebuilding).
git rev-parse --verify --quiet chief/lim-a >/dev/null || fail "the paused branch chief/lim-a was not kept for a resume"
case "$("$CHIEF" run -n 2>&1)" in *lim-a*) ;; *) fail "lim-a is not schedulable again after the pause" ;; esac

echo "LIMITSTATE PASS — usage limit → 'rate-limited' (dependent stays schedulable); genuine stall → 'failed' (dependent blocked)"
