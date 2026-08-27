#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/chief-decision.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/.chief" "$tmp/tasks/chief" "$tmp/runs"
cp "$ROOT/.chief/config" "$tmp/.chief/config"
# SELF-CONTAINED. This fixture used to be `jq` over tasks/chief/106-…json, which
# stopped existing the moment 106 merged and was retired to completed/ — so the copy
# produced nothing, `choice.json` was not a DECISION tasklist, and every assertion
# below tested the refusal path of a tasklist that did not exist. A test must not
# depend on a live tasklist staying live.
jq -n '{project:"fixture",type:"DECISION",branchName:"chief/choice",
        description:"choose a storage backend",dependsOn:[],touches:[],warmup:[],
        parked:true,parkedReason:"HUMAN_DECISION: choose storage",userStories:[]}' \
  > "$tmp/tasks/chief/choice.json"
jq -n '{project:"fixture",branchName:"chief/dependent",dependsOn:["choice"],userStories:[]}' > "$tmp/tasks/chief/dependent.json"

out="$(cd "$tmp" && CHIEF_RUNS="$tmp/runs" "$ROOT/bin/chief" decide choice sqlite --note 'portable and already supported' --retire replacement 2>&1)" && {
  echo "decision: retirement with a live dependent was accepted" >&2; exit 1
} || :
grep -q 'live dependents: dependent' <<<"$out" || { echo "$out" >&2; exit 1; }
cd "$tmp" || exit 1
CHIEF_RUNS="$tmp/runs" "$ROOT/bin/chief" decide choice sqlite --note 'portable and already supported' --unpark >/dev/null || exit 1
jq -e '.verdict.note=="portable and already supported" and .parked==false and (has("parkedReason")|not)' tasks/chief/choice.json >/dev/null || exit 1
jq '.dependsOn=[]' tasks/chief/dependent.json > tasks/chief/dependent.tmp && mv tasks/chief/dependent.tmp tasks/chief/dependent.json
CHIEF_RUNS="$tmp/runs" "$ROOT/bin/chief" decide choice sqlite --note 'portable and already supported' --retire replacement >/dev/null || exit 1
jq -e '.verdict.choice=="sqlite" and .supersededBy=="replacement" and (has("mergedToMain")|not)' tasks/chief/completed/choice.json >/dev/null || exit 1
jq -e 'select(.event=="tasklist.decision" and .name=="choice" and .state=="retire")' "$tmp/runs/decisions.events.jsonl" >/dev/null || exit 1
echo "decision: refusal, unpark, retirement, and event stream green"
