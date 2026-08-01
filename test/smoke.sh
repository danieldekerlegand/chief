#!/usr/bin/env bash
# test/smoke.sh — end-to-end smoke test of the chief tool, fully offline.
#
# Proves the WHOLE runtime, not just the scheduler: it installs chief from this
# checkout via install.sh into a throwaway prefix, scaffolds a fresh git repo,
# and drives a 2-story tasklist through init → agent loop → verify → merge →
# retire-to-completed. The "agent" is a scripted test double — a fake `claude`
# on PATH that implements one story per call and prints the completion promise —
# so there is no network, no real AI, and the result is deterministic.
#
# Installs the COMMITTED state of this checkout (install.sh git-clones), so commit
# your engine changes before running. Exits non-zero on the first failed assertion.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=smoke GIT_AUTHOR_EMAIL=smoke@test \
       GIT_COMMITTER_NAME=smoke GIT_COMMITTER_EMAIL=smoke@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"   # hermetic: don't touch ~/.chief
fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }

command -v jq  >/dev/null || fail "jq is required for the smoke test"
command -v git >/dev/null || fail "git is required for the smoke test"

# ── 1. Install chief from THIS checkout (exercises install.sh + the shim) ──────
PREFIX="$WORK/chiefhome"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" \
CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" \
  sh "$ROOT/install.sh" >/dev/null || fail "install.sh failed"
CHIEF="$BIN/chief"
[ -x "$CHIEF" ] || fail "shim not installed at $CHIEF"
[ "$("$CHIEF" version)" = "chief $(cat "$ROOT/VERSION")" ] || fail "version wrong via installed shim (symlink resolution?)"

# ── 2. A scripted test-double agent: a fake `claude` that does ONE story/call ──
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null                                  # drain the prompt on stdin
PRD=".chief/state/prd.json"                     # cwd = the worktree (set by the driver)
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
TRACKED="tasks/chief/$name.json"
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  mkdir -p out; printf 'impl %s\n' "$id" > "out/$id.txt"     # the "implementation"
  for f in "$PRD" "$TRACKED"; do                              # flip passes in BOTH files
    t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id).passes)=true' "$f" > "$t" && mv "$t" "$f"
  done
  git add -A >/dev/null 2>&1 || true
  git commit -q -m "feat: $id - scripted" >/dev/null 2>&1 || true
fi
[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── 3. Scaffold a fresh repo + a deterministic tasklist + a real verify hook ──
REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null || fail "chief init failed"

rm -f tasks/chief/example.json
cat > tasks/chief/smoke.json <<'JSON'
{ "project":"smoke","branchName":"chief/smoke","description":"smoke tasklist",
  "iters":4,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[
    {"id":"US-1","title":"first","description":"","acceptanceCriteria":["out/US-1.txt exists"],"passes":false,"notes":""},
    {"id":"US-2","title":"second","description":"","acceptanceCriteria":["out/US-2.txt exists"],"passes":false,"notes":""}
  ] }
JSON
# A verify hook with teeth: the branch merges only if BOTH artifacts are present.
cat > .chief/verify.sh <<'SH'
#!/usr/bin/env bash
set -eu
[ -f out/US-1.txt ] && [ -f out/US-2.txt ] || { echo "verify: missing artifacts"; exit 1; }
echo "verify: artifacts present"
SH
chmod +x .chief/verify.sh
git add -A && git commit -q -m "smoke: tasklist + verify hook"

# ── 4. Run chief (sequential, auto-merge) with the fake agent first on PATH ────
PATH="$WORK/fakebin:$PATH" "$CHIEF" run >"$WORK/run.log" 2>&1 || { cat "$WORK/run.log"; fail "chief run exited non-zero"; }

# ── 5. Assert the full-runtime outcome landed on the base branch ──────────────
git checkout -q main
[ -f out/US-1.txt ] && [ -f out/US-2.txt ]                     || fail "agent artifacts not merged to main"
[ -f tasks/chief/completed/smoke.json ]                        || fail "tasklist not retired to completed/"
[ -n "$(jq -r '.mergedToMain // empty' tasks/chief/completed/smoke.json)" ] || fail "completed record has no mergedToMain stamp"
[ ! -f tasks/chief/smoke.json ]                                || fail "pending tasklist not removed after merge"
# case-match (not `| grep -q`) so pipefail's SIGPIPE race can't false-negative.
case "$(git log --oneline)" in *"Merge chief/smoke"*) ;; *) fail "no --no-ff merge commit on main" ;; esac
if git rev-parse --verify -q chief/smoke >/dev/null; then fail "feature branch not deleted after merge"; fi
case "$("$CHIEF" list)" in *smoke*) ;; *) fail "chief list doesn't show the completed smoke tasklist" ;; esac

# ── 6. init guard: refuse to scaffold in $HOME (collides with the install prefix) ──
GHOME="$WORK/ghome"; mkdir -p "$GHOME"
if ( cd "$GHOME" && HOME="$GHOME" "$CHIEF" init >/dev/null 2>&1 ); then fail "chief init did NOT refuse to run in \$HOME"; fi
[ ! -e "$GHOME/.chief/config" ] || fail "chief init scaffolded into \$HOME despite the guard"

echo "SMOKE PASS — install → init → agent loop → verify → merge → completed + \$HOME-init guard (offline)"
