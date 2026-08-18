#!/usr/bin/env bash
# test/liveliness.sh — the fine-grained PROGRESS + LIVELINESS record, end to end.
#
# The gap this pins: the scheduler persisted exactly ONE coarse word per tasklist
# (<name>.state), so a tasklist that sat silent for hours was indistinguishable
# from one that was working — the operator could not answer "is it working or
# hung?" at all. engine/live.sh now writes a small per-tasklist record next to
# that word, and `chief ps` / `chief monitor` render it.
#
# Three parts, cheapest first:
#   1. THE RECORD    — live_set/live_get/live_age semantics: atomic writes, a
#                      heartbeat that moves on every action, a phase_since that
#                      moves only on a real phase change, and the no-op/no-file
#                      degradation that is the whole backward-compat story.
#   2. A REAL RUN    — the hermetic driver (fake `claude`, temp prefixes, like
#                      test/ratelimit.sh) actually emitting the record: the fake
#                      snapshots $CHIEF_LIVE_FILE and `chief ps` from INSIDE its
#                      turn, which is the exact moment the monitor must be
#                      truthful. Also proves the record is never committed.
#   3. THE RENDERING — the three buckets an operator must tell apart at a glance
#                      (actively-progressing · stalled · paused-on-limit), driven
#                      against a synthetic run registry the way test/limitmonitor.sh
#                      does: no driver, no git, no timing sensitivity.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
holder=""
cleanup() {
  if [ -n "$holder" ]; then
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true    # reap quietly: no "Terminated" job notice
  fi
  rm -rf "$WORK"
}
trap 'rc=$?; cleanup; exit "$rc"' EXIT
fail() { echo "LIVELINESS FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

export GIT_AUTHOR_NAME=lv GIT_AUTHOR_EMAIL=lv@test GIT_COMMITTER_NAME=lv GIT_COMMITTER_EMAIL=lv@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"   # hermetic: never touch ~/.chief

# ══ PART 1 — THE RECORD ══════════════════════════════════════════════════════
# engine/live.sh is sourced straight from this checkout (it is pure functions, no
# install needed). Every writer contract the monitor depends on.
# shellcheck source=engine/live.sh
. "$ROOT/engine/live.sh"

REC="$WORK/rec/lv.live.json"
echo "liveliness: part 1 — the record"

# An EMPTY path is a silent no-op (agent.sh run standalone, no driver) and a
# missing file reads as empty — never an error, under `set -e` callers.
live_set "" phase=agent-turn || fail "live_set with an empty path must return 0"
[ -z "$(live_get '' phase)" ]              || fail "live_get on an empty path must be empty"
[ -z "$(live_get "$WORK/nope.json" phase)" ] || fail "live_get on a missing file must be empty"
[ -z "$(live_age "$WORK/nope.json")" ]     || fail "live_age on a missing file must be empty"

live_set "$REC" name=lv state=running phase=agent-turn story=US-1 iter=2 \
  passing=1 total=4 stall=0 waits=0 retry_at=0 || fail "live_set failed"
[ -f "$REC" ] || fail "no record written at $REC"

jq -e . "$REC" >/dev/null 2>&1 || { cat "$REC" >&2; fail "the record is not valid JSON"; }
for kv in name=lv state=running phase=agent-turn story=US-1 iter=2 passing=1 total=4; do
  got="$(live_get "$REC" "${kv%%=*}")"
  [ "$got" = "${kv#*=}" ] || fail "live_get ${kv%%=*} = '$got', want '${kv#*=}'"
done
# Numeric fields are emitted UNQUOTED (0 = unknown) — parsed with jq.
grep -q '"iter": 2'  "$REC" || { cat "$REC" >&2; fail "numeric field 'iter' is not unquoted"; }
grep -q '"name": "lv"' "$REC" || fail "string field 'name' is not quoted"
[ "$(jq -r '.total' "$REC")" = 4 ] || fail "jq cannot read the record's numbers"

# Atomic (temp-in-the-same-dir + mv) leaves no debris behind.
[ -z "$(find "$WORK/rec" -name '*.tmp' 2>/dev/null)" ] || fail "a .tmp file survived a write"

# A story title or phase carrying JSON metacharacters must never break the record.
live_set "$REC" story='US-"1" \ `x` $y' || fail "live_set failed on a hostile value"
jq -e . "$REC" >/dev/null 2>&1 || { cat "$REC" >&2; fail "a hostile value broke the JSON"; }
live_set "$REC" story=US-1

# Back-date a numeric field in place (only this key's line matches).
backdate() {  # FILE SECONDS KEY…
  local f="$1" off="$2" k v t; shift 2
  for k in "$@"; do
    v="$(live_get "$f" "$k")"
    case "$v" in ''|0|*[!0-9]*) continue ;; esac
    t="$f.bd"; sed "s/\"$k\": $v/\"$k\": $(( v - off ))/" "$f" > "$t" && mv "$t" "$f"
  done
}

# HEARTBEAT: bumped by ANY write, so `now - heartbeat` is a true liveliness age.
# (This is what the in-turn ticker relies on — a bare live_set is a pure bump.)
backdate "$REC" 120 heartbeat
age="$(live_age "$REC")"
[ "${age:-0}" -ge 100 ] || fail "live_age didn't see the back-dated heartbeat (got '${age:-}')"
live_set "$REC"
age="$(live_age "$REC")"
[ "${age:-999}" -le 5 ] || fail "a bare live_set didn't bump the heartbeat (age ${age:-}s)"

# PHASE_SINCE: moves ONLY on a real phase change — that is monitor's elapsed-in-phase.
backdate "$REC" 300 phase_since
ps0="$(live_get "$REC" phase_since)"
live_set "$REC" story=US-2 iter=3                       # same phase → must not move
[ "$(live_get "$REC" phase_since)" = "$ps0" ] || fail "phase_since moved without a phase change"
live_set "$REC" phase=verifying                          # real change → must move
[ "$(live_get "$REC" phase_since)" != "$ps0" ] || fail "phase_since didn't move on a phase change"
echo "   ok  atomic write · unquoted numbers · heartbeat bumps · phase_since pinned to the phase"

# ══ PART 2 — A REAL RUN EMITS IT (hermetic driver, fake claude) ══════════════
echo "liveliness: part 2 — a real run"
PREFIX="$WORK/rh"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# The fake `claude` snapshots the record and `chief ps` from inside its FIRST turn
# — the run is live, the driver is blocked on this process, and the monitor has to
# be truthful about it right now — then implements the story like test/ratelimit's.
export LV_SNAP="$WORK/live.snap" LV_PATH="$WORK/live.path" LV_PS="$WORK/ps.snap"
export CHIEF_BIN="$CHIEF"
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null
if [ ! -f "$LV_SNAP" ]; then
  printf '%s\n' "${CHIEF_LIVE_FILE:-}" > "$LV_PATH"
  cp "${CHIEF_LIVE_FILE:-/dev/null}" "$LV_SNAP" 2>/dev/null || : > "$LV_SNAP"
  "$CHIEF_BIN" ps > "$LV_PS" 2>&1 || true
fi
PRD=".chief/state/prd.json"
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"; TRACKED="tasks/chief/$name.json"
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  mkdir -p out; echo "impl $id" > "out/$id.txt"
  for f in "$PRD" "$TRACKED"; do t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id).passes)=true' "$f" > "$t" && mv "$t" "$f"; done
  git add -A >/dev/null 2>&1 || true; git commit -q -m "feat: $id" >/dev/null 2>&1 || true
fi
[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null
rm -f tasks/chief/example.json
cat > tasks/chief/lv.json <<'JSON'
{ "project":"lv","branchName":"chief/lv","description":"liveliness record",
  "iters":3,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":["out/US-1.txt"],"passes":false,"notes":""}] }
JSON
printf '#!/usr/bin/env bash\nset -eu\n[ -f out/US-1.txt ] || { echo missing; exit 1; }\necho ok\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "lv setup"

PATH="$WORK/fakebin:$PATH" "$CHIEF" run -p 1 >"$WORK/run.log" 2>&1 \
  || { tail -30 "$WORK/run.log" >&2; fail "run exited non-zero"; }

# 2a) The engine handed the agent a record path under the gitignored state dir…
lp="$(cat "$LV_PATH" 2>/dev/null || echo)"
[ -n "$lp" ] || { tail -30 "$WORK/run.log" >&2; fail "CHIEF_LIVE_FILE was not exported to the agent"; }
case "$lp" in */.chief/state/parallel/lv.live.json) ;; *) fail "record at an unexpected path: $lp" ;; esac

# 2b) …and it was already live, mid-turn, with the fields the monitor needs.
snap="$WORK/live.snap"
jq -e . "$snap" >/dev/null 2>&1 || { cat "$snap" >&2; fail "the mid-run record is not valid JSON"; }
for kv in name=lv state=running phase=provider-waiting story=US-1 iter=1; do
  got="$(live_get "$snap" "${kv%%=*}")"
  [ "$got" = "${kv#*=}" ] || { cat "$snap" >&2; fail "mid-run ${kv%%=*} = '$got', want '${kv#*=}'"; }
done
hb="$(live_get "$snap" heartbeat)"
case "$hb" in ''|0|*[!0-9]*) fail "mid-run record has no heartbeat" ;; esac
[ "$(( $(date +%s) - hb ))" -lt 600 ] || fail "the mid-run heartbeat is not a recent epoch"
echo "   ok  mid-turn record: state=running phase=provider-waiting story=US-1 iter=1"

# 2c) `chief ps`, run from inside that same turn, SURFACED it — phase, story,
#     iteration and a time-since-activity — and stayed plain text when piped.
ps_out="$(cat "$LV_PS" 2>/dev/null || echo)"
has_ps() { case "$ps_out" in *"$1"*) ;; *) printf '%s\n' "--- chief ps (mid-run) ---" "$ps_out" >&2; fail "$2" ;; esac; }
has_ps 'lv'             "the running tasklist is missing from mid-run \`chief ps\`"
has_ps 'running'        "the tasklist didn't render as running"
has_ps 'provider-waiting' "\`chief ps\` didn't show the fine-grained phase"
has_ps 'US-1'           "\`chief ps\` didn't show the current story"
has_ps 'iter 1'         "\`chief ps\` didn't show the current iteration"
has_ps ' ago'           "\`chief ps\` didn't show a time-since-last-activity"
case "$ps_out" in *$'\033'*) fail "\`chief ps\` emitted ANSI when redirected (breaks | grep)" ;; esac
echo "   ok  mid-run \`chief ps\`: phase · story · iter · age, ANSI-free when piped"

# 2d) After the merge the record tracks the terminal state — and was NEVER committed.
rec="$REPO/.chief/state/parallel/lv.live.json"
[ -f "$rec" ] || fail "the record vanished after the run"
[ "$(live_get "$rec" state)" = done ] || fail "post-run state = '$(live_get "$rec" state)', want done"
[ "$(live_get "$rec" phase)" = merged ] || fail "post-run phase = '$(live_get "$rec" phase)', want merged"
[ "$(live_get "$rec" passing)" = "$(live_get "$rec" total)" ] || fail "post-run passing != total"
if git -C "$REPO" ls-files | grep -q 'live\.json'; then fail "the liveliness record got committed"; fi
git -C "$REPO" check-ignore -q .chief/state/parallel/lv.live.json \
  || fail "the record's path is not gitignored — it can be committed by accident"
echo "   ok  post-run: state=done phase=merged, record uncommitted + gitignored"

# ══ PART 3 — THE RENDERING (three buckets, synthetic registry) ═══════════════
echo "liveliness: part 3 — the rendering"
STATE="$WORK/mon"; PAR="$STATE/parallel"; RUNS="$WORK/monruns"
mkdir -p "$PAR" "$RUNS" "$WORK/mrepo" "$WORK/mtasks" "$WORK/mwt"
sleep 120 & holder=$!                     # a live pid: the monitor prunes dead runs

NOW="$(date +%s)"
RESET=$(( NOW + 900 ))
ETA="$(date -r "$RESET" '+%H:%M' 2>/dev/null || date -d "@$RESET" '+%H:%M')"

# Four rows = the four things that must never be confused. Records are written by
# the REAL writer and then back-dated, so the fixtures cannot drift from the format.
echo running > "$PAR/work-fresh.state"
live_set "$PAR/work-fresh.live.json" name=work-fresh state=running phase=agent-turn \
  story=US-2 iter=3 passing=2 total=4
backdate "$PAR/work-fresh.live.json" 30 heartbeat
backdate "$PAR/work-fresh.live.json" 90 phase_since

echo running > "$PAR/work-hung.state"
# `agent-turn`, not `verifying`: this row is about the DEFAULT threshold and the knob
# that moves it, and `verifying` carries a measured per-phase threshold of its own
# (51m — see engine/monitor.sh's STALE_PHASE_SECONDS and test/stall-flag.sh), so at
# 40m it is legitimately not stale and CHIEF_STALE_SECONDS would no longer move it.
live_set "$PAR/work-hung.live.json" name=work-hung state=running phase=agent-turn \
  story=US-9 iter=7 stall=2 passing=1 total=5
backdate "$PAR/work-hung.live.json" 2400 heartbeat phase_since     # 40m of silence

echo rate-limited > "$PAR/pause-eta.state"
printf '%s' "$RESET" > "$PAR/pause-eta.retry-at"; printf '1' > "$PAR/pause-eta.retries"
live_set "$PAR/pause-eta.live.json" name=pause-eta state=rate-limited phase=rate-limited \
  story=US-1 iter=4 passing=1 total=4 retry_at="$RESET"
backdate "$PAR/pause-eta.live.json" 2400 heartbeat phase_since     # equally quiet…

echo running > "$PAR/norecord.state"                                # …and no record at all

cat > "$RUNS/$holder.run" <<EOF
pid=$holder
repo=$WORK/mrepo
base=main
parallel=4
tool=claude
automerge=1
limitmax=3
started=$NOW
state=$STATE
staterel=.chief/state
tasks=$WORK/mtasks
wt=$WORK/mwt
names=work-fresh work-hung pause-eta norecord
EOF

mon() { CHIEF_RUNS="$RUNS" env "$@" bash "$ROOT/engine/monitor.sh" once; }
out="$(mon)" || fail "monitor.sh exited non-zero"
echo "--- chief ps (synthetic: fresh · stalled · paused · no-record) ---"; printf '%s\n' "$out"
has()  { case "$out" in *"$1"*) ;; *) printf '%s\n' "$out" >&2; fail "$2" ;; esac; }
row()  { printf '%s\n' "$out" | grep -A1 "$1 " | tr -d '\n'; }   # the row + its detail line

# 3a) Actively progressing: phase, elapsed-in-phase, story, iteration, fresh age.
has 'agent-turn for 1m' "the fresh row lost its phase / elapsed-in-phase"
has 'US-2 · iter 3'     "the fresh row lost its story/iteration"
fresh="$(row work-fresh)"
printf '%s\n' "$fresh" | grep -qE '[0-9]+s ago' || fail "the fresh row lost its time-since-last-activity: $fresh"
case "$fresh" in
  *stalled*) fail "a tasklist that ticked 30s ago was flagged stalled: $fresh" ;;
  *'●'*) ;; *) fail "the actively-progressing row lost its ● glyph: $fresh" ;;
esac

# 3b) Stalled: the same 'running' word, but unmistakably at-risk.
hung="$(row work-hung)"
case "$hung" in *'⚠'*) ;; *) fail "the stalled row is missing the ⚠ glyph: $hung" ;; esac
case "$hung" in *stalled*) ;; *) fail "the stalled row doesn't say 'stalled' in words: $hung" ;; esac
case "$hung" in *'40m'*) ;; *) fail "the stalled row doesn't say how long it's been quiet: $hung" ;; esac
case "$hung" in *'agent-turn for 40m'*) ;; *) fail "the stalled row lost its elapsed-in-phase: $hung" ;; esac
# The flag carries the DIAGNOSIS: which state was quiet, not just that something was.
case "$hung" in *'stalled in agent-turn'*) ;; *) fail "the stall flag doesn't name the state it was stuck in: $hung" ;; esac
case "$hung" in *'stall 2'*) ;; *) fail "the stalled row lost the agent's stall count: $hung" ;; esac

# 3c) Paused on a usage limit: quiet is EXPECTED, so an equally old heartbeat must
#     not turn a pause into an alarm — it keeps ⏸ and shows when it will retry.
paused="$(row pause-eta)"
case "$paused" in *'⏸'*) ;; *) fail "the paused row lost its ⏸ glyph: $paused" ;; esac
case "$paused" in *'paused: usage limit'*) ;; *) fail "the paused row lost its explanation: $paused" ;; esac
case "$paused" in *"retry at $ETA"*) ;; *) fail "the paused row lost the retry ETA ($ETA): $paused" ;; esac
case "$paused" in *'(15m)'*) ;; *) fail "the paused row lost the countdown: $paused" ;; esac
case "$paused" in *'re-dispatch 1/3'*) ;; *) fail "the paused row lost the re-dispatch budget: $paused" ;; esac
case "$paused" in *stalled*) fail "a paused tasklist was flagged stalled: $paused" ;; esac
case "$paused" in *'⚠'*) fail "a paused tasklist took the at-risk glyph: $paused" ;; esac

# 3d) No record at all → exactly the pre-71 row: no fine-grained line, no alarm.
nor="$(row norecord)"
case "$nor" in *'↳'*) fail "a tasklist with no record grew a detail line: $nor" ;; esac
case "$nor" in *'⚠'*|*stalled*) fail "an unknown age manufactured a stall alarm: $nor" ;; esac
case "$nor" in *running*) ;; *) fail "the no-record row stopped rendering: $nor" ;; esac
[ "$(printf '%s\n' "$out" | grep -c '↳')" = 3 ] || fail "expected exactly 3 detail lines (fresh/hung/paused)"

# 3e) Plain text when piped, so `chief ps | grep stalled` works in a script.
case "$out" in *$'\033'*) fail "monitor emitted ANSI into a pipe" ;; esac
printf '%s\n' "$out" | grep -q 'stalled' || fail "the stall flag doesn't survive a grep"

# 3f) The threshold is a knob: raised past the age, the flag clears; garbage falls
#     back to the 900s default rather than disabling the signal.
out="$(mon CHIEF_STALE_SECONDS=7200)" || fail "monitor.sh exited non-zero (raised threshold)"
case "$out" in *stalled*) fail "CHIEF_STALE_SECONDS=7200 didn't clear the 40m flag" ;; esac
case "$(row work-hung)" in *'●'*) ;; *) fail "the un-flagged row didn't get its ● back" ;; esac
case "$out" in *"retry at $ETA"*) ;; *) fail "the paused row lost its ETA at a raised threshold" ;; esac

out="$(mon CHIEF_STALE_SECONDS=nonsense)" || fail "monitor.sh exited non-zero (garbage threshold)"
has 'stalled' "a garbage CHIEF_STALE_SECONDS silently disabled the staleness signal"

out="$(mon CHIEF_STALE_SECONDS=10)" || fail "monitor.sh exited non-zero (low threshold)"
case "$(row work-fresh)" in *stalled*) ;; *) fail "a 10s threshold didn't flag the 30s-quiet row" ;; esac

echo "LIVELINESS PASS — record written atomically + emitted by a real run; \`chief ps\` shows phase/story/iter/age, flags a 40m-quiet run as stalled (knob: CHIEF_STALE_SECONDS), and keeps a usage-limit pause reading as 'paused … retry at $ETA'"
