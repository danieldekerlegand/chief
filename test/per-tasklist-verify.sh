#!/usr/bin/env bash
# test/per-tasklist-verify.sh — a tasklist's own "verify" commands are the merge gate.
#
# Why: with several repos in one project, the single .chief/verify.sh hook grows a
# `case` per repo that must dispatch off cwd. A per-tasklist "verify" array lets each
# tasklist declare its own gate, run with cwd = the work repo.
#
# Two things must hold, and this pins BOTH:
#   1. OVERRIDE — a tasklist with passing "verify" merges even though the project hook
#      always fails (so the per-tasklist commands really took precedence).
#   2. STILL GATES — a tasklist with failing "verify" does NOT merge (so it isn't
#      vacuously passing everything).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=pv GIT_AUTHOR_EMAIL=pv@test GIT_COMMITTER_NAME=pv GIT_COMMITTER_EMAIL=pv@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
fail() { echo "PER-TASKLIST-VERIFY FAIL: $*" >&2; [ -f "$WORK/run.log" ] && tail -40 "$WORK/run.log" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# fake claude: implement the story, flip flags, commit
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null
PRD=".chief/state/prd.json"
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
mkdir -p out; printf 'impl\n' > "out/$name.txt"
for f in "$PRD" "tasks/chief/$name.json"; do
  [ -f "$f" ] || continue
  t="$(mktemp)"; jq '.userStories |= map(.passes=true)' "$f" > "$t" && mv "$t" "$f"
done
git add -A >/dev/null 2>&1 || true
git commit -q -m "feat: story" >/dev/null 2>&1 || true
echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null
rm -f tasks/chief/example.json

# The PROJECT hook always FAILS — anything that merges proves the per-tasklist gate won.
printf '#!/usr/bin/env bash\necho "PROJECT HOOK RAN (always fails)"\nexit 1\n' > .chief/verify.sh
chmod +x .chief/verify.sh

# (1) passing per-tasklist verify -> must MERGE despite the failing project hook
cat > tasks/chief/pv-pass.json <<'JSON'
{ "project":"pv","branchName":"chief/pv-pass","description":"per-tasklist verify passes",
  "iters":2,"dependsOn":[],"touches":["a"],"warmup":[],
  "verify":["echo ran > .verify-marker","test -f out/pv-pass.txt"],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":["out/pv-pass.txt"],"passes":false,"notes":""}] }
JSON
# (2) failing per-tasklist verify -> must NOT merge
cat > tasks/chief/pv-fail.json <<'JSON'
{ "project":"pv","branchName":"chief/pv-fail","description":"per-tasklist verify fails",
  "iters":2,"dependsOn":[],"touches":["b"],"warmup":[],
  "verify":["test -f definitely-not-here.txt"],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":["out/pv-fail.txt"],"passes":false,"notes":""}] }
JSON
git add -A && git commit -q -m setup

PATH="$WORK/fakebin:$PATH" "$CHIEF" run >"$WORK/run.log" 2>&1 || true

git checkout -q main
# 1. OVERRIDE: pv-pass merged + retired, and its verify commands actually ran
[ -f tasks/chief/completed/pv-pass.json ] || fail "pv-pass did not merge — the failing PROJECT hook gated it, so per-tasklist verify did NOT override"
[ -f .verify-marker ]                     || fail "per-tasklist verify commands never ran (no marker)"
[ -f out/pv-pass.txt ]                    || fail "pv-pass work not merged"
# 2. STILL GATES: pv-fail blocked by its own failing verify
[ ! -f tasks/chief/completed/pv-fail.json ] || fail "pv-fail MERGED despite a failing per-tasklist verify — the gate is vacuous"
case "$(cat .chief/state/parallel/pv-fail.status 2>/dev/null)" in
  VERIFY-FAILED*) ;;
  *) fail "pv-fail status should be VERIFY-FAILED, got: $(cat .chief/state/parallel/pv-fail.status 2>/dev/null)" ;;
esac

echo "PER-TASKLIST-VERIFY PASS — own verify overrode the failing project hook, and a failing one still blocked the merge"
