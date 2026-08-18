#!/usr/bin/env bash
# test/submodule-gitlink.sh — a branch whose whole point is a SUBMODULE POINTER BUMP
# must be able to merge, and a submodule carrying real work must still block.
#
# Git does not move a submodule's working tree when a ref moves, so the instant a
# branch whose gitlink differs from the current one is checked out, `git status`
# reports ` M <sub>`. The merge phase reads that as "uncommitted tracked changes" and
# parks the tasklist REBASE-REFUSED — so a pin-bump branch is blocked by the very
# change it exists to make, on every run, forever. (Measured in chief-cloud on
# 2026-08-17: three consecutive refusals on a one-line bump, hand-merged in the end.)
#
# Section A drives the field case end to end: a project tasklist whose one story bumps
# the gitlink, through agent → merge, and asserts the operator's checkout is handed
# back HONEST (submodule at the merged sha, `git status` empty).
# Section B is the other half of the fix, and the reason it is not `--ignore-submodules`:
# a submodule with genuine uncommitted work inside it still refuses BOTH gates — the
# startup one and the merge one — and the human's edit is never touched.
# Fully offline; deterministic fake agent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=gl GIT_AUTHOR_EMAIL=gl@test GIT_COMMITTER_NAME=gl GIT_COMMITTER_EMAIL=gl@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
# file:// submodules are refused by default since git 2.38 (CVE-2022-39253); the engine
# clones/updates them with plain `git`, so the allowance has to reach it via the env.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
fail() { echo "SUBMODULE-GITLINK FAIL: $*" >&2; [ -f "$WORK/run.log" ] && tail -60 "$WORK/run.log" >&2; exit 1; }
has()  { grep -qF -- "$2" "$1" 2>/dev/null; }
command -v jq >/dev/null || fail "jq required"; command -v git >/dev/null || fail "git required"

# ── install chief from this checkout ──────────────────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# ── the dependency repo: three commits, each adding one file ──────────────────
DEPSRC="$WORK/depsrc"; mkdir -p "$DEPSRC"; cd "$DEPSRC"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
printf 'one\n' > a.txt; git add -A; git commit -q -m dep1; C1="$(git rev-parse HEAD)"
printf 'two\n' > b.txt; git add -A; git commit -q -m dep2; C2="$(git rev-parse HEAD)"
printf 'three\n' > c.txt; git add -A; git commit -q -m dep3; C3="$(git rev-parse HEAD)"
git checkout -q "$C1"     # the submodule is added at C1, so `add` clones the OLD pin

# ── the project: pins dep at C1 ───────────────────────────────────────────────
REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
git submodule add "file://$DEPSRC" dep >/dev/null 2>&1 || fail "submodule add failed"
git commit -q -m "add submodule dep @C1"
git -C "$REPO/dep" fetch -q origin "$C3" 2>/dev/null || git -C "$REPO/dep" fetch -q origin
git -C "$REPO/dep" cat-file -e "${C2}^{commit}" || fail "fixture: C2 not reachable in the submodule clone"
[ "$(git -C "$REPO" ls-tree main dep | awk '{print $3}')" = "$C1" ] || fail "fixture: project does not pin C1"
[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] || fail "fixture: project starts dirty"

"$CHIEF" init >/dev/null || fail "chief init failed"
rm -f tasks/chief/example.json

# The merge gate proves the SYNC, not just the merge: b.txt exists only at C2, and the
# hook runs with cwd = the work repo on the rebased branch. A stale submodule working
# tree (the bug) fails it; `--ignore-submodules` would have hidden the mismatch and
# left the gate reading a tree that does not match the ref it is about to merge.
cat > .chief/verify.sh <<'SH'
#!/usr/bin/env bash
set -eu
[ -f dep/b.txt ] || { echo "verify: submodule working tree is STALE (no dep/b.txt, cwd=$PWD)"; exit 1; }
echo "verify: submodule working tree matches the checked-out gitlink"
SH
chmod +x .chief/verify.sh
git add -A && git commit -q -m "chief init + verify hook"

# ── fake `claude`: bump the gitlink from the WORKTREE, where `dep` is an empty
#     directory (a project worktree never initializes submodules) — so the bump is
#     made against the index, exactly as `git add dep` would record it. ──────────
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null
PRD=".chief/state/prd.json"
name="$(jq -r '.branchName' "$PRD" | sed 's|^chief/||')"
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  git update-index --add --cacheinfo "160000,$DEP_NEW,dep"
  for f in "$PRD" "tasks/chief/$name.json"; do
    [ -f "$f" ] || continue
    t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id)|.passes)=true
      | (.userStories[]|select(.id==$id)|.notes)="gitlink bumped; verify green"' "$f" > "$t" && mv "$t" "$f"
    case "$f" in tasks/*) git add "$f" ;; esac
  done
  git commit -q -m "feat: $id - bump the dep pointer" >/dev/null 2>&1 || true
fi
[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

tasklist() {  # tasklist NAME
  cat > "$REPO/tasks/chief/$1.json" <<JSON
{ "project":"$1","branchName":"chief/$1","description":"advance the dep pointer",
  "iters":3,"dependsOn":[],"touches":["dep"],"warmup":[],
  "userStories":[{"id":"US-1","title":"bump dep","description":"","acceptanceCriteria":["the dep gitlink advances"],"passes":false,"notes":""}] }
JSON
  git -C "$REPO" add "tasks/chief/$1.json" && git -C "$REPO" commit -q -m "tasklist $1"
}

# ═══ A. the field case: a gitlink bump merges, unattended ══════════════════════
tasklist pin-bump
cd "$REPO"
DEP_NEW="$C2" PATH="$WORK/fakebin:$PATH" "$CHIEF" run >"$WORK/run.log" 2>&1 \
  || { cat "$WORK/run.log"; fail "run exited non-zero on a plain gitlink bump"; }

st="$(cat "$REPO/.chief/state/parallel/pin-bump.status" 2>/dev/null || echo MISSING)"
case "$st" in MERGED*) ;; *) fail "A: expected MERGED, got '$st'" ;; esac
ptr="$(git -C "$REPO" ls-tree main dep | awk '{print $3}')"
[ "$ptr" = "$C2" ]                                    || fail "A: main still pins $ptr, not the bumped $C2"
[ -f "$REPO/tasks/chief/completed/pin-bump.json" ]    || fail "A: tasklist not retired"
# The worker's own log, not the run log: run_worker redirects the merge phase into it.
wlog="$REPO/.chief/state/parallel/pin-bump.log"
has "$wlog" "synced submodule working tree"           || fail "A: the engine never announced a submodule sync"
has "$wlog" "verify: submodule working tree matches"  || fail "A: the gate did not run against a synced tree"
grep -qi "REFUSED" "$wlog" "$WORK/run.log"            && fail "A: something reported a refusal on a clean gitlink bump"
# The operator's checkout is handed back HONEST: submodule at the merged sha, so the
# next run's startup gate (and the next merge) do not trip over chief's own leftovers.
[ "$(git -C "$REPO/dep" rev-parse HEAD)" = "$C2" ]    || fail "A: the operator's submodule working tree was left stale"
[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ] \
  || fail "A: the run left the operator's checkout dirty: $(git -C "$REPO" status --short | tr '\n' ' ')"
[ -z "$(git -C "$REPO" stash list)" ]                 || fail "A: the run left a stash behind"

# ═══ B. genuine work INSIDE the submodule still blocks both gates ══════════════
tasklist pin-bump2
printf 'operator edit\n' >> "$REPO/dep/a.txt"          # uncommitted, in the submodule
sub_dirt_before="$(git -C "$REPO/dep" rev-parse HEAD):$(cat "$REPO/dep/a.txt")"

# B1 — the STARTUP gate names the condition and points at the submodule.
set +e
DEP_NEW="$C3" PATH="$WORK/fakebin:$PATH" "$CHIEF" run >"$WORK/gate.log" 2>&1
grc=$?
set -e
[ "$grc" != 0 ]                                          || fail "B1: a dirty submodule started a run"
has "$WORK/gate.log" "uncommitted tracked changes"       || fail "B1: the refusal does not name the condition: $(cat "$WORK/gate.log")"
has "$WORK/gate.log" "INSIDE that submodule"             || fail "B1: the refusal does not distinguish submodule work: $(cat "$WORK/gate.log")"
git -C "$REPO" rev-parse --verify -q chief/pin-bump2 >/dev/null && fail "B1: a refused startup still created the branch"

# B2 — FORCE=1 past the startup gate: the MERGE must still refuse, and say why.
DEP_NEW="$C3" FORCE=1 PATH="$WORK/fakebin:$PATH" "$CHIEF" run >"$WORK/run.log" 2>&1 || true
st="$(cat "$REPO/.chief/state/parallel/pin-bump2.status" 2>/dev/null || echo MISSING)"
case "$st" in REBASE-REFUSED*) ;; *) fail "B2: expected REBASE-REFUSED with dirt inside the submodule, got '$st'" ;; esac
case "$st" in *"INSIDE submodule"*) ;; *) fail "B2: the refusal does not name the submodule as the cause: $st" ;; esac
case "$st" in *"in the submodule itself"*) ;; *) fail "B2: the refusal does not name the fix: $st" ;; esac
ptr="$(git -C "$REPO" ls-tree main dep | awk '{print $3}')"
[ "$ptr" = "$C2" ]                                       || fail "B2: main pointer moved to $ptr despite the refusal"
[ "$(git -C "$REPO/dep" rev-parse HEAD):$(cat "$REPO/dep/a.txt")" = "$sub_dirt_before" ] \
  || fail "B2: the operator's uncommitted work inside the submodule was moved or lost"
[ -z "$(git -C "$REPO" stash list)" ]                    || fail "B2: the run left a stash behind"

# ═══ C. the fix is a SYNC, never a loosened check ══════════════════════════════
# `--ignore-submodules=dirty` would hide B's case (work inside a submodule) and would
# not even hide A's (a gitlink mismatch is not "dirty"), so it must not appear in the
# engine outside prose explaining why.
if grep -rn -- '--ignore-submodules' "$ROOT/engine" "$ROOT/bin" 2>/dev/null | grep -v ':[[:space:]]*#' | grep -q .; then
  fail "C: the engine suppresses submodule status instead of syncing the tree"
fi

echo "SUBMODULE-GITLINK PASS — a pin bump merges unattended (checkout left honest); work inside a submodule still blocks both gates and is never touched"
