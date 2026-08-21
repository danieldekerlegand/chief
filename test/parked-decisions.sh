#!/usr/bin/env bash
# Decision classes make human-held parks filterable without making park prose closed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export CHIEF_PREFIX="$WORK/prefix" CHIEF_REPOS="$WORK/repos"
export GIT_AUTHOR_NAME=decision GIT_AUTHOR_EMAIL=decision@test GIT_COMMITTER_NAME=decision GIT_COMMITTER_EMAIL=decision@test
CHIEF="$ROOT/bin/chief"
fail() { echo "DECISION FAIL: $*" >&2; exit 1; }
mkdir -p "$WORK/repo"; (cd "$WORK/repo" && git init -q -b main && git commit -q --allow-empty -m init && "$CHIEF" init >/dev/null && rm -f tasks/chief/example.json)
task() { jq -n --arg n "$1" --arg r "$2" '{project:"t",branchName:("chief/"+$n),description:"x",dependsOn:[],touches:[],warmup:[],userStories:[],parked:true,parkedReason:$r}' > "$WORK/repo/tasks/chief/$1.json"; }
task 10-decision 'HUMAN_DECISION: choose option A'
task 11-toolchain 'TOOLCHAIN: SDK is not provisioned'
task 12-counterparty 'COUNTERPARTY: awaiting licence'
task 13-unknown 'MYSTERY: still opaque'
task 14-missing ''

if (cd "$WORK/repo" && "$CHIEF" lint 14-missing >/dev/null 2>&1); then fail 'lint accepted parked tasklist without parkedReason'; fi
OUT="$(cd "$WORK/repo" && "$CHIEF" status --decision 2>/dev/null)" || fail 'status --decision failed'
case "$OUT" in *10-decision*) ;; *) fail "decision filter omitted HUMAN_DECISION park: $OUT" ;; esac
case "$OUT" in *11-toolchain*|*12-counterparty*|*13-unknown*) fail "decision filter included a non-decision park: $OUT" ;; esac
OUT="$(cd "$WORK/repo" && "$CHIEF" status 2>/dev/null)" || fail 'plain status failed'
case "$OUT" in *'MYSTERY: still opaque'*) ;; *) fail 'unknown class was not rendered verbatim' ;; esac
echo 'PARKED-DECISIONS PASS — lint requires reasons and --decision filters HUMAN_DECISION parks'
