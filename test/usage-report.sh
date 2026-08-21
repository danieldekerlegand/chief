#!/usr/bin/env bash
# `chief usage` aggregation over real-shaped event-log fixtures.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rc=$?; rm -rf "$WORK"; exit "$rc"' EXIT
fail() { echo "USAGE-REPORT FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

mkdir -p "$WORK/runs"
now="$(date +%s)"
repo="$WORK/repo"
mkdir -p "$repo"
repo="$(cd -P "$repo" && pwd)"

# One provider reported no usage at all, but did hit a limit and waited 60s.
printf '%s\n' \
  "{\"v\":1,\"schema\":\"chief.event/1\",\"ts\":$now,\"runId\":\"null-provider\",\"repo\":\"$repo\",\"event\":\"agent.turn\",\"usage\":null,\"limit\":null}" \
  "{\"v\":1,\"schema\":\"chief.event/1\",\"ts\":$now,\"runId\":\"null-provider\",\"repo\":\"$repo\",\"event\":\"tasklist.rate-limit-wait\",\"usage\":null,\"limit\":{\"hit\":true,\"retry_at\":$((now + 60)),\"waits\":1,\"max_waits\":8}}" \
  > "$WORK/runs/null-provider.events.jsonl"

# A second provider reported usage on one turn and null on another.
printf '%s\n' \
  "{\"v\":1,\"schema\":\"chief.event/1\",\"ts\":$now,\"runId\":\"measured\",\"repo\":\"$repo\",\"event\":\"agent.turn\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15,\"cost_usd\":0.25},\"limit\":null}" \
  "{\"v\":1,\"schema\":\"chief.event/1\",\"ts\":$now,\"runId\":\"measured\",\"repo\":\"$repo\",\"event\":\"agent.turn\",\"usage\":null,\"limit\":null}" \
  > "$WORK/runs/measured.events.jsonl"

json="$(CHIEF_RUNS="$WORK/runs" bash "$ROOT/bin/chief" usage --repo "$repo" --json)"
jq -e '
  (.runs | length) == 2 and
  (.total.turns == 3) and (.total.input_tokens == 10) and
  (.total.output_tokens == 5) and (.total.total_tokens == 15) and
  (.total.cost_usd == 0.25) and (.total.limit_incidents == 1) and
  (.total.wait_seconds == 60) and (.total.last_reset_eta != null) and
  ([.runs[] | select(.run_id == "null-provider")][0].usage.input_tokens == null) and
  ([.runs[] | select(.run_id == "null-provider")][0].limits.incidents == 1)
' <<<"$json" >/dev/null || { echo "$json" >&2; fail "fixture aggregation did not preserve measured values, null usage, and limit wait"; }

help="$(CHIEF_RUNS="$WORK/runs" bash "$ROOT/bin/chief" usage --help)"
[[ "$help" == *"chief usage"* && "$help" == *"--json"* ]] || fail "usage --help omitted the command shape"

echo "USAGE-REPORT PASS — 2 fixture runs, 3 turns, 10/5/15 tokens, 0.25 cost, 1 limit, 60s wait; null usage preserved"
