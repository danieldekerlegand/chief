#!/usr/bin/env bash
# `chief ps --all` is the aggregate repo view: every live state is visible and
# completed records are not. The fixture has no driver, so a second implementation
# cannot accidentally make the test pass by reusing only registry rows.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CHIEF_PREFIX="$WORK/prefix" CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
export GIT_AUTHOR_NAME=psall GIT_AUTHOR_EMAIL=psall@test GIT_COMMITTER_NAME=psall GIT_COMMITTER_EMAIL=psall@test
REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$ROOT/bin/chief" init >/dev/null
rm -f tasks/chief/example.json
task() {
  local extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  jq -n --arg n "$1" --argjson x "$extra" \
    '{project:"ps-all",branchName:("chief/"+$n),description:"fixture",iters:1,dependsOn:[],touches:[],warmup:[],userStories:[{id:"US-1",title:"fixture",description:"",acceptanceCriteria:["fixture"],passes:false,notes:""}]} + $x' \
    > "tasks/chief/$1.json"
}
task ready
task blocked '{"dependsOn":["ready"]}'
task parked '{"parked":true,"parkedReason":"waiting for product"}'
mkdir -p tasks/chief/completed
task done '{"userStories":[{"id":"US-1","title":"fixture","description":"","acceptanceCriteria":["fixture"],"passes":true,"notes":"done"}]}'
mv tasks/chief/done.json tasks/chief/completed/done.json

out="$($ROOT/bin/chief ps --all)"
for name in ready blocked parked; do case "$out" in *"$name"*) ;; *) echo "$out"; echo "missing $name" >&2; exit 1 ;; esac; done
case "$out" in *"blocked"*"needs "*) ;; *) echo "$out"; echo "missing blocked dependency reason" >&2; exit 1 ;; esac
case "$out" in *"parked"*"waiting for product"*) ;; *) echo "$out"; echo "missing parked reason" >&2; exit 1 ;; esac
printf '%s\n' "$out" | grep -Eq '^   done[[:space:]]' && { echo "$out"; echo "completed tasklist leaked into --all" >&2; exit 1; } || :

monitor_out="$WORK/monitor.out"
"$ROOT/bin/chief" monitor --all 0 >"$monitor_out" 2>&1 & monitor_pid=$!
sleep 0.2
kill "$monitor_pid" 2>/dev/null || :
wait "$monitor_pid" 2>/dev/null || :
grep -q 'waiting for product' "$monitor_out"
echo "PS-ALL PASS — ready, blocked, parked rendered with reasons; done omitted"
