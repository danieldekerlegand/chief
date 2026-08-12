#!/usr/bin/env bash
# .chief/verify.sh — Chief verification hook.
#
# Chief runs this after a tasklist's stories are done and its branch has been
# rebased onto the base. Return 0 to ALLOW the merge, non-zero to BLOCK it (the
# branch is left for review). Runs with cwd = repo root, the finished branch
# checked out; $CHIEF_BASE_BRANCH names the base (use it to baseline if you want).
#
# Replace the body with your project's real checks (build + tests + lint).
set -uo pipefail

changed="$(git diff --name-only "$CHIEF_BASE_BRANCH"...HEAD)"
[ -z "$changed" ] && { echo "verify: no diff vs $CHIEF_BASE_BRANCH"; exit 0; }

# --- EDIT ME: run the checks relevant to what the branch changed ---
# make test        || exit 1
# npm test         || exit 1
# uv run pytest -q || exit 1

# --- OPTIONAL: the code-quality RATCHET (a second, MEASURED axis) -------------
# The checks above are a pass/fail test oracle — they answer "did the gates exit
# 0", which is blind to maintainability damage. Tests come back in seconds;
# duplication, ballooning functions, deep nesting and helpers nobody reuses show
# up in weeks. `chief quality ratchet` measures those deterministically (awk over
# text — no model judgment, no network) on the files this branch changed, compares
# them against the SAME files at $CHIEF_BASE_BRANCH, and exits non-zero when a
# tracked metric regressed past its tolerance. It is a RATCHET, not a threshold:
# your repo's existing complexity is never held against it, only what a branch adds.
#
# OFF BY DEFAULT ON PURPOSE. Turning a gate on for a brownfield repo the moment
# `chief init` runs is how a gate gets disabled permanently instead of adopted.
# Bootstrap it deliberately:
#
#   1. Look at the numbers first, block on nothing:
#        chief quality measure --changed "$CHIEF_BASE_BRANCH" | jq .totals
#   2. Turn on the delta axis by uncommenting the line below. This alone gates
#      every file the branch MODIFIED, and needs no baseline file.
#   3. OPTIONAL, once the tree is in a shape you'd defend: add the whole-tree
#      floor, which also covers files a branch CREATES (the delta axis cannot —
#      a new file has no base version to regress from):
#        chief quality ratchet --write-baseline    # writes .chief/quality-baseline.json
#        git add .chief/quality-baseline.json && git commit -m 'chore: quality baseline'
#      Re-run --write-baseline to re-baseline; committing the result is the
#      explicit, reviewable escape hatch. Skip this step while the tree is messy —
#      a floor you can't hold is worse than no floor.
#   4. Tune the tracked metrics + tolerances in .chief/quality.conf (created by
#      `chief init`). Dropping a metric is a visible edit to a tracked file; there
#      is deliberately no implicit way to switch one off.
#
# CHIEF_VERIFY_QUALITY=0 skips just this gate while iterating locally;
# NO_VERIFY=1 bypasses the whole hook. Full contract: docs/verify-hook.md.
#
# chief quality ratchet --base "$CHIEF_BASE_BRANCH" || exit 1

echo "verify: no checks configured yet — edit .chief/verify.sh (allowing merge)"
exit 0
