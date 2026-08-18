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
#   3. THE DIAGNOSIS — the flag NAMES the state it was stuck in and the limit that
#                    state had earned. 'stalled in rate-limited-waiting … past its
#                    6h30m limit' is actionable; 'no activity for 2h' is not.
#   4. GONE ≠ QUIET — a worker pid that died mid-run is a different, worse finding than
#                    a quiet one, and must not render as the same note. A worker that
#                    wrote its verdict FINISHED and is not either.
#   5. BOTH VIEWS  — `chief ps` and `chief monitor`, against a synthetic registry.
#                    The two render the flag differently (live_note … stale vs a bare
#                    fallback string), so a fix landing in one is not a fix.
#   6. ELAPSED-IN-PHASE — and the other half of the same morning: seven of the nine
#                    runs killed on 2026-08-17 were working, and looked stalled only
#                    because the phase never changed and nothing said how long it had
#                    been held. Every row arm carries the duration, in both views, from
#                    `phase_since` and never from the render clock.
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
# FLAGGED — every other phase the engine publishes, each against ITS OWN threshold.
# `provider-waiting` heads the list on purpose: it is the whole duration of an agent
# turn and so is quiet MOST of the time, but a provider that never returns is a real
# hang — on 2026-08-17 two runs sat in it having produced 0 bytes and never reached
# iteration 1. It is classified EXPLICITLY at the default rather than lengthened:
# agent.sh's `_beat_start` ticks the record every ~15s for the whole provider call, so
# 15m of silence there is ~60 missed beats — a dead ticker, not a long turn — and a
# longer threshold would hide exactly those two runs. Never an exemption, either.
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

# Match the MARKER, not the word: `stalled` is itself a phase literal (agent.sh
# publishes it at a no-progress iteration boundary), so a bare *stalled* glob is true
# of that row's phase name whether or not the flag was ever appended.
flagged() { case "$(note "$1" "$2")" in *'⚠ stalled'*) return 0 ;; *) return 1 ;; esac; }

# 40m of silence: nearly 3x the 15m default, and the age the real rows carried.
for p in $QUIET_PHASES; do
  flagged "$p" 2400 && fail "'$p' is quiet by design and was still flagged stalled: $(note "$p" 2400)"
  case "$(note "$p" 2400)" in
    *"$p for 40m"*) ;;
    *) fail "'$p' lost its phase / elapsed-in-phase: $(note "$p" 2400)" ;;
  esac
done
# Every non-exempt phase, driven against ITS OWN threshold in both directions — which
# is what makes "each phase carries its own" a checkable claim rather than a comment.
for p in $FLAGGED_PHASES; do
  thr="$(stale_threshold_for_phase "$p")"
  flagged "$p" "$(( thr + 60 ))" \
    || fail "'$p' went quiet past its own ${thr}s threshold and was NOT flagged: $(note "$p" "$(( thr + 60 ))")"
  flagged "$p" "$(( thr - 60 ))" \
    && fail "'$p' was flagged BEFORE its own ${thr}s threshold: $(note "$p" "$(( thr - 60 ))")"
done
# The threshold function is the one place the list is consulted — assert it directly
# too, so a caller that forgets to pass the phase is a visible regression.
[ "$(stale_threshold_for_phase rate-limited-waiting)" = "$STALE_QUIET_AFTER" ] \
  || fail "stale_threshold_for_phase didn't give the quiet phase its own threshold"
[ "$(stale_threshold_for_phase provider-waiting)" = "$STALE_AFTER" ] \
  || fail "provider-waiting must keep the DEFAULT threshold, not a longer one"
# The re-tuned phases: the figure is the 36m block-buffered `cargo test` of
# cuneiform:314 (2026-08-13) plus one default window, and a round number substituted
# for it later should have to change this line deliberately.
for p in verifying warmup; do
  [ "$(stale_threshold_for_phase "$p")" = 3060 ] \
    || fail "'$p' must carry its own measured threshold (2160 observed + one window), got $(stale_threshold_for_phase "$p")"
done
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
# 890, not 899: the fixture stamps the record and then reads it back a beat later, so
# an offset within a second of the boundary is decided by whether the clock ticked
# between the two — a flake, not a policy. The thr±60 sweep above is the real check.
flagged provider-waiting 890 && fail "a phase under the default threshold was flagged"
flagged provider-waiting 900 || fail "the default threshold no longer flags at 900s"

# ══ PART 3 — THE DIAGNOSIS ═══════════════════════════════════════════════════
# A flag that only reports silence is a flag an operator learns to skip. Past its own
# threshold, the line has to say WHICH state was quiet and what that state was allowed.
echo "stall-flag: part 3 — the flag names the state and its limit"
diag() {  # PHASE OFFSET SUBSTRING… — every substring must appear in the flagged line
  local p="$1" off="$2" line; shift 2
  line="$(note "$p" "$off")"
  for want in "$@"; do
    case "$line" in *"$want"*) ;; *) fail "the flag for '$p' is missing '$want': $line" ;; esac
  done
}
diag rate-limited-waiting "$(( STALE_QUIET_AFTER + 600 ))" \
  'stalled in rate-limited-waiting' 'past its 6h30m limit'
diag verifying 3200 'stalled in verifying' 'past its 51m limit'
diag provider-waiting 1200 'stalled in provider-waiting' 'past its 15m limit'

# ══ PART 4 — GONE ≠ QUIET ════════════════════════════════════════════════════
# The other half of "is this run in trouble": a quiet worker is THERE and not talking,
# an absent one is not coming back. Rendering both as the same yellow note is how nine
# runs came to be killed on 2026-08-17 on the assumption they were the same thing.
echo "stall-flag: part 4 — a dead worker is not a quiet one"
sh -c 'exit 0' & dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
kill -0 "$dead_pid" 2>/dev/null && fail "fixture pid $dead_pid is somehow still alive"

# A FRESH heartbeat throughout: 'gone' must not need the run to be stale first.
live_set "$PAR/probe.live.json" name=probe state=running phase=agent-turn story=US-1 iter=2
rm -f "$PAR/probe.pid" "$PAR/probe.status"
worker_gone probe "$STATE" && fail "no pid file at all is UNKNOWN, and unknown is never dead"
case "$(live_note probe "$STATE" stale)" in
  *dead*) fail "a tasklist with no pid file was reported dead: $(live_note probe "$STATE" stale)" ;;
esac
echo "$$" > "$PAR/probe.pid"
worker_gone probe "$STATE" && fail "a LIVE worker pid must not read as dead"
echo "$dead_pid" > "$PAR/probe.pid"
worker_gone probe "$STATE" || fail "a dead worker pid with no verdict must read as gone"
case "$(live_note probe "$STATE")" in
  *'✗ dead'*) ;;
  *) fail "the detail line must say the worker is gone: $(live_note probe "$STATE")" ;;
esac
case "$(live_note probe "$STATE" stale)" in
  *stalled*) fail "a dead worker must not be downgraded to 'stalled': $(live_note probe "$STATE" stale)" ;;
esac
# …and a worker that wrote its verdict FINISHED. The scheduler reaps it on its next
# poll; a row must not flash ✗ for one tick every time a tasklist completes.
echo "MERGED @0123456" > "$PAR/probe.status"
worker_gone probe "$STATE" && fail "a worker that recorded a verdict has finished, not died"
rm -f "$PAR/probe.pid" "$PAR/probe.status"

# ══ PART 5 — BOTH VIEWS ══════════════════════════════════════════════════════
# `chief ps` and `chief monitor` are separate render paths over the same rows.
echo "stall-flag: part 5 — chief ps and chief monitor"
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
mkrow gate-wait  running verifying            2400          # re-tuned: 40m < its 51m
mkrow worker-off running agent-turn             60          # heartbeat FRESH, worker gone
echo "$dead_pid" > "$PAR/worker-off.pid"

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
names=limit-wait prov-wait limit-dead gate-wait worker-off
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
  # The re-tune, at the render site: 40m quiet in a gate is inside the 51m that phase
  # earned, and 40m quiet in provider-waiting (above) is not. One number could not
  # have got both of those right.
  r="$(row gate-wait "$out")"
  case "$r" in
    *stalled*) fail "$what: a 40m verify is inside its own 51m threshold and must not flag: $r" ;;
    *'⚠'*)     fail "$what: a 40m verify still took the ⚠ glyph: $r" ;;
  esac
  # Gone, on a FRESH heartbeat: a row that is quiet has to look different from a row
  # that is not there, in the glyph AND in the words.
  r="$(row worker-off "$out")"
  case "$r" in *'✗'*) ;; *) fail "$what: a dead worker did not take the ✗ glyph: $r" ;; esac
  case "$r" in *dead*) ;; *) fail "$what: a dead worker is not reported as gone: $r" ;; esac
  case "$r" in *stalled*) fail "$what: a dead worker was downgraded to 'stalled': $r" ;; esac
  # …and in the LABEL column too. The glyph and the detail line are not enough on their
  # own: the label is the field `chief ps | grep` and a scanning eye both land on, and a
  # gone row that still reads `running` there is the mistake of 2026-08-17 restated.
  case "$r" in *' gone '*) ;; *) fail "$what: a dead worker's row is still labelled with its stale scheduler state: $r" ;; esac
  case "$r" in *running*) fail "$what: a dead worker's row still reads 'running': $r" ;; esac
}

ps_out="$(CHIEF_RUNS="$RUNS" bash "$ROOT/bin/chief" ps)" || fail "chief ps exited non-zero"
echo "--- chief ps (quiet-by-design · not-exempt · past-the-ceiling · re-tuned · gone) ---"; printf '%s\n' "$ps_out"
check "chief ps" "$ps_out"

# `chief monitor` is the same render in a redraw loop: run it, wait for a frame, stop.
mon_log="$WORK/monitor.out"
CHIEF_RUNS="$RUNS" bash "$ROOT/bin/chief" monitor 1 > "$mon_log" 2>&1 &
mon_pid=$!
# Wait for the LAST row's detail line, not just its row: the poll used to break on
# the first frame byte that matched and then assert against a half-drawn frame.
for _ in $(seq 1 50); do
  [ "$(grep -A1 'worker-off' "$mon_log" 2>/dev/null | wc -l | tr -d ' ')" -ge 2 ] && break
  sleep 0.2
done
kill "$mon_pid" 2>/dev/null || true; wait "$mon_pid" 2>/dev/null || true
mon_out="$(tr -d '\033' < "$mon_log")"
grep -q 'worker-off' "$mon_log" || fail "chief monitor never rendered a frame"
check "chief monitor" "$mon_out"



# ══ PART 6 — ELAPSED-IN-PHASE IS ROUTINE, NOT ONLY WHEN FLAGGED ══════════════
# The other half of the 2026-08-17 morning: seven of the nine runs killed as 'stalled'
# were working. `chief monitor` showed `provider-waiting` and never changed, and there
# was no duration beside it to say whether that meant forty SECONDS into a turn or
# forty MINUTES into nothing. So every row arm — not just a flagged one — has to carry
# how long the current state has been held.
#
# Two properties are asserted, and the second is the one that makes the first mean
# anything:
#   • EVERY arm of the row loop carries it. The five coarse states dispatch to five
#     different note paths (live_note · limit_note · op_note · hold_note ×2), and a
#     duration that appears in one view and not another reproduces the split.
#   • It comes from `phase_since`, NOT from the render clock and NOT from the
#     heartbeat. Every fixture below heartbeats FRESH while its phase is hours old:
#     a duration derived from either of the other two timestamps would read ~0s here,
#     which is exactly the reading that made a long hold look instantaneous.
echo "stall-flag: part 6 — elapsed-in-phase in every arm, from phase_since"

# Backdate phase_since ONLY. The heartbeat stays now, so nothing here is stale and
# nothing takes a flag — this is the ORDINARY view.
mkphase() {  # NAME COARSE-STATE PHASE PHASE-AGE-SECONDS
  local n="$1" f v t
  echo "$2" > "$PAR/$n.state"
  f="$PAR/$n.live.json"
  live_set "$f" name="$n" state="$2" phase="$3" story=US-3 iter=2 passing=1 total=4
  v="$(live_get "$f" phase_since)"; t="$f.bd"
  sed "s/\"phase_since\": $v/\"phase_since\": $(( v - $4 ))/" "$f" > "$t" && mv "$t" "$f"
}
mkphase held-run    running           agent-turn            2400    # 40m
mkphase held-limit  rate-limited      rate-limited-waiting  1500    # 25m
mkphase held-op     paused            operator-paused       3660    # 1h01m
mkphase held-review awaiting-review   awaiting-review      11400    # 3h10m
mkphase held-zone   awaiting-approval awaiting-approval      780    # 13m
printf '{"zones":[{"zone":"engine"}],"files":["engine/monitor.sh"]}\n' > "$PAR/held-zone.zone-request.json"

sed "s|^names=.*|names=held-run held-limit held-op held-review held-zone|" \
  "$RUNS/$holder.run" > "$RUNS/$holder.run.tmp" && mv "$RUNS/$holder.run.tmp" "$RUNS/$holder.run"

held_check() {  # LABEL OUTPUT
  local what="$1" out="$2" r pair
  # name:duration — the value each arm must be showing, and no two alike, so a note
  # that reads another row's record (or a constant) cannot pass.
  for pair in held-run:40m held-limit:25m held-op:1h01m held-review:3h10m held-zone:13m; do
    r="$(row "${pair%%:*}" "$out")"
    case "$r" in
      *"${pair##*:}"*) ;;
      *) fail "$what: ${pair%%:*} does not show its elapsed-in-phase (${pair##*:}): $r" ;;
    esac
    # Never flagged: the heartbeat is fresh. Elapsed-in-phase is INFORMATION, and the
    # moment it reads as an alarm an operator is back to ignoring it.
    case "$r" in *'⚠ stalled'*) fail "$what: ${pair%%:*} heartbeats fresh and must not be flagged: $r" ;; esac
  done
}

held_out="$(CHIEF_RUNS="$RUNS" bash "$ROOT/bin/chief" ps)" || fail "chief ps (part 6) exited non-zero"
echo "--- chief ps (running · rate-limited · operator-paused · in-review · zone-hold) ---"; printf '%s\n' "$held_out"
held_check "chief ps" "$held_out"

mon2_log="$WORK/monitor2.out"
CHIEF_RUNS="$RUNS" bash "$ROOT/bin/chief" monitor 1 > "$mon2_log" 2>&1 &
mon2_pid=$!
for _ in $(seq 1 50); do
  [ "$(grep -A1 'held-zone' "$mon2_log" 2>/dev/null | wc -l | tr -d ' ')" -ge 2 ] && break
  sleep 0.2
done
kill "$mon2_pid" 2>/dev/null || true; wait "$mon2_pid" 2>/dev/null || true
grep -q 'held-zone' "$mon2_log" || fail "chief monitor never rendered a part-6 frame"
held_check "chief monitor" "$(tr -d '\033' < "$mon2_log")"

echo "stall-flag: OK — per-phase thresholds, a flag that names the state, gone ≠ quiet, and elapsed-in-phase in every arm"
