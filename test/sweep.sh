#!/usr/bin/env bash
# test/sweep.sh — the build-artifact sweep refuses everything it should refuse.
#
# engine/sweep.sh deletes directories. The only reason that is safe is that the
# decision to delete one is a PURE function of three paths — root, worktree,
# candidate — and this file is where that function meets the paths designed to fool
# it. The shape that matters most is a shared build cache (`CARGO_TARGET_DIR`) that
# several live runs are compiling into: reached by absolute path, by a symlink
# planted inside the worktree, or by `..` — every one of which must come back
# REFUSED with a stated reason rather than deleted.
#
# Hermetic: a temp tree, no chief install, no processes. It sources the module out
# of THIS WORKING TREE on purpose (the behavioural suite installs from HEAD, which
# cannot see an uncommitted engine edit).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
fail() { echo "SWEEP FAIL: $*" >&2; nfail=$(( nfail + 1 )); }
ok()   { pass=$(( pass + 1 )); }

# shellcheck source=/dev/null
. "$ROOT/engine/sweep.sh" || { echo "SWEEP FAIL: cannot source engine/sweep.sh" >&2; exit 1; }

# ── the fixture ──────────────────────────────────────────────────────────────
# $WTS is chief's worktree root; $WT is one run's worktree. $SHARED is the cache
# that belongs to nobody here and must survive every case below.
WTS="$WORK/worktrees"; WT="$WTS/repo-123/tl-a"
SHARED="$WORK/shared/target"      # a shared CARGO_TARGET_DIR, as several live runs would use
mkdir -p "$WT/target/debug" "$WT/crates/inner/node_modules/dep" "$WT/.venv/lib" \
         "$WT/src" "$WT/.git" "$WTS/repo-123/tl-b/target" "$WTS/repo-123-evil/target" \
         "$SHARED/debug" "$WORK/not-chief/tl/target"
echo x > "$WT/target/debug/blob"; echo y > "$SHARED/debug/blob"
ln -s "$SHARED" "$WT/crates/shared-target-link"
ln -s "$SHARED" "$WT/build"                     # a build dir that IS a link out

# expect EXPECTED-VERDICT  DESCRIPTION  ROOT WT PATH
expect() {
  local want="$1" what="$2"; shift 2
  local got; got="$(chief_sweep_candidate "$1" "$2" "$3")"
  case "$got" in
    "$want"|"$want "*) ok ;;
    *) fail "$what: expected '$want', got '$got'" ;;
  esac
}

# ── 1. what MUST be swept ────────────────────────────────────────────────────
expect sweep "a cargo target inside the worktree"     "$WTS" "$WT" "$WT/target"
expect sweep "a nested node_modules"                  "$WTS" "$WT" "$WT/crates/inner/node_modules"
expect sweep "a python .venv"                         "$WTS" "$WT" "$WT/.venv"

# ── 2. the shared-cache hazard — three ways in, all refused ──────────────────
expect "refuse outside-worktree" "the shared cache by absolute path" "$WTS" "$WT" "$SHARED"
expect "refuse symlink"          "a symlinked build/ pointing at the shared cache" "$WTS" "$WT" "$WT/build"
expect "refuse unknown-artifact" "a symlink whose NAME is not in the table"        "$WTS" "$WT" "$WT/crates/shared-target-link"
expect "refuse outside-worktree" "an escape via .."   "$WTS" "$WT" "$WT/../tl-b/target"

# ── 3. scoping — another worktree, another root, a prefix near-miss ──────────
expect "refuse outside-worktree"     "a SIBLING worktree's target"      "$WTS" "$WT" "$WTS/repo-123/tl-b/target"
expect "refuse not-a-chief-worktree" "a worktree chief did not create"  "$WTS" "$WORK/not-chief/tl" "$WORK/not-chief/tl/target"
# The prefix near-miss: "$WTS/repo-123-evil" starts with "$WTS/repo-123" as a STRING.
expect "refuse outside-worktree" "a path whose prefix merely looks contained" \
       "$WTS" "$WTS/repo-123" "$WTS/repo-123-evil/target"

# ── 4. arguments that are not paths at all ───────────────────────────────────
expect "refuse empty-argument"   "an empty candidate"   "$WTS" "$WT" ""
expect "refuse empty-argument"   "an empty root"        "" "$WT" "$WT/target"
expect "refuse relative-path"    "a relative candidate" "$WTS" "$WT" "target"
expect "refuse unknown-artifact" "source code"          "$WTS" "$WT" "$WT/src"
expect "refuse missing"          "a target that is not there"    "$WTS" "$WT" "$WT/crates/target"
expect "refuse worktree-missing" "a worktree that is not there"  "$WTS" "$WTS/repo-123/gone" "$WTS/repo-123/gone/target"

# A symlinked WORKTREE is refused whole — containment judged against a directory the
# operator chose is not containment.
ln -s "$WT" "$WTS/repo-123/tl-link"
expect "refuse worktree-is-a-symlink" "a symlinked worktree" "$WTS" "$WTS/repo-123/tl-link" "$WTS/repo-123/tl-link/target"

# ── 5. the sweep itself: bytes reported, shared cache untouched ──────────────
out="$(chief_sweep_worktree "$WTS" "$WT" tl-a -n)"
case "$out" in *"would reclaim"*) ok ;; *) fail "dry run reported nothing: $out" ;; esac
case "$out" in *"REFUSED to sweep $WT/build"*) ok ;; *) fail "dry run did not report the refused symlink: $out" ;; esac
[ -f "$WT/target/debug/blob" ] && ok || fail "dry run DELETED $WT/target"

out="$(chief_sweep_worktree "$WTS" "$WT" tl-a)"
case "$out" in *reclaimed*target*) ok ;; *) fail "sweep reported no reclaim: $out" ;; esac
case "$out" in *' B of build artifacts'*|*' KB of build artifacts'*|*' MB of build artifacts'*) ok ;;
  *) fail "sweep reported no byte total: $out" ;; esac
[ -d "$WT/target" ] && fail "sweep left $WT/target behind" || ok
[ -d "$WT/crates/inner/node_modules" ] && fail "sweep left the nested node_modules" || ok
[ -f "$SHARED/debug/blob" ] && ok || fail "SWEEP DELETED THE SHARED CACHE"
[ -L "$WT/build" ] && ok || fail "sweep followed/removed the symlinked build/"
[ -d "$WT/src" ] && ok || fail "sweep removed source code"
[ -d "$WTS/repo-123/tl-b/target" ] && ok || fail "sweep reached into a sibling worktree"

# CHIEF_SWEEP=0 is the operator's off switch.
mkdir -p "$WT/target"; echo z > "$WT/target/blob"
CHIEF_SWEEP=0 chief_sweep_worktree "$WTS" "$WT" tl-a >/dev/null
[ -f "$WT/target/blob" ] && ok || fail "CHIEF_SWEEP=0 still swept"

# A worktree chief did not create is never touched, end to end.
chief_sweep_worktree "$WTS" "$WORK/not-chief/tl" other >/dev/null
[ -d "$WORK/not-chief/tl/target" ] && ok || fail "swept a worktree chief did not create"

echo "sweep: $pass passed, $nfail failed"
[ "$nfail" -eq 0 ] || exit 1
