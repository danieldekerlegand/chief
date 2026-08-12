#!/usr/bin/env bash
# test/account-env.sh — pin the ACCOUNT CREDENTIAL SEAM (docs/account-credentials.md).
#
# The seam lets a caller start a run UNDER A DESIGNATED PROVIDER ACCOUNT — the
# runner-side prerequisite chief-cloud's account pooler drives (chief itself does no
# pooling). Its correctness bar is two-sided, so both sides are asserted here rather
# than left to inspection:
#
#   · REACH — the KEY=VALUE file named by `chief run --account-env` (or
#     CHIEF_ACCOUNT_ENV_FILE) is applied to the PROVIDER SUBPROCESS. A scripted fake
#     `claude` reports the variables it actually sees, so "designated" means "arrived".
#   · BOUNDARY — and nowhere else. The verify hook reports what IT sees; a credential
#     that leaked past the provider boundary would show up there.
#   · NON-LEAKAGE — the value never reaches the run registry, the live records, the
#     per-iteration logs, `chief`'s own output (traced with -V), the worktrees, or
#     anything under .chief/state. What IS recorded is the DESIGNATION: the env-file
#     path and the account label, which is how `chief ps` names the account.
#   · LOUD FAILURE — a bogus designation (flag OR env var) kills the launch before any
#     agent turn, rather than silently spending the inherited account's quota.
#   · NO REGRESSION — an UNDESIGNATED run still drives implement → verify → merge with
#     an untouched environment, exactly as before the seam existed.
#
# Hermetic: a scripted fake `claude` on PATH, temp prefixes ($CHIEF_PREFIX included, so
# worktrees land in the temp dir), never touches the real ~/.chief. Drives bin/chief
# straight out of this checkout, so it tests uncommitted work. Offline, deterministic.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=acct GIT_AUTHOR_EMAIL=acct@test \
       GIT_COMMITTER_NAME=acct GIT_COMMITTER_EMAIL=acct@test
export CHIEF_PREFIX="$WORK/ch" CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
export RETRY_MAX=1                       # one attempt per tasklist; states, not budgets
CHIEF="$ROOT/bin/chief"
LOG=""
fail() { echo "ACCOUNT-ENV FAIL: $*" >&2; [ -n "$LOG" ] && [ -f "$LOG" ] && tail -40 "$LOG" >&2; exit 1; }
command -v jq  >/dev/null || fail "jq required"
command -v git >/dev/null || fail "git required"

# ── the designated account ───────────────────────────────────────────────────
# One token in BOTH values, so a single grep proves "no value, of either variable,
# anywhere". Deliberately NOT a substring of the env-file path or the label: those two
# ARE meant to be reported, and a scan that couldn't tell them apart would prove nothing.
LEAK="9f3a7c1e"
SECRET="sk-chief-acct-$LEAK-DO-NOT-LOG"
CFGDIR="$WORK/acct/cfg-$LEAK"
mkdir -p "$WORK/acct" "$WORK/probe" "$CFGDIR"
ENVFILE="$WORK/acct/pool-a.env"
cat > "$ENVFILE" <<EOF
# a designated account, as an operator (or a pooler) would hand it to chief
ANTHROPIC_API_KEY=$SECRET
export CLAUDE_CONFIG_DIR="$CFGDIR"
not an assignment — must be ignored, never executed
EOF
chmod 600 "$ENVFILE"

# ── the fake agent: reports its environment, then does one story per call ────
# ACCT_PROBE / ACCT_SNAP are ordinary inherited env, set per invocation below.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null                                    # drain the prompt on stdin
# WHAT THE PROVIDER SUBPROCESS ACTUALLY SEES — the whole point of the seam.
if [ -n "${ACCT_PROBE:-}" ]; then
  printf 'ANTHROPIC_API_KEY=[%s]\nCLAUDE_CONFIG_DIR=[%s]\n' \
    "${ANTHROPIC_API_KEY:-}" "${CLAUDE_CONFIG_DIR:-}" >> "$ACCT_PROBE"
fi
# The run registry and the live records exist only WHILE the run is live (the driver
# removes its entry on exit), so snapshot them from inside the run.
if [ -n "${ACCT_SNAP:-}" ]; then
  mkdir -p "$ACCT_SNAP"
  cp "$CHIEF_RUNS"/*.run                        "$ACCT_SNAP/" 2>/dev/null || true
  cp "$ACCT_STATE"/parallel/*.live.json         "$ACCT_SNAP/" 2>/dev/null || true
  cp "$ACCT_STATE"/parallel/*.log               "$ACCT_SNAP/" 2>/dev/null || true
fi
PRD=".chief/state/prd.json"                       # cwd = the worktree
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"; TRACKED="tasks/chief/$name.json"
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  mkdir -p out; echo "impl $name/$id" > "out/$name-$id.txt"
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

# ── scaffold a repo with two one-story tasklists + a reporting verify hook ────
REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null || fail "chief init failed"
rm -f tasks/chief/example.json
for n in acct plain; do
  cat > "tasks/chief/$n.json" <<JSON
{ "project":"acct","branchName":"chief/$n","description":"$n",
  "iters":3,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[
    {"id":"US-1","title":"first","description":"","acceptanceCriteria":["out/$n-US-1.txt"],"passes":false,"notes":""}
  ] }
JSON
done
# The verify hook runs in the MERGE phase, under chief's own environment. It reports
# what it sees so a credential leaking past the provider boundary is a failed assertion
# rather than something nobody looks for.
cat > .chief/verify.sh <<'SH'
#!/usr/bin/env bash
set -eu
if [ -n "${ACCT_VERIFY_PROBE:-}" ]; then
  printf 'ANTHROPIC_API_KEY=[%s]\nCLAUDE_CONFIG_DIR=[%s]\n' \
    "${ANTHROPIC_API_KEY:-}" "${CLAUDE_CONFIG_DIR:-}" >> "$ACCT_VERIFY_PROBE"
fi
ls out/*.txt >/dev/null 2>&1 || { echo "verify: missing artifact"; exit 1; }
echo "verify: ok"
SH
chmod +x .chief/verify.sh
git add -A && git commit -q -m "acct: tasklists + verify hook"
export ACCT_STATE="$REPO/.chief/state"

# ── 1. LOUD FAILURE — a bogus designation never reaches an agent turn ────────
# Both routes: the flag and the CHIEF_ACCOUNT_ENV_FILE equivalent a headless caller
# (or .chief/config) uses. Neither may fall back to the inherited account.
BOGUS="$WORK/acct/nope.env"
[ ! -e "$BOGUS" ] || fail "fixture error: $BOGUS should not exist"
out="$(PATH="$WORK/fakebin:$PATH" "$CHIEF" run --account-env "$BOGUS" acct 2>&1)" && \
  fail "a bogus --account-env exited 0 — the launch must fail loudly"
case "$out" in *"$BOGUS"*) ;; *) fail "bogus --account-env error doesn't name the path: $out" ;; esac
out="$(PATH="$WORK/fakebin:$PATH" CHIEF_ACCOUNT_ENV_FILE="$BOGUS" "$CHIEF" run acct 2>&1)" && \
  fail "a bogus CHIEF_ACCOUNT_ENV_FILE exited 0 — the env route must fail the same way"
case "$out" in *"$BOGUS"*) ;; *) fail "bogus CHIEF_ACCOUNT_ENV_FILE error doesn't name the path: $out" ;; esac
[ -z "$(ls "$CHIEF_RUNS"/*.run 2>/dev/null || true)" ] || fail "a failed launch registered a run"
git rev-parse --verify -q chief/acct >/dev/null && fail "a failed launch created the feature branch"

# ── 2. REACH + BOUNDARY + NON-LEAKAGE — the designated run ──────────────────
PROBE="$WORK/probe/provider.env"; VPROBE="$WORK/probe/verify.env"
SNAP="$WORK/probe/snap"
LOG="$WORK/designated.log"
ACCT_PROBE="$PROBE" ACCT_VERIFY_PROBE="$VPROBE" ACCT_SNAP="$SNAP" \
  PATH="$WORK/fakebin:$PATH" \
  "$CHIEF" run -V --account-env "$ENVFILE" --account-label pool-a acct \
  >"$LOG" 2>&1 || fail "designated run exited non-zero"

# REACH: the provider subprocess saw the designated account.
[ -f "$PROBE" ] || fail "the fake provider never ran (no probe)"
grep -qF "ANTHROPIC_API_KEY=[$SECRET]"  "$PROBE" || fail "ANTHROPIC_API_KEY did not reach the provider: $(cat "$PROBE")"
grep -qF "CLAUDE_CONFIG_DIR=[$CFGDIR]"  "$PROBE" || fail "CLAUDE_CONFIG_DIR did not reach the provider: $(cat "$PROBE")"

# BOUNDARY: the verify hook ran under chief's own environment, not the account's.
[ -f "$VPROBE" ] || fail "the verify hook never ran (no probe)"
grep -qF "ANTHROPIC_API_KEY=[]" "$VPROBE" || fail "the credential leaked into the verify hook: $(cat "$VPROBE")"
grep -qF "CLAUDE_CONFIG_DIR=[]" "$VPROBE" || fail "the credential leaked into the verify hook: $(cat "$VPROBE")"

# DESIGNATION IS REPORTED: the registry entry `chief ps`/`chief monitor` read names
# WHICH account the run spends — by label and by path, never by a value.
RUNSNAP="$(ls "$SNAP"/*.run 2>/dev/null | head -1 || true)"
[ -n "$RUNSNAP" ] || fail "no run-registry entry was captured during the run"
grep -qF "accountlabel=pool-a" "$RUNSNAP" || fail "run registry doesn't record the account label: $(cat "$RUNSNAP")"
grep -qF "account=$ENVFILE"    "$RUNSNAP" || fail "run registry doesn't record the env-file path: $(cat "$RUNSNAP")"

# NON-LEAKAGE: the VALUES are nowhere a human or a host can read them. Scanned live
# (the snapshot, taken mid-run) and after (records that outlive the run).
scan() {
  local what="$1" where="$2"
  [ -e "$where" ] || return 0
  local hit
  hit="$(grep -rlF "$LEAK" "$where" 2>/dev/null || true)"
  [ -z "$hit" ] || fail "credential value leaked into $what: $hit"
}
scan "the live run registry + live records + per-tasklist logs (snapshot)" "$SNAP"
scan "the run registry / event stream"                                     "$CHIEF_RUNS"
scan ".chief/state (live records, logs, snapshots, runtime PRD)"            "$ACCT_STATE"
scan "the worktree root"                                                   "$CHIEF_PREFIX"
scan "chief's own output (-V verbose trace included)"                      "$LOG"
scan "the tasklists"                                                      "$REPO/tasks"
# The per-iteration log `chief logs` serves still NAMES the account — reported, not
# exposed. It is the same file the scan above just proved carries no value.
grep -q "account=pool-a" "$ACCT_STATE/parallel/acct.log" \
  || fail "the -V provider trace doesn't name the designated account"

# NO REGRESSION on the merge path: the designated run merged like any other.
git checkout -q main
[ -f out/acct-US-1.txt ]                || fail "designated run's work not merged to main"
[ -f tasks/chief/completed/acct.json ]  || fail "designated tasklist not retired to completed/"

# ── 3. UNDESIGNATED — byte-for-byte the old behaviour ───────────────────────
PROBE2="$WORK/probe/provider-plain.env"; VPROBE2="$WORK/probe/verify-plain.env"
LOG="$WORK/plain.log"
ACCT_PROBE="$PROBE2" ACCT_VERIFY_PROBE="$VPROBE2" PATH="$WORK/fakebin:$PATH" \
  "$CHIEF" run plain >"$LOG" 2>&1 || fail "undesignated run exited non-zero"
[ -f "$PROBE2" ] || fail "the fake provider never ran in the undesignated run"
grep -qF "ANTHROPIC_API_KEY=[]" "$PROBE2" || fail "an undesignated run inherited a credential: $(cat "$PROBE2")"
grep -qF "CLAUDE_CONFIG_DIR=[]" "$PROBE2" || fail "an undesignated run inherited a credential: $(cat "$PROBE2")"
git checkout -q main
[ -f out/plain-US-1.txt ]               || fail "undesignated run's work not merged to main"
[ -f tasks/chief/completed/plain.json ] || fail "undesignated tasklist not retired to completed/"

echo "ACCOUNT-ENV PASS — designated env reaches the provider ONLY, values leak nowhere, a bogus designation fails the launch, an undesignated run is unchanged"
