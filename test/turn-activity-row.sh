#!/usr/bin/env bash
# test/turn-activity-row.sh — THE ROW SAYS WHAT THE AGENT IS DOING, in `chief ps` and
# in `chief monitor` alike.
#
# The defect, measured 2026-09-15 on a live run: a tasklist read
#   provider-waiting for 16m · US-3 · iter 1 · 2s ago
# and an operator could not tell work from a hang. Both durations on that line are
# about CHIEF — how long the phase has been held, and when chief's own in-turn ticker
# last wrote — and neither is about the AGENT. It was working: the provider had run a
# Bash tool call 8 seconds earlier. 126/US-2 taught the engine to publish that
# (`tool` · `tool_since` · `tools`, engine/live.sh); this file is the claim that the
# ROW renders it, and that nothing else about the row moved.
#
# What is asserted:
#   A. THE SEGMENT   — a record carrying turn activity renders `⚙ Bash Ns ago ·
#                      12 tools` beside the phase. Asserted as a WHOLE detail line,
#                      not a fragment: the fields also appear in the record, in the
#                      event stream and in agent.sh's own log, and a grep for `Bash`
#                      would pass on any of them.
#   B. AND NOTHING ELSE — a record WITHOUT those fields (an older engine, a provider
#                      with no streaming mode, CHIEF_STREAM_ACTIVITY=0) renders
#                      exactly the line it always did.
#   C. THE FLAG IS NOT DEFEATED — a record whose heartbeat has stopped while a stream
#                      was open is STILL flagged ⚠, and its last-known tool is
#                      rendered with an age that corroborates the flag rather than
#                      contradicting it. This is the fact the flag rests on
#                      (engine/monitor.sh, `is_stale`): the heartbeat, never the
#                      stream.
#   D. BOTH SURFACES — `chief ps` (monitor.sh once) and `chief monitor` (watch). One
#                      renderer serves both, and a shared renderer is not a shared
#                      assertion.
#   E. SABOTAGE CONTROL — the activity fields are then REMOVED from the same records
#                      and the same registry re-rendered. The new assertions go red
#                      (nothing renders `⚙`), and every existing row assertion stays
#                      green — proved by stripping the activity segment out of the
#                      with-fields line and requiring the result to equal the
#                      without-fields line BYTE FOR BYTE. The addition did not rewrite
#                      the old rows; it appended to them.
#
# Staged records throughout, never a live provider: the claim is about the RENDERER,
# and a test that has to win a race with a real turn to see a tool name is a test that
# reports the race.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; . "$ROOT/test/lib.sh"
WORK="$(mktemp -d)"

# HERMETIC IN STATE IS NOT HERMETIC IN ENV — this suite may itself be running inside a
# chief worktree whose driver exported an operator-pause path (see test/stall-flag.sh).
unset CHIEF_PAUSE_FILE
holder=""
mon_pid=""
cleanup() {
  for p in $holder $mon_pid; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap 'rc=$?; cleanup; exit "$rc"' EXIT
fail() { echo "TURN-ACTIVITY-ROW FAIL: $*" >&2; exit 1; }

export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"   # hermetic: never touch ~/.chief
STATE="$WORK/state"; PAR="$STATE/parallel"
mkdir -p "$CHIEF_RUNS" "$PAR" "$WORK/mrepo" "$WORK/mtasks" "$WORK/mwt"

# monitor.sh in `lib` mode defines the helpers and renders nothing, and it sources
# live.sh — so every fixture below is written by the REAL writer and cannot drift from
# the record format. (A record re-dumped by `jq -c` is valid JSON that `live_get` reads
# back EMPTY; see the live_set note in CLAUDE.md.)
# shellcheck source=engine/monitor.sh
. "$ROOT/engine/monitor.sh" lib

age_key() {  # FILE KEY SECONDS — move a numeric field back in time, line-wise
  local f="$1" k="$2" by="$3" v t
  v="$(live_get "$f" "$k")"
  case "$v" in ''|*[!0-9]*) fail "age_key: $k is not numeric in $f" ;; esac
  t="$f.aged"
  sed "s/\"$k\": $v/\"$k\": $(( v - by ))/" "$f" > "$t" && mv "$t" "$f"
}

mkrow() {  # NAME PHASE HB_AGE PHASE_AGE [TOOL TOOL_AGE TOOLS]
  local n="$1" f now
  echo running > "$PAR/$n.state"
  f="$PAR/$n.live.json"
  now="$(date +%s)"
  if [ -n "${5:-}" ]; then
    live_set "$f" name="$n" state=running phase="$2" story=US-3 iter=1 passing=2 total=3 \
      tool="$5" tool_since=$(( now - $6 )) tools="$7"
  else
    live_set "$f" name="$n" state=running phase="$2" story=US-3 iter=1 passing=2 total=3
  fi
  age_key "$f" heartbeat "$3"; age_key "$f" phase_since "$4"
}

strip_tools() {  # NAME — the sabotage: the same row, with the interior removed
  live_set "$PAR/$1.live.json" tool= tool_since=0 tools=0
  age_key "$PAR/$1.live.json" heartbeat "$2"
}

# tl-stream  a healthy long turn chief CAN see inside: 16m in phase, ticker fresh,
#            a Bash call chief first saw 8s ago, 12 calls so far.
# tl-plain   the same turn from a provider chief CANNOT see inside — the control for
#            "renders exactly as today".
# tl-stale   the stream was open and the ticker STOPPED: 40m of silence in a phase
#            that allows 15m. The flag must fire anyway.
mkrow tl-stream provider-waiting    5  960 Bash    8 12
mkrow tl-plain  provider-waiting    5  960
mkrow tl-stale  provider-waiting 2400 2400 Bash 2340 12

sleep 300 & holder=$!                        # a live pid: the monitor prunes dead runs
cat > "$CHIEF_RUNS/$holder.run" <<EOF
pid=$holder
repo=$WORK/mrepo
base=main
parallel=3
tool=claude
automerge=1
limitmax=3
started=$(date +%s)
state=$STATE
staterel=.chief/state
tasks=$WORK/mtasks
wt=$WORK/mwt
names=tl-stream tl-plain tl-stale
EOF

# The rendered detail line for one row, normalised: escapes out, and second-resolution
# clocks folded to `Ns` so two renders taken a second apart compare byte for byte. The
# MINUTE-scale durations are left alone — they are the assertion.
detail() {  # NAME OUTPUT -> the first `↳` line under that row, without its marker
  printf '%s\n' "$2" \
    | grep -A1 -- "$1 " \
    | grep '↳' | head -1 \
    | sed -e 's/^ *↳ *//' -e 's/[0-9][0-9]*s ago/Ns ago/g'
}

# EVERY EXISTING ROW FACT — phase, elapsed-in-phase, story, iter, and the flag. Run
# against BOTH renders and against the sabotaged one, so "the addition did not rewrite
# the old rows" is checked rather than assumed.
base_check() {  # LABEL OUTPUT
  local what="$1" out="$2" r
  r="$(detail tl-stream "$out")"
  case "$r" in
    'provider-waiting for 16m · US-3 · iter 1'*) ;;
    *) fail "$what: the healthy row lost its phase/story/iter head: [$r]" ;;
  esac
  case "$r" in *stalled*|*'⚠'*) fail "$what: a 16m turn with a fresh heartbeat was flagged: [$r]" ;; esac
  case "$r" in *'Ns ago') ;; *) fail "$what: the healthy row lost its trailing heartbeat age: [$r]" ;; esac
  r="$(detail tl-plain "$out")"
  case "$r" in
    'provider-waiting for 16m · US-3 · iter 1 · Ns ago') ;;
    *) fail "$what: a record with no turn activity did not render exactly as before: [$r]" ;;
  esac
  # THE FLAG RESTS ON THE HEARTBEAT. An open stream does not buy a run 40m of silence.
  r="$(detail tl-stale "$out")"
  case "$r" in
    *'⚠ stalled in provider-waiting — no activity for 40m, past its 15m limit') ;;
    *) fail "$what: a stalled row with a stream open was not flagged: [$r]" ;;
  esac
  printf '%s\n' "$out" | grep -A1 -- 'tl-stale ' | grep -q '⚠' \
    || fail "$what: the stalled row lost its ⚠ glyph"
}

# THE NEW CLAIM — the whole line, both for the healthy row and for the flagged one.
activity_check() {  # LABEL OUTPUT
  local what="$1" out="$2" r
  r="$(detail tl-stream "$out")"
  [ "$r" = 'provider-waiting for 16m · US-3 · iter 1 · ⚙ Bash Ns ago · 12 tools · Ns ago' ] \
    || fail "$what: the running row does not render the turn's interior: [$r]"
  # On a flagged row the activity CORROBORATES the flag: the tool name chief last saw
  # is 39m old, beside 40m of silence. It must not be suppressed (an operator asking
  # "what was it doing when it stopped?" is the first question) and it must not read
  # as freshness.
  r="$(detail tl-stale "$out")"
  [ "$r" = 'provider-waiting for 40m · US-3 · iter 1 · ⚙ Bash 39m ago · 12 tools · ⚠ stalled in provider-waiting — no activity for 40m, past its 15m limit' ] \
    || fail "$what: the flagged row does not render its last-known activity: [$r]"
  r="$(detail tl-plain "$out")"
  case "$r" in *'⚙'*) fail "$what: a record with no turn activity rendered an activity segment: [$r]" ;; esac
}

# ══ A/B/C/D — chief ps ═══════════════════════════════════════════════════════
echo "turn-activity-row: chief ps"
ps_out="$(bash "$ROOT/bin/chief" ps 2>/dev/null)" || fail "chief ps exited non-zero"
ps_out="$(printf '%s' "$ps_out" | tr -d '\033' | sed 's/\[[0-9;]*[A-Za-z]//g')"
echo "--- chief ps ---"; printf '%s\n' "$ps_out"
base_check     "chief ps" "$ps_out"
activity_check "chief ps" "$ps_out"

# ══ D — chief monitor ════════════════════════════════════════════════════════
# The same render in a redraw loop. Run it, wait for the LAST row's detail line (not
# merely its row — the poll used to break on a half-drawn frame), stop.
echo "turn-activity-row: chief monitor"
mon_log="$WORK/monitor.out"
bash "$ROOT/bin/chief" monitor 1 > "$mon_log" 2>&1 &
mon_pid=$!
for _ in $(seq 1 50); do
  [ "$(grep -A1 -- 'tl-stale ' "$mon_log" 2>/dev/null | wc -l | tr -d ' ')" -ge 2 ] && break
  sleep 0.2
done
kill "$mon_pid" 2>/dev/null || true; wait "$mon_pid" 2>/dev/null || true; mon_pid=""
grep -q 'tl-stale' "$mon_log" || fail "chief monitor never rendered a frame"
mon_out="$(tr -d '\033' < "$mon_log" | sed 's/\[[0-9;]*[A-Za-z]//g')"
base_check     "chief monitor" "$mon_out"
activity_check "chief monitor" "$mon_out"

# ══ E — SABOTAGE CONTROL ═════════════════════════════════════════════════════
# Remove the interior from the records and re-render the SAME registry. The new
# assertions must go red and every old one must stay green.
echo "turn-activity-row: sabotage control — the fields removed"
before_stream="$(detail tl-stream "$ps_out")"
before_stale="$(detail tl-stale  "$ps_out")"
strip_tools tl-stream    5
strip_tools tl-stale  2400
sab_out="$(bash "$ROOT/bin/chief" ps 2>/dev/null)" || fail "chief ps exited non-zero after sabotage"
sab_out="$(printf '%s' "$sab_out" | tr -d '\033' | sed 's/\[[0-9;]*[A-Za-z]//g')"
echo "--- chief ps (activity fields removed) ---"; printf '%s\n' "$sab_out"

base_check "sabotage" "$sab_out"                         # every OLD assertion still green
# In a SUBSHELL: `fail` exits, and an `exit` inside an `if` condition still ends the
# whole script — the discriminating case would have killed the run silently.
if ( activity_check "sabotage" "$sab_out" ) 2>/dev/null; then
  fail "sabotage: the new assertions still pass with the activity fields removed — they are not discriminating"
fi
# `grep -q ... && fail` would return 1 under `set -e` on the PASSING path and kill the
# run with no message at all — the negative assertion is spelled as an `if`.
if printf '%s\n' "$sab_out" | grep -q '⚙'; then
  fail "sabotage: a row still rendered an activity segment with no fields on the record"
fi

# …and the two lines differ by EXACTLY the appended segment, which is the whole
# "did not rewrite the old rows" claim stated as an equality rather than as a mood.
dropped() { printf '%s' "$1" | sed 's/ · ⚙ [^·]*· [0-9]* tools*//'; }
for pair in "tl-stream:$before_stream" "tl-stale:$before_stale"; do
  n="${pair%%:*}"; was="${pair#*:}"
  now="$(detail "$n" "$sab_out")"
  [ "$(dropped "$was")" = "$now" ] \
    || fail "$n: removing the activity segment does not reproduce the pre-feature line:
  with:    [$was]
  dropped: [$(dropped "$was")]
  without: [$now]"
done

echo "TURN-ACTIVITY-ROW PASS"
