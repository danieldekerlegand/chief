#!/usr/bin/env bash
# test/monitor.sh — prove the GLOBAL run registry + `chief ps`/`chief monitor`
# reflect a live run, and get cleaned up when it ends. Offline & deterministic.
#
# A fake `claude` signals "I started", then BLOCKS on a gate file the test
# controls. While it's blocked the driver is mid-run, so: a <pid>.run file must
# exist in CHIEF_RUNS, and `chief ps` must show the repo, the tasklist, "running",
# and "0/1" progress. The test then releases the gate; the story completes and
# merges, the driver exits, and its run file must be gone (so `chief ps` reports
# no active runs). This exercises register-on-start + prune/cleanup-on-exit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=mon GIT_AUTHOR_EMAIL=mon@test GIT_COMMITTER_NAME=mon GIT_COMMITTER_EMAIL=mon@test
fail() { echo "MONITOR FAIL: $*" >&2; [ -f "$WORK/run.log" ] && tail -30 "$WORK/run.log" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

# ── install chief from this checkout, into a throwaway prefix ──────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
export CHIEF_RUNS="$WORK/runs"                    # both driver + monitor read this
export CHIEF_REPOS="$WORK/repos"                  # hermetic: don't touch ~/.chief
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# ── fake `claude`: announce start, block on a gate, then implement the story ──
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null
: "${AGENT_GATE:?}" "${AGENT_STARTED:?}"
touch "$AGENT_STARTED"
while [ ! -f "$AGENT_GATE" ]; do sleep 0.2; done   # hold the run open for observation
PRD=".chief/state/prd.json"; name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
TRACKED="tasks/chief/$name.json"
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

# ── scaffold a repo + a 1-story tasklist + a real verify hook ─────────────────
REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null
rm -f tasks/chief/example.json
cat > tasks/chief/mon.json <<'JSON'
{ "project":"mon","branchName":"chief/mon","description":"monitor registry",
  "iters":3,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":["out/US-1.txt"],"passes":false,"notes":""}] }
JSON
printf '#!/usr/bin/env bash\nset -eu\n[ -f out/US-1.txt ] || { echo missing; exit 1; }\necho ok\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "mon setup"

# ── launch the run in the background; the agent blocks until we open the gate ──
export AGENT_GATE="$WORK/gate" AGENT_STARTED="$WORK/started"
PATH="$WORK/fakebin:$PATH" "$CHIEF" run -p 1 >"$WORK/run.log" 2>&1 &
runpid=$!

waited=0
while [ ! -f "$AGENT_STARTED" ]; do
  kill -0 "$runpid" 2>/dev/null || { cat "$WORK/run.log"; fail "run exited before the agent started"; }
  sleep 0.2; waited=$(( waited + 1 )); [ "$waited" -gt 150 ] && fail "agent never started (30s)"
done

# ── while the run is held open: registry + `chief ps` must reflect it ─────────
ls "$CHIEF_RUNS"/*.run >/dev/null 2>&1 || fail "no <pid>.run file registered while running"
# The registry carries the re-dispatch cap so a paused tasklist can render
# "re-dispatch n/max" (see test/limitmonitor.sh for that rendering).
grep -q '^limitmax=[0-9]' "$CHIEF_RUNS"/*.run || fail "run file has no limitmax= (usage-limit re-dispatch cap)"
ps_out="$("$CHIEF" ps)"
echo "--- chief ps (live) ---"; echo "$ps_out"
case "$ps_out" in *"$(basename "$REPO")"*) ;; *) fail "ps didn't show the repo label" ;; esac
case "$ps_out" in *mon*)     ;; *) fail "ps didn't show the tasklist name" ;; esac
case "$ps_out" in *running*) ;; *) fail "ps didn't show the running state" ;; esac
case "$ps_out" in *0/1*)     ;; *) fail "ps didn't show 0/1 story progress" ;; esac
case "$ps_out" in *"1 active run"*) ;; *) fail "ps didn't report 1 active run" ;; esac

# ── release the gate; the story completes, merges, and the driver exits ───────
touch "$AGENT_GATE"
wait "$runpid" || { cat "$WORK/run.log"; fail "backgrounded run exited non-zero"; }

# ── after exit: run file pruned, story merged, ps reports nothing active ──────
ls "$CHIEF_RUNS"/*.run >/dev/null 2>&1 && fail "run file not removed after the driver exited"
git checkout -q main
[ -f out/US-1.txt ] || fail "story didn't merge after the gate opened"
case "$("$CHIEF" ps)" in *"no active runs"*) ;; *) fail "ps still shows an active run after exit" ;; esac

echo "MONITOR PASS — registry + chief ps reflected the live run (repo/tasklist/running/0-1), then cleaned up on exit"
