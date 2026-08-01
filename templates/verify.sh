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
echo "verify: no checks configured yet — edit .chief/verify.sh (allowing merge)"
exit 0
