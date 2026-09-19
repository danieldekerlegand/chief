#!/usr/bin/env bash
# test/host-isolation.sh — WHAT A FIXTURE RUN MAY NOT READ OFF THE HOST.
#
# The guard for test/lib.sh. Its subject is not the scheduler — the load ceiling is
# correct, and engine/concurrency.sh is asserted in full by test/load-admission.sh —
# but the SUITE: whether a fixture run can be made to sit and wait on a number that
# belongs to the machine rather than to the fixture.
#
# WHY IT IS A REAL RUN AND NOT A PREDICATE CALL. "chief_machine_load_allows returned
# 0" and "the run launched with nobody asked" are different claims, and only the
# second is the property. The measured incident (2026-09-18, six hours inside
# test/suspectlimit.sh) happened through the driver's launch loop, so that is where
# it is pinned — one `chief run -p 2`, one grep of the log it wrote.
#
# TWO PARTS, and PART B is the whole reason PART A means anything. "The log contains
# no `machine budget hold`" is a sentence that also passes when nothing could ever
# have held: the load rule only defers to the machine while CHIEF ITSELF has a gate
# in flight (the bound in chief_machine_load_allows), so a fixture with no gate live
# is admitted whatever the number says, and an assertion written against that state
# would pass on the unfixed engine too. So both parts stage the same live gate, both
# report the same synthetic load of 62 — the incident host's reading, rounded up —
# and the ONLY difference between them is the one line test/lib.sh writes:
#
#   PART A   CHIEF_MACHINE_LOAD_LIMIT unset  -> lib.sh's `off`  -> runs, merges
#   PART B   CHIEF_MACHINE_LOAD_LIMIT=4      -> the host's rule -> HOLDS, by name
#
# PART B is therefore the mutation check, performed by configuration rather than by
# neutering a function in a copy of the engine: it restores the pre-lib.sh behaviour
# exactly and shows this file failing PART A's assertion against it.
#
# PART D is the SECOND host input, and it is built the same way. The worktree root
# resolves CHIEF_WORKTREE_ROOT -> $CHIEF_PREFIX/worktrees -> $HOME/.chief/worktrees,
# twenty-seven scripts pinned neither end of that chain, and the startup sweep walks
# whatever it lands on — so a hermetic fixture was enumerating the operator's real
# worktrees and printing a keep-or-reclaim verdict about each one. Its two halves
# differ in exactly the same one thing:
#
#   PART D   the suite's own prefix  -> every `>> startup:` line is inside the test
#   PART E   $CHIEF_PREFIX unset,    -> the same fixture walks the decoy home and
#            $HOME = a decoy tree       names it, so PART D's check is not vacuous
#
# Both halves PLANT a worktree in the root the run will walk, because "no line fell
# outside" also passes when no line was printed at all: an empty root produces a
# summary and nothing else. The decoy is a temp tree of this test's own — the control
# for "a fixture reads the real ~/.chief" may not itself read the real ~/.chief.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; . "$ROOT/test/lib.sh"
WORK="$(mktemp -d)"
drv=""; drvpg=""
HOSTDECOY=""
# STOP THE TREE, NOT THE SHIM — and wait for it to be gone before removing anything.
# `kill "$drv"` ends the subshell that started the run; the driver re-execs itself and
# its workers are not its children in any way `wait` can see, so they went on writing
# `runs/<pid>.ledger` and `repo-b/.chief/state` INTO $WORK while the EXIT trap's
# `rm -rf` was walking it. Measured: three $TMPDIR trees left by this file on one host,
# each holding exactly the files a still-live descendant recreated after rm had passed.
# So the run is launched with `set -m`, into a group of its own, and stopped by group.
stop_run() {
  [ -n "$drv" ] || return 0
  [ -z "$drvpg" ] || kill -TERM -"$drvpg" 2>/dev/null || true
  kill "$drv" 2>/dev/null || true
  wait "$drv" 2>/dev/null || true
  local i=0
  while [ -n "$drvpg" ] && [ "$i" -lt 60 ] && kill -0 -"$drvpg" 2>/dev/null; do sleep 0.25; i=$((i+1)); done
  drv=""; drvpg=""
}
cleanup() { stop_run; rm -rf "$WORK" ${HOSTDECOY:+"$HOSTDECOY"}; }
trap 'rc=$?; cleanup; exit "$rc"' EXIT
# Hermetic in ENV as well as in state — this suite may itself be running inside a
# chief worktree whose driver exported a pause file (test/suspectlimit.sh's note).
unset CHIEF_PAUSE_FILE
export GIT_AUTHOR_NAME=hi GIT_AUTHOR_EMAIL=hi@test GIT_COMMITTER_NAME=hi GIT_COMMITTER_EMAIL=hi@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"   # hermetic: don't touch ~/.chief
fail() { echo "HOST-ISOLATION FAIL: $*" >&2; [ -f "$WORK/$LOG" ] && tail -40 "$WORK/$LOG" >&2; exit 1; }
LOG=a.log
command -v jq >/dev/null || fail "jq required"

# ── a gate of CHIEF'S OWN, live for the whole file ────────────────────────────
# Without one the load rule's bound admits everything and neither part discriminates.
# THIS shell is the pid: a registry record is only as live as the process behind it.
mkdir -p "$WORK/runs" "$WORK/decoy/parallel"
cat > "$WORK/runs/decoy.run" <<REC
pid=$$
state=$WORK/decoy
names=decoy
REC
# Written by live_set and never by hand: live_get is a LINE-WISE reader, so a record
# dumped as compact JSON is valid, parses, and reads back EMPTY for every field —
# the gate would not be counted and this fixture would quietly assert nothing.
# shellcheck source=engine/live.sh
. "$ROOT/engine/live.sh"
live_set "$WORK/decoy/parallel/decoy.live.json" name=decoy state=running phase=verifying
[ -s "$WORK/decoy/parallel/decoy.live.json" ] || fail "setup: the decoy gate record was not written"

# ── install chief from this checkout ──────────────────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# ── fake `claude`: implement the one story, commit it, report COMPLETE ────────
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null
mkdir -p out && echo done > out/US-1.txt
t="$(mktemp)"; jq '.userStories |= map(.passes=true | .notes="fixture: green")' \
  .chief/state/prd.json > "$t" && mv "$t" .chief/state/prd.json
name="$(jq -r '.branchName' .chief/state/prd.json | sed 's#^chief/##')"
t="$(mktemp)"; jq '.userStories |= map(.passes=true | .notes="fixture: green")' \
  "tasks/chief/$name.json" > "$t" && mv "$t" "tasks/chief/$name.json"
git add -A >/dev/null 2>&1 && git commit -q -m "feat: [US-1] - one" >/dev/null 2>&1 || true
echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── two repos, one per part: PART A merges its work, so PART B needs its own ──
scaffold() {   # <dir>
  local repo="$1"
  mkdir -p "$repo"; ( cd "$repo"
    git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
    git commit -q --allow-empty -m init
    "$CHIEF" init >/dev/null
    rm -f tasks/chief/example.json
    local n
    for n in one two; do
      cat > "tasks/chief/$n.json" <<JSON
{ "project":"hi","branchName":"chief/$n","description":"host isolation $n",
  "iters":2,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":["out/US-1.txt exists"],"passes":false,"notes":""}] }
JSON
    done
    printf '#!/usr/bin/env bash\nset -eu\necho "verify: (would pass)"\nexit 0\n' > .chief/verify.sh
    chmod +x .chief/verify.sh
    git add -A && git commit -q -m "host-isolation setup" )
}

# Both budgets that count chief's OWN records are set wide, in BOTH parts. The decoy
# gate would otherwise trip the gate budget (default 2, or 1 on a single-core runner)
# and PART B could pass on a hold that names the wrong resource entirely.
export CHIEF_MACHINE_BUDGET=8 CHIEF_MACHINE_GATE_BUDGET=8
# The load the host is reported to be under, in both parts: 4.4x oversubscribed on
# the incident's 14 cores, and over any ceiling a real machine would resolve to.
export CHIEF_LOAD_AVERAGE=62

# ══ PART A — the suite's default: the number is not consulted ════════════════
echo "host-isolation: part A — a fixture run under a reported load of 62"
scaffold "$WORK/repo-a"
LOG=a.log
( cd "$WORK/repo-a" && PATH="$WORK/fakebin:$PATH" "$CHIEF" run -p 2 ) >"$WORK/a.log" 2>&1 \
  || { cat "$WORK/a.log"; fail "A: run exited non-zero"; }

if grep -q 'machine budget hold' "$WORK/a.log"; then
  fail "A: a fixture run held on the host's capacity — $(grep -m1 'machine budget hold' "$WORK/a.log")"
fi
if grep -q 'HOLD .*machine load' "$WORK/a.log"; then
  fail "A: a fixture GATE held on the host's load — $(grep -m1 'HOLD .*machine load' "$WORK/a.log")"
fi
# ...and it did the work, so "no hold" is not "no run".
for n in one two; do
  [ -f "$WORK/repo-a/tasks/chief/completed/$n.json" ] || fail "A: $n did not merge (no completed record)"
done
( cd "$WORK/repo-a" && git checkout -q main && [ -f out/US-1.txt ] ) || fail "A: the merged work is not on main"
echo "host-isolation:   both tasklists merged, no hold logged"

# ══ PART B — the same run with the host's rule restored ══════════════════════
# The mutation check. If this part does NOT hold, PART A's grep is vacuous and this
# file is asserting nothing — so a missing hold here is a FAILURE OF THE TEST.
echo "host-isolation: part B — the same fixture with CHIEF_MACHINE_LOAD_LIMIT=4 (the pre-lib.sh reading)"
scaffold "$WORK/repo-b"
LOG=b.log
set -m
( cd "$WORK/repo-b" && PATH="$WORK/fakebin:$PATH" CHIEF_MACHINE_LOAD_LIMIT=4 "$CHIEF" run -p 2 ) \
  >"$WORK/b.log" 2>&1 &
drv=$!
set +m
drvpg="$(ps -o pgid= -p "$drv" 2>/dev/null | tr -d ' ')"
[ -n "$drvpg" ] && [ "$drvpg" != "$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')" ] \
  || fail "B: the run shares this shell's process group (pgid '$drvpg') — refusing to signal it"
# Bounded by a POLL, never by a fixed sleep: the hold is the first thing the launch
# loop does, so this normally returns in well under a second, and the ceiling is only
# here so a fix that removes the hold entirely fails rather than hangs.
held=0
for _ in $(seq 1 120); do
  grep -q 'machine budget hold' "$WORK/b.log" 2>/dev/null && { held=1; break; }
  kill -0 "$drv" 2>/dev/null || break
  sleep 1
done
stop_run
[ "$held" = 1 ] || fail "B: the host's load ceiling did NOT hold this run — PART A proves nothing"
grep -q 'machine budget hold — machine load: load average 62 over 4 core(s)' "$WORK/b.log" \
  || fail "B: held, but not on the load: $(grep -m1 'machine budget hold' "$WORK/b.log")"
[ ! -f "$WORK/repo-b/tasks/chief/completed/one.json" ] \
  || fail "B: the run got past the hold — the control is not controlling"
echo "host-isolation:   the same fixture holds, by name, when the host's rule is restored"

# ══ PART C — the default is a DEFAULT, not an override ═══════════════════════
# PART B took its ceiling from the command line. This asserts the same of the
# environment the test itself inherits, because that is the shape an operator and
# test/load-admission.sh both use, and a helper that clobbered it would silently
# disarm the five tests whose subject IS the ceiling.
out="$(CHIEF_MACHINE_LOAD_LIMIT=4 bash -c '. "$1/test/lib.sh"; printf %s "$CHIEF_MACHINE_LOAD_LIMIT"' _ "$ROOT")"
[ "$out" = 4 ] || fail "C: lib.sh overrode an explicit request (got '$out', want 4)"
out="$(env -u CHIEF_MACHINE_LOAD_LIMIT bash -c '. "$1/test/lib.sh"; printf %s "$CHIEF_MACHINE_LOAD_LIMIT"' _ "$ROOT")"
[ "$out" = off ] || fail "C: lib.sh did not disable the ceiling in the silence (got '$out')"
echo "host-isolation:   an explicit ceiling survives lib.sh; silence resolves to off"

# ══ PART D — the startup sweep walks a tree this test owns ═══════════════════
# The suite's default prefix, unmodified: the run resolves its own worktree root and
# the sweep's verdicts are about directories nobody else has a stake in.
echo "host-isolation: part D — the startup sweep under the suite's own prefix"

# A worktree-shaped directory at <root>/<repo>/<wt>, which is the only depth the
# sweep's path verdict accepts. Without one the sweep prints its summary and no
# `>> startup:` line at all, and the check below would pass on silence.
plant_stale() { mkdir -p "$1/worktrees/sibling-12345678/tl-x"; : > "$1/worktrees/sibling-12345678/tl-x/marker"; }

# The check itself, and the only copy of it: a `>> startup:` line always carries the
# path it judged, and every path the sweep can judge is under the root it walked, so
# "inside" is a substring test against the two temp trees this test owns. Prints the
# offenders and returns non-zero when there are any; PART E asserts that it does.
startup_outside() {   # <log> <allowed>…
  local log="$1"; shift
  local out root
  out="$(grep '^>> startup:' "$log" 2>/dev/null || true)"
  # Emptiness is checked BEFORE each filter and not only after the loop: `printf` of
  # an empty string is still one blank line, and a blank line contains no root, so a
  # filter applied to nothing hands back a line and this reports a violation that was
  # never in the log.
  for root in "$@"; do
    [ -n "$out" ] || return 1
    out="$(printf '%s\n' "$out" | grep -v -F "$root" || true)"
  done
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"; return 0
}
startup_count() { grep -c '^>> startup:' "$1" 2>/dev/null || true; }

[ "$CHIEF_PREFIX" != "${HOME:-}/.chief" ] \
  || fail "D: the suite is still running on the operator's own prefix ($CHIEF_PREFIX)"
plant_stale "$CHIEF_PREFIX"
scaffold "$WORK/repo-d"
LOG=d.log
( cd "$WORK/repo-d" && PATH="$WORK/fakebin:$PATH" "$CHIEF" run -p 2 ) >"$WORK/d.log" 2>&1 \
  || { cat "$WORK/d.log"; fail "D: run exited non-zero"; }
n="$(startup_count "$WORK/d.log")"
[ "${n:-0}" -ge 1 ] || fail "D: the startup sweep judged nothing — the plant did not take, so this proves nothing"
if out="$(startup_outside "$WORK/d.log" "$WORK" "$CHIEF_PREFIX")"; then
  fail "D: a fixture run's startup sweep walked outside this test's temp trees:
$out"
fi
echo "host-isolation:   $n startup verdict(s), all inside this test's own trees"

# ══ PART E — the same fixture with the prefix taken away ═════════════════════
# The mutation check, by configuration again: unset the prefix and the chain falls
# through to $HOME/.chief/worktrees, which is precisely what twenty-seven scripts
# were doing. $HOME is a decoy tree OUTSIDE $WORK so that the check above has
# something to catch and the real ~/.chief is never touched.
echo "host-isolation: part E — the same fixture with \$CHIEF_PREFIX unset (the pre-lib.sh reading)"
HOSTDECOY="$(mktemp -d)"
mkdir -p "$HOSTDECOY/.chief"
plant_stale "$HOSTDECOY/.chief"
scaffold "$WORK/repo-e"
LOG=e.log
( cd "$WORK/repo-e" && PATH="$WORK/fakebin:$PATH" \
    env -u CHIEF_PREFIX -u CHIEF_TEST_PREFIX HOME="$HOSTDECOY" "$CHIEF" run -p 2 ) >"$WORK/e.log" 2>&1 \
  || { cat "$WORK/e.log"; fail "E: run exited non-zero"; }
out="$(startup_outside "$WORK/e.log" "$WORK" "$CHIEF_PREFIX")" \
  || fail "E: the sweep stayed inside this test's trees with no prefix set — PART D proves nothing"
case "$out" in *"$HOSTDECOY"*) ;; *) fail "E: the sweep went outside, but not to the decoy home:
$out" ;; esac
echo "host-isolation:   with no prefix the same fixture walks \$HOME/.chief/worktrees, and PART D's check names it"

echo "HOST-ISOLATION PASS — a fixture run ignores the host's load average and walks only its own worktree root"
