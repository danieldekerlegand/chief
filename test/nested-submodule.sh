#!/usr/bin/env bash
# test/nested-submodule.sh — proof that a submodule worktree gets its NESTED
# submodules populated.
#
# THE BUG THIS PINS. `git worktree add` writes tracked files but leaves a nested
# submodule as an EMPTY DIRECTORY: the worktree gets the gitlink and no content.
# A repo that mounts a dependency that way (insimul/babylon mounts packages/core,
# which ~264 of its files import) therefore handed the agent a tree whose imports
# could not resolve, and every build failed for a reason unrelated to the story.
#
# The shape here mirrors that exactly:
#
#     project ──(submodule)──> sub ──(submodule)──> nested
#                              ^ the tasklist's repo
#
# The fake agent REFUSES to do the story unless nested/'s content is actually
# present in its cwd, so a regression fails the run rather than quietly producing
# work against a broken tree. Fully offline; deterministic.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=nst GIT_AUTHOR_EMAIL=nst@test GIT_COMMITTER_NAME=nst GIT_COMMITTER_EMAIL=nst@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
# Submodule clones over file:// are refused by default since git 2.38. Allow them
# for every git this test drives, including the ones chief runs.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
fail() {
  echo "NESTED-SUBMODULE FAIL: $*" >&2
  [ -f "$WORK/run.log" ] && { echo "--- run.log ---" >&2; tail -30 "$WORK/run.log" >&2; }
  # The driver's per-tasklist narration (where the init message lands) is here.
  for f in "$WORK/repo/.chief/state/parallel/"*.log; do
    [ -f "$f" ] && { echo "--- $(basename "$f") ---" >&2; tail -60 "$f" >&2; }
  done
  exit 1
}
command -v jq >/dev/null || fail "jq required"; command -v git >/dev/null || fail "git required"

# ── install chief from this checkout ──────────────────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# ── fake `claude`: assert the nested content is THERE before doing any work ────
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null
PRD=".chief/state/prd.json"                       # cwd = the `sub` worktree
# The whole point: a nested submodule must be a populated checkout, not a hole.
if [ ! -f "packages/dep/DEP.txt" ]; then
  echo "AGENT: packages/dep/DEP.txt MISSING — nested submodule was not initialized" >&2
  exit 3
fi
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  mkdir -p src; cp packages/dep/DEP.txt "src/$id.txt"
  t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id).passes)=true' "$PRD" > "$t" && mv "$t" "$PRD"
  git add -A >/dev/null 2>&1 || true
  git commit -q -m "feat: $id - read the nested dependency" >/dev/null 2>&1 || true
fi
[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── scaffold: dep <- sub <- project ───────────────────────────────────────────
DEPSRC="$WORK/depsrc"; mkdir -p "$DEPSRC"; cd "$DEPSRC"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
printf 'the dependency\n' > DEP.txt; git add -A; git commit -q -m "dep base"

SUBSRC="$WORK/subsrc"; mkdir -p "$SUBSRC"; cd "$SUBSRC"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
printf 'lib\n' > README.md; git add -A; git commit -q -m "sub base"
git submodule add "file://$DEPSRC" packages/dep >/dev/null 2>&1 || fail "nested submodule add failed"
git commit -q -m "mount dep at packages/dep"

REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
git submodule add "file://$SUBSRC" sub >/dev/null 2>&1 || fail "submodule add failed"
git commit -q -m "add submodule sub"

# Sanity: the bug is real. A bare `git worktree add` leaves the nested dir empty.
probe="$WORK/probe"
git -C "$REPO/sub" worktree add -q "$probe" HEAD 2>/dev/null || fail "probe worktree failed"
[ -f "$probe/packages/dep/DEP.txt" ] && fail "premise broken: worktree add already populated the nested submodule"
git -C "$REPO/sub" worktree remove --force "$probe"

"$CHIEF" init >/dev/null || fail "chief init failed"
rm -f tasks/chief/example.json
cat > tasks/chief/nested-demo.json <<'JSON'
{ "project":"nested-demo","branchName":"chief/nested-demo","repo":"sub","description":"nested submodule tasklist",
  "iters":3,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":["src/US-1.txt"],"passes":false,"notes":""}] }
JSON
cat > .chief/verify.sh <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x .chief/verify.sh
git add -A; git commit -q -m "chief scaffolding"

PATH="$WORK/fakebin:$PATH" "$CHIEF" run -p 1 nested-demo > "$WORK/run.log" 2>&1 || true

# ── assertions ────────────────────────────────────────────────────────────────
# The driver narrates per tasklist, not into the run summary — assert against both.
LOGS="$WORK/run.log $WORK/repo/.chief/state/parallel/nested-demo.log"
# shellcheck disable=SC2086
grep -qs "initialized nested submodule" $LOGS \
  || fail "driver never reported initializing the nested submodule"
# shellcheck disable=SC2086
grep -qs "MISSING — nested submodule was not initialized" $LOGS \
  && fail "the agent saw an empty nested submodule"
git -C "$REPO/sub" show main:src/US-1.txt >/dev/null 2>&1 \
  || fail "story output never reached the submodule's main"
[ "$(git -C "$REPO/sub" show main:src/US-1.txt)" = "the dependency" ] \
  || fail "story output does not carry the nested dependency's content"

echo "NESTED-SUBMODULE PASS — a submodule worktree gets its nested submodules populated"
