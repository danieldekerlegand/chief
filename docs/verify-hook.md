# The verify hook (`.chief/verify.sh`)

Chief calls this to decide whether a completed, rebased branch may merge. It's the
one place your project's real quality bar lives.

**Contract:**
- Runs with **cwd = repo root**, the finished branch **checked out**, after a rebase
  onto the base.
- `$CHIEF_BASE_BRANCH` is exported (the base branch name).
- **Exit 0 = allow the merge. Non-zero = block it** (the branch is left for review,
  marked `VERIFY-FAILED`).
- If `CHIEF_VERIFY` is unset/empty in `.chief/config`, verification is skipped.

**Keep it fast and focused** — gate only on what the branch changed:

```bash
#!/usr/bin/env bash
set -uo pipefail
changed="$(git diff --name-only "$CHIEF_BASE_BRANCH"...HEAD)"
[ -z "$changed" ] && exit 0

if echo "$changed" | grep -q '^web/';    then (cd web && npm test)         || exit 1; fi
if echo "$changed" | grep -q '^api/';    then (cd api && uv run pytest -q) || exit 1; fi
if echo "$changed" | grep -q '\.go$';    then go build ./... && go test ./... || exit 1; fi
exit 0
```

## Baselining against the base (optional but recommended)

If your repo has failures that pre-exist on the base (flaky tests, drifted
generated files), a strict pass/fail will wrongly block good branches. Baseline
instead: run the check on the branch; if it fails, run the *same* check on
`$CHIEF_BASE_BRANCH` and fail only on the **new** failures. Pattern:

```bash
new_failures() { comm -23 <(printf '%s\n' "$1"|sort -u) <(printf '%s\n' "$2"|sort -u); }
# branch_failures=... ; git stash; git checkout "$CHIEF_BASE_BRANCH"; base_failures=... ; git checkout -
# [ -z "$(new_failures "$branch_failures" "$base_failures")" ] || exit 1
```

(The extraction this tool came from ships a full baselined verify — copy that
approach if your suite is noisy.)
