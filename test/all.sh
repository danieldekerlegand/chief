#!/usr/bin/env bash
# test/all.sh — the whole-repo test entry point (run everything, one command).
#
# CI (.github/workflows/ci.yml) and .chief/verify.sh both run PATH-SCOPED subsets:
# CI enumerates the shell tests, verify.sh only pays for what a branch touched. This
# is the un-scoped counterpart — the single command a developer runs to prove the
# entire tree, both halves of the codebase at once:
#
#     integration test).
#
# which wraps it in a canary $HOME/$TMPDIR to prove the real driver it spawns never
# driving that slow, real-engine suite twice; a guard asserts the target still
# exists so the skip can never silently drop coverage.
#
# (install.sh git-clones) — commit your changes before trusting a green run. Cargo
# (never a fail), because the bash engine must stay testable on a host without Rust.
# implement→verify→merge) — budget several minutes. Offline and deterministic.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pass=0 fail=0 skip=0
declare -a FAILED=()

hr() { printf '━%.0s' {1..72}; echo; }
note() { echo "all: $*"; }

# Run one bash test; record the outcome. A test that `exit 0`s with a SKIP note
# itself there was nothing to assert; only a non-zero exit is a failure.
run_sh() {
  local t="$1" path="$ROOT/test/$1.sh"
  [ -x "$path" ] || { note "MISSING test/$1.sh — skipping"; skip=$((skip+1)); return; }
  hr; note "test/$1.sh"; hr
  if bash "$path"; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); FAILED+=("test/$1.sh")
  fi
}

# ── 1. The bash engine + packaging suite ─────────────────────────────────────
# Order mirrors CI (cheap/behavioral first), then the cross-repo and packaging
BASH_SUITE=(
  smoke provider provider-conformance ratelimit limitstate limitresume limitmonitor pause plan-review research liveliness monitor teardown reapscope reapenv bystander noworkguard evidence-gate criteria-scope measured-bars five-cases noworkguard-jsononly headless events container account-env
  stale-resume conflict-forensics rebase-refusal touches-audit
  quality-ratchet
  gen doc-sync
  crossrepo submodule nested-submodule nested-submodule-pointer retry-on-failure per-tasklist-verify retire-dirty-tasklist
  version-bump
)
for t in "${BASH_SUITE[@]}"; do run_sh "$t"; done


# ── 2. Verdict ───────────────────────────────────────────────────────────────
hr
note "$pass passed, $fail failed, $skip skipped"
if [ "$fail" -ne 0 ]; then
  printf 'all: FAILED — %s\n' "${FAILED[*]}" >&2
  exit 1
fi
note "OK — the whole repo is green"
