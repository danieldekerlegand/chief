#!/usr/bin/env bash
# test/noworkguard.sh — prove the EMPTY-NO-WORK guard blocks a false-complete.
#
# The failure it guards against (ported from the production driver): an agent that
# declares <promise>COMPLETE</promise> and marks every story passing in the runtime
# prd.json but commits NOTHING to the branch. Without the guard the driver would see
# remaining==0, "merge" an empty branch (git reports up-to-date), and RETIRE the
# tasklist to completed/ — a silent false-completion. With the guard the branch has
# no diff vs base, so the run is marked EMPTY-NO-WORK and nothing is merged/retired.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=nw GIT_AUTHOR_EMAIL=nw@test GIT_COMMITTER_NAME=nw GIT_COMMITTER_EMAIL=nw@test
fail() { echo "NOWORK FAIL: $*" >&2; [ -f "$WORK/run.log" ] && tail -40 "$WORK/run.log" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

# ── install chief from this checkout ──────────────────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"; export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# ── fake `claude`: MISFIRE — mark the runtime prd all-pass, emit COMPLETE, commit nothing ──
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null
PRD=".chief/state/prd.json"                       # cwd = the worktree
t="$(mktemp)"; jq '.userStories |= map(.passes=true)' "$PRD" > "$t" && mv "$t" "$PRD"
# deliberately NO file creation and NO git commit — the branch stays == base
echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── scaffold a repo + a 1-story tasklist + a verify hook that would PASS if reached ──
REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null
rm -f tasks/chief/example.json
cat > tasks/chief/nw.json <<'JSON'
{ "project":"nw","branchName":"chief/nw","description":"no-work guard",
  "iters":2,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":["out/US-1.txt"],"passes":false,"notes":""}] }
JSON
printf '#!/usr/bin/env bash\nset -eu\necho "verify: (would pass)"\nexit 0\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "nw setup"
base_sha="$(git rev-parse HEAD)"

# ── run; the agent misfires (COMPLETE, no commits) ────────────────────────────
PATH="$WORK/fakebin:$PATH" "$CHIEF" run >"$WORK/run.log" 2>&1 || { cat "$WORK/run.log"; fail "run exited non-zero"; }

# ── assert the guard fired and NOTHING was merged/retired ─────────────────────
status="$(cat "$REPO/.chief/state/parallel/nw.status" 2>/dev/null || echo MISSING)"
case "$status" in EMPTY-NO-WORK*) ;; *) fail "expected EMPTY-NO-WORK status, got: '$status'" ;; esac
git checkout -q main
[ "$(git rev-parse HEAD)" = "$base_sha" ]        || fail "main advanced — an empty branch was merged (guard failed)"
[ -f tasks/chief/nw.json ]                       || fail "tasklist was retired despite no work (guard failed)"
[ ! -f tasks/chief/completed/nw.json ]           || fail "a completed record was written for a no-work run (guard failed)"
case "$(git log --oneline)" in *"Merge chief/nw"*) fail "a merge commit exists for the empty branch (guard failed)" ;; *) ;; esac
case "$("$CHIEF" run -n 2>&1)" in *nw*) ;; *) fail "tasklist not still pending after the guard" ;; esac

echo "NOWORK PASS — false-complete (COMPLETE + zero commits) caught as EMPTY-NO-WORK; not merged, not retired"
