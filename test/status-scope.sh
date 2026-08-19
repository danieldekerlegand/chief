#!/usr/bin/env bash
# test/status-scope.sh — `chief status` from a PARENT directory: the portfolio scope.
#
# THE POINT OF THIS TEST. US-1 made status honest about one repo's backlog by running
# the scheduler's own gate. This is the arithmetic that sits on top of it, and the
# failure mode is entirely different: not a wrong verdict but a wrong COUNT — a repo
# counted twice, a fixture counted as a backlog, a repo silently absent. A portfolio
# total is a number an operator cannot check by eye, so every way the walk can miscount
# is pinned here, each one a trap that exists in the real tree this was written against:
#
#   nesting     chief/examples/minimal/tasks/chief is a FIXTURE. A naive
#               `find -path '*/tasks/chief'` finds it and reports chief twice.
#   worktrees   a worktree is a full copy, .chief/config and all. Relocate
#               CHIEF_WORKTREE_ROOT under the scanned tree and every in-flight
#               tasklist is counted twice unless the guard is explicit.
#   identity    the registry may spell a repo with a trailing slash, or through a
#               symlink. Either mints a phantom second repo unless both sides are
#               reconciled by RESOLVED ABSOLUTE PATH.
#   exclusion   an operator must be able to drop a subtree (the AutomatedRetailAssociates
#               case) without editing the walk — and an excluded repo must be REPORTED
#               as excluded, because a repo that vanishes reads as a repo with no work.
#   staleness   a registry entry whose repo is gone must be named, not dropped.
#
# Every assertion is on the ARITHMETIC, not on prose: the TOTAL row must equal the sum
# of the per-repo rows, and each trap must move that total by exactly the amount it is
# worth. A cosmetic change to the table cannot make this test pass vacuously.
#
# Hermetic: scaffolded git repos in a temp dir, its own CHIEF_PREFIX/CHIEF_REPOS/
# CHIEF_WORKTREE_ROOT. No agent runs — discovery and counting only.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=scope GIT_AUTHOR_EMAIL=scope@test \
       GIT_COMMITTER_NAME=scope GIT_COMMITTER_EMAIL=scope@test
# Hermetic in STATE: our own prefix (which is where the ignore file lives), our own
# registry, and a worktree root we deliberately relocate INSIDE the scanned tree.
export CHIEF_PREFIX="$WORK/prefix" CHIEF_REPOS="$WORK/prefix/repos"
mkdir -p "$CHIEF_PREFIX"
CHIEF="$ROOT/bin/chief"
fail() { echo "SCOPE FAIL: $*" >&2; exit 1; }
has()  { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

command -v jq >/dev/null || fail "jq is required"

DEV="$WORK/dev"                       # the "parent directory like ~/Development"
export CHIEF_WORKTREE_ROOT="$DEV/worktrees"   # relocated UNDER the scanned tree, on purpose

# ── fixture ──────────────────────────────────────────────────────────────────
# `chief init` self-registers, which would put EVERY fixture repo in the registry and
# make the walk/registry reconciliation untestable. Scaffolding writes to a scratch
# registry instead; the real one is composed by hand below, one entry per case.
mkrepo() {   # $1 = path — a chief-initialized git repo with no tasklists
  mkdir -p "$1" || fail "mkdir $1"
  ( cd "$1" || exit 1
    export CHIEF_REPOS="$WORK/scratch-repos"
    git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
    git commit -q --allow-empty -m init
    "$CHIEF" init >/dev/null 2>&1 || exit 1
    rm -f tasks/chief/example.json ) || fail "could not scaffold $1"
}
tasklist() {   # $1 = repo, $2 = name, $3 = extra JSON merged in
  jq -n --arg n "$2" --argjson x "$3" \
    '{project:"t",branchName:("chief/"+$n),description:"x",iters:1,dependsOn:[],touches:[],warmup:[],
      userStories:[{id:"US-1",title:"t",description:"",acceptanceCriteria:["x"],passes:false,notes:""}]} + $x' \
    > "$1/tasks/chief/$2.json" || fail "could not write $2 in $1"
}

# alpha: 3 remaining (2 live, 1 parked). Plus a NESTED fixture repo of its own, with a
# tasklist of its own — the examples/minimal trap. It must contribute nothing.
mkrepo "$DEV/alpha"
tasklist "$DEV/alpha" 10-a '{}'; tasklist "$DEV/alpha" 11-a '{}'
tasklist "$DEV/alpha" 12-a '{"parked":true}'
mkrepo "$DEV/alpha/examples/minimal"
tasklist "$DEV/alpha/examples/minimal" 90-fixture '{}'

# beta: 1 remaining. Reached by the registry through a SYMLINK and a trailing slash.
mkrepo "$DEV/beta"
tasklist "$DEV/beta" 20-b '{}'
ln -s "$DEV/beta" "$DEV/beta-link" || fail "symlink"

# gamma: 2 remaining, in a subtree the operator wants excluded (AutomatedRetailAssociates).
mkrepo "$DEV/out/gamma"
tasklist "$DEV/out/gamma" 30-g '{}'; tasklist "$DEV/out/gamma" 31-g '{}'

# delta: 4 remaining, in a directory the WALK skips (node_modules) but the REGISTRY
# knows about — the reconciliation case that is not merely a duplicate.
mkrepo "$DEV/node_modules/delta"
for n in 40-d 41-d 42-d 43-d; do tasklist "$DEV/node_modules/delta" "$n" '{}'; done

# A dot-directory the walk must never descend into, holding a repo with work in it.
mkrepo "$DEV/.cache/hidden"
tasklist "$DEV/.cache/hidden" 50-h '{}'

# The worktree trap: a full copy of alpha, complete with alpha's tasklists, living
# under the relocated CHIEF_WORKTREE_ROOT inside the scanned tree.
mkrepo "$CHIEF_WORKTREE_ROOT/alpha-abc123/10-a"
tasklist "$CHIEF_WORKTREE_ROOT/alpha-abc123/10-a" 10-a '{}'

# THE REGISTRY, composed deliberately — three entries, three distinct cases:
#   beta, spelled through a symlink AND with a trailing slash — the walk finds it too,
#     so it is the "found both ways, counted once" case;
#   node_modules/delta — a real repo the walk prunes, so reconciliation is the ONLY
#     thing that can put it in the report;
#   vanished — an entry whose repo is gone, which must be named as stale.
# Nothing else is registered, so `.cache/hidden` is reachable by the walk alone and
# tests the dot-directory prune rather than the registry.
{ printf '%s/\n' "$DEV/beta-link"; printf '%s\n' "$DEV/node_modules/delta"; \
  printf '%s\n' "$DEV/vanished"; } > "$CHIEF_REPOS"

status() { ( cd "$1" && shift && "$CHIEF" status "$@" 2>&1 ); }

# Table readers. The table is whitespace-aligned — label, then the six counts, then
# the source — and it is BOUNDED: it starts at the header row and ends at the rule
# above TOTAL. The bound is not cosmetic. The scope notes below the table ("worktrees
# 1", "excluded 1", "stale 1") are also "a word then a number", so an unbounded sum
# over numeric second fields would quietly fold the skipped repos back into the total
# this test exists to check.
tab() { printf '%s\n' "$1" | awk '
  $1=="repo" && $2=="remaining" { t=1; next }
  t && $1 ~ /^-+$/              { t=0; next }
  t                             { print }'; }
row()       { tab "$1" | awk -v l="$2" '$1==l { print $2; exit }'; }   # remaining
source_of() { tab "$1" | awk -v l="$2" '$1==l { print $NF; exit }'; }
total()     { printf '%s\n' "$1" | awk '$1=="TOTAL" { print $2; exit }'; }

# ── 1. The walk, from a directory that is NOT a chief project ────────────────
OUT="$(status "$DEV")"; rc=$?
[ "$rc" = 0 ] || fail "chief status from a parent directory exited $rc:
$OUT"
case "$OUT" in *"no .chief/config found"*) fail "status went through load_project's hard exit:
$OUT" ;; esac
has "scope:" "$OUT" || fail "the header does not state the scope:
$OUT"
has "$DEV"   "$OUT" || fail "the header does not name what the totals cover:
$OUT"

for r in alpha beta; do
  [ -n "$(row "$OUT" "$r")" ] || fail "$r missing from the per-repo table:
$OUT"
done

# ── 2. Nesting: a repo is one whose ROOT the walk finds ─────────────────────
has "examples/minimal" "$OUT" && fail "the nested fixture repo was reported as a separate backlog:
$OUT"
[ "$(row "$OUT" alpha)" = 3 ] || fail "alpha should have 3 remaining, got '$(row "$OUT" alpha)' — the nested fixture leaked into it:
$OUT"

# ── 3. Dot-directories are not walked ───────────────────────────────────────
has ".cache/hidden" "$OUT" && fail "the walk descended into a dot-directory:
$OUT"

# ── 4. Worktrees cannot corrupt a count ─────────────────────────────────────
has "worktrees" "$OUT"     || fail "the worktree guard did not report what it skipped:
$OUT"
has "alpha-abc123" "$OUT"  || fail "the skipped worktree is not named — a silent skip is unauditable:
$OUT"
tab "$OUT" | awk '$1 ~ /alpha-abc123/ { exit 1 }' \
  || fail "a worktree was counted as a repo in the table:
$OUT"

# ── 5. Identity: symlink + trailing slash + walk = ONE repo ─────────────────
has "beta-link" "$OUT" && fail "a symlinked registry spelling minted a phantom second repo:
$OUT"
[ "$(tab "$OUT" | awk '$1=="beta"' | wc -l | tr -d ' ')" = 1 ] \
  || fail "beta appears more than once in the table:
$OUT"
[ "$(source_of "$OUT" beta)" = both ] \
  || fail "beta was found by BOTH the walk and the registry but its source reads '$(source_of "$OUT" beta)':
$OUT"
[ "$(source_of "$OUT" alpha)" = walk ] || [ "$(source_of "$OUT" alpha)" = both ] \
  || fail "alpha's source is not attributed: '$(source_of "$OUT" alpha)'"

# ── 6. Reconciliation adds what the walk alone would miss ──────────────────
[ "$(row "$OUT" node_modules/delta)" = 4 ] \
  || fail "a registry repo the walk prunes was dropped instead of reconciled in:
$OUT"
[ "$(source_of "$OUT" node_modules/delta)" = registry ] \
  || fail "a registry-only repo is not attributed to the registry:
$OUT"

# ── 7. THE ARITHMETIC: TOTAL is the sum of the rows, and it is the right sum ─
sum="$(tab "$OUT" | awk '$2 ~ /^[0-9]+$/ { s += $2 } END { print s+0 }')"
[ "$(total "$OUT")" = "$sum" ] \
  || fail "TOTAL ($(total "$OUT")) is not the sum of the per-repo rows ($sum):
$OUT"
# alpha 3 + beta 1 + out/gamma 2 + node_modules/delta 4 = 10. The fixture repo (1),
# the dot-dir repo (1) and the worktree copy (1) are each excluded for their own
# reason; any one of them leaking makes this 11 or more.
[ "$(total "$OUT")" = 10 ] || fail "portfolio remaining should be 10, got $(total "$OUT"):
$OUT"

# ── 8. Exclusion: a subtree drops out, and SAYS it dropped out ──────────────
printf '# the operator considers this out of scope\n%s\n' "$DEV/out" > "$CHIEF_PREFIX/ignore"
EX="$(status "$DEV")"
has "excluded" "$EX"  || fail "an ignored subtree was not reported as excluded:
$EX"
has "out/gamma" "$EX" || fail "the excluded repo vanished instead of being named — indistinguishable from an empty one:
$EX"
tab "$EX" | awk '$1=="out/gamma" { exit 1 }' \
  || fail "an excluded repo is still in the counted table:
$EX"
[ "$(total "$EX")" = 8 ] \
  || fail "excluding gamma must drop the total by exactly its 2 tasklists (10 -> 8), got $(total "$EX"):
$EX"

# ── 9. Staleness ────────────────────────────────────────────────────────────
ALL="$( cd "$WORK" && "$CHIEF" status --all 2>&1 )"; rc=$?
[ "$rc" = 0 ] || fail "chief status --all exited $rc:
$ALL"
has "registry" "$ALL"  || fail "--all does not say the registry produced the scope:
$ALL"
has "stale" "$ALL"     || fail "--all did not report the registry entry whose repo is gone:
$ALL"
has "vanished" "$ALL"  || fail "--all did not NAME the stale registry entry:
$ALL"
# --all is cwd-independent: run from a directory with no repos under it at all.
has "beta" "$ALL" || fail "--all did not report a registry repo from an unrelated cwd:
$ALL"

# ── 10. Inside a repo it is still US-1's single-repo report ────────────────
IN="$( cd "$DEV/alpha" && "$CHIEF" status 2>&1 )"; rc=$?
[ "$rc" = 0 ] || fail "chief status inside a repo exited $rc:
$IN"
has "this repo" "$IN" || fail "inside a repo the scope is not stated as this repo:
$IN"
has "remaining" "$IN" || fail "the single-repo report did not render:
$IN"
has "10-a" "$IN"      || fail "the single-repo report lists no tasklists:
$IN"
has "TOTAL" "$IN"     && fail "inside a repo status rendered a portfolio table:
$IN"

echo "SCOPE PASS — the walk finds repo ROOTS, reconciles with the registry by resolved path, and never double-counts"
