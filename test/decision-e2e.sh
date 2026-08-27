#!/usr/bin/env bash
# test/decision-e2e.sh — the path a decision tasklist takes ALL THE WAY THROUGH:
# halt at AWAITING-DECISION -> `chief decide` -> resume -> verify -> merge -> retire.
#
# 106 shipped the operator surface and the halt and never connected them, and the
# reason it survived shipping is that this sequence had never once executed: there
# were tests for the halt, and tests for the command, and none that ran the second
# after the first. The first decision tasklist to run in anger could not be finished
# by any invocation of the command built to finish it.
#
# The tasklist here CARRIES CODE (a file the verify hook insists on) rather than being
# a bare verdict, because that is the shape that broke — an implementation gated on a
# licence call, waiting for a human to say yes.
#
# Also pins the STALENESS bind: a verdict is consent to a specific brief, so re-wording
# the stories after it is recorded must send the tasklist back to the operator instead
# of merging on an approval given for something else.
#
# And the ACTION SET, because a mechanism that can only say yes is not a decision
# point: a verdict recorded with --unpark authorises NO merge and the tasklist halts
# again; --proceed is what lets the gated work through; --decline records the operator
# saying NO and the branch never merges; --retire still refuses while live dependents
# exist. The verdict, its note and its action land in the event stream on both halves —
# the operator recording it, and the driver reading it back.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export CHIEF_PREFIX="$WORK/prefix" CHIEF_REPOS="$WORK/repos" CHIEF_RUNS="$WORK/runs"
export GIT_AUTHOR_NAME=decision-e2e GIT_AUTHOR_EMAIL=decision-e2e@test
export GIT_COMMITTER_NAME=decision-e2e GIT_COMMITTER_EMAIL=decision-e2e@test
CHIEF="$ROOT/bin/chief"
fail() { echo "DECISION-E2E FAIL: $*" >&2; [ -s "$WORK/last.log" ] && cat "$WORK/last.log" >&2; exit 1; }
command -v jq >/dev/null || fail "jq is required"

# ── the scripted agent: prepares the gated implementation, never the verdict ──
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
prompt="$(cat)"
if [[ "$prompt" == *"RESEARCH PHASE"* ]]; then
  mkdir -p .chief/state
  cat > .chief/state/research.md <<'DOC'
# Research — licence
<!-- chief.research/1 -->
## Target files
- shippable.txt — the implementation the licence call gates.
## Data flow
- The agent builds it; the operator decides whether it ships.
## Point of insertion
- The brief is the handoff before the human decision.
## Conventions
- The verdict is the operator's, recorded through `chief decide`.
DOC
  exit 0
fi
PRD=".chief/state/prd.json"
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  printf 'the anchor row this decision gates\n' > shippable.txt
  # A per-tasklist marker: 'shippable.txt' cannot tell whose branch reached main once a
  # second decision tasklist exists, and the declined one has to be provably absent.
  printf 'prepared by %s\n' "$name" > "$name.stamp"
  for f in "$PRD" "tasks/chief/$name.json"; do
    t="$(mktemp)"; jq --arg id "$id" \
      '(.userStories[]|select(.id==$id)|.passes)=true |
       (.userStories[]|select(.id==$id)|.notes)="shippable.txt written; verify hook green"' \
      "$f" > "$t" && mv "$t" "$f"
  done
  git add -A >/dev/null 2>&1 || true
  git commit -q -m "feat: $id - prepare the gated implementation" >/dev/null 2>&1 || true
fi
[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── a repo whose verify hook has teeth: the gated file must be on the branch ──
REPO="$WORK/repo"; mkdir -p "$REPO"
( cd "$REPO" && git init -q -b main && git commit -q --allow-empty -m init \
  && "$CHIEF" init >/dev/null && rm -f tasks/chief/example.json ) || fail "scaffold failed"
cat > "$REPO/.chief/verify.sh" <<'SH'
#!/usr/bin/env bash
set -eu
[ -f shippable.txt ] || { echo "verify: the gated implementation is missing"; exit 1; }
echo "verify: gated implementation present"
SH
chmod +x "$REPO/.chief/verify.sh"
# Pretty-printed, so the stale-case edit to `title` and the agent's edit to `passes`
# land in hunks far enough apart to rebase cleanly. A one-line fixture would collide
# and report a conflict where this test means to report a stale verdict.
jq -n '{project:"licence",type:"DECISION",branchName:"chief/licence",
        description:"Ship the commercial base anchor, or do not",
        iters:3,dependsOn:[],touches:[],warmup:[],
        userStories:[{id:"US-1",title:"Prepare the gated implementation",description:"",
                      acceptanceCriteria:["shippable.txt exists","the brief names both options",
                                          "no verdict is recorded by the agent"],
                      passes:false,notes:""}]}' > "$REPO/tasks/chief/licence.json"
( cd "$REPO" && git add -A && git commit -q -m "decision tasklist + verify hook" ) || fail "commit failed"

run() { # $1 = label, $2 = tasklist (default licence), $3… = extra `chief run` flags
  local label="$1" name="${2:-licence}"; shift 2>/dev/null || true; shift 2>/dev/null || true
  ( cd "$REPO" && PATH="$WORK/fakebin:$PATH" CHIEF_RESEARCH_MAX_ATTEMPTS=1 \
      "$CHIEF" run "$@" "$name" ) >"$WORK/last.log" 2>&1
  local rc=$?
  # The worker's own log, not just the scheduler's: worker_park writes the sentence
  # that says WHY it stopped to the per-tasklist log, and the summary carries only
  # the status line. Both are what an operator reads, so both are asserted on.
  cat "$REPO/.chief/state/parallel/$name.log" >>"$WORK/last.log" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "$label: chief run exited $rc"
}
saw() { case "$(cat "$WORK/last.log")" in *"$2"*) ;; *) fail "$1: the run never said '$2'" ;; esac; }
decide() { # $1 = tasklist, then the rest of `chief decide`s arguments
  ( cd "$REPO" && "$CHIEF" decide "$@" ) >"$WORK/decide.log" 2>&1
}
awaiting() { case "$(cat "$WORK/last.log")" in *AWAITING-DECISION*) ;; *) fail "$1: not AWAITING-DECISION" ;; esac; }

# ── 1. the halt: work is prepared, nothing merges ────────────────────────────
run 'first run'
awaiting 'first run'
[ -n "$(cd "$REPO" && git branch --list 'chief/licence')" ] || fail "the prepared branch was not kept"
[ ! -f "$REPO/tasks/chief/completed/licence.json" ] || fail "merged with no verdict at all"
[ ! -f "$REPO/shippable.txt" ] || fail "the gated implementation reached main with no verdict"

# ── 2. a verdict that authorises NOTHING: --unpark is not consent to merge ───
# The action set before this story had only --retire and --unpark, both of which
# assume the deliverable IS the verdict. Recording one on a tasklist carrying code
# must NOT release the branch, and must say which flag would.
decide licence approved --note 'Licence review cleared the commercial terms.' --unpark \
  || { cat "$WORK/decide.log" >&2; fail "chief decide --unpark failed"; }
case "$(cat "$WORK/decide.log")" in *'authorises no merge'*) ;;
  *) cat "$WORK/decide.log" >&2; fail "--unpark did not say that it authorises no merge" ;; esac
run 'unparked run'
awaiting 'unparked run'
saw 'unparked run' 'authorises no merge'
[ ! -f "$REPO/tasks/chief/completed/licence.json" ] || fail "--unpark alone authorised the merge"

# ── 3. the verdict that DOES: --proceed ──────────────────────────────────────
decide licence approved --note 'Licence review cleared the commercial terms.' --proceed \
  || { cat "$WORK/decide.log" >&2; fail "chief decide --proceed failed"; }
VF="$REPO/.chief/state/decisions/licence.json"
[ -s "$VF" ] || fail "chief decide wrote no durable record at $VF"
jq -e '.choice=="approved" and .action=="proceed" and (.stories|length>0) and (.who|length>0)' "$VF" >/dev/null \
  || { jq . "$VF" >&2; fail "the durable record is not bound to the stories, the action and the human"; }
# The LIVE tasklist is deliberately left alone by --proceed: it is about to rebase, and
# a verdict committed beside the branch's own edits to that file is a REBASE-CONFLICT.
# So the tree must be CLEAN afterwards, or the next run refuses to start at all.
[ -z "$(cd "$REPO" && git status --porcelain)" ] \
  || { (cd "$REPO" && git status --porcelain >&2); fail "chief decide left the tree dirty — the next run cannot start"; }

# ── 4. STALENESS: re-word the stories and the yes does not carry over ────────
BOUND="$(jq -r '.stories' "$VF")"
PRE="$(cd "$REPO" && git rev-parse HEAD)"
( cd "$REPO" && jq '(.userStories[0].title)="Prepare something else entirely"' tasks/chief/licence.json \
    > tasks/chief/licence.tmp && mv tasks/chief/licence.tmp tasks/chief/licence.json \
    && git commit -q -am 're-word the story after the verdict' ) || fail "re-word failed"
run 're-worded run'
awaiting 're-worded run'
saw 're-worded run' 'different stories'
[ ! -f "$REPO/tasks/chief/completed/licence.json" ] || fail "a stale verdict authorised the merge"
( cd "$REPO" && git checkout -q "$PRE" -- tasks/chief/licence.json \
    && git commit -q -m 'put the decided stories back' ) || fail "restoring the stories failed"
[ "$(cd "$REPO" && jq -r '.stories' .chief/state/decisions/licence.json)" = "$BOUND" ] \
  || fail "the recorded binding changed under us"

# ── 5. the resume: the verdict is read, and the gated work merges ────────────
run 'decided run'
saw 'decided run' DECIDED
( cd "$REPO" && git checkout -q main ) || fail "checkout main failed"
[ -f "$REPO/shippable.txt" ] || fail "the decided work did not merge to main"
[ -f "$REPO/licence.stamp" ] || fail "the decided branch is not what reached main"
[ -f "$REPO/tasks/chief/completed/licence.json" ] || fail "the decided tasklist was not retired"
[ -n "$(jq -r '.mergedToMain // empty' "$REPO/tasks/chief/completed/licence.json")" ] \
  || fail "the retired record carries no mergedToMain stamp"
# The permanent human-readable copy of the verdict: stamped onto the completed record
# at the merge, which is the one file past every rebase.
jq -e '.verdict.choice=="approved" and .verdict.action=="proceed" and (.verdict.who|length>0)' \
  "$REPO/tasks/chief/completed/licence.json" >/dev/null \
  || { jq '.verdict' "$REPO/tasks/chief/completed/licence.json" >&2; fail "the merged record carries no verdict"; }
if (cd "$REPO" && git rev-parse --verify -q chief/licence >/dev/null); then
  fail "the feature branch survived the merge"
fi

# ── 6. WHICH HUMAN DECIDED WHAT, in the event stream ─────────────────────────
# Both halves: `chief decide` emits when the operator records it (there may be no run
# alive then), and decision_stop emits when the DRIVER reads the record — which is the
# one that puts the consent in the completed run's own stream.
ev_has() { # $1 = a glob of event files, $2 = label
  local f found=0
  for f in $1; do
    [ -f "$f" ] || continue
    jq -e -s 'any(.[]; .event=="tasklist.decision" and .state=="proceed"
                        and (.detail|test("approved")) and (.detail|test("commercial terms")))' \
      "$f" >/dev/null 2>&1 && found=1
  done
  [ "$found" = 1 ] || fail "$2 carries no tasklist.decision event with the verdict, action and note"
}
ev_has "$CHIEF_RUNS/decisions.events.jsonl" 'the operator-side event log'
ev_has "$CHIEF_RUNS/*.events.jsonl" "the run's own event stream"

# ── 7. SAYING NO: a decision that carries code, declined ─────────────────────
# The whole point of the negative arm — a mechanism that can only say yes is not a
# decision point. A dependent is planted first, so the two end-of-life actions can be
# told apart: --retire is REFUSED while one is live, --decline is the operator's answer
# and is reported, not vetoed.
jq -n '{project:"licence",type:"DECISION",branchName:"chief/licence-b",
        description:"Ship the second anchor, or do not",
        iters:3,dependsOn:[],touches:[],warmup:[],
        userStories:[{id:"US-1",title:"Prepare the second gated implementation",description:"",
                      acceptanceCriteria:["shippable.txt exists","the brief names both options"],
                      passes:false,notes:""}]}' > "$REPO/tasks/chief/licence-b.json"
jq -n '{project:"licence",branchName:"chief/waits-on-b",description:"waits on the decision",
        iters:1,dependsOn:["licence-b"],touches:[],warmup:[],
        userStories:[{id:"US-1",title:"Downstream",description:"",acceptanceCriteria:["x"],
                      passes:false,notes:""}]}' > "$REPO/tasks/chief/waits-on-b.json"
( cd "$REPO" && git add -A && git commit -q -m 'a second decision, and something waiting on it' ) \
  || fail "second fixture commit failed"

run 'second decision' licence-b
awaiting 'second decision'
decide licence-b rejected --note 'The vendor licence forbids redistribution.' --retire 999-successor \
  && { cat "$WORK/decide.log" >&2; fail "--retire did not refuse while a live dependent exists"; }
case "$(cat "$WORK/decide.log")" in *'live dependents'*waits-on-b*) ;;
  *) cat "$WORK/decide.log" >&2; fail "the retirement refusal did not name the dependent" ;; esac
[ -f "$REPO/tasks/chief/licence-b.json" ] || fail "the refused retirement filed the tasklist anyway"

decide licence-b rejected --note 'The vendor licence forbids redistribution.' --decline \
  || { cat "$WORK/decide.log" >&2; fail "chief decide --decline failed"; }
case "$(cat "$WORK/decide.log")" in *waits-on-b*) ;;
  *) cat "$WORK/decide.log" >&2; fail "the decline did not name the dependents it strands" ;; esac
jq -e '.verdict.action=="decline" and .parked==true and .parkedReason=="declined"' \
  "$REPO/tasks/chief/licence-b.json" >/dev/null || fail "a declined tasklist was not parked as declined"
# A declined tasklist never rebases, so its own JSON IS the right place for the verdict —
# and it has to be committed, or the next run stops on the dirty tree instead of the park.
[ -z "$(cd "$REPO" && git status --porcelain)" ] \
  || { (cd "$REPO" && git status --porcelain >&2); fail "the decline left the tasklist edit uncommitted"; }

# The park is the first guard: a declined decision is not scheduled again at all.
run 'declined, scheduled normally' licence-b
case "$(cat "$WORK/last.log")" in *declined*) ;; *) fail "the park did not report the decline" ;; esac

# And the driver is the second, independent one: run it anyway and it still refuses.
run 'declined, run anyway' licence-b --parked
saw 'declined, run anyway' DECISION-DECLINED
( cd "$REPO" && git checkout -q main ) || fail "checkout main failed"
[ ! -f "$REPO/licence-b.stamp" ] || fail "a DECLINED decision merged its work to main"
[ ! -f "$REPO/tasks/chief/completed/licence-b.json" ] || fail "a declined tasklist was retired behind the operator"
[ -n "$(cd "$REPO" && git branch --list 'chief/licence-b')" ] \
  || fail "the declined branch was discarded — declining work is not deleting it"

echo 'DECISION-E2E PASS — halt -> unpark authorises nothing -> --proceed -> stale verdict refused -> merge -> retire; --decline never merges'
