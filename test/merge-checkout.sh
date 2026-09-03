#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test/merge-checkout.sh — THE BASE CHECKOUT IS PART OF THE MERGE
# ---------------------------------------------------------------------------
# The merge phase ends `git checkout <base>` then `git merge --no-ff <branch>`. If the
# checkout fails, HEAD is still on the BRANCH — and merging a branch into itself prints
# "Already up to date." and exits ZERO. Unguarded, the merge site read that as success:
#
#     >> alpha acquired merge lock after 0x2s
#     >> verifying chief/alpha (rebased)
#     Already up to date.
#       !! branch kept: chief/alpha is not an ancestor of main (unmerged work)
#     >> alpha MERGED @f19d300            <-- f19d300 is the BRANCH tip, not a merge
#
# `finalize_merged` then wrote the completed record and the retire commit onto the
# FEATURE BRANCH; main never moved, `completed/` never got a record, and the run summary
# said done. Observed for real in test/merge-batch.sh PART A, whose `retired` assertion
# was the only thing that noticed — the status file said MERGED.
#
# Why the checkout failed is the second half. The project index is SHARED: sibling
# workers mutate it from the reconcile step's isolation guard and from finalize_merged,
# and a checkout that loses that race dies with `Unable to create '.git/index.lock'`
# and rc 128. main's reflog proved it was transient — no base-checkout entry at all,
# then the EXIT trap's identical checkout landing first time seconds later.
#
# So there are two claims and this file asserts BOTH, deterministically, by holding a
# real `.git/index.lock` across the base checkout with a `git` shim:
#
#   PART A — TRANSIENT. The lock is held for ONE attempt. work_checkout retries, the
#            tasklist merges and retires normally. This is the flake, closed.
#   PART B — PERSISTENT. The lock is held for every attempt. The tasklist ends
#            CHECKOUT-FAILED with NOTHING merged — no merge commit on the base, no
#            completed/ record, and above all no retire commit stranded on the branch.
#            An honest stop, never a false MERGED.
#
# Hermetic: a scripted fake `claude` and a `git` shim on PATH, temp prefixes; never
# touches the real ~/.chief. Drives bin/chief out of this checkout, so it tests
# uncommitted work.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rc=$?; rm -rf "$WORK"; exit "$rc"' EXIT
export GIT_AUTHOR_NAME=oz GIT_AUTHOR_EMAIL=oz@test GIT_COMMITTER_NAME=oz GIT_COMMITTER_EMAIL=oz@test
export CHIEF_PREFIX="$WORK/ch" CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
unset CHIEF_MERGE_BATCH CHIEF_MERGE_BATCH_WAIT MERGE_BATCH MERGE_BATCH_WAIT \
      CHIEF_DIFF_BUDGET CHIEF_ZONES CHIEF_CHECKOUT_RETRIES 2>/dev/null || true
export RETRY_MAX=1
CHIEF="$ROOT/bin/chief"
LOG=""
fail() { echo "MERGE-CHECKOUT FAIL: $*" >&2; [ -n "$LOG" ] && [ -f "$LOG" ] && tail -60 "$LOG" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"
# Resolved BEFORE the shim goes on PATH, or the shim would exec itself.
REAL_GIT="$(command -v git)"; export REAL_GIT
export OZ_WORK="$WORK"

mkdir -p "$WORK/fakebin"

# ── the fake agent: one story, one artifact, one commit ──────────────────────
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
PRD=".chief/state/prd.json"
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"; TRACKED="tasks/chief/$name.json"
cat >/dev/null
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
[ -n "$id" ] || exit 0
mkdir -p "out/$name"; printf 'artifact %s\n' "$id" > "out/$name/$id.txt"
for f in "$PRD" "$TRACKED"; do
  [ -f "$f" ] || continue
  t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id)|.passes)=true
    | (.userStories[]|select(.id==$id)|.notes)="artifact written; verify green"' "$f" > "$t" && mv "$t" "$f"
done
git add -A >/dev/null 2>&1 || true
git commit -q -m "feat: [$id] - story $id of $name" >/dev/null 2>&1 || true
[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── the git shim: hold a REAL index.lock across `checkout <base>` ─────────────
# Faithful rather than simulated — it reproduces the exact contention the engine
# loses to, and git's own rc/stderr are what the engine sees. Armed by a sentinel
# file whose contents say how long the lock is held:
#   once   — removed on the first hit, so the retry finds a clean repo (PART A)
#   always — every attempt loses (PART B)
# Anything else git does — including `checkout -- <path>` and `checkout <branch>` —
# passes straight through.
cat > "$WORK/fakebin/git" <<'SHIM'
#!/usr/bin/env bash
sent="$OZ_WORK/lock-base"
if [ -f "$sent" ] && [ $# -ge 2 ] && [ "${*: -2:1}" = "checkout" ] && [ "${*: -1}" = "$(cat "$OZ_WORK/base")" ]; then
  repo="."; [ "${1:-}" = "-C" ] && repo="${2:-.}"
  gd="$("$REAL_GIT" -C "$repo" rev-parse --git-dir 2>/dev/null || echo "$repo/.git")"
  case "$gd" in /*) ;; *) gd="$repo/$gd" ;; esac
  [ "$(cat "$sent")" = once ] && rm -f "$sent"
  : > "$gd/index.lock"
  "$REAL_GIT" "$@"; rc=$?
  rm -f "$gd/index.lock"
  echo "shim: held $gd/index.lock across 'checkout $(cat "$OZ_WORK/base")' (rc=$rc)" >> "$OZ_WORK/shim.log"
  exit $rc
fi
exec "$REAL_GIT" "$@"
SHIM
chmod +x "$WORK/fakebin/git"
printf 'main' > "$WORK/base"

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  ( cd "$repo"
    git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
    git commit -q --allow-empty -m init
    "$CHIEF" init >/dev/null
    rm -f tasks/chief/example.json
    printf '#!/usr/bin/env bash\nexit 0\n' > .chief/verify.sh; chmod +x .chief/verify.sh
    jq -n '{ project:"oz", branchName:"chief/solo", description:"base-checkout fixture",
             iters:3, dependsOn:[], touches:["domain-solo"], warmup:[],
             userStories:[ { id:"US-1", title:"story of solo", description:"",
                             acceptanceCriteria:["out/solo/US-1.txt exists"], passes:false, notes:"" } ] }' \
      > tasks/chief/solo.json
    git add -A && git commit -q -m setup )
}

status()  { cat "$1/.chief/state/parallel/solo.status" 2>/dev/null || echo MISSING; }
retired() { [ -f "$1/tasks/chief/completed/solo.json" ]; }
merges()  { ( cd "$1" && git log main --oneline | grep -c 'Merge chief/solo' ) || true; }
# THE CORRUPTION SIGNATURE: finalize_merged's record+retire commit sitting on the
# feature branch instead of on the base. Nothing else in the engine writes it there.
stranded() { ( cd "$1" && git log chief/solo --oneline 2>/dev/null | grep -c 'complete @' ) || true; }

# ══ PART A — TRANSIENT: one lost race is retried, and the tasklist still merges ══
echo "merge-checkout: PART A — a base checkout that loses ONE index.lock race is retried"
REPO_A="$WORK/transient"
make_repo "$REPO_A"
printf 'once' > "$WORK/lock-base"; : > "$WORK/shim.log"
LOG="$WORK/a.log"
( cd "$REPO_A" && PATH="$WORK/fakebin:$PATH" POLL_SECONDS=1 "$CHIEF" run ) >"$LOG" 2>&1 \
  || fail "PART A: chief run exited non-zero"
[ -s "$WORK/shim.log" ] || fail "PART A: the shim never fired — the fixture proved nothing"
case "$(status "$REPO_A")" in MERGED*) ;; *) fail "PART A: solo is $(status "$REPO_A"), expected MERGED" ;; esac
retired "$REPO_A" || fail "PART A: solo was not retired to completed/"
[ "$(merges "$REPO_A")" = 1 ] || fail "PART A: expected 1 merge commit on main, got $(merges "$REPO_A")"
echo "merge-checkout: PART A ok — retried, merged, retired ($(wc -l < "$WORK/shim.log" | tr -d ' ') lost race)"

# ══ PART B — PERSISTENT: no checkout, therefore no merge, and it SAYS so ═══════
echo "merge-checkout: PART B — a base checkout that never succeeds merges NOTHING"
REPO_B="$WORK/persistent"
make_repo "$REPO_B"
printf 'always' > "$WORK/lock-base"; : > "$WORK/shim.log"
LOG="$WORK/b.log"
( cd "$REPO_B" && PATH="$WORK/fakebin:$PATH" POLL_SECONDS=1 "$CHIEF" run ) >"$LOG" 2>&1 \
  || fail "PART B: chief run exited non-zero"
rm -f "$WORK/lock-base"
[ -s "$WORK/shim.log" ] || fail "PART B: the shim never fired — the fixture proved nothing"
case "$(status "$REPO_B")" in
  CHECKOUT-FAILED*) ;;
  MERGED*) fail "PART B: solo reported $(status "$REPO_B") on a base checkout that never happened" ;;
  *) fail "PART B: solo is $(status "$REPO_B"), expected CHECKOUT-FAILED" ;;
esac
[ "$(merges "$REPO_B")" = 0 ] || fail "PART B: main carries $(merges "$REPO_B") merge commit(s) after a failed checkout"
retired "$REPO_B" && fail "PART B: solo was retired to completed/ without merging"
[ "$(stranded "$REPO_B")" = 0 ] || fail "PART B: a record+retire commit was stranded on chief/solo (the base never moved)"
grep -q '>> solo MERGED' "$LOG" && fail "PART B: the run reported solo MERGED"
grep -q 'could not check out\|could not check out main' "$LOG" \
  || grep -q 'CHECKOUT-FAILED' "$REPO_B/.chief/state/parallel/solo.status" \
  || fail "PART B: the failure was not named anywhere a human reads"
echo "merge-checkout: PART B ok — CHECKOUT-FAILED, base untouched, nothing retired, nothing stranded"

echo "MERGE-CHECKOUT PASS — the base checkout is retried when it loses a shared-index race, and a merge is NEVER reported on a checkout that did not happen"
