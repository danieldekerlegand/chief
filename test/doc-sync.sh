#!/usr/bin/env bash
# test/doc-sync.sh — the README must not drift from the engine.
#
# The failure this pins (hit in production): on 2026-08-11 the README's version
# string and command table had to be re-synced BY HAND against VERSION and
# bin/chief (995263c). test/version-bump.sh already forces an engine change to
# bump VERSION — but nothing asserted the DOCS caught up, so the drift only
# surfaced when a human happened to audit the file.
#
# Two assertions, both derived from the source of truth rather than a list:
#   1. every version the README CLAIMS (a bold **vX.Y.Z**) equals VERSION;
#   2. every subcommand in bin/chief's dispatch `case "$cmd"` appears in the
#      README command-reference table (an alias arm like `monitor|watch` counts
#      as covered when its PRIMARY name is documented).
#
# Hermetic by construction: grep/sed/awk over tracked files in this checkout.
# No network, no agent, no ~/.chief access, no writes outside a temp dir. The
# temp dir exists only for the negative self-check at the end, which doctors a
# COPY of the README to prove the script actually fails on drift.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Overridable so the negative self-check can point the same logic at a doctored
# copy. Unset in normal use — the real tree is the default.
README="${DOC_SYNC_README:-$ROOT/README.md}"
VERSION_FILE="${DOC_SYNC_VERSION:-$ROOT/VERSION}"
CLI="${DOC_SYNC_CLI:-$ROOT/bin/chief}"

fails=0
fail() { echo "DOC-SYNC FAIL: $*" >&2; fails=$((fails + 1)); }

for f in "$README" "$VERSION_FILE" "$CLI"; do
  [ -f "$f" ] || { echo "DOC-SYNC FAIL: missing $f" >&2; exit 1; }
done

# ── 1) Version claims ────────────────────────────────────────────────────────
# Only BOLD occurrences count as a claim about the current version; a plain
# `v0.4.1` inside an example (CHIEF_VERSION=v0.4.1 chief update) is not one.
version="$(tr -d '[:space:]' < "$VERSION_FILE")"
[ -n "$version" ] || { echo "DOC-SYNC FAIL: $VERSION_FILE is empty" >&2; exit 1; }

claimed="$(grep -oE '\*\*v[0-9]+\.[0-9]+\.[0-9]+\*\*' "$README" | tr -d '*v' | sort -u)"
if [ -z "$claimed" ]; then
  fail "README states no version — expected a bold **v$version** naming the current release"
else
  for c in $claimed; do
    [ "$c" = "$version" ] && continue
    fail "README claims version **v$c** but VERSION is $version" \
         "(README: $(basename "$README"))"
  done
fi

# ── 2) Command coverage ──────────────────────────────────────────────────────
# Roster from the dispatch table itself: the arms between `case "$cmd" in` and
# its `esac`. `*)` (the unknown-command arm) never matches the label pattern.
roster="$(
  awk '/^case "\$cmd" in/ { in_case = 1; next }
       in_case && /^esac/  { in_case = 0 }
       in_case             { print }' "$CLI" \
  | sed -n 's/^[[:space:]]*\([A-Za-z0-9|_-]*\))[[:space:]].*/\1/p'
)"
[ -n "$roster" ] || { echo "DOC-SYNC FAIL: no subcommands parsed from $CLI — has the dispatch moved?" >&2; exit 1; }

# Documented = every `chief <sub>` named in a table row. One row may name more
# than one (`chief version` · `chief help`), so scan occurrences, not lines.
documented="$(grep -E '^\|' "$README" | grep -oE '`chief [a-z][a-z-]*' | sed 's/`chief //' | sort -u)"

for arm in $roster; do
  primary="${arm%%|*}"
  case "$primary" in -*) continue ;; esac   # flag-only arm (-v/--version): not a subcommand
  if ! grep -qx -- "$primary" <<<"$documented"; then
    fail "bin/chief dispatches '$primary' but the README command-reference table never documents it"
  fi
done

# ── 3) Negative self-check ───────────────────────────────────────────────────
# Prove the assertions above can actually fail: re-run this script against
# doctored COPIES of the README and require a non-zero exit naming the drift.
# DOC_SYNC_NEGATIVE marks the child runs so they don't recurse.
if [ "$fails" -eq 0 ] && [ -z "${DOC_SYNC_NEGATIVE:-}" ]; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/doc-sync.XXXXXX")" || exit 1
  trap 'rm -rf "$tmp"' EXIT

  # (a) a README claiming a version VERSION does not carry
  sed -E 's/\*\*v[0-9]+\.[0-9]+\.[0-9]+\*\*/**v9.9.9**/' "$README" > "$tmp/version.md"
  out="$(DOC_SYNC_NEGATIVE=1 DOC_SYNC_README="$tmp/version.md" bash "$ROOT/test/doc-sync.sh" 2>&1)"
  if [ $? -eq 0 ] || ! grep -q 'claims version \*\*v9.9.9\*\*' <<<"$out"; then
    fail "negative self-check: a README claiming **v9.9.9** did not trip the version assertion"
  fi

  # (b) a README whose table lost a row for a real subcommand
  grep -v '`chief init`' "$README" > "$tmp/table.md"
  out="$(DOC_SYNC_NEGATIVE=1 DOC_SYNC_README="$tmp/table.md" bash "$ROOT/test/doc-sync.sh" 2>&1)"
  if [ $? -eq 0 ] || ! grep -q "dispatches 'init'" <<<"$out"; then
    fail "negative self-check: a README missing the 'chief init' row did not trip the coverage assertion"
  fi
fi

[ "$fails" -eq 0 ] || {
  echo "  → sync README.md with the engine (version string + command-reference table)." >&2
  exit 1
}

[ -n "${DOC_SYNC_NEGATIVE:-}" ] && exit 0
echo "DOC-SYNC PASS — README states v$version and documents every bin/chief subcommand"
