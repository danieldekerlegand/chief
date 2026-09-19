#!/usr/bin/env bash
# test/unavailnote.sh — a REFUSED row must name who refused it, in the words chief
# already wrote down.
#
# US-3 of tasks/chief/125-a-spent-account-says-so. The reason chief was given lives on
# disk from the moment the worker parks (driver.sh copies the agent's
# `.provider-unavailable` to `$STATE/<name>.unavailable`), and until 0.9.37 the ONLY
# reader was the end-of-run summary: a `provider-unavailable` row fell through to the
# generic phase line and read `provider-unavailable for 4m`, so an operator WATCHING a
# run saw strictly less than one reading its epilogue.
#
# This drives the RENDERER against a staged state directory + a synthetic run registry
# — no driver, no agent, no git, no provider — because the claim is about what the row
# does with a record. Both views are asserted, separately: `chief ps` is `monitor.sh
# once` and `chief monitor` is `watch`, and only the first is cheap to assert.
#
#   PART A  the four refusals, one state: exhausted · credential · transient-spent ·
#           nothing recorded. Each asserted as ONE WHOLE LINE (the row and its note,
#           joined), because a fragment like `HTTP 402` is also printed by the run
#           summary and cannot tell the two surfaces apart.
#   PART B  the same four in `chief monitor`.
#   PART C  REPRODUCES the defect first: with the new arm neutered in a COPY of the
#           engine, the same records render the old generic phase line. Without this,
#           the file could pass by restating behaviour that always worked.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; . "$ROOT/test/lib.sh"
WORK="$(mktemp -d)"
holder=""; mon_pid=""
cleanup() {
  [ -n "$mon_pid" ] && { kill "$mon_pid" 2>/dev/null || true; wait "$mon_pid" 2>/dev/null || true; }
  if [ -n "$holder" ]; then kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap 'rc=$?; cleanup; exit "$rc"' EXIT
fail() { echo "UNAVAILNOTE FAIL: $*" >&2; exit 1; }

STATE="$WORK/state"; PAR="$STATE/parallel"; RUNS="$WORK/runs"
mkdir -p "$PAR" "$RUNS" "$WORK/repo" "$WORK/tasks" "$WORK/wt"
# shellcheck source=engine/live.sh
. "$ROOT/engine/live.sh"            # the REAL writer, so the fixture cannot drift

sleep 60 & holder=$!                # the monitor prunes run files whose pid is dead
NOW="$(date +%s)"

# The record is written by live_set and only AGED by hand — and the ageing is a
# line-wise sed on purpose. live_get is a one-key-per-line sed reader (engine/live.sh),
# so re-dumping the record with any compact JSON writer produces a file that is valid
# JSON, looks perfectly healthy, and reads back as EMPTY for every field.
age_rec() {  # $1 file  $2 seconds-in-phase  $3 seconds-since-heartbeat
  sed -e "s/^  \"phase_since\": .*/  \"phase_since\": $(( NOW - $2 )),/" \
      -e "s/^  \"heartbeat\": .*/  \"heartbeat\": $(( NOW - $3 ))/" "$1" > "$1.aged"
  mv "$1.aged" "$1"
}
refused() {  # $1 name  $2 refusal verdict ('' = none recorded)  $3 noturn  $4 recorded reason ('' = none)
  echo provider-unavailable > "$PAR/$1.state"
  live_set "$PAR/$1.live.json" name="$1" state=provider-unavailable phase=provider-unavailable \
    story=US-3 iter=3 passing=1 total=4 noturn="$3" noturn_limit=3 refusal="$2"
  age_rec "$PAR/$1.live.json" 260 120
  [ -n "$4" ] && printf '%s' "$4" > "$PAR/$1.unavailable"
  return 0
}

# The reason lines are the AGENT's own, verbatim from _provider_unavailable's two
# printf calls — a fixture that invents its own format would test the fixture.
refused spent-row  exhausted  1 'HTTP 402 (billing_error) — PERMANENT refusal, not retried: the account has no usage left to spend (add credit or raise the plan limit on this account, or point the run at one that has usage left — the credential itself is fine) — 2026-09-15 09:12:00'
refused badkey-row credential 1 'HTTP 401 (authentication_error) — PERMANENT refusal, not retried: the credential is wrong, revoked, or not entitled to this model (fix or replace the credential — topping an account up cannot lift this one) — 2026-09-15 09:12:00'
refused blip-row   transient  3 'HTTP 503 — 2026-09-15 09:12:00'
refused mute-row   ''         0 ''
# STILL RETRYING a transient refusal: the scheduler still calls it running, and the
# operator action is to WAIT. It is the case the three above must be distinguishable
# from, so it is staged as the control rather than described.
echo running > "$PAR/wait-row.state"
live_set "$PAR/wait-row.live.json" name=wait-row state=running phase=provider-backoff \
  story=US-3 iter=3 passing=1 total=4 noturn=2 noturn_limit=3 refusal=transient \
  retry_at="$(( NOW + 30 ))"
age_rec "$PAR/wait-row.live.json" 20 5

cat > "$RUNS/$holder.run" <<EOF
pid=$holder
repo=$WORK/repo
base=main
parallel=2
tool=claude
automerge=1
limitmax=3
started=$NOW
state=$STATE
staterel=.chief/state
tasks=$WORK/tasks
wt=$WORK/wt
names=spent-row badkey-row blip-row mute-row wait-row
EOF

# ONE WHOLE LINE: the row and the note beneath it, joined and stripped of colour.
row() { printf '%s\n' "$2" | tr -d '\033' | grep -A1 "$1 " | tr -d '\n'; }
want() {  # WHAT  ROW  NEEDLE  (the needle is the whole note, not a fragment)
  case "$2" in *"$3"*) ;; *) fail "$1: expected the row to carry
  $3
got
  $2" ;; esac
}
never() { case "$2" in *"$3"*) fail "$1: the row must NOT carry '$3': $2" ;; esac ; }

# The four notes, in full. Everything up to the age is fixed text, so the assertion is
# the whole line minus a clock reading nothing can pin.
N_SPENT='the provider refused the request — HTTP 402 (billing_error) · refusal 1/3 · the account has no usage left to spend · PERMANENT — not retried, because no delay lifts it · add credit, raise the plan limit, or point the run at an account that has usage · branch + worktree kept · held '
N_BADKEY='the provider refused the request — HTTP 401 (authentication_error) · refusal 1/3 · the credential is wrong, revoked, or not entitled to this model · PERMANENT — not retried, because no delay lifts it · fix or replace the credential · branch + worktree kept · held '
N_BLIP='the provider refused the request — HTTP 503 · refusal 3/3 · each refusal was waited out first and the budget is spent · re-run once the provider answers again · branch + worktree kept · held '
# NOTHING RECORDED: the conclusion, and not one word of invented reason. No `—`
# clause, no verdict, no refusal count (a `0/3` is an accounting that never happened).
N_MUTE='the provider refused the request · branch + worktree kept · held '

check() {  # $1 label  $2 output
  local what="$1" out="$2" r
  want "$what" "$(row spent-row  "$out")" "$N_SPENT"
  want "$what" "$(row badkey-row "$out")" "$N_BADKEY"
  want "$what" "$(row blip-row   "$out")" "$N_BLIP"
  want "$what" "$(row mute-row   "$out")" "$N_MUTE"
  # The verdicts are not interchangeable, in the note as well as in the label: the
  # whole point is that topping an account up cannot lift a revoked key.
  r="$(row spent-row "$out")"
  want  "$what" "$r" 'no-credit'
  never "$what" "$r" 'the credential is wrong'
  r="$(row badkey-row "$out")"
  want  "$what" "$r" 'bad-key'
  never "$what" "$r" 'no usage left'
  # PERMANENT vs STILL RETRYING. The two permanent rows say so; the transient ones —
  # the one whose budget is spent and the one still in backoff — never do, because a
  # row that claims a wait is pointless when a retry is scheduled is the worse error.
  for n in blip-row mute-row wait-row; do never "$what" "$(row $n "$out")" 'PERMANENT'; done
  r="$(row wait-row "$out")"
  want  "$what" "$r" 'provider-backoff'
  want  "$what" "$r" 'provider attempt 2/3'
  never "$what" "$r" 'the provider refused the request'
  never "$what" "$r" 'branch + worktree kept'
  # None of the refusals is a failure, and none borrows the stall vocabulary.
  for n in spent-row badkey-row blip-row mute-row; do
    r="$(row $n "$out")"
    case "$r" in *'✗'*|*'⤬'*) fail "$what: $n took a failure glyph: $r" ;; esac
    case "$r" in *'⏸'*) ;; *) fail "$what: $n is missing the hold glyph: $r" ;; esac
    never "$what" "$r" 'no progress last iter'
  done
}

# ══ PART A — chief ps ════════════════════════════════════════════════════════
echo "unavailnote: part A — chief ps, against a staged record"
ps_out="$(CHIEF_RUNS="$RUNS" bash "$ROOT/bin/chief" ps)" || fail "chief ps exited non-zero"
echo "--- chief ps (four refusals + one still retrying) ---"; printf '%s\n' "$ps_out"
check "chief ps" "$ps_out"
echo "   ok  four refused rows name their reason, their verdict and their fix"

# ══ PART B — chief monitor ═══════════════════════════════════════════════════
# The same render in a redraw loop. Wait for a WHOLE frame (the last row's detail
# line, not just its row), then stop.
echo "unavailnote: part B — chief monitor, the same records through the watcher"
mon_log="$WORK/monitor.out"
CHIEF_RUNS="$RUNS" bash "$ROOT/bin/chief" monitor 1 > "$mon_log" 2>&1 &
mon_pid=$!
for _ in $(seq 1 50); do
  [ "$(grep -A1 'wait-row' "$mon_log" 2>/dev/null | wc -l | tr -d ' ')" -ge 2 ] && break
  sleep 0.2
done
kill "$mon_pid" 2>/dev/null || true; wait "$mon_pid" 2>/dev/null || true; mon_pid=""
grep -q 'spent-row' "$mon_log" || fail "chief monitor never rendered a frame"
check "chief monitor" "$(cat "$mon_log")"
echo "   ok  one renderer, both views"

# ══ PART C — REPRODUCE: the row without the arm ══════════════════════════════
# The pre-0.9.37 render, produced by neutering the arm in a COPY of the engine (not by
# checking out an older revision: CI clones shallow). If the assertions above pass
# against THIS engine too, they are asserting something that always worked.
echo "unavailnote: part C — the same records with the arm neutered"
CP="$WORK/engine-cp"; cp -R "$ROOT/engine" "$CP"
sed 's/^      elif \[ "\$st" = provider-unavailable \]; then$/      elif [ "$st" = never-a-state ]; then/' \
  "$ROOT/engine/monitor.sh" > "$CP/monitor.sh"
grep -q 'never-a-state' "$CP/monitor.sh" || fail "part C could not neuter the arm — the render loop moved"
old_out="$(CHIEF_RUNS="$RUNS" bash "$CP/monitor.sh" once)" || fail "the neutered monitor exited non-zero"
r="$(row spent-row "$old_out")"
case "$r" in *'provider-unavailable for'*) ;; *) fail "part C did not reproduce the old generic line: $r" ;; esac
case "$r" in *'HTTP 402'*) fail "part C: the neutered engine still named the reason — the assertion above proves nothing: $r" ;; esac
echo "   ok  without the arm the same record renders 'provider-unavailable for 4m' and nothing else"

echo "UNAVAILNOTE PASS — a refused row names the code, the verdict and the fix in both views; an unrecorded reason invents nothing; a retrying row is still a wait"
