#!/usr/bin/env bash
# test/nested-submodule-pointer.sh — proof that a tasklist targeting a NESTED submodule
# bumps the pointer at EVERY level.
#
# THE BUG THIS PINS. finalize_merged used to bump the pointer with a single
# `git -C <project> add "$sub"`. For a nested submodule that is not merely wrong, it is
# impossible:
#
#     $ git -C <project> add babylon/packages/core
#     fatal: Pathspec 'babylon/packages/core' is in submodule 'babylon'
#
# The project tracks `babylon` as a gitlink; the inner pointer lives in babylon's index.
# The call was error-suppressed, so the failure was INVISIBLE: the branch merged into the
# nested submodule's base, no pointer moved at any level, and the run still said MERGED.
# The merged code was unreachable from the project and nothing said so.
#
#     project ──(submodule)──> sub ──(submodule)──> dep
#                                                    ^ the tasklist's repo
#
# Asserts all three: the work is on dep's main, sub's gitlink for packages/dep advanced,
# and project's gitlink for sub advanced. Fully offline; deterministic.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=nsp GIT_AUTHOR_EMAIL=nsp@test GIT_COMMITTER_NAME=nsp GIT_COMMITTER_EMAIL=nsp@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
fail() {
  echo "NESTED-POINTER FAIL: $*" >&2
  [ -f "$WORK/run.log" ] && { echo "--- run.log ---" >&2; tail -30 "$WORK/run.log" >&2; }
  for f in "$WORK/repo/.chief/state/parallel/"*.log; do
    [ -f "$f" ] && { echo "--- $(basename "$f") ---" >&2; tail -60 "$f" >&2; }
  done
  exit 1
}
command -v jq >/dev/null || fail "jq required"; command -v git >/dev/null || fail "git required"

PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null
PRD=".chief/state/prd.json"                       # cwd = the NESTED repo's worktree
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  printf 'impl %s\n' "$id" > "IMPL.txt"
  t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id).passes)=true' "$PRD" > "$t" && mv "$t" "$PRD"
  git add -A >/dev/null 2>&1 || true
  git commit -q -m "feat: $id - work in the nested submodule" >/dev/null 2>&1 || true
fi
[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── scaffold: dep <- sub (at packages/dep) <- project ─────────────────────────
DEPSRC="$WORK/depsrc"; mkdir -p "$DEPSRC"; cd "$DEPSRC"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
printf 'dep\n' > README.md; git add -A; git commit -q -m "dep base"

SUBSRC="$WORK/subsrc"; mkdir -p "$SUBSRC"; cd "$SUBSRC"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
printf 'sub\n' > README.md; git add -A; git commit -q -m "sub base"
git submodule add "file://$DEPSRC" packages/dep >/dev/null 2>&1 || fail "nested submodule add failed"
git commit -q -m "mount dep at packages/dep"

REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
git submodule add "file://$SUBSRC" sub >/dev/null 2>&1 || fail "submodule add failed"
git commit -q -m "add submodule sub"
git submodule update --init --recursive >/dev/null 2>&1 || fail "recursive init failed"

# The premise: staging the nested path from the project is impossible.
if git -C "$REPO" add sub/packages/dep 2>/dev/null; then
  fail "premise broken: the project could stage the nested submodule path directly"
fi

dep_before="$(git -C "$REPO/sub/packages/dep" rev-parse HEAD)"
sub_before="$(git -C "$REPO/sub" rev-parse HEAD)"
repo_before="$(git -C "$REPO" rev-parse HEAD)"

"$CHIEF" init >/dev/null || fail "chief init failed"
rm -f tasks/chief/example.json
cat > tasks/chief/deep.json <<'JSON'
{ "project":"deep","branchName":"chief/deep","repo":"sub/packages/dep","description":"nested submodule tasklist",
  "iters":3,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":["IMPL.txt"],"passes":false,"notes":""}] }
JSON
printf '#!/usr/bin/env bash\nexit 0\n' > .chief/verify.sh; chmod +x .chief/verify.sh
git add -A; git commit -q -m "chief scaffolding"

PATH="$WORK/fakebin:$PATH" "$CHIEF" run -p 1 deep > "$WORK/run.log" 2>&1 || true

# ── assertions: the work landed AND every pointer moved ───────────────────────
git -C "$REPO/sub/packages/dep" show main:IMPL.txt >/dev/null 2>&1 \
  || fail "story output never reached the nested submodule's main"

dep_after="$(git -C "$REPO/sub/packages/dep" rev-parse main)"
[ "$dep_after" != "$dep_before" ] || fail "dep's main did not advance"

# sub must RECORD the new dep sha (not merely have it checked out).
sub_records="$(git -C "$REPO/sub" ls-tree HEAD -- packages/dep | awk '{print $3}')"
[ "$sub_records" = "$dep_after" ] \
  || fail "sub records packages/dep at ${sub_records:-<none>}, expected $dep_after"
[ "$(git -C "$REPO/sub" rev-parse HEAD)" != "$sub_before" ] || fail "sub's HEAD did not advance"

# project must RECORD the new sub sha.
repo_records="$(git -C "$REPO" ls-tree HEAD -- sub | awk '{print $3}')"
[ "$repo_records" = "$(git -C "$REPO/sub" rev-parse HEAD)" ] \
  || fail "project records sub at ${repo_records:-<none>}, expected $(git -C "$REPO/sub" rev-parse HEAD)"
[ "$(git -C "$REPO" rev-parse HEAD)" != "$repo_before" ] || fail "project HEAD did not advance"

grep -qs "POINTER STALE\|SUBMODULE POINTER NOT BUMPED\|stale pointer" "$WORK/run.log" \
  "$REPO/.chief/state/parallel/deep.log" && fail "chief reported a stale pointer"

[ -f "$REPO/tasks/chief/completed/deep.json" ] || fail "tasklist was not retired into completed/"

echo "NESTED-POINTER PASS — a nested-submodule tasklist bumps the pointer at every level"
