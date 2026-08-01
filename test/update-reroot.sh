#!/usr/bin/env bash
# test/update-reroot.sh — `chief update` (and a re-run of install.sh) must cross a
# force-pushed, RE-ROOTED origin history instead of silently freezing on the old version.
#
# THE FAILURE THIS PINS (hit in production). main was re-rooted — a fresh initial commit,
# a history UNRELATED to the old lineage — and force-pushed. Installs cloned from the old
# lineage share no common ancestor with the new main, so `git pull --ff-only` failed; both
# `chief update` and a re-run of install.sh swallowed that failure (`|| true`) and did
# nothing. `chief version` kept reporting the stale number with no error, and the user had
# no way to land the new engine short of deleting the checkout by hand.
#
# THE FIX. Both updaters now track the remote EXACTLY — `git reset --hard origin/<ver>` —
# which crosses unrelated roots. This test drives that end to end against real git repos:
# install at an old version on one root, force-push a new version on a DISJOINT root, then
# assert the install follows across the re-root. Hermetic: temp prefix/bindir, a bare
# file:// origin, no network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=ur GIT_AUTHOR_EMAIL=ur@test GIT_COMMITTER_NAME=ur GIT_COMMITTER_EMAIL=ur@test
command -v git >/dev/null || { echo "UPDATE-REROOT FAIL: git is required" >&2; exit 1; }
fail() { echo "UPDATE-REROOT FAIL: $*" >&2; exit 1; }

root_of() { git -C "$1" rev-list --max-parents=0 HEAD 2>/dev/null | tail -1; }

# ── a bare "origin" seeded from THIS checkout, pinned to an OLD version ───────────────
SEED="$WORK/seed"; ORIGIN="$WORK/origin.git"
git clone --quiet "$ROOT" "$SEED"  || fail "seed clone failed"
git -C "$SEED" checkout --quiet -B main
printf '0.0.1\n' > "$SEED/VERSION"
git -C "$SEED" commit --quiet -am "seed: old lineage v0.0.1"
git clone --quiet --bare "$SEED" "$ORIGIN" || fail "bare origin clone failed"

# ── install from that origin ─────────────────────────────────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
export CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN"
CHIEF_REPO="file://$ORIGIN" sh "$ROOT/install.sh" >/dev/null 2>&1 || fail "initial install failed"
CHIEF="$BIN/chief"
[ "$("$CHIEF" version)" = "chief 0.0.1" ] || fail "initial install not 0.0.1 (got '$("$CHIEF" version)')"
old_root="$(root_of "$PREFIX/src")"
[ -n "$old_root" ] || fail "could not read installed root"

# ── RE-ROOT origin: a fresh, UNRELATED history at a new version, force-pushed ─────────
NEW="$WORK/new"
git clone --quiet "$ROOT" "$NEW" || fail "new clone failed"
rm -rf "$NEW/.git"
git -C "$NEW" init --quiet -b main
printf '0.0.2\n' > "$NEW/VERSION"
git -C "$NEW" add -A
git -C "$NEW" commit --quiet -m "re-root: unrelated lineage v0.0.2"
new_root="$(root_of "$NEW")"
[ "$old_root" != "$new_root" ] || fail "test bug: roots identical — histories not disjoint"
git -C "$NEW" push --quiet --force "file://$ORIGIN" main || fail "force-push to origin failed"

# ── sanity: a plain ff-only pull CANNOT cross this (proves the scenario is real) ──────
if git -C "$PREFIX/src" fetch --quiet origin && git -C "$PREFIX/src" merge --ff-only --quiet origin/main 2>/dev/null; then
  fail "precondition broken: ff-only pull unexpectedly crossed the re-root"
fi

# ── the assertion: `chief update` follows across the re-root to 0.0.2 ─────────────────
"$CHIEF" update >/dev/null 2>&1 || fail "chief update exited non-zero"
[ "$("$CHIEF" version)" = "chief 0.0.2" ] || fail "chief update did NOT cross the re-root (still '$("$CHIEF" version)')"
[ "$(root_of "$PREFIX/src")" = "$new_root" ] || fail "install still on the old root after update"

# ── and a re-run of install.sh over the existing checkout stays correct ───────────────
CHIEF_REPO="file://$ORIGIN" sh "$ROOT/install.sh" >/dev/null 2>&1 || fail "install re-run failed"
[ "$("$CHIEF" version)" = "chief 0.0.2" ] || fail "install re-run regressed the version"

echo "UPDATE-REROOT PASS — chief update + install.sh re-run cross a force-pushed re-root (0.0.1 → 0.0.2)"
