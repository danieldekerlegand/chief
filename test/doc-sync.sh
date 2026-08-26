#!/usr/bin/env bash
# test/doc-sync.sh — the docs must not drift from the engine.
#
# The failure this pins (hit in production): on 2026-08-11 the README's version
# string and command table had to be re-synced BY HAND against VERSION and
# bin/chief (995263c). test/version-bump.sh already forces an engine change to
# bump VERSION — but nothing asserted the DOCS caught up, so the drift only
# surfaced when a human happened to audit the file.
#
# WHY ROADMAP.md IS IN HERE TOO (added by 114). The gate that shipped in 86
# covered README.md and deliberately stopped there — and ROADMAP.md is the file
# that then rotted. Audited 2026-08-25 it claimed "v0.8.0" beside a VERSION of
# 0.8.94, listed 12 of 22 subcommands, and was silent on 21 merged tasklists
# (`93`–`113`) — while README.md, which the gate DID cover, was correct on the
# version to the patch. A doc nobody checks is a doc that reverts to fiction at
# the portfolio's measured drift rate of about a fortnight, so the two checks
# that would EACH independently have caught this drift are now assertions:
# the roadmap's version claim, and its coverage of tasks/chief/completed/.
#
# Four assertions, all derived from the source of truth rather than a list:
#   1. every version README.md CLAIMS (a bold **vX.Y.Z**) equals VERSION;
#   2. every subcommand in bin/chief's dispatch `case "$cmd"` appears in the
#      README command-reference table (an alias arm like `monitor|watch` counts
#      as covered when its PRIMARY name is documented);
#   3. every version ROADMAP.md claims equals VERSION, by the same rule;
#   4. every merged tasklist stem in tasks/chief/completed/ is named somewhere
#      in ROADMAP.md — a band that shipped and the roadmap never recorded is
#      exactly the invisibility 114 was opened to end.
#
# Hermetic by construction: grep/sed/awk/basename over tracked files in this
# checkout. No network, no agent, no model, no ~/.chief access, no writes
# outside a temp dir. The temp dir exists only for the negative self-checks at
# the end, which doctor COPIES of the two docs to prove each assertion actually
# fails on drift.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Overridable so the negative self-checks can point the same logic at doctored
# copies. Unset in normal use — the real tree is the default.
README="${DOC_SYNC_README:-$ROOT/README.md}"
VERSION_FILE="${DOC_SYNC_VERSION:-$ROOT/VERSION}"
CLI="${DOC_SYNC_CLI:-$ROOT/bin/chief}"
ROADMAP="${DOC_SYNC_ROADMAP:-$ROOT/ROADMAP.md}"
COMPLETED="${DOC_SYNC_COMPLETED:-$ROOT/tasks/chief/completed}"

fails=0
fail() { echo "DOC-SYNC FAIL: $*" >&2; fails=$((fails + 1)); }

for f in "$README" "$VERSION_FILE" "$CLI" "$ROADMAP"; do
  [ -f "$f" ] || { echo "DOC-SYNC FAIL: missing $f" >&2; exit 1; }
done

version="$(tr -d '[:space:]' < "$VERSION_FILE")"
[ -n "$version" ] || { echo "DOC-SYNC FAIL: $VERSION_FILE is empty" >&2; exit 1; }

# Only BOLD occurrences count as a claim about the current version; a plain
# `v0.4.1` inside an example (CHIEF_VERSION=v0.4.1 chief update) is not one.
# Shared by README and ROADMAP so the two can never drift apart in RULE as well
# as in value — LABEL is what the operator reads in the failure.
version_claims_ok() {
  local file="$1" label="$2" claimed c
  claimed="$(grep -oE '\*\*v[0-9]+\.[0-9]+\.[0-9]+\*\*' "$file" | tr -d '*v' | sort -u)"
  if [ -z "$claimed" ]; then
    fail "$label states no version — expected a bold **v$version** naming the current release"
    return
  fi
  for c in $claimed; do
    [ "$c" = "$version" ] && continue
    fail "$label claims version **v$c** but VERSION is $version ($(basename "$file"))"
  done
}

# ── 1) Version claims ────────────────────────────────────────────────────────
version_claims_ok "$README" README
version_claims_ok "$ROADMAP" ROADMAP

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

# ── 3) Roadmap coverage of the merged program ────────────────────────────────
# A record in completed/ means that tasklist MERGED. The roadmap has to name it
# — anywhere: a phase row, its branch, its prose. Matching the STEM (not a
# number) is what makes the check cheap and unambiguous: `93` matches a merge
# sha or a line count, `93-dirty-checkout-merge-safety` matches only itself.
neg_stem=""
merged=0
for f in "$COMPLETED"/*.json; do
  [ -f "$f" ] || continue
  stem="$(basename "$f" .json)"
  merged=$((merged + 1))
  [ -n "$neg_stem" ] || neg_stem="$stem"
  grep -qF -- "$stem" "$ROADMAP" && continue
  fail "$(basename "$ROADMAP") never names merged tasklist '$stem' — it shipped and the roadmap does not record it"
done

# ── 4) Negative self-checks ──────────────────────────────────────────────────
# Prove the assertions above can actually fail: re-run this script against
# doctored COPIES of the docs and require a non-zero exit naming the drift.
# A gate nobody has watched fail is indistinguishable from one that always
# passes. DOC_SYNC_NEGATIVE marks the child runs so they don't recurse.
if [ "$fails" -eq 0 ] && [ -z "${DOC_SYNC_NEGATIVE:-}" ]; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/doc-sync.XXXXXX")" || exit 1
  trap 'rm -rf "$tmp"' EXIT

  # (a) a README claiming a version VERSION does not carry
  sed -E 's/\*\*v[0-9]+\.[0-9]+\.[0-9]+\*\*/**v9.9.9**/' "$README" > "$tmp/version.md"
  out="$(DOC_SYNC_NEGATIVE=1 DOC_SYNC_README="$tmp/version.md" bash "$ROOT/test/doc-sync.sh" 2>&1)"
  if [ $? -eq 0 ] || ! grep -q 'README claims version \*\*v9.9.9\*\*' <<<"$out"; then
    fail "negative self-check: a README claiming **v9.9.9** did not trip the version assertion"
  fi

  # (b) a README whose table lost a row for a real subcommand
  grep -v '`chief init`' "$README" > "$tmp/table.md"
  out="$(DOC_SYNC_NEGATIVE=1 DOC_SYNC_README="$tmp/table.md" bash "$ROOT/test/doc-sync.sh" 2>&1)"
  if [ $? -eq 0 ] || ! grep -q "dispatches 'init'" <<<"$out"; then
    fail "negative self-check: a README missing the 'chief init' row did not trip the coverage assertion"
  fi

  # (c) a ROADMAP claiming a version VERSION does not carry — the 2026-08-25
  #     drift itself (**v0.8.0** beside a VERSION of 0.8.94), reproduced.
  sed -E 's/\*\*v[0-9]+\.[0-9]+\.[0-9]+\*\*/**v9.9.9**/' "$ROADMAP" > "$tmp/roadmap-version.md"
  out="$(DOC_SYNC_NEGATIVE=1 DOC_SYNC_ROADMAP="$tmp/roadmap-version.md" bash "$ROOT/test/doc-sync.sh" 2>&1)"
  if [ $? -eq 0 ] || ! grep -q 'ROADMAP claims version \*\*v9.9.9\*\*' <<<"$out"; then
    fail "negative self-check: a ROADMAP claiming **v9.9.9** did not trip the version assertion"
  fi

  # (d) a ROADMAP that lost every mention of a merged tasklist — the OTHER half
  #     of the 2026-08-25 drift (21 shipped bands invisible), reproduced on one.
  if [ -n "$neg_stem" ]; then
    grep -vF -- "$neg_stem" "$ROADMAP" > "$tmp/roadmap-stem.md"
    out="$(DOC_SYNC_NEGATIVE=1 DOC_SYNC_ROADMAP="$tmp/roadmap-stem.md" bash "$ROOT/test/doc-sync.sh" 2>&1)"
    if [ $? -eq 0 ] || ! grep -q "never names merged tasklist '$neg_stem'" <<<"$out"; then
      fail "negative self-check: a ROADMAP missing every mention of '$neg_stem' did not trip the coverage assertion"
    fi
  else
    fail "negative self-check: no records in $COMPLETED — the roadmap-coverage assertion was never exercised"
  fi
fi

[ "$fails" -eq 0 ] || {
  echo "  → sync README.md (version string + command-reference table) and ROADMAP.md" >&2
  echo "    (version string + a row for every tasks/chief/completed/ record) with the engine." >&2
  exit 1
}

[ -n "${DOC_SYNC_NEGATIVE:-}" ] && exit 0
echo "DOC-SYNC PASS — README and ROADMAP state v$version; README documents every bin/chief subcommand; ROADMAP names all $merged merged tasklists"
