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

run() { # $1 = label
  ( cd "$REPO" && PATH="$WORK/fakebin:$PATH" CHIEF_RESEARCH_MAX_ATTEMPTS=1 \
      "$CHIEF" run licence ) >"$WORK/last.log" 2>&1
  local rc=$?
  # The worker's own log, not just the scheduler's: worker_park writes the sentence
  # that says WHY it stopped to the per-tasklist log, and the summary carries only
  # the status line. Both are what an operator reads, so both are asserted on.
  cat "$REPO/.chief/state/parallel/licence.log" >>"$WORK/last.log" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "$1: chief run exited $rc"
}
awaiting() { case "$(cat "$WORK/last.log")" in *AWAITING-DECISION*) ;; *) fail "$1: not AWAITING-DECISION" ;; esac; }

# ── 1. the halt: work is prepared, nothing merges ────────────────────────────
run 'first run'
awaiting 'first run'
[ -n "$(cd "$REPO" && git branch --list 'chief/licence')" ] || fail "the prepared branch was not kept"
[ ! -f "$REPO/tasks/chief/completed/licence.json" ] || fail "merged with no verdict at all"
[ ! -f "$REPO/shippable.txt" ] || fail "the gated implementation reached main with no verdict"

# ── 2. the verdict, recorded by the operator ─────────────────────────────────
( cd "$REPO" && "$CHIEF" decide licence approved \
    --note 'Licence review cleared the commercial terms.' --unpark ) >"$WORK/decide.log" 2>&1 \
  || { cat "$WORK/decide.log" >&2; fail "chief decide failed"; }
VF="$REPO/.chief/state/decisions/licence.json"
[ -s "$VF" ] || fail "chief decide wrote no durable record at $VF"
jq -e '.choice=="approved" and (.stories|length>0)' "$VF" >/dev/null \
  || fail "the durable record is not bound to the stories it approved"
jq -e '.verdict.choice=="approved"' "$REPO/tasks/chief/licence.json" >/dev/null \
  || fail "the tasklist lost its human-readable verdict"

# ── 3. STALENESS: re-word the stories and the yes does not carry over ────────
BOUND="$(jq -r '.stories' "$VF")"
PRE="$(cd "$REPO" && git rev-parse HEAD)"
( cd "$REPO" && jq '(.userStories[0].title)="Prepare something else entirely"' tasks/chief/licence.json \
    > tasks/chief/licence.tmp && mv tasks/chief/licence.tmp tasks/chief/licence.json \
    && git commit -q -am 're-word the story after the verdict' ) || fail "re-word failed"
run 're-worded run'
awaiting 're-worded run'
case "$(cat "$WORK/last.log")" in *'different stories'*) ;; *) fail "the stale verdict was not named as stale" ;; esac
[ ! -f "$REPO/tasks/chief/completed/licence.json" ] || fail "a stale verdict authorised the merge"
( cd "$REPO" && git checkout -q "$PRE" -- tasks/chief/licence.json \
    && git commit -q -m 'put the decided stories back' ) || fail "restoring the stories failed"
[ "$(cd "$REPO" && jq -r '.stories' .chief/state/decisions/licence.json)" = "$BOUND" ] \
  || fail "the recorded binding changed under us"

# ── 4. the resume: the verdict is read, and the gated work merges ────────────
run 'decided run'
case "$(cat "$WORK/last.log")" in *DECIDED*) ;; *) fail "the recorded verdict was never read" ;; esac
( cd "$REPO" && git checkout -q main ) || fail "checkout main failed"
[ -f "$REPO/shippable.txt" ] || fail "the decided work did not merge to main"
[ -f "$REPO/tasks/chief/completed/licence.json" ] || fail "the decided tasklist was not retired"
[ -n "$(jq -r '.mergedToMain // empty' "$REPO/tasks/chief/completed/licence.json")" ] \
  || fail "the retired record carries no mergedToMain stamp"
if (cd "$REPO" && git rev-parse --verify -q chief/licence >/dev/null); then
  fail "the feature branch survived the merge"
fi
echo 'DECISION-E2E PASS — halt -> chief decide -> stale verdict refused -> resume -> verify -> merge -> retire'
