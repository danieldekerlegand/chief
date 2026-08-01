#!/usr/bin/env bash
# test/version-bump.sh — an engine change must come with a VERSION bump.
#
# The failure this pins (hit in production): a behavioral fix landed on main WITHOUT
# bumping VERSION. Both the buggy and the fixed tree then reported the same version, so
# `chief update` looked like a no-op ("already 0.6.0") and the user had no way to tell
# which code they were actually running — they kept hitting a bug that was "fixed".
#
# Rule: if anything under engine/ (or bin/, scripts/, or install.sh) changed SINCE the
# last commit that touched VERSION, VERSION is stale. scripts/ counts because install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

last_ver_commit="$(git log -1 --format=%H -- VERSION 2>/dev/null || true)"
[ -n "$last_ver_commit" ] || { echo "VERSION-BUMP FAIL: no commit touches VERSION" >&2; exit 1; }

changed="$(git diff --name-only "$last_ver_commit"..HEAD -- engine/ bin/ scripts/ install.sh 2>/dev/null || true)"
if [ -n "$changed" ]; then
  {
    echo "VERSION-BUMP FAIL: shipped code changed since the last VERSION bump" \
         "($(git log -1 --format=%h "$last_ver_commit") — VERSION is $(cat VERSION)):"
    printf '    %s\n' $changed
    echo "  → bump VERSION so 'chief update' and 'chief version' are distinguishable."
  } >&2
  exit 1
fi

echo "VERSION-BUMP PASS — VERSION ($(cat VERSION)) covers every engine/bin change on HEAD"
