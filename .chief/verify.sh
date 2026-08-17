#!/usr/bin/env bash
# .chief/verify.sh — Chief pre-merge verify hook for the chief repo (self-hosting).
#
# Chief runs this in the MERGE phase, after a tasklist's stories are done and its
# branch has been rebased onto the base. cwd = repo root, the finished branch is
# checked out. Exit 0 ALLOWS the merge; any non-zero BLOCKS it (the branch is left
# for re-engagement, status VERIFY-FAILED, output saved to
# .chief/state/snapshots/<name>.verify-failed.log). See docs/reference/verify-hook.md.
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
# CHIEF_VERIFY_TESTS=0 to skip the (slower) behavioral test subset while iterating,
# and CHIEF_VERIFY_QUALITY=0 to skip the code-quality ratchet the same way.
set -uo pipefail

BASE="${CHIEF_BASE_BRANCH:-main}"

changed="$(git diff --name-only "$BASE"...HEAD 2>/dev/null)"
if [ -z "$changed" ]; then
  echo "verify: no diff vs $BASE — nothing to check (allowing merge)"
  exit 0
fi

# --- documentation link gate -------------------------------------------------
# Every local doc reference must resolve. RATCHET, not a wall: it compares this
# branch against the base and blocks only a REGRESSION, so pre-existing rot is
# retired deliberately instead of blocking every merge from day one. Local refs
# only — an external URL checker fails for network reasons, and a gate that fails
# for reasons unrelated to the change is a gate that gets switched off.
# Set CHIEF_VERIFY_DOCLINKS=0 to skip while iterating.
if [ "${CHIEF_VERIFY_DOCLINKS:-1}" = 1 ] \
   && echo "$changed" | grep -qE '\.md$|^docs/' \
   && [ -f scripts/check-doc-links.mjs ] && command -v node >/dev/null 2>&1; then
  node scripts/check-doc-links.mjs --ratchet --base "${CHIEF_BASE_BRANCH:-main}" \
    || { echo "verify: doc-link regression (see above)"; exit 1; }
fi


say()     { echo "verify: $*"; }
block()   { say "BLOCK — $*"; exit 1; }
touches() { grep -qE "$1" <<<"$changed"; }

# ── 1) Code quality — the RATCHET (cheapest gate, so it runs first) ────────
# Everything below this block is a pass/fail test oracle: it answers "did the gates
# exit 0", which is blind to the damage that shows up in weeks rather than seconds
# (duplication, ballooning functions, deep nesting, helpers nobody reuses). This is
# the second, MEASURED axis — deterministic metrics on the branch compared against
# the same files at $BASE, blocking when one regressed past its tolerance. Nothing
# in it consults a model. Tolerances + the tracked set: .chief/quality.conf.
#
# WHY NO COMMITTED .chief/quality-baseline.json HERE. The whole-tree axis stays
# inactive for chief deliberately. Writing one would freeze this repo's current
# duplicate_blocks (68) and single_use_functions (93) as a zero-tolerance floor,
# and the next tasklist that adds a test/*.sh — they all share a ~6-line hermetic
# preamble — would be unmergeable through no fault of its own. The changed-file
# DELTA axis is the honest gate for a repo this shape; the cost is that files a
# branch creates have no base version and so go unmeasured here (announced in the
# gate's own header). Commit a baseline when the tree has been cleaned, not before.
if touches '^(bin/chief|.+\.(sh|bash|py|js|jsx|ts|tsx|go|rs|c|h|cc|cpp|java|rb))$'; then
  say "quality — ratchet (engine/quality.sh, deltas vs $BASE)"
  bash engine/quality.sh ratchet --base "$BASE" || block "code-quality ratchet: a tracked metric regressed (see above)"
fi

# ── 2) Shell engine — syntax (always) · shellcheck (if present) · behavior ──
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
  #
  # The block runs THROUGH test/bystander.sh, which stands up a run belonging to
  # another install — its own driver argv, its own $CHIEF_RUNS, its own worktree root,
  # all outside every prefix these tests mint — runs the list below, and fails the
  # moment one of them signals it. On 2026-08-17 this block killed live runs in three
  # sibling repos, so the guard is not hypothetical. It runs the block itself: nothing
  # here is paid for twice, and a failing test is named and its output streamed.
  if [ "${CHIEF_VERIFY_TESTS:-1}" = "1" ]; then
    say "behavioral — the hermetic subset, under the bystander guard (test/bystander.sh)"
    CHIEF_BYSTANDER_TESTS="smoke provider-conformance ratelimit limitstate limitresume limitmonitor pause plan-review liveliness teardown reapscope reapenv noworkguard evidence-gate criteria-scope measured-bars headless events container account-env stale-resume conflict-forensics rebase-refusal touches-audit quality-ratchet gen" \
      bash test/bystander.sh || block "behavioral tests failed (see above)"
  else
    say "behavioral tests skipped (CHIEF_VERIFY_TESTS=0)"
  fi
fi

# ── 3) Docs — README must not lag the engine (version string + command table) ─
# Cheap grep/sed/awk check, so it runs on any branch that could have caused the
# drift: a VERSION bump, a CLI surface change, or a README edit itself.
if touches '^(bin/|engine/|VERSION$|README\.md$)'; then
  say "docs — test/doc-sync.sh (README vs VERSION + bin/chief dispatch)"
  bash test/doc-sync.sh || block "README is out of sync with the engine"
fi

# ── 4) Tasklists — every changed tasks/chief/*.json must be valid JSON ──────
if touches '^tasks/chief/.+\.json$'; then
  say "tasklists — jq parse"
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    jq -e . "$f" >/dev/null 2>&1 || block "invalid JSON: $f"
  done < <(grep -E '^tasks/chief/.+\.json$' <<<"$changed")
fi

say "OK (allowing merge)"
exit 0
