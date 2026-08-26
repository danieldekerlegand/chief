#!/usr/bin/env bash
# test/cigate.sh — a DECLARED gate that never ran must be reported, and a gate that
# could not be MEASURED must never read as a pass.
#
# The failure this pins (measured 2026-08-25): every private repository in this
# portfolio had dead CI for an unknown period. All three failures were byte-identical
# and none was a code problem — "The job was not started because recent account
# payments have failed or your spending limit needs to be increased." GitHub Actions
# is free for public repos and billed for private ones, so one account-level block
# killed the gate on every private repo while the public ones kept working and kept
# looking normal. Nothing anywhere said so.
#
# Five fixtures, one per case the report has to tell apart:
#   cg-nocI        no .github/workflows at all      -> NO GATE, and NOT flagged
#   cg-green       a workflow with a passing run    -> RAN AND PASSED, and NOT flagged
#   cg-dead        runs that completed with zero    -> DID NOT RUN  (the billing shape:
#                  steps on every job                  cuneiform run 32944778403)
#   cg-norun       a workflow with no runs ever     -> DID NOT RUN
#   cg-noremote    workflows, no GitHub remote      -> UNKNOWN, never a pass
# plus: `gh` absent entirely -> UNKNOWN; an API that refuses -> UNKNOWN; and a green
# run on a DIFFERENT commit than the one asked about -> DID NOT RUN for that commit.
#
# Hermetic: temp git repos, a scripted fake `gh` on PATH serving fixture JSON, its own
# CHIEF_PREFIX. No network, no agent, no ~/.chief access.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/chief-cigate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export CHIEF_PREFIX="$WORK/prefix" CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos/list"
export GIT_AUTHOR_NAME=cg GIT_AUTHOR_EMAIL=cg@test GIT_COMMITTER_NAME=cg GIT_COMMITTER_EMAIL=cg@test

fails=0
fail() { echo "CIGATE FAIL: $*" >&2; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "CIGATE FAIL: jq required" >&2; exit 1; }

# ── the fake `gh`: fixture JSON keyed by --repo slug, and a refusal when absent ──
# `gh run list` and `gh run view --json jobs` are the only two calls the module makes.
# A slug with no fixture exits 1, which is exactly what an offline/unauthenticated
# gh does — the arm that must produce UNKNOWN rather than a pass.
FIX="$WORK/gh"; mkdir -p "$FIX" "$WORK/bin"
cat > "$WORK/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -u
slug=""; mode=""; id=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) slug="$2"; shift ;;
    list)   mode=list ;;
    view)   mode=view; id="$2"; shift ;;
  esac
  shift
done
case "$mode" in
  list) f="$GH_FIX/$slug.runs.json" ;;
  view) f="$GH_FIX/$slug.jobs.$id.json" ;;
  *)    exit 1 ;;
esac
[ -f "$f" ] || exit 1
cat "$f"
FAKE
chmod +x "$WORK/bin/gh"
export GH_FIX="$FIX"
PATH="$WORK/bin:$PATH"; export PATH

# ── fixture repos ────────────────────────────────────────────────────────────
mkrepo() {  # $1 = name, $2 = remote? (yes/no)
  local d="$WORK/$1"
  mkdir -p "$d"; git -C "$d" init -q
  echo x > "$d/f"; git -C "$d" add -A; git -C "$d" commit -qm init
  [ "$2" = yes ] && git -C "$d" remote add origin "https://github.com/acme/$1.git"
  printf '%s\n' "$d"
}
mkwf() {   # $1 = repo dir, $2 = workflow name
  mkdir -p "$1/.github/workflows"
  printf 'name: %s\non: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n' "$2" > "$1/.github/workflows/ci.yml"
}
run_json() {  # $1 = slug, $2 = conclusion, $3 = headSha, $4 = id
  jq -n --arg c "$2" --arg s "$3" --argjson i "$4" \
    '[{workflowName:"CI",databaseId:$i,status:"completed",conclusion:$c,headSha:$s,createdAt:"2026-08-25T04:00:00Z"}]' \
    > "$FIX/acme/$1.runs.json"
}
mkdir -p "$FIX/acme"

R_NOCI="$(mkrepo cg-noci yes)"
R_GREEN="$(mkrepo cg-green yes)";      mkwf "$R_GREEN" CI
R_DEAD="$(mkrepo cg-dead yes)";        mkwf "$R_DEAD" CI
R_NORUN="$(mkrepo cg-norun yes)";      mkwf "$R_NORUN" CI
R_NOREMOTE="$(mkrepo cg-noremote no)"; mkwf "$R_NOREMOTE" CI

GREEN_SHA="$(git -C "$R_GREEN" rev-parse HEAD)"
run_json cg-green   success  "$GREEN_SHA" 11
run_json cg-dead    failure  deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 22
printf '[]\n' > "$FIX/acme/cg-norun.runs.json"
# The billing shape, verbatim: jobs present, conclusion failure, `steps: []` on
# every one of them. Nothing executed; GitHub still calls the run "completed".
jq -n '{jobs:[{name:"build",status:"completed",conclusion:"failure",steps:[]},
              {name:"test",status:"completed",conclusion:"skipped",steps:[]}]}' > "$FIX/acme/cg-dead.jobs.22.json"

# ── the scan ─────────────────────────────────────────────────────────────────
# shellcheck source=../engine/cigate.sh
. "$ROOT/engine/cigate.sh"

tokof() { printf '%s\n' "$1" | head -1 | cut -f1; }
detof() { printf '%s\n' "$1" | head -1 | cut -f4; }

expect() {  # $1 = label, $2 = expected token, $3 = repo, $4 = sha (may be empty)
  local rows tok
  rows="$(cigate_scan "$3" "${4:-}")"
  tok="$(tokof "$rows")"
  [ "$tok" = "$2" ] || fail "$1: expected '$2', got '$tok' — $(detof "$rows")"
  printf '%s\n' "$rows"
}

rows_noci="$(expect  'no workflows at all'          "$CIGATE_NONE"    "$R_NOCI")"
rows_green="$(expect 'a recent green run'           "$CIGATE_PASSED"  "$R_GREEN")"
rows_dead="$(expect  'runs that never started'      "$CIGATE_DEAD"    "$R_DEAD")"
rows_norun="$(expect 'a workflow with no runs ever' "$CIGATE_DEAD"    "$R_NORUN")"
rows_nore="$(expect  'no GitHub remote'             "$CIGATE_UNKNOWN" "$R_NOREMOTE")"

case "$(detof "$rows_dead")" in
  *"never started"*) ;;
  *) fail "the never-started run is not described as never having started: $(detof "$rows_dead")" ;;
esac
case "$(detof "$rows_norun")" in
  *"no run recorded"*) ;;
  *) fail "a workflow with no runs is not described as having none: $(detof "$rows_norun")" ;;
esac

# ── the two states that are NOT findings must stay out of the findings render ──
[ -z "$(cigate_render "$rows_noci")" ]  || fail "a repo with no CI at all was flagged — that is not a finding"
[ -z "$(cigate_render "$rows_green")" ] || fail "a repo whose gate ran and passed was flagged"
case "$(cigate_render "$rows_dead")" in *"DID NOT RUN"*) ;; *) fail "the dead gate is missing from the findings render" ;; esac
case "$(cigate_render "$rows_nore")" in *"UNKNOWN"*) ;; *) fail "an unmeasurable gate is missing from the findings render" ;; esac

# ── the loud-SKIP discipline: could-not-measure is never a pass ──────────────
# Three independent ways to be unable to measure. Every one must land on UNKNOWN.
# A PATH with every tool the scan needs and NO gh — narrowing to /usr/bin would
# also drop tools the check legitimately depends on, and then this would pass for
# the wrong reason.
mkdir -p "$WORK/nogh"
for t in basename git sed head awk jq cut; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$WORK/nogh/$t"
done
nogh_rows="$(PATH="$WORK/nogh" cigate_scan "$R_GREEN")"
[ "$(tokof "$nogh_rows")" = "$CIGATE_UNKNOWN" ] \
  || fail "with gh absent the verdict was '$(tokof "$nogh_rows")', not UNKNOWN"
case "$(detof "$nogh_rows")" in *"NOT a pass"*) ;; *) fail "the gh-absent verdict does not say it is not a pass" ;; esac

rm -f "$FIX/acme/cg-green.runs.json"
refuse_rows="$(cigate_scan "$R_GREEN")"
[ "$(tokof "$refuse_rows")" = "$CIGATE_UNKNOWN" ] \
  || fail "an API that refused produced '$(tokof "$refuse_rows")', not UNKNOWN"
run_json cg-green success "$GREEN_SHA" 11

# ── currency: a green run on ANOTHER commit does not cover this one ──────────
stale_rows="$(cigate_scan "$R_GREEN" 0123456789abcdef0123456789abcdef01234567)"
[ "$(tokof "$stale_rows")" = "$CIGATE_DEAD" ] \
  || fail "a green run on a different commit read as '$(tokof "$stale_rows")' for a commit it never tested"
case "$(detof "$stale_rows")" in *"0123456"*) ;; *) fail "the currency finding never names the commit that has no run" ;; esac
[ "$(tokof "$(cigate_scan "$R_GREEN" "$GREEN_SHA")")" = "$CIGATE_PASSED" ] \
  || fail "a green run ON the commit asked about did not read as RAN AND PASSED"

# ── the CLI: reports, counts, and exits 0 on a finding ───────────────────────
out="$(bash "$ROOT/bin/chief" cigate "$R_DEAD" "$R_GREEN" "$R_NOCI" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "chief cigate exited $rc on a finding — this reports, it never blocks"
case "$out" in *"DID NOT RUN"*) ;; *) fail "chief cigate never names the dead gate: $out" ;; esac
case "$out" in *"1 DID NOT RUN"*) ;; *) fail "chief cigate does not count the states: $out" ;; esac
case "$out" in *"1 RAN AND PASSED"*) ;; *) fail "chief cigate does not count the healthy gate: $out" ;; esac
case "$out" in *"billing"*) ;; *) fail "chief cigate never names the public/private billing asymmetry: $out" ;; esac
case "$out" in *"declare no CI"*) ;; *) fail "chief cigate does not account for the repo that declares no CI: $out" ;; esac
case "$out" in *"cg-noci"*) fail "the no-CI repo was flagged as a finding: $out" ;; esac

[ "$fails" -eq 0 ] || exit 1
echo "CIGATE PASS — declared-but-dead gates reported (never-started · never-run · not-current); no-CI and green repos not flagged; gh absent, no remote and a refusing API all land on UNKNOWN and never on a pass"
