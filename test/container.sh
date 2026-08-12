#!/usr/bin/env bash
# test/container.sh — the CONTAINER-SHAPED conditions, WITHOUT a container.
#
# An embedded run inside a container (a Riju workspace, a `docker run` against a
# bind-mounted checkout) hits four assumptions a laptop run gets for free, and each
# one of them fails in a way that names neither chief nor the container:
#
#   1. $HOME. Unset or read-only in a minimal image. `${CHIEF_PREFIX:-$HOME/.chief}`
#      under `set -u` is not a fallback — it is `HOME: unbound variable` on the
#      driver's first path line (engine/paths.sh).
#   2. The worktree tree. Must be relocatable off the prefix, because the prefix may
#      be a tmpfs and worktrees need a real filesystem outside the repo.
#   3. git ownership. A bind-mounted repo is owned by the HOST uid; git refuses to
#      parse it at all — "detected dubious ownership" — and every `git -C $REPO`
#      fails identically to "not a repository" (engine/gitenv.sh).
#   4. git identity + PID namespace. No passwd entry means no committer; a shared
#      state prefix means the registry holds pids numbered somewhere else, where
#      every pid-keyed decision (`chief ps` pruning, driver.lock stealing) reads
#      backwards (engine/reap.sh).
#
# All four are reproducible on a laptop, which is why this test exists in this form:
#
#   · no $HOME              → `env -u HOME`, and `bash -u` so an unbound read is fatal
#   · dubious ownership     → GIT_TEST_ASSUME_DIFFERENT_OWNER=1 (git's own hook, no
#                             second uid, no mount, no container)
#   · no committer identity → user.useConfigOnly=true + GIT_CONFIG_GLOBAL/SYSTEM
#                             pointed at /dev/null
#   · a foreign PID namespace → $CHIEF_PID_NS, the documented override, written into
#                             records this process then has to decline to interpret
#
# Hermetic: temp prefix, temp worktree root, a scripted fake `claude` on PATH, and
# $HOME unset for every run under test — it cannot touch the real ~/.chief even by
# accident. Drives bin/chief straight out of this checkout (uncommitted work included).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
PIDS=""
cleanup() {
  local p
  for p in $PIDS; do kill -9 "$p" 2>/dev/null || true; done
  chmod -R u+rwX "$WORK" 2>/dev/null || true      # the read-only-$HOME fixtures
  # Three real runs land three run logs here; CHIEF_TEST_KEEP=1 keeps the tree so a
  # failure can be read rather than re-staged.
  if [ -n "${CHIEF_TEST_KEEP:-}" ]; then echo "container: kept $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT
LOG=""
fail() { echo "CONTAINER FAIL: $*" >&2; [ -n "$LOG" ] && [ -f "$LOG" ] && tail -40 "$LOG" >&2; exit 1; }
note() { echo "container: $*"; }

command -v jq  >/dev/null || fail "jq is required"
command -v git >/dev/null || fail "git is required"
CHIEF="$ROOT/bin/chief"
UID_N="$(id -u)"

# ═════════════════════════════════════════════════════════════════════════════
# 1. THE STATE PREFIX RESOLVES WITH NO $HOME  (engine/paths.sh, as units)
# ═════════════════════════════════════════════════════════════════════════════
#
# Every resolver runs in a `bash -u` subshell with HOME and all four knobs REMOVED
# from the environment, so "it did not crash" is asserted by construction on every
# single case below — an unbound $HOME would exit 1 with no output.
resolve() {   # $1 = resolver fn, rest = env assignments (or -u NAME) for this case
  local fn="$1"; shift
  env -u HOME -u CHIEF_PREFIX -u XDG_STATE_HOME -u CHIEF_WORKTREE_ROOT \
      -u CHIEF_RUNS -u CHIEF_REPOS "$@" \
      bash -uc '. "$1"/engine/paths.sh; "$2"' bash "$ROOT" "$fn"
}
eq() {   # $1 = got  $2 = want  $3 = what
  [ "$1" = "$2" ] || fail "$3: got '$1', want '$2'"
}

# (a) $CHIEF_PREFIX always wins — the knob a container host actually sets — and it
#     wins with no $HOME at all, which is the whole point.
eq "$(resolve chief_prefix "CHIEF_PREFIX=$WORK/explicit")" "$WORK/explicit" \
   "CHIEF_PREFIX ignored with HOME unset"
eq "$(resolve chief_prefix "CHIEF_PREFIX=$WORK/explicit/")" "$WORK/explicit" \
   "CHIEF_PREFIX trailing slash not trimmed"

# (b) no $HOME, no $CHIEF_PREFIX → XDG, then the /tmp floor. Keyed by uid and STABLE,
#     so `chief ps` in a second container shell finds the registry the driver wrote.
mkdir -p "$WORK/xdg"
eq "$(resolve chief_prefix "XDG_STATE_HOME=$WORK/xdg")" "$WORK/xdg/chief" \
   "XDG_STATE_HOME not used as the second fallback"
eq "$(resolve chief_prefix "TMPDIR=$WORK/tmpd")" "$WORK/tmpd/chief-$UID_N" \
   "no HOME and no XDG did not land on the uid-keyed TMPDIR floor"
eq "$(resolve chief_prefix "TMPDIR=$WORK/tmpd")" "$(resolve chief_prefix "TMPDIR=$WORK/tmpd")" \
   "the TMPDIR floor is not stable between two calls"
[ ! -e "$WORK/tmpd" ] || fail "chief_prefix CREATED a directory — the resolvers must be pure"
[ ! -e "$WORK/xdg/chief" ] || fail "chief_prefix created the XDG prefix — the resolvers must be pure"

# (c) a writable $HOME still resolves exactly as it always has (the laptop case must
#     not move), and a READ-ONLY $HOME falls through to somewhere writable instead of
#     failing later, inside git, at `worktree add`.
mkdir -p "$WORK/home"
eq "$(resolve chief_prefix "HOME=$WORK/home")" "$WORK/home/.chief" "a writable HOME no longer resolves to \$HOME/.chief"
if [ "$UID_N" != "0" ]; then
  mkdir -p "$WORK/rohome"; chmod 500 "$WORK/rohome"
  eq "$(resolve chief_prefix "HOME=$WORK/rohome" "TMPDIR=$WORK/tmpd")" "$WORK/tmpd/chief-$UID_N" \
     "a read-only HOME resolved to an unwritable prefix instead of falling through"
  # …unless the prefix ITSELF is writable — a bind-mounted ~/.chief under an
  # immutable home is a supported container shape.
  mkdir -p "$WORK/rohome2/.chief"; chmod 500 "$WORK/rohome2"
  eq "$(resolve chief_prefix "HOME=$WORK/rohome2" "TMPDIR=$WORK/tmpd")" "$WORK/rohome2/.chief" \
     "a writable \$HOME/.chief under a read-only \$HOME was not honoured"
else
  note "SKIP read-only-\$HOME cases — running as root, which is never denied write"
fi

# (d) the worktree root and the registry relocate INDEPENDENTLY of the prefix: a host
#     puts the volatile registry on a tmpfs and the worktrees on a real volume.
eq "$(resolve chief_worktree_root "CHIEF_PREFIX=$WORK/p")" "$WORK/p/worktrees" "default worktree root moved"
eq "$(resolve chief_worktree_root "CHIEF_PREFIX=$WORK/p" "CHIEF_WORKTREE_ROOT=$WORK/wt/")" "$WORK/wt" \
   "CHIEF_WORKTREE_ROOT does not relocate the worktree tree"
eq "$(resolve chief_runs_dir  "CHIEF_PREFIX=$WORK/p")" "$WORK/p/runs"  "default runs dir moved"
eq "$(resolve chief_repos_dir "CHIEF_PREFIX=$WORK/p")" "$WORK/p/repos" "default repos dir moved"
eq "$(resolve chief_runs_dir "CHIEF_PREFIX=$WORK/p" "CHIEF_RUNS=$WORK/r")" "$WORK/r" \
   "CHIEF_RUNS does not override the registry independently of the prefix"
note "prefix/worktree resolution under a container-shaped environment: OK"

# ═════════════════════════════════════════════════════════════════════════════
# 2. A WHOLE RUN, IN THE CONTAINER SHAPE
# ═════════════════════════════════════════════════════════════════════════════
# No $HOME · a relocated prefix AND worktree root · a repo git calls dubiously owned ·
# no resolvable committer. The run must still implement → verify → merge.

# ── the fake agent: one story per call, commit included, promise when done ────
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null                                    # drain the prompt
PRD=".chief/state/prd.json"                       # cwd = the worktree
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"; TRACKED="tasks/chief/$name.json"
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  mkdir -p out; echo "impl $id" > "out/$name-$id.txt"    # per-tasklist, so a second
                                                        # branch's work is real work
  for f in "$PRD" "$TRACKED"; do
    [ -f "$f" ] || continue
    t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id).passes)=true' "$f" > "$t" && mv "$t" "$f"
  done
  git add -A >/dev/null 2>&1 || true; git commit -q -m "feat: $id - scripted" >/dev/null 2>&1 || true
fi
[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── scaffold the repo the ordinary way (a HOST built this checkout) ───────────
PREFIX="$WORK/ch"; WTROOT="$WORK/volume/worktrees"      # deliberately NOT under the prefix
REPO="$WORK/repo"; mkdir -p "$REPO" "$WTROOT"; cd "$REPO"
GIT_AUTHOR_NAME=ct GIT_AUTHOR_EMAIL=ct@test GIT_COMMITTER_NAME=ct GIT_COMMITTER_EMAIL=ct@test \
  git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
export GIT_AUTHOR_NAME=ct GIT_AUTHOR_EMAIL=ct@test GIT_COMMITTER_NAME=ct GIT_COMMITTER_EMAIL=ct@test
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null || fail "chief init failed"
rm -f tasks/chief/example.json
cat > tasks/chief/ct.json <<'JSON'
{ "project":"ct","branchName":"chief/ct","description":"container-shaped run",
  "iters":2,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":["the artifact"],"passes":false,"notes":""}] }
JSON
cat > .chief/verify.sh <<'SH'
#!/usr/bin/env bash
set -eu
n="$(git rev-parse --abbrev-ref HEAD | sed 's#^chief/##')"
[ -f "out/$n-US-1.txt" ] || { echo "verify: $n produced no artifact"; exit 1; }
SH
chmod +x .chief/verify.sh
git add -A && git commit -q -m "ct setup"

# ── is git's ownership hook available? Without it, half of section 2 is inert ──
OWNERSHIP_HOOK=1
GIT_TEST_ASSUME_DIFFERENT_OWNER=1 git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 && OWNERSHIP_HOOK=0
[ "$OWNERSHIP_HOOK" = "1" ] || note "SKIP dubious-ownership cases — this git ignores GIT_TEST_ASSUME_DIFFERENT_OWNER"

# The container-shaped environment, in one place. Note GIT_CONFIG_COUNT=1 is ALREADY
# set (by the host, for user.useConfigOnly): chief must EXTEND that command-scope
# config, never overwrite it — if it clobbered index 0 the identity hook below would
# silently stop applying and this section would pass for the wrong reason.
ct_env() {   # rest = extra env for this case; prints nothing, exec's nothing
  env -u HOME -u XDG_STATE_HOME \
      -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
      -u CHIEF_RUN_ID \
      "CHIEF_PREFIX=$PREFIX" "CHIEF_RUNS=$PREFIX/runs" "CHIEF_REPOS=$PREFIX/repos" \
      "CHIEF_WORKTREE_ROOT=$WTROOT" \
      "GIT_TEST_ASSUME_DIFFERENT_OWNER=$OWNERSHIP_HOOK" \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.useConfigOnly GIT_CONFIG_VALUE_0=true \
      "PATH=$WORK/fakebin:$PATH" RETRY_MAX=1 \
      "$@"
}

# ── 2a. NO opt-in: the run must refuse UP FRONT, naming the knob ─────────────
# The value of the preflight is that it fails here, in seconds, with a diagnosis —
# not an hour in, from inside git, on a repo the operator did not choose.
if [ "$OWNERSHIP_HOOK" = "1" ]; then
  LOG="$WORK/refuse.log"; rc=0
  ct_env "$CHIEF" run >"$LOG" 2>&1 || rc=$?
  [ "$rc" != "0" ] || fail "a run against a repo git calls dubiously owned SUCCEEDED without the opt-in"
  grep -q "dubious ownership" "$LOG" || fail "the refusal does not quote git's own diagnosis"
  grep -q "CHIEF_GIT_SAFE_DIRECTORY" "$LOG" || fail "the refusal does not name the knob that fixes it"
  # The per-repo dir under the worktree root is made by the writability guard that
  # runs BEFORE this check — an empty dir is fine; a checkout inside it is not.
  [ -z "$(find "$WTROOT" -mindepth 2 2>/dev/null)" ] || fail "the refused run still created a worktree"
  git -C "$REPO" rev-parse --verify -q chief/ct >/dev/null && fail "the refused run still created the branch"
  LOG=""
  note "un-opted-in dubious ownership refuses up front and names CHIEF_GIT_SAFE_DIRECTORY: OK"
fi

# ── 2b. WITH the opt-in: the whole loop runs, in the container shape ──────────
LOG="$WORK/run.log"
ct_env CHIEF_GIT_SAFE_DIRECTORY='*' "$CHIEF" run >"$LOG" 2>&1 \
  || fail "the container-shaped run exited non-zero"

git -C "$REPO" checkout -q main
[ -f "$REPO/out/ct-US-1.txt" ]                    || fail "the container-shaped run merged no work to main"
[ -f "$REPO/tasks/chief/completed/ct.json" ]      || fail "the tasklist was not retired after the merge"

# the worktree tree went where it was TOLD, not to the prefix's default
[ -d "$WTROOT" ] && [ -n "$(ls -A "$WTROOT")" ]   || fail "nothing was created under \$CHIEF_WORKTREE_ROOT"
[ ! -e "$PREFIX/worktrees" ]                      || fail "worktrees landed under the prefix despite \$CHIEF_WORKTREE_ROOT"

# the registry landed under the relocated prefix, not under a resolved-from-\$HOME one
[ -d "$PREFIX/runs" ]                             || fail "the run registry did not land under \$CHIEF_PREFIX"

# the identity fallback signed BOTH the agent's commit and the driver's merge commit
ident="$(git -C "$REPO" log -1 --format='%an <%ae>')"
eq "$ident" "chief <chief@localhost>" "the merge commit was not signed by the fallback identity"
sident="$(git -C "$REPO" log --format='%an <%ae>' --grep='feat: US-1' -1)"
eq "$sident" "chief <chief@localhost>" "the agent's own commit was not signed by the fallback identity"
grep -q "no committer identity" "$LOG" || fail "the run never announced the identity fallback it applied"
LOG=""
note "no \$HOME + relocated worktrees + dubious ownership + no identity → implement→verify→merge: OK"

# ── 2c. the identity is overridable, and a host that HAS one keeps it ─────────
cat > "$REPO/tasks/chief/ct2.json" <<'JSON'
{ "project":"ct2","branchName":"chief/ct2","description":"container-shaped run 2",
  "iters":2,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":["the artifact"],"passes":false,"notes":""}] }
JSON
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "ct2"
LOG="$WORK/run2.log"
ct_env CHIEF_GIT_SAFE_DIRECTORY='*' \
       CHIEF_GIT_IDENTITY_NAME='riju bot' CHIEF_GIT_IDENTITY_EMAIL='bot@riju.invalid' \
       "$CHIEF" run >"$LOG" 2>&1 || fail "the second container-shaped run exited non-zero"
git -C "$REPO" checkout -q main
eq "$(git -C "$REPO" log -1 --format='%an <%ae>')" "riju bot <bot@riju.invalid>" \
   "CHIEF_GIT_IDENTITY_NAME/_EMAIL did not override the fallback identity"
LOG=""
note "CHIEF_GIT_IDENTITY_NAME/_EMAIL override: OK"

# ── 2d. `1` trusts exactly the repo + the worktree root, and nothing else ─────
# (The end-to-end above uses `*`, the throwaway-container mode, so that it holds on
# every git version. This is the targeted mode, asserted where it is decidable.)
# shellcheck source=engine/gitenv.sh
( . "$ROOT/engine/gitenv.sh"
  set -- $(CHIEF_GIT_SAFE_DIRECTORY=1 chief_git_safe_dirs "/r/repo" "/v/worktrees")
  [ "$#" = "2" ] && [ "$1" = "/r/repo" ] && [ "$2" = "/v/worktrees" ] ) \
  || fail "CHIEF_GIT_SAFE_DIRECTORY=1 does not trust exactly the repo + the worktree root"
( . "$ROOT/engine/gitenv.sh"
  [ -z "$(CHIEF_GIT_SAFE_DIRECTORY= chief_git_safe_dirs /r/repo /v/wt)" ] \
  && [ "$(CHIEF_GIT_SAFE_DIRECTORY='*' chief_git_safe_dirs /r/repo /v/wt)" = "*" ] \
  && [ "$(CHIEF_GIT_SAFE_DIRECTORY=/a:/b chief_git_safe_dirs /r/repo /v/wt | tr '\n' ' ')" = "/a /b " ] ) \
  || fail "CHIEF_GIT_SAFE_DIRECTORY off/'*'/path-list modes do not behave as documented"
# additive, never overwriting: a host's own command-scope config survives.
( . "$ROOT/engine/gitenv.sh"
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.useConfigOnly GIT_CONFIG_VALUE_0=true
  chief_git_trust_dir /r/repo
  [ "$GIT_CONFIG_COUNT" = "2" ] && [ "$GIT_CONFIG_KEY_0" = "user.useConfigOnly" ] \
  && [ "$GIT_CONFIG_KEY_1" = "safe.directory" ] && [ "$GIT_CONFIG_VALUE_1" = "/r/repo" ] ) \
  || fail "chief_git_trust_dir overwrote the host's existing command-scope git config"
note "safe.directory modes + command-scope additivity: OK"

# ═════════════════════════════════════════════════════════════════════════════
# 3. THE PID-KEYED RECORDS DEGRADE, RATHER THAN MIS-READING A FOREIGN PID
# ═════════════════════════════════════════════════════════════════════════════
# A shared state prefix (a bind-mounted ~/.chief, one volume in two containers) puts
# another namespace's pids in this registry. Here they mean nothing — and "nothing"
# must read as unknowable, not as dead.
# shellcheck source=engine/reap.sh
. "$ROOT/engine/reap.sh"

FOREIGN="ns:4026531999"
[ -n "$(chief_ns_token)" ] || fail "chief_ns_token resolved to nothing — every record would be unlabelled"
CHIEF_NS_TOKEN=""   # the memo, so the override below is actually re-read
eq "$(CHIEF_PID_NS=ns:12345 chief_ns_token)" "ns:12345" "\$CHIEF_PID_NS does not override the namespace token"
CHIEF_NS_TOKEN=""
chief_ns_foreign "$FOREIGN"            || fail "a different namespace token was not recognised as foreign"
if chief_ns_foreign "$(chief_ns_token)"; then fail "this process's OWN namespace token read as foreign"; fi
# The compatibility floor: an ABSENT token is a pre-0.8.14 record or a host that could
# not tell. Reading those as foreign would silently retire the stale-lock and
# stale-run-file cleanup every ordinary single-namespace run depends on.
if chief_ns_foreign ""; then fail "an absent namespace token read as foreign — every legacy record would freeze"; fi

# ── 3a. `chief ps` must not prune a run file it cannot judge ─────────────────
RUNS="$PREFIX/runs"; mkdir -p "$RUNS"
mk_run() {   # $1 = pid  $2 = ns token ('' = none)  $3 = repo label
  { printf 'pid=%s\nrunid=%s-1-1-%s\nrepo=%s\nnames=x\nstarted=%s\n' "$1" "$3" "$1" "$WORK/$3" "$(date +%s)"
    [ -n "$2" ] && printf 'ns=%s\n' "$2"; } > "$RUNS/$1.run"
}
mk_run 999001 "$FOREIGN"            foreignrepo
mk_run 999002 "$(chief_ns_token)"   localrepo
out="$(ct_env "$CHIEF" ps 2>&1)" || fail "chief ps exited non-zero: $out"
[ -f "$RUNS/999001.run" ] || fail "chief ps DELETED the registry entry of a run in another PID namespace"
[ ! -f "$RUNS/999002.run" ] || fail "chief ps stopped pruning a dead LOCAL run file — the ordinary case regressed"
case "$out" in *"another PID namespace"*) ;; *) fail "chief ps hid the foreign entries without saying so:
$out" ;; esac
case "$out" in *foreignrepo*) fail "chief ps rendered a foreign run as if its pid meant something here:
$out" ;; esac
rm -f "$RUNS"/*.run
note "chief ps leaves foreign registry entries alone (and still prunes local dead ones): OK"

# ── 3b. a foreign driver.lock is never stolen ────────────────────────────────
# Stealing it is how two drivers end up on one repo — the single thing the lock
# exists to prevent. The pid below is dead HERE, which is exactly the trap: the
# ordinary "stale lock" path would clear it without hesitating.
# A runnable tasklist has to exist for the run to get as far as the lock: a driver
# with nothing to schedule exits before it.
cat > "$REPO/tasks/chief/ct3.json" <<'JSON'
{ "project":"ct3","branchName":"chief/ct3","description":"container-shaped run 3",
  "iters":2,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":["the artifact"],"passes":false,"notes":""}] }
JSON
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "ct3"

LOCK="$REPO/.chief/state/driver.lock"
rm -rf "$LOCK"; mkdir -p "$LOCK"
echo 999003 > "$LOCK/pid"; printf '%s\n' "$FOREIGN" > "$LOCK/ns"
LOG="$WORK/lock.log"; rc=0
ct_env CHIEF_GIT_SAFE_DIRECTORY='*' "$CHIEF" run >"$LOG" 2>&1 || rc=$?
[ "$rc" != "0" ] || fail "a run STOLE a driver.lock taken in another PID namespace"
grep -q "DIFFERENT PID namespace" "$LOG" || fail "the refusal does not explain that the lock is foreign"
[ -d "$LOCK" ] && [ "$(cat "$LOCK/pid")" = "999003" ] || fail "the foreign lock was cleared anyway"
LOG=""
# …and the ordinary stale lock (this namespace, dead pid) is still cleared, or every
# crash would need a manual rmdir.
printf '%s\n' "$(chief_ns_token)" > "$LOCK/ns"
LOG="$WORK/lock2.log"
ct_env CHIEF_GIT_SAFE_DIRECTORY='*' "$CHIEF" run >"$LOG" 2>&1 \
  || fail "a stale LOCAL driver lock is no longer auto-cleared"
grep -q "clearing a stale driver lock" "$LOG" || fail "the stale local lock was not reported as cleared"
LOG=""
note "driver.lock: foreign is refused, stale-local is still cleared: OK"

# ── 3c. the run-id liveness key declines to interpret a foreign pid ──────────
# A LIVE local process, claimed by a run file written in another namespace: the pid
# is alive here, but it is not the pid that record is about.
sleep 60 & live=$!; PIDS="$PIDS $live"; disown "$live" 2>/dev/null || true
export CHIEF_RUNS="$RUNS"
LIVE_ID="nsrepo-77-1700000000-$live"
printf 'pid=%s\nrunid=%s\nrepo=%s\nnames=x\nns=%s\n' "$live" "$LIVE_ID" "$WORK/nsrepo" "$FOREIGN" > "$RUNS/$live.run"
if chief_run_id_live "$LIVE_ID"; then
  fail "a run file from another PID namespace was read as proof its pid is live here"
fi
printf 'pid=%s\nrunid=%s\nrepo=%s\nnames=x\nns=%s\n' "$live" "$LIVE_ID" "$WORK/nsrepo" "$(chief_ns_token)" > "$RUNS/$live.run"
chief_run_id_live "$LIVE_ID" || fail "a LOCAL run file with a live pid stopped reading as live"
rm -f "$RUNS/$live.run"
note "run-id liveness declines foreign records, unchanged for local ones: OK"

echo "CONTAINER PASS — no \$HOME · relocated prefix+worktrees · dubious ownership · no committer · foreign PID namespace"
