#!/usr/bin/env bash
# test/provider-backoff.sh — a transient provider failure is WAITED OUT, not fired
# into three times.
#
# THE OTHER HALF OF THE 2026-08-24 REGRESSION. The message chief threw its budget at
# says so itself — "usually temporary — try again in a moment" — and chief had no
# wait: tasklists 71 and 72 each fired three iterations into an overloaded API back to
# back, spending the whole budget inside a window a single pause would have covered.
#
# EVERY WAIT HERE IS MEASURED ON THE REAL CLOCK. A mocked clock would prove that the
# arithmetic is what it is; the claim under test is that the loop actually SLEEPS, so
# the assertions are `date +%s` before and after and the knobs are turned down to
# single-digit seconds so that costs the suite ~10s rather than minutes.
#
# AND A REAL CLOCK MEASURES THE HOST TOO, which is why section 0 below runs FIRST. An
# agent iteration is some hundreds of forks (jq, git, sed), and a fork is not free
# everywhere: measured 2026-09-13 on a macOS host, ~80ms per `git` and ~28ms per `jq`,
# putting ONE no-wait iteration at ~6s against the ~0.5s it costs on CI. Every ceiling
# here used to be an absolute number chosen on a fast host — `elapsed < 20` for a 4s
# wait — so on a slow one the test failed on the host's own cost while reporting that
# the provider's interval had been ignored. The cost is now MEASURED, by the zero-wait
# control that section 6 used to be, and every ceiling is that cost plus what the case
# itself allows (`ceiling`). The floors are untouched: overhead only ever pushes a run
# further past them, so they mean on any host what they always meant.
#
# FOUR STUBS, one per row of the acceptance criterion:
#   529 + Retry-After   the provider names its own interval -> honoured verbatim,
#                       in BOTH RFC 9110 forms (delta-seconds and HTTP-date)
#   529, no header      -> exponential backoff from $PROVIDER_BACKOFF, with jitter
#   connection reset    no HTTP status at all -> ambiguous, treated as TRANSIENT
#   401 revoked key     permanent -> FAILS FAST, on the FIRST refusal, with no sleep
# …and across all the transient ones, the stall counter stays at zero.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"

# HERMETIC IN STATE IS NOT HERMETIC IN ENV — see test/ratelimit.sh's note.
unset CHIEF_PAUSE_FILE
unset CHIEF_PROVIDER CHIEF_TOOL CHIEF_MODEL CHIEF_PRESET
unset PROVIDER_BACKOFF PROVIDER_BACKOFF_CAP PROVIDER_BACKOFF_JITTER PROVIDER_NOTURN_LIMIT
export CHIEF_PROVIDER=claude CHIEF_TOOL=claude
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=pb GIT_AUTHOR_EMAIL=pb@test GIT_COMMITTER_NAME=pb GIT_COMMITTER_EMAIL=pb@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"   # hermetic: don't touch ~/.chief
fail() { echo "PROVIDER-BACKOFF FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

AGENT="$ROOT/engine/agent.sh"

# ── the stub ──────────────────────────────────────────────────────────────────
# One fake `claude` for every case: it prints $PB_TEXT and exits $PB_RC, and stamps
# the epoch of every call into $PB_CALLS. The GAPS between those stamps are the
# measured wait — read off the provider's own invocations rather than off the log,
# so nothing but a real sleep can produce them.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/claude" <<'STUB'
#!/usr/bin/env bash
set -eu
cat >/dev/null
date +%s >> "$PB_CALLS"
cat "$PB_TEXT"
exit "$(cat "$PB_RC")"
STUB
chmod +x "$WORK/bin/claude"

REPO="$WORK/repo"; mkdir -p "$REPO/.chief/state"
git -C "$REPO" init -q -b main 2>/dev/null || { git -C "$REPO" init -q; }
git -C "$REPO" commit -q --allow-empty -m init
cat > "$REPO/.chief/state/prd.json" <<'JSON'
{ "project":"pb","branchName":"chief/pb","userStories":[
  {"id":"US-1","title":"one","description":"","acceptanceCriteria":[],"passes":false,"notes":""}] }
JSON

export PB_TEXT="$WORK/text" PB_RC="$WORK/rc" PB_CALLS="$WORK/calls"
LIVE="$REPO/.chief/state/pb.live.json"

# drive <claude-rc> <fixture-text> <env…> — run one agent loop against the stub and
# set $RC (the agent's exit code), $ELAPSED (MEASURED wall seconds), $CALLS (how many
# times the provider was actually invoked) and $LOG. Not a $(…) helper on purpose:
# the measurements are the point, and a subshell would drop every one of them.
LOG="$WORK/agent.log"
drive() {
  local crc="$1" text="$2" t0 t1; shift 2
  printf '%s\n' "$text" > "$PB_TEXT"; printf '%s\n' "$crc" > "$PB_RC"
  : > "$PB_CALLS"; rm -f "$LIVE"
  RC=0
  t0="$(date +%s)"
  ( cd "$REPO" && PATH="$WORK/bin:$PATH" CHIEF_PROJECT="$REPO" CHIEF_LIVE_FILE="$LIVE" \
      RATE_LIMIT_RETRY=0 STALL_LIMIT=1 \
      env "$@" bash "$AGENT" 2 ) >"$LOG" 2>&1 || RC=$?
  t1="$(date +%s)"
  ELAPSED=$(( t1 - t0 )); CALLS="$(wc -l < "$PB_CALLS" | tr -d ' ')"
}

# ══ 0 — THE HOST'S OWN COST, AND THAT 0 DISABLES WAITING ═════════════════════
# Two things at once, because they are the same run. PROVIDER_BACKOFF=0 is the
# pre-fix behaviour kept reachable for debugging — the retries fire back to back —
# so a run of it is a stopwatch on an agent loop that sleeps NOTHING, and that is
# exactly the baseline every ceiling below needs. It goes first for that reason: a
# control measured after the cases it calibrates would be calibrating them with a
# number nobody had yet.
echo "provider-backoff: PROVIDER_BACKOFF=0 disables waiting — and measures the host"
drive 1 'API Error: 529 Overloaded. This is a server-side issue, usually temporary' \
      PROVIDER_NOTURN_LIMIT=3 PROVIDER_BACKOFF=0 PROVIDER_BACKOFF_CAP=60
[ "$RC" = 8 ] || fail "PROVIDER_BACKOFF=0: want exit 8, got $RC"
[ "$CALLS" = 3 ] || fail "PROVIDER_BACKOFF=0: want 3 calls, got $CALLS"
grep -q 'Waiting ' "$LOG" && fail "PROVIDER_BACKOFF=0 still printed a wait"
grep -q 'never reached the model' "$LOG" || fail "the refusals are no longer named"

# OH — one iteration of this loop with every wait removed, rounded UP, and never 0
# (a host fast enough to round to nothing still owes the arithmetic a unit).
OH=$(( (ELAPSED + CALLS - 1) / CALLS )); [ "$OH" -ge 1 ] || OH=1
# SLACK absorbs what a single number cannot: the run-to-run spread of that overhead
# (measured at ~±1.5s idle on the slow host above, more under the parallel load this
# suite runs in). Scaled to the host, because a fixed 5s is a third of the budget on
# CI and a rounding error on a machine where a fork costs 80ms.
SLACK=$(( OH * 2 + 5 ))
# ceiling ITERS ALLOWED -> the most this case may take: the host's cost for the
# iterations it runs, plus the seconds the case is allowed to SLEEP, plus slack.
# Still a discriminating bound — on the numbers above, case 1's is ~33s against the
# ~42s an implementation that ignored Retry-After for its 30s cap would take.
ceiling() { echo $(( $1 * OH + $2 + SLACK )); }
echo "   ok  3 calls in ${ELAPSED}s, no wait — this host costs ~${OH}s per iteration (slack ${SLACK}s)"

# ══ 1 — 529 WITH Retry-After: the provider's own interval, honoured ════════════
# "the provider naming its own interval is better information than any backoff
# computed here" — so the wait is the header's value, not $PROVIDER_BACKOFF (set to 1
# here precisely so a computed backoff could not produce 4s by accident).
echo "provider-backoff: 529 + Retry-After (delta-seconds) — the provider's interval wins"
drive 1 'API Error: 529 {"type":"error","error":{"type":"overloaded_error"}}
Retry-After: 4' PROVIDER_NOTURN_LIMIT=2 PROVIDER_BACKOFF=1 PROVIDER_BACKOFF_CAP=30
[ "$RC" = 8 ] || { tail -20 "$LOG" >&2; fail "want exit 8, got $RC"; }
[ "$CALLS" = 2 ] || fail "want 2 provider calls (1 wait between them), got $CALLS"
[ "$ELAPSED" -ge 4 ] || { tail -20 "$LOG" >&2
  fail "MEASURED elapsed ${ELAPSED}s — Retry-After: 4 was not waited out"; }
[ "$ELAPSED" -le "$(ceiling 2 4)" ] \
  || fail "MEASURED elapsed ${ELAPSED}s — far past the 4s the provider asked for (2 iterations on this host plus slack is $(ceiling 2 4)s)"
grep -q 'Waiting 4s before attempt 2/2 — the provider asked for it (Retry-After)' "$LOG" \
  || { grep -n Waiting "$LOG" >&2; fail "the log does not name the delay, the attempt or the source"; }
echo "   ok  waited ${ELAPSED}s (>= the 4s asked for), 2 calls, exit 8"

# THE SECOND RFC 9110 FORM. An HTTP-date is the same instruction written differently
# and providers send both; a client that reads only the integer form silently ignores
# half of them.
#
# THE LEAD IS RELATIVE TO THE HOST, and this is the one case where that is a
# CORRECTNESS matter rather than a slack one: a date is an ABSOLUTE instant, it is
# stamped here, and the engine reads it one whole agent startup later. "A date
# already in the PAST reads as ABSENT" (_provider_wait_seconds) — so a fixed ~5s
# lead on a host where startup costs ~6s does not test the date form at all, it
# tests the fallback, and the failure it prints is "an HTTP-date Retry-After was not
# read as one". The lead is therefore the measured cost of getting there, twice
# over, plus the interval being asserted; the CAP keeps the bill for that small,
# since a clamped Retry-After is still a Retry-After and prints the same source.
echo "provider-backoff: 529 + Retry-After (HTTP-date)"
lead=$(( OH * 2 + 15 ))
when="$(date -u -d "+${lead} seconds" '+%a, %d %b %Y %H:%M:%S GMT' 2>/dev/null \
        || date -u -v+"${lead}"S '+%a, %d %b %Y %H:%M:%S GMT')"
drive 1 'API Error: 529 Overloaded
Retry-After: '"$when" PROVIDER_NOTURN_LIMIT=2 PROVIDER_BACKOFF=1 PROVIDER_BACKOFF_CAP=4
[ "$RC" = 8 ] || fail "HTTP-date form: want exit 8, got $RC"
[ "$ELAPSED" -ge 3 ] || { grep -n Waiting "$LOG" >&2
  fail "HTTP-date form: MEASURED elapsed ${ELAPSED}s — the date was not parsed into a wait"; }
[ "$ELAPSED" -le "$(ceiling 2 4)" ] \
  || fail "HTTP-date form: MEASURED elapsed ${ELAPSED}s — past the 4s cap (ceiling $(ceiling 2 4)s)"
grep -q 'Waiting 4s before attempt 2/2 — the provider asked for it (Retry-After)' "$LOG" \
  || { grep -n Waiting "$LOG" >&2; fail "an HTTP-date Retry-After was not read as one"; }
echo "   ok  an HTTP-date ${lead}s ahead was read as one and waited (${ELAPSED}s measured)"

# THE CAP CLAMPS IT. The worst case is only a stated number if no single wait can
# exceed the cap, whatever interval the far end names.
echo "provider-backoff: an absurd Retry-After is clamped to the cap"
drive 1 'API Error: 529 Overloaded
Retry-After: 86400' PROVIDER_NOTURN_LIMIT=2 PROVIDER_BACKOFF=1 PROVIDER_BACKOFF_CAP=3
[ "$RC" = 8 ] || fail "clamp: want exit 8, got $RC"
[ "$ELAPSED" -le "$(ceiling 2 3)" ] \
  || fail "a 86400s Retry-After was NOT clamped (elapsed ${ELAPSED}s, ceiling $(ceiling 2 3)s)"
grep -q 'Waiting 3s before attempt 2/2' "$LOG" || { grep -n Waiting "$LOG" >&2
  fail "the clamped wait is not the cap"; }
echo "   ok  86400s clamped to the 3s cap"

# ══ 2 — 529 WITHOUT the header: exponential backoff, and the STALL COUNTER ═════
# Three refusals, so TWO waits: 2s then 4s, halved at worst by equal jitter -> the
# measured floor is 1 + 2 = 3s and the ceiling 2 + 4 = 6s.
echo "provider-backoff: 529 with no Retry-After — exponential backoff with jitter"
drive 1 'API Error: 529 Overloaded. This is a server-side issue, usually temporary' \
      PROVIDER_NOTURN_LIMIT=3 PROVIDER_BACKOFF=2 PROVIDER_BACKOFF_CAP=30
[ "$RC" = 8 ] || { tail -20 "$LOG" >&2; fail "want exit 8, got $RC"; }
[ "$CALLS" = 3 ] || fail "want 3 provider calls, got $CALLS"
[ "$ELAPSED" -ge 3 ] || { grep -n Waiting "$LOG" >&2
  fail "MEASURED elapsed ${ELAPSED}s — two backoffs of 2s and 4s (jittered) cannot be that fast"; }
[ "$ELAPSED" -le "$(ceiling 3 6)" ] \
  || fail "MEASURED elapsed ${ELAPSED}s — far past the 2s+4s the backoff allows (ceiling $(ceiling 3 6)s)"
grep -q 'exponential backoff + jitter from 2s, capped at 30s' "$LOG" \
  || { grep -n Waiting "$LOG" >&2; fail "the log does not name the backoff rule"; }
# THE DELAY GROWS. Firing at a fixed interval is not backoff, and the second wait
# must be strictly longer than the first even after jitter halves it (2s -> 1..2,
# 4s -> 2..4 — the ranges touch at 2, so the assertion is >=).
w1="$(grep -o 'Waiting [0-9]*s' "$LOG" | sed -n '1s/[^0-9]//gp')"
w2="$(grep -o 'Waiting [0-9]*s' "$LOG" | sed -n '2s/[^0-9]//gp')"
[ -n "$w1" ] && [ -n "$w2" ] || fail "expected two waits in the log, got '$w1' and '$w2'"
[ "$w2" -ge "$w1" ] || fail "the backoff did not grow: ${w1}s then ${w2}s"
echo "   ok  waits of ${w1}s then ${w2}s, ${ELAPSED}s measured, 3 calls, exit 8"

# THE STALL COUNTER STAYS AT ZERO across every transient case. This is US-1's
# guarantee and the wait must not quietly reintroduce a charge against it.
grep -q 'no progress (stall' "$LOG" && { grep -n 'no progress (stall' "$LOG" >&2
  fail "a waited-out refusal was charged to the stall counter"; }
[ "$(jq -r '.stall' "$LIVE" 2>/dev/null || echo 0)" = 0 ] \
  || fail "the liveliness record shows stall=$(jq -r .stall "$LIVE") after transient refusals only"
echo "   ok  stall counter is 0 in the log and in the live record"

# ══ 3 — THE WAIT IS OBSERVABLE (chief ps + the run log) ═══════════════════════
# "rather than appearing to work or appearing hung": the row a human reads has to
# carry the delay and the attempt count. monitor.sh in `lib` mode renders the note
# from the record the agent just wrote, so this is the real renderer on real data.
echo "provider-backoff: the wait is visible in chief ps"
PSTATE="$WORK/ps"; mkdir -p "$PSTATE/parallel"
cp "$LIVE" "$PSTATE/parallel/pb.live.json"
# The agent's LAST write is the stop, so re-stamp the record into the sleeping state
# the same way it is published before a sleep.
# shellcheck source=engine/live.sh
. "$ROOT/engine/live.sh"
live_set "$PSTATE/parallel/pb.live.json" name=pb state=running phase=provider-backoff \
  story=US-1 iter=1 passing=0 total=1 noturn=2 noturn_limit=3 \
  retry_at="$(( $(date +%s) + 7 ))"
# shellcheck source=engine/monitor.sh
. "$ROOT/engine/monitor.sh" lib
row="$(live_note pb "$PSTATE")"
case "$row" in
  *'provider-backoff'*) ;; *) fail "the ps note does not name the phase: $row" ;;
esac
case "$row" in
  *'provider attempt 2/3'*) ;; *) fail "the ps note does not carry the attempt count: $row" ;;
esac
case "$row" in
  *'retry at '*'(in '*'s)'*) ;; *) fail "the ps note does not carry the delay: $row" ;;
esac
echo "   ok  ps renders: $row"

# ══ 4 — AN AMBIGUOUS REFUSAL IS TREATED AS TRANSIENT, AND SAYS SO ════════════
# A dropped connection never reaches HTTP, so there is no status and no envelope to
# read. "Where the two cannot be told apart the run treats it as transient and says
# so" — both halves are asserted, because a guess that reads as a diagnosis is worse
# than the guess.
echo "provider-backoff: a connection reset — ambiguous, so transient, and said out loud"
drive 1 'request to https://api.anthropic.com/v1/messages failed, reason: read ECONNRESET' \
      PROVIDER_NOTURN_LIMIT=2 PROVIDER_BACKOFF=2 PROVIDER_BACKOFF_CAP=10
[ "$RC" = 8 ] || { tail -20 "$LOG" >&2; fail "connection reset: want exit 8, got $RC"; }
[ "$CALLS" = 2 ] || fail "connection reset: want 2 calls (it was retried), got $CALLS"
[ "$ELAPSED" -ge 1 ] || fail "connection reset: it was not waited out (elapsed ${ELAPSED}s)"
grep -q 'could not be told apart — treating it as transient' "$LOG" \
  || { tail -20 "$LOG" >&2; fail "the ambiguity is not stated"; }
grep -q 'no progress (stall' "$LOG" && fail "a connection reset was charged to the stall counter"
echo "   ok  retried after a ${ELAPSED}s wait, and the log says it could not tell"

# ══ 5 — A PERMANENT REFUSAL FAILS FAST ═══════════════════════════════════════
# A revoked key with PROVIDER_BACKOFF_CAP=30 and a limit of 3: the pre-fix shape
# would sleep through ~60s of backoff and call the provider three times before
# stopping. It must stop on the FIRST refusal, having slept nothing.
echo "provider-backoff: a 401 fails fast — no wait, no second attempt"
drive 1 'API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}' \
      PROVIDER_NOTURN_LIMIT=3 PROVIDER_BACKOFF=30 PROVIDER_BACKOFF_CAP=30
[ "$RC" = 8 ] || { tail -20 "$LOG" >&2; fail "401: want exit 8, got $RC"; }
[ "$CALLS" = 1 ] || fail "401: the provider was called $CALLS time(s) — a permanent refusal is not retried"
[ "$ELAPSED" -le "$(ceiling 1 0)" ] \
  || fail "401: slept ${ELAPSED}s on a refusal no delay can fix (ceiling $(ceiling 1 0)s)"
grep -q 'PERMANENT refusal, not retried' "$REPO/.chief/state/.provider-unavailable" \
  || fail "the reason handed to the driver does not say the refusal was permanent"
grep -q 'That refusal is PERMANENT' "$LOG" || { tail -20 "$LOG" >&2
  fail "the log does not give the reason it failed fast"; }
grep -q 'Waiting ' "$LOG" && fail "401: it waited"
echo "   ok  1 call, ${ELAPSED}s, stopped with its reason"

echo "PROVIDER-BACKOFF PASS — a transient refusal is waited out; a permanent one is not"
