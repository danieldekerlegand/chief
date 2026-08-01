#!/usr/bin/env bash
# .chief/verify.sh — Chief pre-merge verify hook for the chief repo (self-hosting).
#
# Chief runs this in the MERGE phase, after a tasklist's stories are done and its
# branch has been rebased onto the base. cwd = repo root, the finished branch is
# checked out. Exit 0 ALLOWS the merge; any non-zero BLOCKS it (the branch is left
# for re-engagement, status VERIFY-FAILED, output saved to
# .chief/state/snapshots/<name>.verify-failed.log). See docs/verify-hook.md.
#
# Contract facts this script depends on:
#   - Invoked with NO argv; the base branch is $CHIEF_BASE_BRANCH (default main),
#     the branch under test is the checked-out HEAD. Diff scope: "$BASE"...HEAD.
#   - This file MUST stay executable — a non-executable hook returns 1 and blocks
#     every merge (it does not skip).
#   - A tasklist that carries its own "verify":[...] array bypasses this hook.
#   - STRICT_VERIFY / NO_VERIFY are exported in; NO_VERIFY=1 skips verify upstream.
#
# Gates are scoped to what the branch actually changed, cheapest-first. Only
# engine-touching tasklists pay for the shell lint + behavioral tests. Set
# CHIEF_VERIFY_TESTS=0 to skip the (slower) behavioral test subset while iterating.
set -uo pipefail

BASE="${CHIEF_BASE_BRANCH:-main}"

changed="$(git diff --name-only "$BASE"...HEAD 2>/dev/null)"
if [ -z "$changed" ]; then
  echo "verify: no diff vs $BASE — nothing to check (allowing merge)"
  exit 0
fi

say()     { echo "verify: $*"; }
block()   { say "BLOCK — $*"; exit 1; }
touches() { grep -qE "$1" <<<"$changed"; }

# ── 1) Shell engine — syntax (always) · shellcheck (if present) · behavior ──
if touches '^(bin/chief|engine/.+\.sh|install\.sh|templates/.+\.sh|test/.+\.sh)$'; then
  say "shell — bash -n"
  for f in bin/chief engine/*.sh install.sh templates/*.sh test/*.sh; do
    [ -f "$f" ] || continue
    bash -n "$f" || block "bash -n failed: $f"
  done

  if command -v shellcheck >/dev/null 2>&1; then
    say "shell — shellcheck -S error"
    shellcheck -S error bin/chief engine/*.sh install.sh test/*.sh templates/verify.sh || block "shellcheck errors"
  else
    say "shellcheck not installed — skipping (CI enforces it)"
  fi

  # VERSION discipline: an engine/bin/install change must bump VERSION.
  if touches '^(bin/|engine/|install\.sh)'; then
    say "policy — VERSION bump (test/version-bump.sh)"
    bash test/version-bump.sh || block "VERSION not bumped for an engine change"
  fi

  # Behavioral core: the hermetic CI subset (fake claude, temp prefixes — no ~/.chief
  # pollution). monitor.sh is deliberately excluded here (timing-sensitive under the
  # parallel load verify runs beneath); CI still covers it and the full suite.
  if [ "${CHIEF_VERIFY_TESTS:-1}" = "1" ]; then
    for t in smoke ratelimit limitstate limitresume limitmonitor pause liveliness teardown reapscope reapenv noworkguard stale-resume conflict-forensics touches-audit; do
      say "behavioral — test/$t.sh"
      bash "test/$t.sh" || block "test/$t.sh failed"
    done
  else
    say "behavioral tests skipped (CHIEF_VERIFY_TESTS=0)"
  fi
fi

# ── 2) Tasklists — every changed tasks/chief/*.json must be valid JSON ──────
if touches '^tasks/chief/.+\.json$'; then
  say "tasklists — jq parse"
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    jq -e . "$f" >/dev/null 2>&1 || block "invalid JSON: $f"
  done < <(grep -E '^tasks/chief/.+\.json$' <<<"$changed")
fi

say "OK (allowing merge)"
exit 0
