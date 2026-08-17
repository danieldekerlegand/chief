#!/usr/bin/env bash
# test/research.sh — the RESEARCH PHASE end to end (docs/research-phase.md).
#
# tasks/chief/90-research-phase-artifact. The phase's whole claim is that a tasklist
# pays for its mental model of the codebase ONCE and every story spends its context
# on the change instead of rediscovering the code. A claim like that is only worth
# what it can be held to, and all four halves of it are mechanical:
#
#   PART A — PRODUCED ONCE, CARRYING THE CONTRACT: an opt-in tasklist spends exactly
#            one research turn before its first story, the document validates against
#            the four required sections, it is persisted OUTSIDE the worktree — and
#            BOTH stories are briefed with it. The turn that produced it is a research
#            turn, not an implement turn: it writes no code and makes no commit. The
#            sibling tasklist that did NOT opt in pays for nothing (the ~40% one-shot
#            rule: a doc fix must not buy a research iteration).
#   PART B — REUSED ON RESUME, AND HAND-EDITABLE: a run parked mid-tasklist by an
#            operator pause has already banked the map; the resumed run — a NEW
#            process, against a REBUILT worktree — reuses it and spends ZERO research
#            turns. Between the two runs a human EDITS the document, and the edit is
#            what the next story is handed. That is the leverage the phase exists for:
#            correcting the map has to be cheaper than correcting the code.
#   PART C — THE VALIDATOR AND THE OPT-IN RULE, as pure functions (engine/research.sh,
#            no driver, no agent): what counts as a valid document, why a skeleton of
#            four empty headings is not one, and the precedence of $CHIEF_RESEARCH
#            over the tasklist's own flag in both directions.
#
# Hermetic: a scripted fake `claude` on PATH, temp prefixes ($CHIEF_PREFIX included,
# so worktrees land in the temp dir), never touches the real ~/.chief. Drives
# bin/chief straight out of this checkout, so it tests uncommitted work.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rc=$?; rm -rf "$WORK"; exit "$rc"' EXIT
export GIT_AUTHOR_NAME=rs GIT_AUTHOR_EMAIL=rs@test GIT_COMMITTER_NAME=rs GIT_COMMITTER_EMAIL=rs@test
export CHIEF_PREFIX="$WORK/ch" CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
# The phase is opt-in per tasklist; an inherited override from the developer's own
# shell would decide PART A's skip assertion for it.
unset CHIEF_RESEARCH CHIEF_RESEARCH_MAX_ATTEMPTS CHIEF_REVIEW CHIEF_REVIEWER 2>/dev/null || true
CHIEF="$ROOT/bin/chief"
LOG=""
fail() { echo "RESEARCH FAIL: $*" >&2; [ -n "$LOG" ] && [ -f "$LOG" ] && tail -60 "$LOG" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

REPO="$WORK/repo"
S="$REPO/.chief/state/parallel"
DOCS="$REPO/.chief/state/research"          # the driver's DURABLE store, outside every worktree
state()    { cat "$S/$1.state" 2>/dev/null || echo MISSING; }
rturns()   { cat "$WORK/research.$1" 2>/dev/null || echo 0; }   # research turns for tasklist $1
scalls()   { cat "$WORK/calls.$1"    2>/dev/null || echo 0; }   # implement turns for tasklist $1
# NOTE: `[ … ] && fail` would exit the whole script under `set -e` on the PASSING
# branch, so every negative assertion below is written as an `if … then fail; fi`.

mkdir -p "$WORK/fakebin"
export PZ_WORK="$WORK" PZ_REPO="$REPO" PZ_CHIEF="$CHIEF"
# Stamped into the Conventions section by the research turn. Nothing else in the tree
# contains it, so finding it in a STORY's prompt proves the map reached that story
# rather than some other part of the prompt merely mentioning research.
export PZ_MARKER="MAP-TOKEN-c0ffee"

# ── the fake agent ────────────────────────────────────────────────────────────
# Two turn shapes, told apart the way a real agent tells them apart: a research turn's
# prompt opens with "# RESEARCH PHASE" and names the document to write. On that turn it
# writes THAT FILE AND NOTHING ELSE — no source edits, no commit, no passes flip, which
# is what engine/research.sh's prompt asks for and what makes "the research turn wrote
# no code" assertable below. Otherwise it implements one story like every other fake in
# this suite. Every prompt is kept, keyed by what it was for.
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
: "${PZ_WORK:?}" "${PZ_MARKER:?}"
prompt="$(cat)"
PRD=".chief/state/prd.json"
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"; TRACKED="tasks/chief/$name.json"

case "$prompt" in
  *"# RESEARCH PHASE"*)
    r=$(( $(cat "$PZ_WORK/research.$name" 2>/dev/null || echo 0) + 1 )); echo "$r" > "$PZ_WORK/research.$name"
    printf '%s' "$prompt" > "$PZ_WORK/rprompt.$name.$r"
    # The path is read back OUT of the prompt, not assumed: the engine promises the
    # model a worktree-relative path (never the durable one it is told to stay away
    # from), and a fake that hardcoded it would not notice that promise breaking.
    doc="$(printf '%s\n' "$prompt" | grep -o '`[^`]*research\.md`' | tr -d '`' | head -1)"
    [ -n "$doc" ] || { echo "fake claude: the research prompt names no document path" >&2; exit 3; }
    case "$doc" in /*) echo "fake claude: handed an ABSOLUTE document path ($doc)" >&2; exit 3 ;; esac
    mkdir -p "$(dirname "$doc")"
    # Em-dashes and arrows on purpose: a research document is prose about code, and
    # BSD awk aborts on multi-byte input unless the validator forces byte semantics.
    cat > "$doc" <<DOC
# Research — $name
<!-- chief.research/1 -->

## Target files
- \`out/$name/\` — where this tasklist's markers land; the only tree the stories touch.

## Data flow
driver seeds the worktree → the story writes its marker → verify greps for it.

## Point of insertion
One new file per story under \`out/$name/\`, named for the story id — nothing existing
is disturbed.

## Conventions
$PZ_MARKER — one marker file per story, named for its id, content "impl <id>".
DOC
    echo "research document written to $doc"
    exit 0 ;;
esac

id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
[ -n "$id" ] || exit 0
printf '%s' "$prompt" > "$PZ_WORK/story.$name.$id"
n=$(( $(cat "$PZ_WORK/calls.$name" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$PZ_WORK/calls.$name"
# Per-tasklist path ON PURPOSE: two tasklists writing the same file with the same bytes
# would leave the second branch with an EMPTY diff vs a base the first already merged
# into, and the no-work guard would fire instead of the thing under test.
artifact="out/$name/$id.txt"
mkdir -p "$(dirname "$artifact")"; echo "impl $id" > "$artifact"
for f in "$PRD" "$TRACKED"; do
  [ -f "$f" ] || continue
  t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id).passes)=true' "$f" > "$t" && mv "$t" "$f"
done
git add -A >/dev/null 2>&1 || true; git commit -q -m "feat: $id" >/dev/null 2>&1 || true
# Arms the OPERATOR pause from outside the driver, exactly as a person would (cd to the
# project first: cwd here is the worktree, whose own .chief/ find_project would take).
if [ "$name/$n" = "${PZ_PAUSE_AT:-none}" ]; then
  ( cd "$PZ_REPO" && "$PZ_CHIEF" pause ) >/dev/null 2>&1 || echo "fake claude: chief pause failed" >&2
fi
if [ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ]; then
  printf '<promise>%s</promise>\n' COMPLETE
fi
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── a chief repo: two research-enabled tasklists and one that opted out ───────
mkdir -p "$REPO"
( cd "$REPO"
  git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
  git commit -q --allow-empty -m init
  "$CHIEF" init >/dev/null
  rm -f tasks/chief/example.json
  printf '#!/usr/bin/env bash\nset -eu\necho "verify: ok"\nexit 0\n' > .chief/verify.sh
  chmod +x .chief/verify.sh
  cat > tasks/chief/rs.json <<'JSON'
{ "project":"rs","branchName":"chief/rs","description":"two stories over one shared map",
  "research":true,"iters":6,"dependsOn":[],"touches":["rs"],"warmup":[],
  "userStories":[
    {"id":"US-1","title":"first story","description":"","acceptanceCriteria":["out/rs/US-1.txt"],"passes":false,"notes":""},
    {"id":"US-2","title":"second story","description":"","acceptanceCriteria":["out/rs/US-2.txt"],"passes":false,"notes":""}
  ] }
JSON
  cat > tasks/chief/rr.json <<'JSON'
{ "project":"rs","branchName":"chief/rr","description":"parked mid-tasklist, then resumed",
  "research":true,"iters":6,"dependsOn":[],"touches":["rr"],"warmup":[],
  "userStories":[
    {"id":"US-1","title":"before the pause","description":"","acceptanceCriteria":["out/rr/US-1.txt"],"passes":false,"notes":""},
    {"id":"US-2","title":"after the resume","description":"","acceptanceCriteria":["out/rr/US-2.txt"],"passes":false,"notes":""}
  ] }
JSON
  cat > tasks/chief/ns.json <<'JSON'
{ "project":"rs","branchName":"chief/ns","description":"a one-shot — no research, by omission",
  "iters":4,"dependsOn":[],"touches":["ns"],"warmup":[],
  "userStories":[
    {"id":"US-1","title":"one-shot story","description":"","acceptanceCriteria":["out/ns/US-1.txt"],"passes":false,"notes":""}
  ] }
JSON
  git add -A && git commit -q -m setup )

run_chief() {   # $1 = log; rest = args to `chief run`
  local log="$1"; shift
  ( cd "$REPO" && PATH="$WORK/fakebin:$PATH" POLL_SECONDS=1 "$CHIEF" run "$@" ) >"$log" 2>&1
}

# ══ PART A — one research turn, four sections, every story briefed ════════════
echo "research: PART A — produced once, persisted, and carried into both stories"
LOG="$WORK/a.log"
run_chief "$LOG" -p 2 rs ns || fail "the run exited non-zero"

[ "$(rturns rs)" = "1" ] || fail "rs spent $(rturns rs) research turn(s), want exactly 1 (ONCE per tasklist, not per story)"
[ "$(scalls rs)" = "2" ] || fail "rs spent $(scalls rs) implement turn(s), want 2 (one per story)"

# The document is persisted OUTSIDE the worktree, which is what makes it survive the
# rebuild the driver does at the top of every run (PART B leans on this).
DOC="$DOCS/rs.md"
[ -s "$DOC" ] || fail "no research document was persisted at $DOC"
grep -q 'chief.research/1' "$DOC" || fail "the document carries no schema stamp"
for h in '## Target files' '## Data flow' '## Point of insertion' '## Conventions'; do
  grep -q "^$h" "$DOC" || { cat "$DOC" >&2; fail "the persisted document is missing the required section '$h'"; }
done
grep -q 'document persisted' "$S/rs.log" || { tail -40 "$S/rs.log" >&2; fail "the log never says the document was persisted"; }
# …and the engine's own validator agrees, so the test and the engine share one oracle.
( set +u; . "$ROOT/engine/research.sh"; research_validate "$DOC" ) \
  || fail "engine/research.sh does not consider its own persisted document valid"

# THE RESEARCH TURN IS NOT AN IMPLEMENT TURN. It writes no code and makes no commit —
# the map is bought before anything is built, or it is not leverage.
if ( cd "$REPO" && git log --oneline main..chief/rs 2>/dev/null | grep -qi 'research' ); then
  fail "the research turn made a commit — it must produce the document and nothing else"
fi
[ "$( ( cd "$REPO" && git rev-list --count main..chief/rs 2>/dev/null ) || echo 0 )" -le 2 ] \
  || fail "chief/rs carries more commits than its two stories — the research turn committed"

# THE SUB-AGENT CONTRACT, in the prompt that was actually sent: the searching happens
# in sub-agent contexts and only a STRUCTURED SUMMARY comes back. A research phase that
# let raw grep output into the parent's window would be paying the cost it exists to
# remove.
RP="$WORK/rprompt.rs.1"
grep -q 'STRUCTURED SUMMARY' "$RP" || fail "the research prompt does not require a structured summary from sub-agents"
grep -q 'must NOT return raw tool output' "$RP" || fail "the research prompt does not forbid raw tool output"
for f in FILES: FLOW: CONVENTIONS: UNKNOWNS:; do
  grep -q "^    $f" "$RP" || fail "the research prompt does not specify the sub-agent return field '$f'"
done
# The prompt also carries the tasklist's own stories, or the map would be researched
# against nothing in particular.
grep -q 'US-2' "$RP" || fail "the research prompt does not name the stories the map must serve"

# EVERY STORY GOT THE MAP — the point of the whole phase.
for id in US-1 US-2; do
  P="$WORK/story.rs.$id"
  [ -s "$P" ] || fail "no prompt was captured for rs/$id"
  grep -q 'produced ONCE, up front' "$P" || fail "rs/$id was not briefed with the research document"
  grep -qF "$PZ_MARKER" "$P" || fail "rs/$id's prompt does not contain the map's own content"
done

# THE OPT-IN RULE: a tasklist that did not ask for research pays for none of it.
if [ -f "$WORK/research.ns" ]; then fail "ns spent $(rturns ns) research turn(s) — research is opt-in"; fi
if [ -f "$DOCS/ns.md" ]; then fail "a research document was written for a tasklist that never opted in"; fi
if grep -q 'produced ONCE, up front' "$WORK/story.ns.US-1"; then
  fail "the opted-out tasklist's story prompt carries a research section"
fi
[ "$(state rs)" = "done" ] && [ "$(state ns)" = "done" ] \
  || fail "rs is '$(state rs)' and ns is '$(state ns)', want both done"

# The event stream says so too — a host embedding chief learns the map was bought.
EV="$(find "$CHIEF_RUNS" -maxdepth 1 -name '*.events.jsonl' | head -1)"
[ -n "$EV" ] || fail "no event log was written"
[ "$(jq -r 'select(.event=="tasklist.research" and .name=="rs") | .name' "$EV" | wc -l | tr -d ' ')" = "1" ] \
  || { grep research "$EV" >&2 || true; fail "want exactly one tasklist.research event for rs"; }
echo "   ok  1 research turn, 4 sections, persisted, both stories briefed, opt-out paid nothing"

# ══ PART B — resumed runs reuse it, and a human's edit is what stories get ════
echo "research: PART B — reused on resume (zero second turn), and hand-editable"
LOG="$WORK/b1.log"
PZ_PAUSE_AT="rr/1" run_chief "$LOG" rr || fail "the parked run exited non-zero (an operator pause is not a failure)"
[ "$(state rr)" = "paused" ] || fail "rr state is '$(state rr)', want paused"
[ "$(rturns rr)" = "1" ] || fail "rr spent $(rturns rr) research turn(s) before the park, want 1"
RDOC="$DOCS/rr.md"
[ -s "$RDOC" ] || fail "the map was not banked at $RDOC before the park — a resumed run would re-buy it"

# THE HUMAN-CORRECTION WINDOW: a person opens the durable document between iterations
# and fixes the map. No re-run, no research turn — the next story just reads it.
EDIT="HAND-CORRECTED-4f2a: the marker goes under out/rr/, not out/"
printf '%s\n' "$EDIT" >> "$RDOC"

( cd "$REPO" && "$CHIEF" resume ) >"$WORK/resume.log" 2>&1 || fail "chief resume exited non-zero"
LOG="$WORK/b2.log"
run_chief "$LOG" rr || fail "the resumed run exited non-zero"

# A NEW PROCESS, A REBUILT WORKTREE, AND NO SECOND RESEARCH TURN.
[ "$(rturns rr)" = "1" ] || fail "the resumed run bought research AGAIN ($(rturns rr) turns total, want 1)"
grep -q 'reusing the persisted document' "$S/rr.log" \
  || { tail -40 "$S/rr.log" >&2; fail "the resumed run does not report reusing the persisted document"; }
# …and what it reused is the EDITED document, not the one the model wrote.
P="$WORK/story.rr.US-2"
[ -s "$P" ] || fail "no prompt was captured for rr/US-2"
grep -qF "$EDIT" "$P" || { fail "the story after the edit was briefed with the ORIGINAL map — a hand correction is not being consumed"; }
grep -qF "$PZ_MARKER" "$P" || fail "the edited document lost the rest of the map"
# The correction cost nothing but the edit: the tasklist finished normally.
[ "$(state rr)" = "done" ] || fail "rr state is '$(state rr)', want done"
( cd "$REPO" && git checkout -q main
  [ -f out/rr/US-2.txt ] || exit 3
  [ -n "$(jq -r '.mergedToMain // empty' tasks/chief/completed/rr.json 2>/dev/null)" ] || exit 4 ) \
  || fail "the resumed tasklist did not complete + merge (missing artifact or merge stamp)"
echo "   ok  resumed with zero research turns, and the hand-edited map is what US-2 read"

# ══ PART C — the validator and the opt-in rule, as pure functions ═════════════
echo "research: PART C — what validates, what does not, and who decides to run it"
probe() { ( set +u; . "$ROOT/engine/research.sh"; "$@" ); }

# A skeleton of the four headings with nothing under them is the exact failure mode a
# section-PRESENCE check invites, and it is worse than no document: it passes
# validation while telling a story nothing.
{ printf '## Target files\n\n## Data flow\n\n## Point of insertion\n\n## Conventions\n'; } > "$WORK/skeleton.md"
if probe research_validate "$WORK/skeleton.md"; then fail "an empty four-heading skeleton validated"; fi
[ "$(probe research_missing "$WORK/skeleton.md" | wc -l | tr -d ' ')" = "4" ] \
  || fail "an empty skeleton reports $(probe research_missing "$WORK/skeleton.md" | wc -l | tr -d ' ') missing section(s), want 4"

# One section dropped: named, and only it.
sed '/## Conventions/,$d' "$DOC" > "$WORK/partial.md"
if probe research_validate "$WORK/partial.md"; then fail "a document with no Conventions section validated"; fi
[ "$(probe research_missing "$WORK/partial.md")" = "## Conventions" ] \
  || fail "the missing section is reported as '$(probe research_missing "$WORK/partial.md" | tr '\n' ' ')', want '## Conventions'"

# A missing file is "everything is missing" — which is what makes research_missing the
# right thing to feed straight back into a retry prompt.
[ "$(probe research_missing "$WORK/nope.md" | wc -l | tr -d ' ')" = "4" ] \
  || fail "an absent document does not report every section missing"

# A heading with a parenthetical still satisfies the contract: failing a whole research
# turn over a formatting nicety is a worse trade than accepting the prefix. And a
# UTF-8 body must not abort the validator (BSD awk, em-dashes — the LC_ALL=C guard).
sed 's/^## Target files$/## Target files (engine\/ — the three files that matter)/' "$DOC" > "$WORK/prefix.md"
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 probe research_validate "$WORK/prefix.md" \
  || fail "a heading with a parenthetical (or a multi-byte body) failed validation"

# THE OPT-IN RULE, in precedence order: $CHIEF_RESEARCH beats the tasklist, in BOTH
# directions, and silence means off.
mk() { jq -n --argjson r "$1" '{branchName:"chief/x",userStories:[]} + (if $r == null then {} else {research:$r} end)' > "$WORK/prd.$2.json"; }
mk true on; mk false off; mk null none
on_()  { probe research_enabled "$WORK/prd.$1.json"; }
on_ on   || fail '"research": true did not enable the phase'
if on_ off;  then fail '"research": false enabled the phase'; fi
if on_ none; then fail 'a tasklist with no research field enabled the phase (the default is off)'; fi
CHIEF_RESEARCH=1 on_ none || fail 'CHIEF_RESEARCH=1 did not turn research on for a tasklist that never asked'
if CHIEF_RESEARCH=0 on_ on; then fail 'CHIEF_RESEARCH=0 did not override "research": true'; fi
echo "   ok  empty sections fail, a prefix heading passes, and the override beats the tasklist both ways"

echo "RESEARCH PASS — the map is bought once per tasklist, validated against its four required sections, banked outside the worktree, reused by every story and by a resumed run, and a hand-edited map is what the next story reads"
