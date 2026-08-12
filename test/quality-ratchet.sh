#!/usr/bin/env bash
# test/quality-ratchet.sh — THE CODE-QUALITY RATCHET (tasklist 88, US-3).
#
# Every other gate in .chief/verify.sh is a pass/fail test oracle. This one is the
# measured axis, and the property that makes it worth having is not "it computes
# numbers" — it is that the numbers MOVE THE MERGE DECISION in the right direction.
# So this asserts the decision, not the record:
#
#   1. BLOCKED   a branch that adds a deeply-nested, duplicated block regresses a
#                tracked metric — and the message names the metric, both values,
#                the tolerance and the offending file, so an operator can act on it
#                without rerunning anything.
#   2. ALLOWED   refactoring that same block away improves the metric back.
#   3. UNMEASURED  a language with no function analyzer is reported as unmeasured
#                and SKIPPED by the ratchet — never scored 0, never silently passed.
#                (A vanished metric reads to a ratchet as "nothing got worse", which
#                is the failure mode this whole tool exists to avoid.)
#   4. SKIP      CHIEF_VERIFY_QUALITY=0 skips the gate, like CHIEF_VERIFY_TESTS=0.
#   5. VISIBLE   dropping a metric from .chief/quality.conf disables it — an edit to
#                a tracked file, which is the only way to switch one off.
#
# Hermetic: a scratch git repo in a temp dir, this checkout's engine/quality.sh and
# bin/chief run in place. No install, no network, no agent, no ~/.chief access.
# --no-lint everywhere so a host with (or without) shellcheck reaches the same verdict.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/quality-ratchet.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=qr GIT_AUTHOR_EMAIL=qr@test GIT_COMMITTER_NAME=qr GIT_COMMITTER_EMAIL=qr@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"     # hermetic: never touch ~/.chief
REPO="$WORK/repo"

fails=0
fail() { echo "QUALITY-RATCHET FAIL: $*" >&2; fails=$((fails + 1)); }
command -v jq  >/dev/null || { echo "QUALITY-RATCHET FAIL: jq is required" >&2; exit 1; }
command -v git >/dev/null || { echo "QUALITY-RATCHET FAIL: git is required" >&2; exit 1; }

# Run the ratchet in $REPO and capture output + exit code. Sets $out / $rc.
ratchet() {
  out="$(cd "$REPO" && bash "$ROOT/engine/quality.sh" ratchet --base main --no-lint --no-baseline "$@" 2>&1)"
  rc=$?
}

# ── 1. A base commit: one shell file with a shallow, unduplicated body ────────
mkdir -p "$REPO" && cd "$REPO" || exit 1
git init -q -b main . || { echo "QUALITY-RATCHET FAIL: git init" >&2; exit 1; }
mkdir -p .chief
cat > app.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

greet() {
  echo "hello $1"
}

main() {
  greet "$@"
}
main "$@"
SH
# Present on the BASE too: the delta axis only speaks about files that exist on both
# sides, so a language assertion needs a before-state to be about anything at all.
cat > lib.rb <<'RB'
def alpha(x)
  puts x
end
RB
git add -A >/dev/null && git commit -qm base

# ── 2. A branch that adds a deeply-nested, DUPLICATED block → BLOCKED ─────────
# Three copies of the same 8-line body, each buried five levels deep. This is the
# canonical shape the tool exists to catch: it type-checks, it runs, every test
# stays green, and it is unambiguously worse code.
git checkout -q -b slop
cat > app.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

greet() {
  echo "hello $1"
}

handle_a() {
  if [ -n "$1" ]; then
    for x in 1 2 3; do
      if [ "$x" = "2" ]; then
        while true; do
          if [ -z "${SKIP:-}" ]; then
            echo "step one $x"
            echo "step two $x"
            echo "step three $x"
            echo "step four $x"
            echo "step five $x"
            echo "step six $x"
            echo "step seven $x"
          fi
          break
        done
      fi
    done
  fi
}

handle_b() {
  if [ -n "$1" ]; then
    for x in 1 2 3; do
      if [ "$x" = "2" ]; then
        while true; do
          if [ -z "${SKIP:-}" ]; then
            echo "step one $x"
            echo "step two $x"
            echo "step three $x"
            echo "step four $x"
            echo "step five $x"
            echo "step six $x"
            echo "step seven $x"
          fi
          break
        done
      fi
    done
  fi
}

handle_c() {
  if [ -n "$1" ]; then
    for x in 1 2 3; do
      if [ "$x" = "2" ]; then
        while true; do
          if [ -z "${SKIP:-}" ]; then
            echo "step one $x"
            echo "step two $x"
            echo "step three $x"
            echo "step four $x"
            echo "step five $x"
            echo "step six $x"
            echo "step seven $x"
          fi
          break
        done
      fi
    done
  fi
}

main() {
  greet "$@"
  handle_a "$@"
  handle_b "$@"
  handle_c "$@"
}
main "$@"
SH
git add -A >/dev/null && git commit -qm slop

ratchet
[ "$rc" = "1" ] || fail "a deeply-nested duplicated block was ALLOWED (rc=$rc) — the ratchet is not gating
--- output
$out"

# The block message must be actionable on its own: metric, both values, tolerance,
# offending file. An operator who has to rerun the tool to learn what broke has been
# given a red light, not a diagnosis.
grep -q 'BLOCK  duplicate_blocks'  <<<"$out" || fail "block output never names duplicate_blocks
--- output
$out"
grep -q 'BLOCK  max_nesting_depth' <<<"$out" || fail "block output never names max_nesting_depth
--- output
$out"
grep -qE 'BLOCK  duplicate_blocks +base 0 -> branch [0-9]+ \(delta \+[0-9.]+, tolerance 0\)' <<<"$out" \
  || fail "the duplicate_blocks line does not carry base, branch, delta and tolerance
--- output
$out"
grep -q 'top contributors' <<<"$out" || fail "block output names no contributing files
--- output
$out"
grep -q 'app\.sh' <<<"$out" || fail "block output never names the offending file app.sh
--- output
$out"
grep -q 'quality: BLOCKED' <<<"$out" || fail "no BLOCKED verdict line
--- output
$out"

# ── 3. Refactoring it away → ALLOWED ─────────────────────────────────────────
# Same three call sites, one shared helper, nesting flattened by early return. Every
# tracked metric holds or improves, so the ratchet must get out of the way — a gate
# that cannot be satisfied by doing the right thing is a gate people disable.
git checkout -q -b clean main
cat > app.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

greet() {
  echo "hello $1"
}

run_steps() {
  local x="$1" i
  for i in one two three four five six seven; do
    echo "step $i $x"
  done
}

handle() {
  [ -n "$1" ] || return 0
  [ -z "${SKIP:-}" ] || return 0
  run_steps 2
}

main() {
  greet "$@"
  handle "$@"
}
main "$@"
SH
git add -A >/dev/null && git commit -qm refactor

ratchet
[ "$rc" = "0" ] || fail "the refactor that REMOVED the duplication was BLOCKED (rc=$rc)
--- output
$out"
grep -q 'quality: OK' <<<"$out" || fail "the refactor produced no OK verdict
--- output
$out"
# Not one BLOCK line anywhere — the refactor must clear every tracked metric, not
# just the two the slop branch tripped.
grep -q 'BLOCK' <<<"$out" && fail "the refactor tripped a metric
--- output
$out"
grep -qE 'ok +duplicate_blocks +0 -> 0' <<<"$out" \
  || fail "the shared helper did not bring duplicate_blocks back to zero
--- output
$out"

# And the same shape measured directly against the SLOP branch is a strict
# improvement on every axis the slop branch broke — the ratchet is monotone, so
# "allowed" must mean the numbers really came back down, not that the base moved.
sout="$(cd "$REPO" && bash "$ROOT/engine/quality.sh" measure -q --no-lint app.sh)"
sdup="$(jq -r '.totals.duplicate_blocks' <<<"$sout")"
snest="$(jq -r '.totals.max_nesting_depth' <<<"$sout")"
[ "$sdup" = "0" ] || fail "refactored file still has $sdup duplicate block(s)"
[ "$snest" -le 2 ] 2>/dev/null || fail "refactored file still nests $snest deep (slop was 6)"

# ── 4. A language with NO analyzer → UNMEASURED, not 0 ───────────────────────
# Ruby has no function analyzer. The function family must be reported as unmeasured
# with a reason and SKIPPED by the ratchet. Scoring it 0 would let a branch that
# added a 400-line Ruby method read as an improvement over a base that had none.
git checkout -q -b ruby main
cat > lib.rb <<'RB'
def alpha(x)
  puts x
  puts x
end

def beta(y)
  puts y
end
RB
git add -A >/dev/null && git commit -qm 'grow ruby'

rec="$WORK/ruby.json"
(cd "$REPO" && bash "$ROOT/engine/quality.sh" measure -q --no-lint lib.rb -o "$rec") \
  || fail "measure failed on a ruby file"
if [ -s "$rec" ]; then
  jq -e '.unmeasured | map(select(.language == "ruby")) | length > 0' "$rec" >/dev/null \
    || fail "ruby is not reported in unmeasured[]
--- record
$(cat "$rec")"
  jq -e '.unmeasured | map(select(.metric == "functions" and .language == "ruby" and (.reason|length) > 0)) | length == 1' "$rec" >/dev/null \
    || fail "the ruby 'functions' metric carries no unmeasured entry with a reason"
  jq -e '.totals.functions == null' "$rec" >/dev/null \
    || fail "an unmeasurable function count was emitted as a number instead of null — a ratchet reads that as 'nothing got worse'"
fi

ratchet
[ "$rc" = "0" ] || fail "the ruby branch was blocked on a metric nobody can measure (rc=$rc)
--- output
$out"
grep -qE 'skip +(function_length_max|single_use_functions) +not measured' <<<"$out" \
  || fail "the ratchet did not SKIP the unmeasurable function metrics — it must not read them as held-steady
--- output
$out"

# ── 5. The documented skip, and config-visible disabling ─────────────────────
git checkout -q slop
out="$(cd "$REPO" && CHIEF_VERIFY_QUALITY=0 bash "$ROOT/engine/quality.sh" ratchet --base main --no-lint 2>&1)"; rc=$?
[ "$rc" = "0" ] || fail "CHIEF_VERIFY_QUALITY=0 did not skip the gate (rc=$rc)"
grep -q 'skipped' <<<"$out" || fail "CHIEF_VERIFY_QUALITY=0 skipped silently — the skip must announce itself
--- output
$out"

# The only two ways to loosen the gate are edits to a tracked file, so both must
# actually work — a lever that does not move is a lever people route around.
# (d1) drop a metric: it stops being evaluated at all.
cat > "$REPO/.chief/quality.conf" <<'CONF'
CHIEF_QUALITY_METRICS="duplicate_blocks max_nesting_depth"
CONF
ratchet
grep -q 'function_length_mean' <<<"$out" && fail "a metric absent from CHIEF_QUALITY_METRICS was still evaluated
--- output
$out"
grep -q 'BLOCK  duplicate_blocks' <<<"$out" || fail "a metric still IN CHIEF_QUALITY_METRICS stopped being evaluated
--- output
$out"

# (d2) raise a tolerance: the same branch, same metrics, now allowed.
cat > "$REPO/.chief/quality.conf" <<'CONF'
CHIEF_QUALITY_METRICS="max_nesting_depth"
CHIEF_QUALITY_TOL_max_nesting_depth=10
CONF
ratchet
[ "$rc" = "0" ] || fail "raising a tolerance in .chief/quality.conf did not take effect (rc=$rc)
--- output
$out"

# Environment wins over the file, so iterating locally never needs a config edit.
out="$(cd "$REPO" && CHIEF_QUALITY_TOL_max_nesting_depth=0 bash "$ROOT/engine/quality.sh" \
        ratchet --base main --no-lint --no-baseline 2>&1)"; rc=$?
[ "$rc" = "1" ] || fail "an env tolerance did not override the config file (rc=$rc)
--- output
$out"
rm -f "$REPO/.chief/quality.conf"

# ── 6. The CLI surface: `chief quality` reaches the same engine ──────────────
out="$(cd "$REPO" && bash "$ROOT/bin/chief" quality ratchet --base main --no-lint --no-baseline 2>&1)"; rc=$?
[ "$rc" = "1" ] || fail "'chief quality ratchet' did not block the slop branch (rc=$rc) — the CLI is not wired to engine/quality.sh
--- output
$out"

# ── verdict ──────────────────────────────────────────────────────────────────
[ "$fails" -eq 0 ] || { echo "QUALITY-RATCHET: $fails assertion(s) failed" >&2; exit 1; }
echo "QUALITY-RATCHET PASS — slop BLOCKED, refactor ALLOWED, unmeasurable languages skipped not zeroed"
