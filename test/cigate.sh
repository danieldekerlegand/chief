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
# THE TRIGGER MISMATCH is the second, independent version of the same fault, and the
# one nothing on the network can answer: `vita`'s workflow triggers only on
# `pull_request` and `workflow_dispatch`, chief merges locally and pushes the base
# branch, so no event chief generates could ever start it. Its CI had never run once
# in the repository's history, and tasklist 72 was unparked and merged as
# `auto-verified` on the premise that it had. `gh` cannot tell that apart from a
# brand-new workflow: "no runs" is what both look like, and only the trigger says
# which.
#
# So that half is driven by THE FILE, verbatim — test/fixtures/vita-ci-2026-08-25.yml
# is vita/.github/workflows/ci.yml as it stood on 2026-08-25, copied byte for byte
# (sha256 317fb0bbdcdd2d4289c76e899c98e5573510563df34ea98d26f980e4ac00c498). Around it,
# one fixture per YAML form the `on:` mapping is written in, because the parser is
# textual by design and the forms are where a textual parser goes wrong.
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

# ── the TRIGGER MISMATCH ─────────────────────────────────────────────────────
# Offline and textual: no fake gh is on PATH for any of this, and none is needed.
FX="$ROOT/test/fixtures/vita-ci-2026-08-25.yml"
[ -f "$FX" ] || fail "the vita fixture is missing — the counterfactual cannot run"

# The counterfactual, against the real file. It must report the mismatch, and it
# must report it in the OPERATOR's terms: which trigger the workflow waits for,
# and what chief actually does instead.
vita_detail="$(cigate_trigger_check "$FX" main)"; vita_rc=$?
[ "$vita_rc" -eq 1 ] || fail "vita's workflow as it stood on 2026-08-25 returned rc=$vita_rc, not a mismatch"
case "$vita_detail" in
  *"pull request"*) ;; *) fail "the mismatch never names what the workflow waits for: $vita_detail" ;;
esac
case "$vita_detail" in
  *"pushes main"*) ;; *) fail "the mismatch never names what chief actually does: $vita_detail" ;;
esac
case "$vita_detail" in
  *"on: pull_request, workflow_dispatch"*) ;;
  *) fail "the mismatch never names the triggers it read: $vita_detail" ;;
esac

# Every YAML form of `on:`, and the two ways a `push:` can still be unreachable.
# Expected: fires | mismatch | unreadable.
# The verdict goes in $TRIG_OUT rather than on stdout: a test that PRINTS its
# fixtures buries the one line that matters when it fails.
trig() {  # $1 = label, $2 = expected, $3 = base branch, stdin = the workflow
  local f rc got
  f="$WORK/wf-$1.yml"; cat > "$f"
  TRIG_OUT="$(cigate_trigger_check "$f" "$3")"; rc=$?
  case "$rc" in 0) got=fires ;; 1) got=mismatch ;; *) got=unreadable ;; esac
  [ "$got" = "$2" ] || fail "$1: expected $2, got $got — $TRIG_OUT"
}
TRIG_OUT=""
trig scalar   fires      main <<'Y'
on: push
Y
trig flowseq  fires      main <<'Y'
on: [push, pull_request]
Y
trig blockmap fires      main <<'Y'
name: ci
on:
  push:
    branches: [main]
  pull_request:
Y
trig quoted   mismatch   main <<'Y'
"on":
  - pull_request
Y
trig otherbr  mismatch   main <<'Y'
on:
  push:
    branches:
      - develop
      - 'release/**'
Y
trig ignored  mismatch   main <<'Y'
on:
  push:
    branches-ignore: [main]
Y
trig tagonly  mismatch   main <<'Y'
on:
  push:
    tags: ['v*']
Y
case "$TRIG_OUT" in *"never creates a tag"*) ;; *) fail "a tags-only push is not explained as one: $TRIG_OUT" ;; esac
trig comment  fires      main <<'Y'
# on: pull_request   <- a comment, not a trigger
on:
  push:
Y
trig noon     unreadable main <<'Y'
jobs:
  build:
    runs-on: ubuntu-latest
Y

# The declared base branch is the one chief pushes, so it is the one that decides.
# Same file, two projects: `develop` is dead under a repo based on main and live
# under one that declares develop.
trig ondevelop mismatch main <<'Y'
on:
  push:
    branches: [develop]
Y
trig ondevelop2 fires develop <<'Y'
on:
  push:
    branches: [develop]
Y
mkdir -p "$R_GREEN/.chief"
printf 'CHIEF_BASE_BRANCH="develop"   # not main\n' > "$R_GREEN/.chief/config"
[ "$(cigate_base_branch "$R_GREEN")" = develop ] \
  || fail "a declared CHIEF_BASE_BRANCH is not the branch the trigger check measures against"
rm -rf "$R_GREEN/.chief"
[ "$(cigate_base_branch "$R_GREEN")" = main ] || fail "the base branch does not default to main"

# ── the mismatch through the whole surface: scan, render, CLI ───────────────
# A repo whose ONLY workflow is vita's. gh has no fixture for it, so every network
# answer here is a refusal — which is the point: the finding is measured from the
# file, and a repo where nothing else could be measured is where it matters most.
R_VITA="$(mkrepo cg-vita yes)"
mkdir -p "$R_VITA/.github/workflows"; cp "$FX" "$R_VITA/.github/workflows/ci.yml"
vita_rows="$(cigate_scan "$R_VITA")"
[ "$(tokof "$vita_rows")" = "$CIGATE_DEAD" ] \
  || fail "a workflow chief can never start reads as '$(tokof "$vita_rows")', not DID NOT RUN"
case "$(detof "$vita_rows")" in
  "trigger mismatch: "*) ;;
  *) fail "the mismatch is not tagged so the report can find it again: $(detof "$vita_rows")" ;;
esac
case "$(detof "$vita_rows")" in
  *"not measured"*) ;;
  *) fail "the mismatch row swallowed the unmeasured run verdict instead of keeping it: $(detof "$vita_rows")" ;;
esac
case "$(cigate_render "$vita_rows")" in *"DID NOT RUN"*) ;; *) fail "the mismatch is missing from the findings render" ;; esac

# A green run does NOT clear a mismatch. Someone opening a pull request by hand is
# exactly the reassuring surface this whole tasklist exists to stop trusting.
cp "$FX" "$R_GREEN/.github/workflows/ci.yml"
green_wf_rows="$(cigate_scan "$R_GREEN")"
[ "$(tokof "$green_wf_rows")" = "$CIGATE_DEAD" ] \
  || fail "a passing run on a workflow chief cannot start still read as '$(tokof "$green_wf_rows")'"
case "$(detof "$green_wf_rows")" in
  *"passed on"*) ;; *) fail "the mismatch row threw away the passing run instead of reporting it alongside" ;;
esac
mkwf "$R_GREEN" CI    # back to the reachable workflow for anything after this

out="$(bash "$ROOT/bin/chief" cigate "$R_VITA" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "chief cigate exited $rc on a trigger mismatch — this reports, it never blocks"
case "$out" in *"TRIGGER MISMATCH"*) ;; *) fail "chief cigate does not separate the mismatch from the billing story: $out" ;; esac
case "$out" in *"not in billing"*) ;; *) fail "chief cigate does not say the mismatch has a different fix: $out" ;; esac

[ "$fails" -eq 0 ] || exit 1
echo "CIGATE PASS — declared-but-dead gates reported (never-started · never-run · not-current); no-CI and green repos not flagged; gh absent, no remote and a refusing API all land on UNKNOWN and never on a pass; vita's 2026-08-25 workflow reports its trigger mismatch offline, in prose, and a passing run does not clear it"
