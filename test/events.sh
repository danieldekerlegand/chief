#!/usr/bin/env bash
# test/events.sh — the machine-readable EVENT STREAM (NDJSON), end to end.
#
# What this pins: engine/events.sh + the emit points in driver.sh/agent.sh publish a
# per-run, append-only NDJSON log ($CHIEF_RUNS/<run-id>.events.jsonl) that a host —
# chief-cloud, an embedding UI — subscribes to instead of polling <name>.live.json and
# diffing it. docs/reference/events.md is the contract; this test is what keeps the contract
# honest. It asserts against a REAL hermetic run (fake `claude` on PATH, temp CHIEF_*
# prefixes), not fixtures, so the events cannot drift from the transitions they project.
#
# Two runs, because the two outcomes a host must be able to tell apart are the two
# ends of the merge phase:
#   1. A MERGED tasklist    — run.started · tasklist.launched · story.passed ×2 ·
#                             tasklist.merged · run.finished(merged)
#   2. A VERIFY-FAILED one  — the same opening, then tasklist.verify-failed(failed) ·
#                             run.finished(verify-failed)
# Plus, on every line of both: well-formed NDJSON, the versioned `v`/`schema` fields,
# and a runId that matches the file it lives in. Each run gets its OWN log file, and
# `chief events` replays it byte-for-byte on a pure stdout.
#
# Two more runs pin the OBSERVATION-ONLY usage/cost/limit block (docs/reference/events.md), the
# runner-side data source chief-cloud's spend/quota ledger persists — both halves of
# "populated only when the provider exposes the signal":
#   3. A provider that PRINTS usage and trips a limit mid-turn — the sleep-and-retry
#      path: tasklist.rate-limit-wait carries limit{hit,retry_at,waits,max_waits} and
#      the working turn's agent.turn carries usage{tokens,cost,duration}.
#   4. A provider that only ever answers with a limit message — the driver-side stop:
#      tasklist.rate-limited carries the ETA the engine parsed out of that message.
# Runs 1 and 2 are the negative case: their provider prints nothing usage-shaped, so
# every line must read usage:null / limit:null rather than a hollow object of zeros.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rc=$?; rm -rf "$WORK"; exit "$rc"' EXIT
fail() { echo "EVENTS FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

export GIT_AUTHOR_NAME=ev GIT_AUTHOR_EMAIL=ev@test GIT_COMMITTER_NAME=ev GIT_COMMITTER_EMAIL=ev@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"   # hermetic: never touch ~/.chief

# ── The harness: an installed chief + a fake provider ────────────────────────
PREFIX="$WORK/cp"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# One story per turn, then COMPLETE — so a 2-story tasklist produces two turns and
# proves the LAST story (which passes on the COMPLETE turn) is still reported. Output
# files are scoped by tasklist name: two tasklists writing byte-identical paths would
# produce a JSON-only diff and trip the no-work guard (test/noworkguard-jsononly.sh).
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null
PRD=".chief/state/prd.json"
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"; TRACKED="tasks/chief/$name.json"
# The two usage/limit personalities, selected by tasklist name so one fake serves
# every run. Nothing else prints anything usage-shaped — that is runs 1 and 2's
# negative case, and it is easy to break by accident.
case "$name" in
  evlim)
    # First call: a limit with NO parseable reset (the loop falls back to
    # RATE_LIMIT_WAIT, pinned to 1s). Later calls: work + a provider usage line.
    n=$(( $(cat "${EV_LIMIT_COUNTER:-/dev/null}" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "${EV_LIMIT_COUNTER:?}"
    if [ "$n" = "1" ]; then echo "Error: usage limit reached. Please try again later."; exit 0; fi
    echo '{"type":"result","total_cost_usd":0.0421,"duration_ms":18324,"num_turns":3,"usage":{"input_tokens":1200,"output_tokens":340}}'
    ;;
  evlim2)
    # Always limited, with a parseable epoch — the engine must publish THAT ETA.
    echo "Claude AI usage limit reached|${EV_LIMIT_RESET:?}"
    exit 0
    ;;
esac
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  mkdir -p out; echo "impl $name $id" > "out/$name-$id.txt"
  for f in "$PRD" "$TRACKED"; do
    [ -f "$f" ] || continue
    t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id).passes)=true' "$f" > "$t" && mv "$t" "$f"
  done
  git add -A >/dev/null 2>&1 || true; git commit -q -m "feat: $id" >/dev/null 2>&1 || true
fi
[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# mkrepo DIR NAME STORY_IDS VERIFY_BODY — a fresh chief-managed repo with one tasklist.
# Separate repos (not two tasklists in one) keep the two runs' event logs independent:
# a merged tasklist left in place would be re-picked by the next run as an all-pass
# branch and emit a second merge.
mkrepo() {
  local dir="$1" name="$2" ids="$3" vbody="$4" id
  mkdir -p "$dir"; cd "$dir"
  git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
  git commit -q --allow-empty -m init
  "$CHIEF" init >/dev/null
  rm -f tasks/chief/example.json
  jq -n --arg name "$name" --arg ids "$ids" '
    { project:$name, branchName:("chief/"+$name), description:"event stream fixture",
      iters:4, dependsOn:[], touches:[], warmup:[],
      userStories:[ $ids|split(" ")[]|{id:., title:("story "+.), description:"",
                                      acceptanceCriteria:["out"], passes:false, notes:""} ] }
  ' > "tasks/chief/$name.json" || fail "could not write tasks/chief/$name.json"
  printf '%s\n' '#!/usr/bin/env bash' 'set -uo pipefail' "$vbody" > .chief/verify.sh
  chmod +x .chief/verify.sh
  git add -A && git commit -q -m "$name setup"
}

# ── Per-line validation: the shape contract, on every event of every log ─────
# NDJSON means each line must stand alone, so this validates line by line rather
# than slurping — a log that only parses as a whole would break every consumer.
validate() {
  local f="$1" ctx="$2" n=0 line
  [ -s "$f" ] || fail "$ctx: no event log at $f"
  while IFS= read -r line; do
    n=$((n+1))
    printf '%s' "$line" | jq -e . >/dev/null 2>&1 \
      || fail "$ctx: line $n is not valid JSON: $line"
    printf '%s' "$line" | jq -e '
      .v == 1 and .schema == "chief.event/1" and (.ts|type) == "number" and .ts > 0
      and (.runId // "") != "" and (.repo // "") != ""
      and (.event // "") != "" and (.state // "") != ""
    ' >/dev/null 2>&1 || fail "$ctx: line $n is missing a required field (v/schema/ts/runId/repo/event/state): $line"
    # usage/limit are OPTIONAL in content but not in shape: always present, always
    # either null ("not available here") or an object — never a bare number or a
    # string a ledger would have to guess at.
    printf '%s' "$line" | jq -e '
      has("usage") and has("limit")
      and (.usage == null or (.usage|type) == "object")
      and (.limit == null or (.limit|type) == "object")
      and (.usage == null or ((.usage.cost_usd // 0)|type) == "number")
      and (.limit == null or ((.limit.hit // false)|type) == "boolean")
    ' >/dev/null 2>&1 || fail "$ctx: line $n has a malformed usage/limit block: $line"
  done < "$f"
  [ "$n" -gt 0 ] || fail "$ctx: the event log is empty"
  echo "$n"
}

# events_log_of RUNS_DIR — the single event log in a runs dir (one run at a time here).
seq_of()   { jq -r '.event' "$1" | tr '\n' ' ' | sed 's/ $//'; }
state_of() { jq -r --arg e "$2" 'select(.event==$e)|.state' "$1" | tr '\n' ' ' | sed 's/ $//'; }

# ══ RUN 1 — a MERGED tasklist ════════════════════════════════════════════════
echo "events: run 1 — a merged tasklist"
mkrepo "$WORK/ok" ev "US-1 US-2" 'echo "verify: ok"; exit 0'
PATH="$WORK/fakebin:$PATH" "$CHIEF" run -p 1 >"$WORK/run1.log" 2>&1 \
  || { tail -30 "$WORK/run1.log" >&2; fail "run 1 exited non-zero"; }

logs="$(find "$CHIEF_RUNS" -maxdepth 1 -name '*.events.jsonl' | sort)"
[ "$(printf '%s\n' "$logs" | wc -l | tr -d ' ')" = 1 ] \
  || fail "expected exactly one event log after run 1, got: $logs"
LOG1="$logs"
n1="$(validate "$LOG1" "run 1")"
echo "--- $(basename "$LOG1") ($n1 events) ---"; cat "$LOG1"

# The filename IS the run id — that is how a host holding only `chief: run-id=` finds
# the log (docs/reference/events.md), so the two must never disagree.
rid1="$(basename "$LOG1" .events.jsonl)"
[ "$(jq -r '.runId' "$LOG1" | sort -u | wc -l | tr -d ' ')" = 1 ] || fail "run 1's log mixes runIds"
[ "$(jq -r '.runId' "$LOG1" | head -1)" = "$rid1" ] \
  || fail "runId in the log != the filename ($rid1)"

got="$(seq_of "$LOG1")"
want="run.started tasklist.launched story.passed agent.turn story.passed agent.turn tasklist.merged run.finished"
[ "$got" = "$want" ] || fail "merged-run sequence
  want: $want
  got:  $got"

[ "$(state_of "$LOG1" run.started)"       = running ] || fail "run.started state != running"
[ "$(state_of "$LOG1" tasklist.launched)" = running ] || fail "tasklist.launched state != running"
[ "$(state_of "$LOG1" tasklist.merged)"   = done ]    || fail "tasklist.merged state != done"
[ "$(state_of "$LOG1" run.finished)"      = merged ]  || fail "run.finished state != merged (got '$(state_of "$LOG1" run.finished)')"

# Scoping: run.* events name no tasklist, tasklist.*/story.* always do, and only
# story.passed carries a story id — a consumer routes on exactly these three shapes.
[ "$(jq -r 'select(.event|startswith("run."))|.name' "$LOG1" | sort -u)" = null ] \
  || fail "a run.* event carried a tasklist name"
[ "$(jq -r 'select(.event|startswith("run."))|.story' "$LOG1" | sort -u)" = null ] \
  || fail "a run.* event carried a story id"
[ "$(jq -r 'select(.event|startswith("run.")|not)|.name' "$LOG1" | sort -u)" = ev ] \
  || fail "a tasklist/story event named the wrong tasklist"
[ "$(jq -r 'select(.story != null)|.event' "$LOG1" | sort -u)" = story.passed ] \
  || fail "a non-story event carried a story id"
[ "$(jq -r 'select(.event=="story.passed")|.story' "$LOG1" | tr '\n' ' ')" = "US-1 US-2 " ] \
  || fail "story.passed didn't report US-1 then US-2 (the last story passes on the COMPLETE turn)"
[ "$(jq -r '.repo' "$LOG1" | sort -u)" = "$WORK/ok" ] || fail "the repo field is not the driven repo"

# NEGATIVE USAGE CASE: this provider prints nothing usage-shaped and no limit was hit,
# so every line — including the per-turn agent.turn events — must read null rather than
# a hollow object of zeros. A ledger has to be able to tell "not reported" from "free".
[ "$(jq -r '.usage' "$LOG1" | sort -u)" = null ] \
  || fail "a run-1 event carried a usage block from a provider that printed none"
[ "$(jq -r '.limit' "$LOG1" | sort -u)" = null ] \
  || fail "a run-1 event carried a limit block though no limit was hit"
[ "$(jq -r 'select(.event=="agent.turn")|.name' "$LOG1" | tr '\n' ' ')" = "ev ev " ] \
  || fail "agent.turn wasn't emitted once per provider turn, named with its tasklist"

# Non-decreasing timestamps: a subscriber orders on `ts`, so it must never go backwards.
[ "$(jq -r '.ts' "$LOG1" | sort -n | tr '\n' ' ')" = "$(jq -r '.ts' "$LOG1" | tr '\n' ' ')" ] \
  || fail "timestamps are not non-decreasing in write order"
echo "   ok  $n1 events: launched → US-1 → US-2 → merged → run.finished(merged), all schema-valid"
echo "   ok  a provider that reports no usage yields usage:null / limit:null on every line"

# ── The subscribe surface replays the same bytes on a pure stdout ────────────
"$CHIEF" events "$rid1" > "$WORK/replay.out" 2>"$WORK/replay.err" || fail "\`chief events $rid1\` exited non-zero"
cmp -s "$WORK/replay.out" "$LOG1" || fail "\`chief events\` stdout is not byte-identical to the log"
"$CHIEF" events -l >"$WORK/list.out" 2>&1 || fail "\`chief events -l\` exited non-zero"
grep -q "$rid1" "$WORK/list.out" || { cat "$WORK/list.out" >&2; fail "\`chief events -l\` didn't list $rid1"; }
echo "   ok  \`chief events <run-id>\` replays the log verbatim; \`-l\` lists it"

# ══ RUN 2 — a VERIFY-FAILED tasklist ════════════════════════════════════════
# Same opening events, a different end of the merge phase: the branch is kept and the
# run reports verify-failed. This is the transition a poller is most likely to miss.
echo "events: run 2 — a verify-failed tasklist"
mkrepo "$WORK/bad" evbad "US-1" 'echo "verify: deliberately red"; exit 1'
# --headless so the run's outcome is also visible as an EXIT CODE, and the stream can
# be crossed against it: the contract is one decision published twice (docs/reference/events.md).
# (A plain `chief run` reports the same outcome in words but always exits 0 — hl_rc.)
# RETRY_MAX=2 pins the retry budget so the sequence below is exact: a verify failure is
# RETRYABLE (docs — a flaky gate must not rot a branch), so the tasklist is re-armed and
# re-attempted, and every attempt re-emits the launched → verify-failed pair. The retry
# DOES take a turn (it reports one, because it really happened and really cost tokens),
# but that turn has nothing left to do and announces no story: story.passed appears ONCE
# across both attempts — a subscriber must never see a story announced twice.
# The retry's launched is followed by `tasklist.re-engaged`: the second attempt picks up
# a branch that already passes every story and whose verify failed, which is not a fresh
# start and says so (engine/driver.sh mark_reengage). It is the durable half of that
# statement — the live phase is gone the moment the turn begins, and "why did this branch
# run again?" is a question asked afterwards.
PATH="$WORK/fakebin:$PATH" RETRY_MAX=2 "$CHIEF" run --headless -p 1 >"$WORK/run2.log" 2>&1 && rc2=0 || rc2=$?
[ "$rc2" = 4 ] || { tail -30 "$WORK/run2.log" >&2; fail "a verify-failed headless run exited $rc2, want 4 (HL_RC_VERIFY)"; }

LOG2="$(find "$CHIEF_RUNS" -maxdepth 1 -name '*.events.jsonl' ! -name "$(basename "$LOG1")")"
[ -n "$LOG2" ] && [ "$(printf '%s\n' "$LOG2" | wc -l | tr -d ' ')" = 1 ] \
  || fail "run 2 did not get its own event log (got: $LOG2)"
n2="$(validate "$LOG2" "run 2")"
echo "--- $(basename "$LOG2") ($n2 events) ---"; cat "$LOG2"

got="$(seq_of "$LOG2")"
want="run.started tasklist.launched story.passed agent.turn tasklist.verify-failed tasklist.launched tasklist.re-engaged agent.turn tasklist.verify-failed run.finished"
[ "$got" = "$want" ] || fail "verify-failed sequence
  want: $want
  got:  $got"
[ "$(state_of "$LOG2" tasklist.verify-failed)" = "failed failed" ] \
  || fail "tasklist.verify-failed state != failed on both attempts"
[ "$(jq -r 'select(.event=="story.passed")|.story' "$LOG2" | tr '\n' ' ')" = "US-1 " ] \
  || fail "the skip-agent retry re-announced a story that had already passed"
[ "$(state_of "$LOG2" run.finished)" = verify-failed ] \
  || fail "run.finished state != verify-failed (got '$(state_of "$LOG2" run.finished)')"
# The verify-failed event must point a human at the persisted log — `detail` is not
# machine contract, but an empty one makes the stream useless for triage.
[ -n "$(jq -r 'select(.event=="tasklist.verify-failed")|.detail // ""' "$LOG2")" ] \
  || fail "tasklist.verify-failed carries no detail"
[ "$(jq -r '.runId' "$LOG2" | head -1)" = "$(basename "$LOG2" .events.jsonl)" ] \
  || fail "run 2's runId != its filename"
[ "$(jq -r '.runId' "$LOG2" | head -1)" != "$rid1" ] || fail "run 2 reused run 1's id"
[ "$(jq -r 'select(.event=="run.finished")|.detail' "$LOG2")" = "exit=$rc2" ] \
  || fail "run.finished's detail doesn't carry the run's exit code ($rc2)"
# The headless stdout announces the log a subscriber should attach to, and it is the
# log this run actually wrote.
grep -q "chief: events=$LOG2" "$WORK/run2.log" \
  || { grep '^chief: ' "$WORK/run2.log" >&2; fail "the headless run didn't announce its own event log"; }

# The two runs never share a line: one log per run is what lets a host subscribe to
# exactly the run it launched.
[ "$(validate "$LOG1" "run 1 (recheck)")" = "$n1" ] || fail "run 2 appended to run 1's log"
echo "   ok  $n2 events: launched → US-1 → verify-failed(failed) → run.finished(verify-failed)"

# ══ RUN 3 — a provider that REPORTS usage and trips a limit mid-turn ═════════
# The positive half of the usage/limit contract, on the self-healing path: the agent
# loop sleeps out the window (RATE_LIMIT_WAIT pinned to 1s so the test does not) and
# the retry does the work. Two blocks must land: `limit` on the sleep event, `usage`
# on the turn the provider reported figures for.
echo "events: run 3 — usage reported + a limit slept out"
mkrepo "$WORK/lim" evlim "US-1" 'echo "verify: ok"; exit 0'
export EV_LIMIT_COUNTER="$WORK/evlim-calls"
PATH="$WORK/fakebin:$PATH" RATE_LIMIT_RETRY=1 RATE_LIMIT_WAIT=1 \
  "$CHIEF" run -p 1 >"$WORK/run3.log" 2>&1 \
  || { tail -30 "$WORK/run3.log" >&2; fail "run 3 exited non-zero"; }
[ "$(cat "$EV_LIMIT_COUNTER")" -ge 2 ] \
  || fail "run 3's provider was not re-invoked after the limit (calls=$(cat "$EV_LIMIT_COUNTER"))"

LOG3="$(find "$CHIEF_RUNS" -maxdepth 1 -name '*.events.jsonl' \
  ! -name "$(basename "$LOG1")" ! -name "$(basename "$LOG2")")"
[ -n "$LOG3" ] && [ "$(printf '%s\n' "$LOG3" | wc -l | tr -d ' ')" = 1 ] \
  || fail "run 3 did not get its own event log (got: $LOG3)"
n3="$(validate "$LOG3" "run 3")"
echo "--- $(basename "$LOG3") ($n3 events) ---"; cat "$LOG3"

# The limited turn still returns, so it still reports a turn — with no usage, because
# the provider printed none on it. Then the sleep, then the working turn.
got="$(seq_of "$LOG3")"
want="run.started tasklist.launched agent.turn tasklist.rate-limit-wait story.passed agent.turn tasklist.merged run.finished"
[ "$got" = "$want" ] || fail "usage/limit run sequence
  want: $want
  got:  $got"

# limit{} — the accounting the engine already did to decide how long to sleep.
lim="$(jq -c 'select(.event=="tasklist.rate-limit-wait")|.limit' "$LOG3")"
[ -n "$lim" ] || fail "tasklist.rate-limit-wait carried no limit block"
printf '%s' "$lim" | jq -e '.hit == true and .waits == 1 and .max_waits == 8 and (.retry_at|type) == "number" and .retry_at > 0' \
  >/dev/null || fail "limit block is not {hit:true, retry_at:<epoch>, waits:1, max_waits:8}: $lim"
[ "$(jq -r 'select(.event=="tasklist.rate-limit-wait")|.state' "$LOG3")" = rate-limited \
  ] || fail "tasklist.rate-limit-wait state != rate-limited (a limit is not a failure)"
[ "$(jq -r 'select(.event=="tasklist.rate-limit-wait")|.usage' "$LOG3")" = null ] \
  || fail "the limit event invented a usage block"

# usage{} — scraped from the provider's OWN printed result line, nothing asked of it.
u="$(jq -c 'select(.event=="agent.turn" and .usage != null)|.usage' "$LOG3")"
[ -n "$u" ] || fail "no agent.turn carried the usage the provider printed"
[ "$(printf '%s\n' "$u" | wc -l | tr -d ' ')" = 1 ] \
  || fail "usage was attributed to more than one turn: $u"
printf '%s' "$u" | jq -e '
  .input_tokens == 1200 and .output_tokens == 340 and .cost_usd == 0.0421
  and .duration_ms == 18324 and .turns == 3' >/dev/null \
  || fail "usage block does not match what the provider printed: $u"
# The turn that reported nothing must stay null — per-turn attribution, not a smear.
[ "$(jq -r 'select(.event=="agent.turn")|.usage' "$LOG3" | head -1)" = null ] \
  || fail "the limited turn (which printed no usage) was given a usage block"
echo "   ok  $n3 events: limit slept out with limit{hit,retry_at,waits,max_waits}; the reporting turn carries usage{tokens,cost,duration}"

# ══ RUN 4 — the driver-side stop: a limit the loop will not retry ════════════
# RATE_LIMIT_RETRY=0 stops the agent loop at once (exit 2) and RATE_LIMIT_REDISPATCH_MAX=0
# spends the scheduler's re-dispatch budget immediately, so the run ends without waiting
# out anything. What is pinned: driver.sh's tasklist.rate-limited publishes the reset ETA
# the engine parsed out of the provider's OWN message — one parser, two publishers.
echo "events: run 4 — a limit the loop won't retry (driver-side)"
mkrepo "$WORK/lim2" evlim2 "US-1" 'echo "verify: ok"; exit 0'
EV_RESET=$(( $(date +%s) + 7200 ))
export EV_LIMIT_RESET="$EV_RESET"
PATH="$WORK/fakebin:$PATH" RATE_LIMIT_RETRY=0 RATE_LIMIT_REDISPATCH_MAX=0 \
  "$CHIEF" run -p 1 >"$WORK/run4.log" 2>&1 || true

LOG4="$(find "$CHIEF_RUNS" -maxdepth 1 -name '*.events.jsonl' \
  ! -name "$(basename "$LOG1")" ! -name "$(basename "$LOG2")" ! -name "$(basename "$LOG3")")"
[ -n "$LOG4" ] && [ "$(printf '%s\n' "$LOG4" | wc -l | tr -d ' ')" = 1 ] \
  || fail "run 4 did not get its own event log (got: $LOG4)"
n4="$(validate "$LOG4" "run 4")"
echo "--- $(basename "$LOG4") ($n4 events) ---"; cat "$LOG4"

rl="$(jq -c 'select(.event=="tasklist.rate-limited")|.limit' "$LOG4")"
[ -n "$rl" ] || { fail "no tasklist.rate-limited event with a limit block: $(seq_of "$LOG4")"; }
printf '%s' "$rl" | jq -e --argjson eta "$EV_RESET" \
  '.hit == true and .waits == 0 and .retry_at >= $eta and .retry_at < ($eta + 600)' \
  >/dev/null || fail "limit block did not publish the ETA parsed from the provider message (want ~$EV_RESET): $rl"
[ "$(jq -r 'select(.event=="tasklist.rate-limited")|.state' "$LOG4")" = rate-limited ] \
  || fail "tasklist.rate-limited state != rate-limited"
# The ETA the stream publishes is the one the scheduler is acting on — the whole point
# of a single parser is that the two can never disagree.
[ "$(cat "$WORK/lim2/.chief/state/parallel/evlim2.retry-at" 2>/dev/null)" \
  = "$(jq -r 'select(.event=="tasklist.rate-limited")|.limit.retry_at' "$LOG4")" ] \
  || fail "the published retry_at differs from the ETA the scheduler recorded"
echo "   ok  $n4 events: tasklist.rate-limited carries the parsed reset ETA the scheduler itself is using"

# ── Backward compatibility: the stream is purely additive ───────────────────
# The live records ps/monitor read are untouched by all of the above, and the event
# logs are never committed into the repo they describe.
[ -f "$WORK/ok/.chief/state/parallel/ev.live.json" ] || fail "the live record disappeared"
[ "$(jq -r '.phase' "$WORK/ok/.chief/state/parallel/ev.live.json")" = merged ] \
  || fail "the live record's terminal phase changed"
if git -C "$WORK/ok" ls-files | grep -q 'events\.jsonl'; then fail "an event log got committed"; fi

echo "EVENTS PASS — one NDJSON log per run at \$CHIEF_RUNS/<run-id>.events.jsonl; every line schema-valid (v=1 · chief.event/1) and stamped with its run id; a merged tasklist and a verify-failed one each emit their full documented sequence, \`chief events\` replays them verbatim, and the usage/cost/limit block is populated only where the provider exposed the signal (null everywhere else)"
