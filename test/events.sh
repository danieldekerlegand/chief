#!/usr/bin/env bash
# test/events.sh — the machine-readable EVENT STREAM (NDJSON), end to end.
#
# What this pins: engine/events.sh + the emit points in driver.sh/agent.sh publish a
# per-run, append-only NDJSON log ($CHIEF_RUNS/<run-id>.events.jsonl) that a host —
# chief-cloud, an embedding UI — subscribes to instead of polling <name>.live.json and
# diffing it. docs/events.md is the contract; this test is what keeps the contract
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
# the log (docs/events.md), so the two must never disagree.
rid1="$(basename "$LOG1" .events.jsonl)"
[ "$(jq -r '.runId' "$LOG1" | sort -u | wc -l | tr -d ' ')" = 1 ] || fail "run 1's log mixes runIds"
[ "$(jq -r '.runId' "$LOG1" | head -1)" = "$rid1" ] \
  || fail "runId in the log != the filename ($rid1)"

got="$(seq_of "$LOG1")"
want="run.started tasklist.launched story.passed story.passed tasklist.merged run.finished"
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

# Non-decreasing timestamps: a subscriber orders on `ts`, so it must never go backwards.
[ "$(jq -r '.ts' "$LOG1" | sort -n | tr '\n' ' ')" = "$(jq -r '.ts' "$LOG1" | tr '\n' ' ')" ] \
  || fail "timestamps are not non-decreasing in write order"
echo "   ok  $n1 events: launched → US-1 → US-2 → merged → run.finished(merged), all schema-valid"

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
# be crossed against it: the contract is one decision published twice (docs/events.md).
# (A plain `chief run` reports the same outcome in words but always exits 0 — hl_rc.)
# RETRY_MAX=2 pins the retry budget so the sequence below is exact: a verify failure is
# RETRYABLE (docs — a flaky gate must not rot a branch), so the tasklist is re-armed and
# re-attempted, and every attempt re-emits the launched → verify-failed pair. The retry
# skips the agent (all stories already pass), which is why story.passed appears ONCE — a
# subscriber must never see a story announced twice.
PATH="$WORK/fakebin:$PATH" RETRY_MAX=2 "$CHIEF" run --headless -p 1 >"$WORK/run2.log" 2>&1 && rc2=0 || rc2=$?
[ "$rc2" = 4 ] || { tail -30 "$WORK/run2.log" >&2; fail "a verify-failed headless run exited $rc2, want 4 (HL_RC_VERIFY)"; }

LOG2="$(find "$CHIEF_RUNS" -maxdepth 1 -name '*.events.jsonl' ! -name "$(basename "$LOG1")")"
[ -n "$LOG2" ] && [ "$(printf '%s\n' "$LOG2" | wc -l | tr -d ' ')" = 1 ] \
  || fail "run 2 did not get its own event log (got: $LOG2)"
n2="$(validate "$LOG2" "run 2")"
echo "--- $(basename "$LOG2") ($n2 events) ---"; cat "$LOG2"

got="$(seq_of "$LOG2")"
want="run.started tasklist.launched story.passed tasklist.verify-failed tasklist.launched tasklist.verify-failed run.finished"
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

# ── Backward compatibility: the stream is purely additive ───────────────────
# The live records ps/monitor read are untouched by all of the above, and the event
# logs are never committed into the repo they describe.
[ -f "$WORK/ok/.chief/state/parallel/ev.live.json" ] || fail "the live record disappeared"
[ "$(jq -r '.phase' "$WORK/ok/.chief/state/parallel/ev.live.json")" = merged ] \
  || fail "the live record's terminal phase changed"
if git -C "$WORK/ok" ls-files | grep -q 'events\.jsonl'; then fail "an event log got committed"; fi

echo "EVENTS PASS — one NDJSON log per run at \$CHIEF_RUNS/<run-id>.events.jsonl; every line schema-valid (v=1 · chief.event/1) and stamped with its run id; a merged tasklist and a verify-failed one each emit their full documented sequence, and \`chief events\` replays them verbatim"
