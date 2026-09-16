#!/usr/bin/env bash
# test/suspectlimit.sh — A LIMIT NO PATTERN RECOGNISED IS REPORTED AS A SUSPECTED
# LIMIT, NOT AS A STALL.
#
# The defect, reported by an operator 2026-09-15: a tasklist stopped because the
# provider account was out of usage, and neither `chief ps` nor `chief monitor` said
# that was what happened. Both of agent.sh's acting patterns were written against the
# Claude Code CLI's own wordings (docs/guides/providers.md, Usage-limit detection),
# four of the five providers in the roster have never been verified against them, and
# the doc already states the consequence in its own words: an unmatched limit is
# demoted to a no-progress iteration, so the loop burns its budget and exits 1 as a
# stall — indistinguishable, to the driver, from a genuinely failed tasklist.
#
# TWO PARTS, because the claim has two halves and only one of them is cheap.
#
#   PART A — CLASSIFICATION, through the REAL parallel driver with a fake provider on
#            PATH whose behaviour is keyed by branch name (test/limitstate.sh's
#            shape). FOUR tasklists, and half of them are the controls that make the
#            other half mean something:
#              known-limit     a phrasing the patterns DO match  -> rate-limited, unchanged
#              unknown-limit   a limit-shaped line they do not, non-zero exit, no
#                              commits                           -> SUSPECTED-LIMIT
#              noise-stall     ordinary prose, ALSO non-zero, no commits -> ordinary stall
#              wrote-about-it  prose ABOUT a spent quota, exit ZERO      -> ordinary stall
#            The last two are the sabotage controls. Without noise-stall, "report every
#            stall as a suspected limit" passes; without wrote-about-it, "report any
#            output that says `quota`" does.
#
#   PART B — THE RENDER, against a staged state directory and a synthetic run
#            registry: no driver, no agent, no git, so the assertion is about the
#            RENDERER. `chief ps` and `chief monitor` are asserted SEPARATELY — one is
#            `monitor.sh once` and the other `watch`, and a fix that lands in one is
#            not a fix — and a plain failed row is rendered beside it, because "the
#            suspect row says limit?" is worthless if every failed row does.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
holder=""; mon_pid=""
cleanup() {
  for p in $holder $mon_pid; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap 'rc=$?; cleanup; exit "$rc"' EXIT
# HERMETIC IN STATE IS NOT HERMETIC IN ENV: this suite may itself be running inside a
# chief worktree whose driver exported CHIEF_PAUSE_FILE, and agent.sh drains on it at
# the top of its loop — every turn below would exit 3 before the provider ever ran.
unset CHIEF_PAUSE_FILE
export GIT_AUTHOR_NAME=sl GIT_AUTHOR_EMAIL=sl@test GIT_COMMITTER_NAME=sl GIT_COMMITTER_EMAIL=sl@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"   # hermetic: don't touch ~/.chief
fail() { echo "SUSPECTLIMIT FAIL: $*" >&2; [ -f "$WORK/run.log" ] && tail -60 "$WORK/run.log" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

# ══ PART A — CLASSIFICATION ══════════════════════════════════════════════════
echo "suspectlimit: part A — four stops, four verdicts, through the real driver"

PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# The fake provider. None of these commits anything, so the ONLY differences are the
# exit status and the words — which is exactly the surface _suspected_limit reads.
#
# `unknown-limit`'s line is a real shape and deliberately NOT a Claude one: no "usage
# limit", no "429", no "rate limit", no envelope and no status code, so it matches
# neither acting pattern AND is not a _is_no_turn refusal either. If a future widening
# of RATE_LIMIT_PATTERN starts matching it, this test goes red at the `known` end
# rather than silently passing — the SUSPECTED assertion below would fail first.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null
name="$(jq -r '.branchName' .chief/state/prd.json | sed 's#^chief/##')"
case "$name" in
  known-limit)
    echo "Claude AI usage limit reached|1795000000"; exit 0 ;;
  unknown-limit)
    echo "Error: your workspace has used all of its included usage for this billing period."
    echo "Add credits at the console to continue."
    exit 1 ;;
  noise-stall)
    echo "I read the code and opened three files, but could not finish this story yet."
    exit 1 ;;
  *)
    echo "This story asks me to document how a spent quota is reported. I read the docs and wrote nothing."
    exit 0 ;;
esac
FAKE
chmod +x "$WORK/fakebin/claude"

REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null
rm -f tasks/chief/example.json
mk() {
  cat > "tasks/chief/$1.json" <<JSON
{ "project":"sl","branchName":"chief/$1","description":"suspected-limit $1",
  "iters":1,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":["out/US-1.txt"],"passes":false,"notes":""}] }
JSON
}
for n in known-limit unknown-limit noise-stall wrote-about-it; do mk "$n"; done
printf '#!/usr/bin/env bash\nset -eu\necho "verify: (would pass)"\nexit 0\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "suspectlimit setup"

# RATE_LIMIT_RETRY=0 + RATE_LIMIT_REDISPATCH_MAX=0 pin this on CLASSIFICATION only:
# neither the worker nor the scheduler waits out the fixture's reset epoch.
PATH="$WORK/fakebin:$PATH" RATE_LIMIT_RETRY=0 STALL_LIMIT=1 RATE_LIMIT_REDISPATCH_MAX=0 \
  "$CHIEF" run -p 4 >"$WORK/run.log" 2>&1 || { cat "$WORK/run.log"; fail "run exited non-zero"; }

S="$REPO/.chief/state/parallel"
state()  { cat "$S/$1.state"  2>/dev/null || echo MISSING; }
status() { cat "$S/$1.status" 2>/dev/null || echo MISSING; }

# 1) THE RECOGNISED LIMIT IS UNTOUCHED. This is the no-regression half that matters
#    most: the new arm sits at the same stop, and a pattern hit must still reach the
#    pause path with its reset ETA rather than being re-labelled a suspicion.
case "$(status known-limit)" in
  RATE-LIMITED*) ;;
  *) fail "known-limit status is '$(status known-limit)', want RATE-LIMITED* — a RECOGNISED limit must still take the pause path" ;;
esac
[ "$(state known-limit)" = "rate-limited" ] \
  || fail "known-limit state is '$(state known-limit)', want rate-limited"
[ ! -f "$S/known-limit.suspected-limit" ] \
  || fail "a RECOGNISED limit also wrote a suspicion report — the two paths are exclusive"

# 2) THE UNRECOGNISED ONE IS A SUSPICION, not a stall.
case "$(status unknown-limit)" in
  SUSPECTED-LIMIT*) ;;
  *) fail "unknown-limit status is '$(status unknown-limit)', want SUSPECTED-LIMIT* (it was demoted to a stall)" ;;
esac
[ -s "$S/unknown-limit.suspected-limit" ] || fail "no suspicion report was recorded for unknown-limit"
rpt="$(cat "$S/unknown-limit.suspected-limit")"
case "$rpt" in *'claude'*) ;; *) fail "the report does not name the provider: $rpt" ;; esac
case "$rpt" in *'included usage for this billing period'*) ;; *) fail "the report does not quote the provider's line verbatim: $rpt" ;; esac
case "$rpt" in *'RATE_LIMIT_PATTERN'*) ;; *) fail "the report does not name the pattern that would have to be extended: $rpt" ;; esac
# …and it says it is a SUSPICION, not a verdict. Chief has no rule that recognised
# this line, so it may not claim to know what the line means.
case "$rpt" in *'not a verdict'*) ;; *) fail "the report reads as a verdict rather than a suspicion: $rpt" ;; esac
# NOTHING WAS ACTED ON. The whole discipline: a guess may be reported and may not be
# slept on or re-dispatched. `attempt n/m` is what a re-dispatch writes.
[ ! -f "$S/unknown-limit.retry-at" ] || fail "a SUSPECTED limit armed a retry ETA — it must not act on a guess"
[ ! -f "$S/unknown-limit.attempts" ] || fail "a SUSPECTED limit was re-dispatched — it must not act on a guess"
grep -q 'SUSPECTED USAGE LIMIT' "$WORK/run.log" \
  || fail "the run summary never reports the suspicion"

# 3) SABOTAGE CONTROL ONE — ordinary prose on a NON-ZERO exit with no commits. Every
#    fact the suspicion rests on except the words. It must still be an ordinary stall.
[ "$(state noise-stall)" = "failed" ] || fail "noise-stall state is '$(state noise-stall)', want failed"
case "$(status noise-stall)" in
  SUSPECTED-LIMIT*) fail "ordinary agent prose was reported as a suspected usage limit" ;;
esac
[ ! -f "$S/noise-stall.suspected-limit" ] || fail "ordinary agent prose wrote a suspicion report"

# 4) SABOTAGE CONTROL TWO — prose ABOUT a spent quota, on exit ZERO. The words are
#    limit-shaped and the run is not: a provider that exited 0 produced a turn,
#    whatever its text says, and an agent WRITING about quotas is the false positive
#    this fence exists for.
[ "$(state wrote-about-it)" = "failed" ] || fail "wrote-about-it state is '$(state wrote-about-it)', want failed"
case "$(status wrote-about-it)" in
  SUSPECTED-LIMIT*) fail "an agent that merely WROTE about a quota (exit 0) was reported as a suspected limit" ;;
esac
[ ! -f "$S/wrote-about-it.suspected-limit" ] || fail "an exit-0 turn wrote a suspicion report"

# 5) Nothing merged or retired, and the suspected branch is kept for a resume.
git checkout -q main
for n in known-limit unknown-limit noise-stall wrote-about-it; do
  [ -f "tasks/chief/$n.json" ]             || fail "$n was retired without completing"
  [ ! -f "tasks/chief/completed/$n.json" ] || fail "a completed record was written for $n"
done
git rev-parse --verify --quiet chief/unknown-limit >/dev/null \
  || fail "the suspected-limit branch was not kept for a resume"

# ══ PART B — THE RENDER, in BOTH views ═══════════════════════════════════════
# Staged rather than driven: the claim is about what the renderer does with a record,
# and a live provider would make it about timing instead.
echo "suspectlimit: part B — chief ps and chief monitor, against a staged record"

MSTATE="$WORK/mon"; MPAR="$MSTATE/parallel"; MRUNS="$WORK/mruns"
mkdir -p "$MPAR" "$MRUNS" "$WORK/mrepo" "$WORK/mtasks" "$WORK/mwt"
# shellcheck source=engine/live.sh
. "$ROOT/engine/live.sh"            # the REAL writer, so the fixture cannot drift

sleep 60 & holder=$!                # the monitor prunes run files whose pid is dead

echo failed > "$MPAR/suspect.state"
live_set "$MPAR/suspect.live.json" name=suspect state=failed phase=suspected-limit \
  story=US-2 iter=3 passing=1 total=4 stall=2 stall_limit=2
cp "$S/unknown-limit.suspected-limit" "$MPAR/suspect.suspected-limit"
# The control: a plain failed row. If it also reads `limit?`, the label proves nothing.
echo failed > "$MPAR/plain-fail.state"
live_set "$MPAR/plain-fail.live.json" name=plain-fail state=failed phase=incomplete \
  story=US-1 iter=3 passing=0 total=4

cat > "$MRUNS/$holder.run" <<EOF
pid=$holder
repo=$WORK/mrepo
base=main
parallel=2
tool=claude
automerge=1
limitmax=3
started=$(date +%s)
state=$MSTATE
staterel=.chief/state
tasks=$WORK/mtasks
wt=$WORK/mwt
names=suspect plain-fail
EOF

# ONE WHOLE LINE, not a fragment: the row and the note beneath it, joined. A needle the
# run summary also prints cannot tell the two surfaces apart.
row() { printf '%s\n' "$2" | grep -A1 "$1 " | tr -d '\n'; }
check() {  # LABEL OUTPUT
  local what="$1" out="$2" r
  r="$(row suspect "$out")"
  case "$r" in *'limit?'*) ;; *) fail "$what: the suspected row is not labelled 'limit?': $r" ;; esac
  case "$r" in *'✗'*)  fail "$what: a suspected limit took the FAILURE glyph: $r" ;; esac
  case "$r" in *'suspected usage limit'*) ;; *) fail "$what: the row says nothing about what chief suspects: $r" ;; esac
  case "$r" in *'included usage for this billing period'*) ;; *) fail "$what: the row does not quote the provider's own line: $r" ;; esac
  case "$r" in *"check the account's remaining usage"*) ;; *) fail "$what: the row does not say what the operator should check: $r" ;; esac
  case "$r" in *'neither waited nor re-dispatched'*) ;; *) fail "$what: the row does not say chief acted on nothing: $r" ;; esac
  # THE CONTROL. An ordinary failure must be untouched by all of the above.
  r="$(row plain-fail "$out")"
  case "$r" in *'limit?'*) fail "$what: an ordinary failed row was labelled 'limit?': $r" ;; esac
  case "$r" in *'suspected usage limit'*) fail "$what: an ordinary failed row got the suspicion note: $r" ;; esac
  case "$r" in *' failed '*) ;; *) fail "$what: an ordinary failed row stopped reading 'failed': $r" ;; esac
}

ps_out="$(CHIEF_RUNS="$MRUNS" bash "$ROOT/bin/chief" ps)" || fail "chief ps exited non-zero"
echo "--- chief ps (suspected limit beside a plain failure) ---"; printf '%s\n' "$ps_out"
check "chief ps" "$ps_out"

# `chief monitor` is the same render in a redraw loop: run it, wait for a WHOLE frame
# (the last row's detail line, not just its row), stop.
mon_log="$WORK/monitor.out"
CHIEF_RUNS="$MRUNS" bash "$ROOT/bin/chief" monitor 1 > "$mon_log" 2>&1 &
mon_pid=$!
for _ in $(seq 1 50); do
  [ "$(grep -A1 'plain-fail' "$mon_log" 2>/dev/null | wc -l | tr -d ' ')" -ge 2 ] && break
  sleep 0.2
done
kill "$mon_pid" 2>/dev/null || true; wait "$mon_pid" 2>/dev/null || true; mon_pid=""
grep -q 'suspect' "$mon_log" || fail "chief monitor never rendered a frame"
check "chief monitor" "$(tr -d '\033' < "$mon_log")"

echo "SUSPECTLIMIT PASS — a recognised limit still pauses; an unrecognised one is reported as a SUSPICION in both views; prose and exit-0 turns are still ordinary stalls"
