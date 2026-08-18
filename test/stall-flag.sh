#!/usr/bin/env bash
# test/stall-flag.sh — the stall flag is RUN-STATE AWARE: it is not appended to a
# phase whose silence is the behaviour chief itself just printed.
#
# The defect this pins, measured 2026-08-13: ten tasklists across three repos read
#   rate-limited-waiting for 16m · ⚠ stalled — no activity for 16m
# — one live_note() call printing the reason for the silence and then flagging that
# same silence. Every driver was alive and every run resumed when the window reopened.
# `⚠ stalled` was derived purely from the LOG WRITE age, which cannot tick while
# agent.sh's `_rate_limit_wait` sleeps, so the flag fired on exactly the state that
# explains it. A flag whose two halves contradict each other trains an operator to
# ignore it.
#
# What is asserted, cheapest first:
#   1. THE TABLE   — every phase the engine can publish, driven through live_note()
#                    against a synthetic record, so "which states are exempt" is a
#                    checkable list rather than a reading of the shell. Includes the
#                    drift guard: a phase added to the engine and classified nowhere
#                    fails here.
#   2. THE CEILING — the exemption EXPIRES. Quiet by design is not quiet forever; a
#                    usage window that never reopens must still become noteworthy.
#   3. BOTH VIEWS  — `chief ps` and `chief monitor`, against a synthetic registry.
#                    The two render the flag differently (live_note … stale vs a bare
#                    fallback string), so a fix landing in one is not a fix.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
holder=""
cleanup() {
  if [ -n "$holder" ]; then kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap 'rc=$?; cleanup; exit "$rc"' EXIT
fail() { echo "STALL-FLAG FAIL: $*" >&2; exit 1; }

export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"   # hermetic: never touch ~/.chief
mkdir -p "$CHIEF_RUNS"

# ══ PART 1 — THE TABLE ═══════════════════════════════════════════════════════
# monitor.sh in `lib` mode renders nothing and exports its helpers, so the policy is
# driven directly instead of being inferred from a screenful of rows. It sources
# live.sh itself, so the fixtures are written by the REAL writer and cannot drift
# from the record format.
echo "stall-flag: part 1 — the exempt/flagged table"
# shellcheck source=engine/monitor.sh
. "$ROOT/engine/monitor.sh" lib

# QUIET — silence here is the state, and chief printed the reason for it already.
QUIET_PHASES='rate-limited-waiting rate-limited operator-paused awaiting-review awaiting-approval'
# FLAGGED — every other phase the engine publishes. `provider-waiting` heads the list
# on purpose: it is the whole duration of an agent turn and so is quiet MOST of the
# time, but a provider that never returns is a real hang — on 2026-08-17 two runs sat
# in it having produced 0 bytes and never reached iteration 1. It takes a longer
# threshold, never an exemption, and this line is where that decision is recorded.
FLAGGED_PHASES='provider-waiting agent-turn writing stalled unverified complete
  research research-failed plan-turn plan-ready plan-invalid review-wait approved
  worktree seeded warmup reconcile merge-wait merge-queued batch-stacking rebasing
  rebase-conflict rebase-refused verifying verify-failed zone-check merging merged
  done checkout-failed merge-conflict re-dispatch empty-no-work incomplete
  complete-unmerged unsatisfiable'

STATE="$WORK/mon"; PAR="$STATE/parallel"
mkdir -p "$PAR"

# note PHASE AGE -> the detail line the monitor would render for a running row that
# has been silent for AGE seconds in PHASE, with the caller asking for the flag.
note() {
  local p="$1" off="$2" f="$PAR/probe.live.json" v t
  rm -f "$f"
  live_set "$f" name=probe state=running phase="$p" story=US-1 iter=2 passing=0 total=3
  for k in heartbeat phase_since; do
    v="$(live_get "$f" "$k")"; t="$f.bd"
    sed "s/\"$k\": $v/\"$k\": $(( v - off ))/" "$f" > "$t" && mv "$t" "$f"
  done
  live_note probe "$STATE" stale
}

flagged() { case "$(note "$1" "$2")" in *stalled*) return 0 ;; *) return 1 ;; esac; }

# 40m of silence: nearly 3x the 15m default, and the age the real rows carried.
for p in $QUIET_PHASES; do
  flagged "$p" 2400 && fail "'$p' is quiet by design and was still flagged stalled: $(note "$p" 2400)"
  case "$(note "$p" 2400)" in
    *"$p for 40m"*) ;;
    *) fail "'$p' lost its phase / elapsed-in-phase: $(note "$p" 2400)" ;;
  esac
done
for p in $FLAGGED_PHASES; do
  flagged "$p" 2400 || fail "'$p' went quiet for 40m and was NOT flagged: $(note "$p" 2400)"
done
# The threshold function is the one place the list is consulted — assert it directly
# too, so a caller that forgets to pass the phase is a visible regression.
[ "$(stale_threshold_for_phase rate-limited-waiting)" = "$STALE_QUIET_AFTER" ] \
  || fail "stale_threshold_for_phase didn't give the quiet phase its own threshold"
[ "$(stale_threshold_for_phase provider-waiting)" = "$STALE_AFTER" ] \
  || fail "provider-waiting must keep the DEFAULT threshold, not a longer one"
[ "$(stale_threshold_for_phase '')" = "$STALE_AFTER" ] \
  || fail "an unknown phase must take the default threshold (pre-existing behaviour)"

# DRIFT GUARD. Every phase literal the engine can publish must appear in one of the
# two lists above. A new state classified nowhere is exactly how a false stall gets
# reintroduced, and the answer must be a deliberate word in a list, not a default.
known=" $(printf '%s %s' "$QUIET_PHASES" "$FLAGGED_PHASES" | tr '\n' ' ' | tr -s ' ') "
while read -r p; do
  [ -n "$p" ] || continue
  case "$known" in *" $p "*) ;; *) fail "engine publishes phase '$p' but no list here classifies it" ;; esac
done <<EOF
$(grep -ohE 'phase=[a-z][a-z0-9-]*' "$ROOT"/engine/*.sh | sed 's/^phase=//' | sort -u)
EOF

# ══ PART 2 — THE CEILING ═════════════════════════════════════════════════════
# An exemption that never expires is a blind spot, not a fix: a usage window that
# never reopens is precisely what an operator needs told.
echo "stall-flag: part 2 — the exemption expires"
flagged rate-limited-waiting "$(( STALE_QUIET_AFTER + 600 ))" \
  || fail "a quiet-by-design phase past its ceiling must STILL flag: $(note rate-limited-waiting "$(( STALE_QUIET_AFTER + 600 ))")"
# …and the default is untouched for everything else.
[ "$STALE_AFTER" = 900 ] || fail "the default staleness window moved (now $STALE_AFTER)"
flagged provider-waiting 899 && fail "a phase under the default threshold was flagged"
flagged provider-waiting 900 || fail "the default threshold no longer flags at 900s"

# ══ PART 3 — BOTH VIEWS ══════════════════════════════════════════════════════
# `chief ps` and `chief monitor` are separate render paths over the same rows.
echo "stall-flag: part 3 — chief ps and chief monitor"
RUNS="$WORK/monruns"; mkdir -p "$RUNS" "$WORK/mrepo" "$WORK/mtasks" "$WORK/mwt"
sleep 300 & holder=$!                      # a live pid: the monitor prunes dead runs

rm -f "$PAR/probe.live.json"
mkrow() {  # NAME COARSE-STATE PHASE AGE
  local n="$1" f v t
  echo "$2" > "$PAR/$n.state"
  f="$PAR/$n.live.json"
  live_set "$f" name="$n" state="$2" phase="$3" story=US-1 iter=2 passing=1 total=4
  for k in heartbeat phase_since; do
    v="$(live_get "$f" "$k")"; t="$f.bd"
    sed "s/\"$k\": $v/\"$k\": $(( v - $4 ))/" "$f" > "$t" && mv "$t" "$f"
  done
}
mkrow limit-wait running rate-limited-waiting 2400          # quiet by design, 40m
mkrow prov-wait  running provider-waiting     2400          # NOT exempt, 40m
mkrow limit-dead running rate-limited-waiting "$(( STALE_QUIET_AFTER + 600 ))"   # past the ceiling

cat > "$RUNS/$holder.run" <<EOF
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
names=limit-wait prov-wait limit-dead
EOF

row() { printf '%s\n' "$2" | grep -A1 "$1 " | tr -d '\n'; }
check() {  # LABEL OUTPUT
  local what="$1" out="$2" r
  r="$(row limit-wait "$out")"
  case "$r" in
    *stalled*) fail "$what: the rate-limited row still says stalled: $r" ;;
    *'⚠'*)     fail "$what: the rate-limited row still took the ⚠ glyph: $r" ;;
  esac
  case "$r" in *'rate-limited-waiting for 40m'*) ;; *) fail "$what: the row lost its phase: $r" ;; esac
  r="$(row prov-wait "$out")"
  case "$r" in *stalled*) ;; *) fail "$what: a 40m provider-waiting row was NOT flagged: $r" ;; esac
  case "$r" in *'⚠'*) ;; *) fail "$what: the provider-waiting row lost its ⚠ glyph: $r" ;; esac
  r="$(row limit-dead "$out")"
  case "$r" in *stalled*) ;; *) fail "$what: a rate-limit wait past the ceiling was NOT flagged: $r" ;; esac
}

ps_out="$(CHIEF_RUNS="$RUNS" bash "$ROOT/bin/chief" ps)" || fail "chief ps exited non-zero"
echo "--- chief ps (quiet-by-design · not-exempt · past-the-ceiling) ---"; printf '%s\n' "$ps_out"
check "chief ps" "$ps_out"

# `chief monitor` is the same render in a redraw loop: run it, wait for a frame, stop.
mon_log="$WORK/monitor.out"
CHIEF_RUNS="$RUNS" bash "$ROOT/bin/chief" monitor 1 > "$mon_log" 2>&1 &
mon_pid=$!
for _ in $(seq 1 50); do grep -q 'limit-dead' "$mon_log" 2>/dev/null && break; sleep 0.2; done
kill "$mon_pid" 2>/dev/null || true; wait "$mon_pid" 2>/dev/null || true
mon_out="$(tr -d '\033' < "$mon_log")"
grep -q 'limit-dead' "$mon_log" || fail "chief monitor never rendered a frame"
check "chief monitor" "$mon_out"

echo "stall-flag: OK — quiet-by-design states are not flagged, and the exemption expires"
