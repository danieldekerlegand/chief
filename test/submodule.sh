#!/usr/bin/env bash
# test/submodule.sh — end-to-end proof of `repo:<sub>` submodule tasklists.
#
# A tasklist can target a submodule (or any nested git repo) via its "repo" field.
# The branch/worktree/commits/merge then happen INSIDE that submodule; on success
# chief merges the submodule branch into the submodule's own base, bumps the
# project's submodule pointer, and retires the tasklist in the project. This test
# scaffolds a project with a real file:// submodule, drives a 1-story submodule
# tasklist through init → agent (in the submodule worktree) → verify → merge, and
# asserts the submodule got the code, the project pointer advanced, and no chief
# bookkeeping leaked into the submodule. Fully offline; deterministic fake agent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=sub GIT_AUTHOR_EMAIL=sub@test GIT_COMMITTER_NAME=sub GIT_COMMITTER_EMAIL=sub@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
fail() { echo "SUBMODULE FAIL: $*" >&2; [ -f "$WORK/run.log" ] && tail -50 "$WORK/run.log" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"; command -v git >/dev/null || fail "git required"

# ── install chief from this checkout ──────────────────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# ── fake `claude`: run in the SUBMODULE worktree. One story/call: write real code,
#     flip the runtime prd (there is NO tracked tasklist JSON in a submodule), and
#     commit with `add -A` (chief's .chief/ must be locally excluded, or it leaks). ──
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null
PRD=".chief/state/prd.json"                       # cwd = the submodule worktree
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  mkdir -p src; printf 'impl %s\n' "$id" > "src/$id.txt"
  t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id).passes)=true' "$PRD" > "$t" && mv "$t" "$PRD"
  git add -A >/dev/null 2>&1 || true
  git commit -q -m "feat: $id - scripted (submodule)" >/dev/null 2>&1 || true
fi
[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── scaffold: a standalone submodule repo, then a project that embeds it ───────
SUBSRC="$WORK/subsrc"; mkdir -p "$SUBSRC"; cd "$SUBSRC"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
printf 'lib\n' > README.md; git add -A; git commit -q -m "sub base"

REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
git -c protocol.file.allow=always submodule add "file://$SUBSRC" sub >/dev/null 2>&1 || fail "submodule add failed"
git commit -q -m "add submodule sub"
sub_base="$(git -C "$REPO/sub" rev-parse HEAD)"

"$CHIEF" init >/dev/null || fail "chief init failed"
rm -f tasks/chief/example.json
cat > tasks/chief/sub-demo.json <<'JSON'
{ "project":"sub-demo","branchName":"chief/sub-demo","repo":"sub","description":"submodule tasklist",
  "iters":3,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":["src/US-1.txt"],"passes":false,"notes":""}] }
JSON
# Verify hook runs with cwd = the submodule (chief exports CHIEF_PROJECT=the sub).
cat > .chief/verify.sh <<'SH'
#!/usr/bin/env bash
set -eu
[ -f src/US-1.txt ] || { echo "verify: missing src/US-1.txt (cwd=$PWD)"; exit 1; }
echo "verify: submodule artifact present"
SH
chmod +x .chief/verify.sh
git add -A && git commit -q -m "sub-demo tasklist + verify hook"

# ── run ───────────────────────────────────────────────────────────────────────
PATH="$WORK/fakebin:$PATH" "$CHIEF" run >"$WORK/run.log" 2>&1 || { cat "$WORK/run.log"; fail "run exited non-zero"; }

# ── assert: code merged INTO the submodule's main, branch gone, no chief leak ──
git -C "$REPO/sub" checkout -q main
[ -f "$REPO/sub/src/US-1.txt" ]                                     || fail "submodule code not merged to submodule main"
case "$(git -C "$REPO/sub" log --oneline)" in *"Merge chief/sub-demo"*) ;; *) fail "no merge commit in the submodule" ;; esac
if git -C "$REPO/sub" rev-parse --verify -q chief/sub-demo >/dev/null; then fail "submodule branch not deleted after merge"; fi
if git -C "$REPO/sub" ls-files | grep -q '^\.chief/'; then fail ".chief/ bookkeeping leaked into the submodule branch"; fi
[ "$(git -C "$REPO/sub" rev-parse HEAD)" != "$sub_base" ]           || fail "submodule main did not advance"

# ── assert: project pointer bumped to the merged submodule sha + tasklist retired ──
git -C "$REPO" checkout -q main
[ -f "$REPO/tasks/chief/completed/sub-demo.json" ]                  || fail "tasklist not retired to completed/"
[ -n "$(jq -r '.mergedToMain // empty' "$REPO/tasks/chief/completed/sub-demo.json")" ] || fail "completed record missing mergedToMain"
[ ! -f "$REPO/tasks/chief/sub-demo.json" ]                          || fail "pending tasklist not removed"
subhead="$(git -C "$REPO/sub" rev-parse HEAD)"
ptr="$(git -C "$REPO" ls-tree main sub | awk '{print $3}')"
[ "$ptr" = "$subhead" ]                                             || fail "project pointer ($ptr) != submodule main HEAD ($subhead)"
case "$(git -C "$REPO" log --oneline)" in *"bump sub"*) ;; *) fail "no pointer-bump/retire commit on the project" ;; esac
# the project's own tree must carry NO source files — all real work lives in the submodule
if git -C "$REPO" ls-tree -r --name-only main | grep -q '^src/'; then fail "project tree wrongly holds submodule source"; fi

echo "SUBMODULE PASS — repo:<sub> tasklist: merged into the submodule, project pointer bumped, tasklist retired, no chief leak"
