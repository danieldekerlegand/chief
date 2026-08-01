#!/usr/bin/env bash
# test/retire-dirty-tasklist.sh — a completed tasklist must RETIRE even when the agent
# dirtied the project's copy of it.
#
# The failure this pins (seen in production): a submodule worktree has no tasks/ dir, so
# the agent reaches OUT of its worktree and flips pass-flags in the PROJECT's tracked
# tasklist. `git rm` then REFUSES to remove that file ("local modifications" —
# --ignore-unmatch does not cover it), and because the call was `2>/dev/null || true`
# the failure was silent: the completed record + pointer-bump committed, but the tasklist
# was never retired. It sat "pending" forever while is_recorded_done skipped it, so
# `chief run` reported it as still-to-do and it never ran again.
#
# Fixes under test: (1) an isolation guard restores the project's copy after the agent
# loop, and (2) the retire uses `git rm -f` so a dirty file is removed regardless.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=rd GIT_AUTHOR_EMAIL=rd@test GIT_COMMITTER_NAME=rd GIT_COMMITTER_EMAIL=rd@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
fail() { echo "RETIRE-DIRTY FAIL: $*" >&2; [ -f "$WORK/run.log" ] && tail -40 "$WORK/run.log" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

# ── install chief from this checkout ──────────────────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

REPO="$WORK/repo"

# ── fake `claude`: does REAL work, and ALSO dirties the PROJECT's tasklist copy ──
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<FAKE
#!/usr/bin/env bash
set -eu
cat >/dev/null
# cwd = the worktree. Do real work + flip flags in the worktree copies (legitimate).
mkdir -p out; printf 'impl\n' > out/US-1.txt
for f in .chief/state/prd.json tasks/chief/nw.json; do
  [ -f "\$f" ] || continue
  t="\$(mktemp)"; jq '.userStories |= map(.passes=true)' "\$f" > "\$t" && mv "\$t" "\$f"
done
git add -A >/dev/null 2>&1 || true
git commit -q -m "feat: US-1 - real work" >/dev/null 2>&1 || true
# THE LEAK: reach out of the worktree and dirty the PROJECT's tracked tasklist
# (uncommitted). This is what made the retire fail silently.
t="\$(mktemp)"; jq '.userStories |= map(.passes=true)' "$REPO/tasks/chief/nw.json" > "\$t" && mv "\$t" "$REPO/tasks/chief/nw.json"
echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── scaffold repo + a 1-story tasklist + a passing verify hook ─────────────────
mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null
rm -f tasks/chief/example.json
cat > tasks/chief/nw.json <<'JSON'
{ "project":"nw","branchName":"chief/nw","description":"retire-dirty",
  "iters":2,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":["out/US-1.txt"],"passes":false,"notes":""}] }
JSON
printf '#!/usr/bin/env bash\nset -eu\n[ -f out/US-1.txt ] || { echo "missing artifact"; exit 1; }\necho ok\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "setup"

# ── run ───────────────────────────────────────────────────────────────────────
PATH="$WORK/fakebin:$PATH" "$CHIEF" run >"$WORK/run.log" 2>&1 || { cat "$WORK/run.log"; fail "run exited non-zero"; }

# ── assert: merged AND retired, with a clean tree ─────────────────────────────
git checkout -q main
[ -f tasks/chief/completed/nw.json ]                            || fail "no completed record written"
[ -n "$(jq -r '.mergedToMain // empty' tasks/chief/completed/nw.json)" ] || fail "record has no mergedToMain"
[ ! -f tasks/chief/nw.json ]                                    || fail "TASKLIST NOT RETIRED — the dirty project copy blocked \`git rm\` (the bug)"
[ -z "$(git status --porcelain tasks/chief/)" ]                 || fail "project tasks/ left dirty after the run: $(git status --porcelain tasks/chief/)"
[ -f out/US-1.txt ]                                             || fail "real work not merged to main"
# and it must not resurface as pending on a re-run
case "$(PATH="$WORK/fakebin:$PATH" "$CHIEF" run -n 2>&1)" in *nw*) fail "retired tasklist still shows as pending" ;; *) ;; esac

echo "RETIRE-DIRTY PASS — agent dirtied the project's tasklist copy; it still merged, retired, and left a clean tree"
