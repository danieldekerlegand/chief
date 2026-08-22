#!/usr/bin/env bash
# A decision agent may prepare a brief and even try to write a verdict, but the
# driver must leave the terminal decision to chief decide.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CHIEF_PREFIX="$WORK/prefix" CHIEF_REPOS="$WORK/repos"
export GIT_AUTHOR_NAME=decision-agent GIT_AUTHOR_EMAIL=decision-agent@test
export GIT_COMMITTER_NAME=decision-agent GIT_COMMITTER_EMAIL=decision-agent@test
fail() { echo "DECISION-AGENT FAIL: $*" >&2; exit 1; }

mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
prompt="$(cat)"
if [[ "$prompt" == *"RESEARCH PHASE"* ]]; then
  mkdir -p .chief/state
  cat > .chief/state/research.md <<'DOC'
# Research — decision
<!-- chief.research/1 -->
## Target files
- tasks/chief/decision.json — tasklist and prepared deliverable.
## Data flow
- The agent prepares the brief; the operator records the choice.
## Point of insertion
- The brief is the handoff before the human decision.
## Conventions
- Keep verdict provenance in the operator command, not the agent turn.
DOC
  exit 0
fi
# Counterfactual: an agent tries to approve its own choice in both state copies.
name="$(jq -r '.branchName' .chief/state/prd.json | sed 's#^chief/##')"
for file in ".chief/state/prd.json" "tasks/chief/$name.json"; do
  jq '.verdict={choice:"sqlite",note:"agent approval"} | (.userStories[0].passes)=true' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
done
mkdir -p out
printf 'prepared ADR draft\n' > out/draft.md
git add -A
git commit -q -m 'agent: prepare decision draft'
echo '<promise>COMPLETE</promise>'
FAKE
chmod +x "$WORK/fakebin/claude"

REPO="$WORK/repo"
mkdir -p "$REPO"
(cd "$REPO" && git init -q -b main && git commit -q --allow-empty -m init && "$ROOT/bin/chief" init >/dev/null && rm -f tasks/chief/example.json)
cat > "$REPO/tasks/chief/decision.json" <<'JSON'
{"project":"decision-agent","type":"DECISION","branchName":"chief/decision","description":"Choose a storage backend","userStories":[{"id":"US-1","title":"Prepare the decision brief","description":"","acceptanceCriteria":["out/draft.md exists"],"passes":false,"notes":""}]}
JSON
(cd "$REPO" && git add tasks && git commit -q -m 'add decision tasklist')

set +e
(cd "$REPO" && PATH="$WORK/fakebin:$PATH" CHIEF_RESEARCH_MAX_ATTEMPTS=1 "$ROOT/bin/chief" run decision >"$WORK/run.log" 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || { cat "$WORK/run.log" >&2; fail "run failed with rc=$rc"; }
case "$(cat "$WORK/run.log")" in *AWAITING-DECISION*) ;; *) cat "$WORK/run.log" >&2; fail 'driver did not park for the human verdict' ;; esac
[ ! -e "$REPO/tasks/chief/completed/decision.json" ] || fail 'agent-authored verdict was treated as retirement'
[ -n "$(cd "$REPO" && git branch --list 'chief/decision')" ] || fail 'feature branch was merged despite no human verdict'
case "$(cd "$REPO" && git log --all --format=%s)" in *'agent: prepare decision draft'*) ;; *) fail 'agent preparation commit was not preserved' ;; esac
echo 'DECISION-AGENT PASS — agent draft/approval was ignored and the tasklist remained awaiting a human verdict'
