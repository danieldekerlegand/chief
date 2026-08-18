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
#   7. TWO FINDINGS, TWO SENTENCES — the agent loop's no-progress COUNTER (normal, and
#                    now rendered as 'no progress last iter (n/N)') is not the at-risk
#                    FLAG (this run has not made a sound). One word for both is what
#                    made the actionable one unreadable.
#   8. THE PHASE IS ABOUT NOW — the agent loop driven through two consecutive
#                    no-progress iterations: `stalled` appears only BETWEEN them, the
#                    boundary hook that used to inherit it reports its own work, and
#                    the budget still stops the run on schedule.
#   9. RE-ENGAGEMENT SAYS SO — a real (hermetic) run picking a VERIFY-FAILED branch
#                    back up announces itself instead of wearing the phase the previous
#                    attempt left behind.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
holder=""
poller=""
cleanup() {
  for p in $holder $poller; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
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
FLAGGED_PHASES='provider-waiting agent-turn writing integrating stalled unverified
  complete research research-failed plan-turn plan-ready plan-invalid review-wait
  approved worktree re-engaging seeded warmup reconcile merge-wait merge-queued
  batch-stacking rebasing rebase-conflict rebase-refused verifying verify-failed
  zone-check merging merged done checkout-failed merge-conflict re-dispatch
  empty-no-work incomplete complete-unmerged unsatisfiable'

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

# ══ PART 7 — THE COUNTER IS NOT THE FLAG ═════════════════════════════════════
# Two findings wore one word. `stall 2` on a row that is heartbeating every fifteen
# seconds says the LAST iteration advanced nothing — normal, and the run is working —
# while `⚠ stalled` says this run has not made a sound. An operator who has learned
# that the first is noise reads past the second, which is how nine runs came to be
# killed on 2026-08-17. The counter now says what it means, in words, with the budget
# it is spent against: '2/2' is one iteration from the end of the run, '1/5' is a shrug.
#
# Its own state dir and its own rows: nothing here re-uses (or has to clean up) the
# fixtures parts 5 and 6 built, so a row asserted there cannot be perturbed here.
echo "stall-flag: part 7 — 'no progress last iter' vs the at-risk flag"
STATE7="$WORK/mon7"; PAR7="$STATE7/parallel"; mkdir -p "$PAR7"

mkcount() {  # NAME PHASE HEARTBEAT-AGE STALL STALL-LIMIT
  local n="$1" f v t
  echo running > "$PAR7/$n.state"
  f="$PAR7/$n.live.json"
  live_set "$f" name="$n" state=running phase="$2" story=US-1 iter=4 passing=1 total=4 \
    stall="$4" stall_limit="$5"
  for k in heartbeat phase_since; do
    v="$(live_get "$f" "$k")"; t="$f.bd"
    sed "s/\"$k\": $v/\"$k\": $(( v - $3 ))/" "$f" > "$t" && mv "$t" "$f"
  done
}
mkcount spent-budget  agent-turn         30 2 2   # ticking: one iteration from the end
mkcount early-stall   agent-turn         30 1 5   # ticking: barely started
mkcount old-record    agent-turn         30 2 0   # an engine that wrote no budget
mkcount really-quiet  provider-waiting 2400 1 2   # BOTH a counter and a real flag

sed -e "s|^state=.*|state=$STATE7|" \
    -e "s|^names=.*|names=spent-budget early-stall old-record really-quiet|" \
  "$RUNS/$holder.run" > "$RUNS/$holder.run.tmp" && mv "$RUNS/$holder.run.tmp" "$RUNS/$holder.run"

count_check() {  # LABEL OUTPUT
  local what="$1" out="$2" r
  r="$(row spent-budget "$out")"
  case "$r" in *'no progress last iter (2/2)'*) ;; *) fail "$what: the no-progress counter is not in words with its budget: $r" ;; esac
  case "$r" in *'⚠'*|*stalled*) fail "$what: a ticking run with a spent stall budget was flagged at-risk: $r" ;; esac
  r="$(row early-stall "$out")"
  case "$r" in *'no progress last iter (1/5)'*) ;; *) fail "$what: the counter lost its own budget: $r" ;; esac
  # An older engine's record carries the count and no budget — it must still render,
  # and must not invent a limit it was never told.
  r="$(row old-record "$out")"
  case "$r" in *'no progress last iter (2)'*) ;; *) fail "$what: a record with no stall_limit stopped rendering the count: $r" ;; esac
  case "$r" in *'(2/0)'*) fail "$what: an absent budget was rendered as a limit of 0: $r" ;; esac
  # And the two findings TOGETHER on one row, in two sentences that cannot be confused:
  # the last iteration advanced nothing AND this run has gone silent past its limit.
  r="$(row really-quiet "$out")"
  case "$r" in *'no progress last iter (1/2)'*) ;; *) fail "$what: the quiet row lost its counter: $r" ;; esac
  case "$r" in *'⚠ stalled in provider-waiting'*) ;; *) fail "$what: the quiet row lost the at-risk flag: $r" ;; esac
  # The old phrasing is what made them one finding — it must be gone from both views.
  case "$out" in *'· stall '*) fail "$what: the bare 'stall N' phrasing is back: $out" ;; esac
}

cnt_out="$(CHIEF_RUNS="$RUNS" bash "$ROOT/bin/chief" ps)" || fail "chief ps (part 7) exited non-zero"
echo "--- chief ps (spent budget · early · no-budget · quiet-and-counting) ---"; printf '%s\n' "$cnt_out"
count_check "chief ps" "$cnt_out"

cnt_log="$WORK/monitor3.out"
CHIEF_RUNS="$RUNS" bash "$ROOT/bin/chief" monitor 1 > "$cnt_log" 2>&1 &
cnt_pid=$!
for _ in $(seq 1 50); do
  [ "$(grep -A1 'really-quiet' "$cnt_log" 2>/dev/null | wc -l | tr -d ' ')" -ge 2 ] && break
  sleep 0.2
done
kill "$cnt_pid" 2>/dev/null || true; wait "$cnt_pid" 2>/dev/null || true
grep -q 'really-quiet' "$cnt_log" || fail "chief monitor never rendered a part-7 frame"
count_check "chief monitor" "$(tr -d '\033' < "$cnt_log")"

# ══ PART 8 — THE PHASE IS A STATEMENT ABOUT NOW ══════════════════════════════
# agent.sh sets phase=stalled at an iteration boundary that advanced neither a passing
# story nor HEAD. The COUNT is right there and is the budget mechanism. The PHASE is
# the claim that goes stale: it used to persist through everything that happens next,
# and what happens next is the ITERATION-BOUNDARY HOOK — the driver re-integrating a
# base that sibling merges keep moving, which fetches, rebases and queues behind a
# merge lock another worker can hold for the length of a verify gate. Measured
# 2026-08-17: tasklist 99 read `stalled` for ~25 minutes of exactly that while it was
# re-engaging, fixing a ratchet regression and merging; 98 read it with a 2-second
# heartbeat. Both were working.
#
# The loop is driven for real (a fake provider on PATH, no driver, no install) through
# two consecutive no-progress iterations, and three witnesses are collected: the phase
# each TURN ran under, the phase the HOOK ran under, and a polled transcript of every
# value the record held, in order.
echo "stall-flag: part 8 — two no-progress iterations"
command -v git >/dev/null || fail "git required"
command -v jq  >/dev/null || fail "jq required"
export GIT_AUTHOR_NAME=sf GIT_AUTHOR_EMAIL=sf@test GIT_COMMITTER_NAME=sf GIT_COMMITTER_EMAIL=sf@test

AG="$WORK/agentrepo"; OBS="$WORK/obs"; AGLIVE="$WORK/agent.live.json"
mkdir -p "$AG/.chief/state" "$OBS" "$WORK/agentbin"
git init -q -b main "$AG" 2>/dev/null || { git init -q "$AG"; git -C "$AG" checkout -q -b main; }
git -C "$AG" commit -q --allow-empty -m init
cat > "$AG/.chief/state/prd.json" <<'JSON'
{"branchName":"chief/sf","userStories":[{"id":"US-1","title":"never lands","description":"","acceptanceCriteria":[],"passes":false,"notes":""}]}
JSON
printf '# Chief Progress Log\n' > "$AG/.chief/state/progress.txt"
printf 'stall-flag agent context\n' > "$AG/agent-context.md"
git -C "$AG" add -A && git -C "$AG" commit -q -m scaffold

# The provider does NOTHING — no commit, no pass flip. That IS a no-progress
# iteration, and it records the phase it was running under.
cat > "$WORK/agentbin/claude" <<FAKE
#!/usr/bin/env bash
set -eu
cat >/dev/null
. "$ROOT/engine/live.sh"
printf '%s\n' "\$(live_get "$AGLIVE" phase)" >> "$OBS/turn.phases"
exit 0
FAKE
chmod +x "$WORK/agentbin/claude"
# The hook stands in for driver.sh --integrate-base: it records the phase IT runs
# under and takes a second, so the sample is a fact and not a race.
cat > "$WORK/hook.sh" <<HOOK
#!/usr/bin/env bash
. "$ROOT/engine/live.sh"
printf '%s\n' "\$(live_get "$AGLIVE" phase)" >> "$OBS/hook.phases"
sleep 1
HOOK
chmod +x "$WORK/hook.sh"

# The transcript: every phase the record holds, in order, deduped.
( prev=""
  while :; do
    cur="$(live_get "$AGLIVE" phase)"
    if [ -n "$cur" ] && [ "$cur" != "$prev" ]; then printf '%s\n' "$cur" >> "$OBS/transcript"; prev="$cur"; fi
    sleep 0.05
  done ) & poller=$!

agent_rc=0
( cd "$AG" && env -u CHIEF_PRESET -u CHIEF_TOOL -u CHIEF_VERBOSE -u CHIEF_TASKLIST \
    CHIEF_PROVIDER=claude CHIEF_PROJECT="$AG" CHIEF_HOME="$ROOT/engine" \
    CHIEF_STATE_DIR=.chief/state CHIEF_AGENT_CONTEXT=agent-context.md \
    CHIEF_LIVE_FILE="$AGLIVE" CHIEF_ITER_HOOK="bash $WORK/hook.sh" STALL_LIMIT=2 \
    PATH="$WORK/agentbin:$PATH" bash "$ROOT/engine/agent.sh" 2 ) > "$WORK/agent.log" 2>&1 || agent_rc=$?
kill "$poller" 2>/dev/null || true; wait "$poller" 2>/dev/null || true; poller=""

# 8a) THE BUDGET IS UNTOUCHED. Legibility must not be bought with a budget leak: two
#     no-progress iterations in a row still end the run, at the same iteration.
[ "$agent_rc" = 1 ] || { tail -20 "$WORK/agent.log" >&2; fail "two stalled iterations no longer stop the run (agent.sh exited $agent_rc, want 1)"; }
grep -q 'Chief stalled 2 iterations' "$WORK/agent.log" || { tail -20 "$WORK/agent.log" >&2; fail "the give-up line does not report 2 counted stalls"; }
[ "$(live_get "$AGLIVE" stall)" = 2 ] || fail "the stall count did not persist across the boundary (record says '$(live_get "$AGLIVE" stall)')"
[ "$(live_get "$AGLIVE" stall_limit)" = 2 ] || fail "the record does not carry the budget the count is measured against"
[ "$(live_get "$AGLIVE" iter)" = 2 ] || fail "the run did not spend exactly 2 iterations (iter=$(live_get "$AGLIVE" iter))"
# It gave up BECAUSE it stalled — the one place the word is a statement about now.
[ "$(live_get "$AGLIVE" phase)" = stalled ] || fail "the terminal record should read stalled, got '$(live_get "$AGLIVE" phase)'"

# 8b) NO TURN RAN UNDER THE PREVIOUS ITERATION'S VERDICT.
[ "$(grep -c . "$OBS/turn.phases")" = 2 ] || { cat "$OBS/turn.phases" >&2; fail "expected exactly 2 provider turns"; }
while read -r ph; do
  [ "$ph" = provider-waiting ] || fail "a turn ran under phase '$ph' — a turn that has begun is not the last one's verdict"
done < "$OBS/turn.phases"

# 8c) THE BOUNDARY HOOK IS WORK, AND SAYS SO. This is the 25 minutes of 2026-08-17:
#     before the fix both samples read `stalled`.
[ "$(grep -c . "$OBS/hook.phases")" = 2 ] || { cat "$OBS/hook.phases" >&2; fail "expected the iteration-boundary hook to run twice"; }
while read -r ph; do
  [ "$ph" = integrating ] || fail "the iteration-boundary hook ran under phase '$ph' — it is re-integrating the base, not stalling"
done < "$OBS/hook.phases"

# 8d) …and `stalled` is still published BETWEEN the iterations — this is a phase that
#     expires, not a phase that was deleted.
grep -qx 'stalled' "$OBS/transcript" || { cat "$OBS/transcript" >&2; fail "the no-progress boundary no longer publishes 'stalled' at all"; }
# Nothing that RUNS may follow it directly: what the record says after a stalled
# boundary is the work that boundary handed off to.
awk 'p=="stalled" && ($0=="provider-waiting" || $0=="writing") {found=1} {p=$0} END{exit !found}' \
  "$OBS/transcript" && { cat "$OBS/transcript" >&2; fail "a turn ran with 'stalled' still on the record"; }
# The whole boundary, in order and in one line: the iteration ends, chief says so,
# the hook does the work that ending handed it, and the next TURN is a turn — the
# record reads `agent-turn` while it runs, and `stalled` only between them.
case " $(tr '\n' ' ' < "$OBS/transcript")" in
  *' stalled integrating agent-turn provider-waiting '*) ;;
  *) cat "$OBS/transcript" >&2; fail "the boundary does not read stalled → integrating → agent-turn → the next turn" ;;
esac
echo "   ok  transcript: $(tr '\n' ' ' < "$OBS/transcript")"

# 8e) THE FIRST WRITE OF AN ITERATION IS WHAT MOVES OFF IT. In this harness the window
#     between the iteration counter and the turn is milliseconds wide; in the field it
#     holds the research re-read, the plan-review gate and the prompt compose, and a
#     loop that publishes late displays the previous boundary's verdict for all of it.
#     That window is not reliably samplable from outside, so it is asserted on the
#     source: the first live_set after `i=$((i+1))` names the turn, not the verdict.
#     LC_ALL=C — agent.sh's comments are full of em-dashes and BSD awk aborts on a
#     multi-byte character in a UTF-8 locale.
first_write="$(LC_ALL=C awk '/i=\$\(\(i\+1\)\)/{seen=1} seen && /live_set "\$LIVE" phase=/{print; exit}' "$ROOT/engine/agent.sh")"
case "$first_write" in
  *'phase=agent-turn'*) ;;
  *) fail "an iteration's FIRST live_set must move the phase off the last boundary's verdict, got: ${first_write:-<none>}" ;;
esac

# ══ PART 9 — RE-ENGAGEMENT ANNOUNCES ITSELF ══════════════════════════════════
# The driver's `persisted for re-engagement` path: a branch whose stories all pass but
# whose verify failed post-rebase is picked back up and the agent sent in to fix it.
# The pickup rebuilds the worktree and re-integrates the base before the first turn —
# minutes — and it is not a fresh start, so it must not read as one. Two surfaces: the
# live phase while it happens, and an event that outlives it, because "why did this
# branch run again?" is a question asked afterwards.
echo "stall-flag: part 9 — a re-engaged branch says so"
DR="$WORK/reengage"; mkdir -p "$DR" "$WORK/drvbin" "$WORK/drvruns"
cat > "$WORK/drvbin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null
PRD=".chief/state/prd.json"                       # cwd = the worktree
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"; TRACKED="tasks/chief/$name.json"
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  mkdir -p out; echo "impl $id" > "out/$id.txt"
  for f in "$PRD" "$TRACKED"; do
    [ -f "$f" ] || continue
    t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id).passes)=true' "$f" > "$t" && mv "$t" "$f"
  done
else
  mkdir -p out; echo "fixed what verify rejected" > out/fix.txt   # the re-engaged turn
fi
git add -A >/dev/null 2>&1 || true; git commit -q -m "feat: scripted" >/dev/null 2>&1 || true
[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/drvbin/claude"

git init -q -b main "$DR" 2>/dev/null || { git init -q "$DR"; git -C "$DR" checkout -q -b main; }
git -C "$DR" commit -q --allow-empty -m init
( cd "$DR" && bash "$ROOT/bin/chief" init >/dev/null && rm -f tasks/chief/example.json ) \
  || fail "chief init failed"
cat > "$DR/tasks/chief/re.json" <<'JSON'
{ "project":"re","branchName":"chief/re","description":"re-engagement",
  "iters":2,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":["out/US-1.txt exists"],"passes":false,"notes":"created out/US-1.txt"}] }
JSON
printf '#!/usr/bin/env bash\nset -eu\nexit "${SF_VERIFY_RC:-0}"\n' > "$DR/.chief/verify.sh"
chmod +x "$DR/.chief/verify.sh"
git -C "$DR" add -A && git -C "$DR" commit -q -m "re setup"

drv() {  # VERIFY-RC LOG — one hermetic run of the driver, straight from this checkout
  ( cd "$DR" && SF_VERIFY_RC="$1" RETRY_MAX=1 CHIEF_RUNS="$WORK/drvruns" \
      CHIEF_REPOS="$WORK/drvrepos" CHIEF_WORKTREE_ROOT="$WORK/drvwt" \
      PATH="$WORK/drvbin:$PATH" bash "$ROOT/bin/chief" run ) > "$2" 2>&1 || true
}
events() { cat "$WORK/drvruns"/*.events.jsonl 2>/dev/null || true; }

drv 1 "$WORK/re1.log"
case "$(cat "$DR/.chief/state/parallel/re.status" 2>/dev/null)" in
  VERIFY-FAILED*) ;;
  *) tail -30 "$WORK/re1.log" >&2; fail "the first run did not leave the branch VERIFY-FAILED" ;;
esac
events | jq -e 'select(.event=="tasklist.re-engaged")' >/dev/null 2>&1 \
  && fail "a first, un-re-engaged run announced a re-engagement"

drv 0 "$WORK/re2.log"
# The worker's own log, not the run's stdout: run_worker redirects everything it says
# into $STATE/parallel/<name>.log, and the run summary is all that reaches the console.
grep -q 're-engaging the agent to fix it' "$DR/.chief/state/parallel/re.log" \
  || { tail -30 "$DR/.chief/state/parallel/re.log" >&2; fail "the second run did not re-engage the VERIFY-FAILED branch"; }
ev="$(events | jq -c 'select(.event=="tasklist.re-engaged")' | tail -1)"
[ -n "$ev" ] || { events | tail -20 >&2; fail "the re-engagement was never published to the event stream"; }
[ "$(printf '%s' "$ev" | jq -r '.name')"  = re      ] || fail "the re-engaged event names the wrong tasklist: $ev"
[ "$(printf '%s' "$ev" | jq -r '.state')" = running ] || fail "a re-engagement is a running tasklist, not a terminal state: $ev"
case "$(printf '%s' "$ev" | jq -r '.detail')" in
  *verify*) ;;
  *) fail "the re-engaged event does not say WHY the branch was picked back up: $ev" ;;
esac
echo "   ok  re-engaged: $(printf '%s' "$ev" | jq -r '.detail')"

echo "stall-flag: OK — per-phase thresholds, a flag that names the state, gone ≠ quiet, elapsed-in-phase in every arm, the counter told apart from the flag, a phase that is about NOW, and a re-engagement that announces itself"
