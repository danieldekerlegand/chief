#!/usr/bin/env bash
# test/noworkguard-jsononly.sh — prove the no-work guard is not defeated by a
# branch whose ONLY commit touches the tasklist's own JSON.
#
# The subtler false-complete (the one seen in production): an agent produces no
# code but DOES commit the tracked tasklist file `tasks/chief/<name>.json` with its
# stories flipped to passes:true. That branch DOES diverge from base, so a naive
# `git diff --name-only base...branch` guard sees a changed file, treats it as
# "work", and merges+retires an empty-of-code branch. The fix: the work-check
# EXCLUDES the tasklist JSON (chief's own bookkeeping), so a JSON-only branch is
# still EMPTY-NO-WORK and nothing is merged/retired.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=nw GIT_AUTHOR_EMAIL=nw@test GIT_COMMITTER_NAME=nw GIT_COMMITTER_EMAIL=nw@test
fail() { echo "NOWORK-JSONONLY FAIL: $*" >&2; [ -f "$WORK/run.log" ] && tail -40 "$WORK/run.log" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

# ── install chief from this checkout ──────────────────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"; export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# ── fake `claude`: flip the TRACKED tasklist JSON to all-pass and COMMIT it, but
#     write no code. Branch diverges from base by exactly one file: the tasklist. ──
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null
# cwd = the worktree. Mark BOTH the runtime prd (drives remaining==0) and the
# tracked tasklist, then commit ONLY the tracked tasklist — no source files.
for f in .chief/state/prd.json tasks/chief/nw.json; do
  [ -f "$f" ] || continue
  t="$(mktemp)"; jq '.userStories |= map(.passes=true)' "$f" > "$t" && mv "$t" "$f"
done
git add tasks/chief/nw.json
git commit -q -m "chore: mark US-1 passed (no code)" || true
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
{ "project":"nw","branchName":"chief/nw","description":"no-work guard (json-only)",
  "iters":2,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":["out/US-1.txt"],"passes":false,"notes":""}] }
JSON
printf '#!/usr/bin/env bash\nset -eu\necho "verify: (would pass)"\nexit 0\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "nw setup"
base_sha="$(git rev-parse HEAD)"

# ── run; the agent misfires (COMPLETE, commits ONLY the tasklist JSON) ─────────
PATH="$WORK/fakebin:$PATH" "$CHIEF" run >"$WORK/run.log" 2>&1 || { cat "$WORK/run.log"; fail "run exited non-zero"; }

# ── the branch DID diverge (has a JSON commit); assert the guard still fired ───
git checkout -q main
[ -n "$(git rev-parse --verify --quiet chief/nw || true)" ] \
  && [ -n "$(git diff --name-only "$base_sha...chief/nw")" ] \
  || fail "test setup wrong: branch should carry a JSON-only commit"
status="$(cat "$REPO/.chief/state/parallel/nw.status" 2>/dev/null || echo MISSING)"
case "$status" in EMPTY-NO-WORK*) ;; *) fail "expected EMPTY-NO-WORK for a JSON-only branch, got: '$status'" ;; esac
[ "$(git rev-parse HEAD)" = "$base_sha" ]        || fail "main advanced — a JSON-only branch was merged (loophole open)"
[ -f tasks/chief/nw.json ]                       || fail "tasklist was retired despite no code (loophole open)"
[ ! -f tasks/chief/completed/nw.json ]           || fail "a completed record was written for a code-less run (loophole open)"
case "$(git log --oneline)" in *"Merge chief/nw"*) fail "a merge commit exists for the JSON-only branch (loophole open)" ;; *) ;; esac
case "$("$CHIEF" run -n 2>&1)" in *nw*) ;; *) fail "tasklist not still pending after the guard" ;; esac

echo "NOWORK-JSONONLY PASS — a branch whose only commit flips its own tasklist JSON is EMPTY-NO-WORK; not merged, not retired"
