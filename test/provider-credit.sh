#!/usr/bin/env bash
# test/provider-credit.sh — AN ACCOUNT WITH NOTHING LEFT TO SPEND IS NOT A BAD KEY.
#
# `_provider_unavailable` classified `401 402 403` + `authentication_error` +
# `permission_error` as ONE permanent bucket and printed one sentence for all of them:
# "bad or revoked credentials, or a quota that will not replenish". Those are two
# different operator actions — top the account up, or replace the credential — and the
# monitor's own glyph comment says `no-api` deliberately does NOT mean the account is
# out of quota, so until 0.9.36 nothing anywhere said that sentence.
#
# FOUR PARTS.
#   PART A — CLASSIFICATION, three codes through the REAL agent loop. 402 is the
#            account; 401 and 403 are the credential; all three stop on the FIRST
#            refusal. "Without sleeping" is asserted as the PROVIDER CALL COUNT and the
#            absence of the wait announcement, never as a clock: a permanent refusal
#            that slept would also have retried, and a wall-clock ceiling is an
#            assertion about the host (CLAUDE.md). The 529 CONTROL is what makes that
#            mean something — same loop, same knobs, three calls and two waits.
#   PART B — THE RENDER, against a staged state directory and a synthetic run
#            registry: no driver, no agent, no git, so the claim is about the RENDERER.
#            Three rows in ONE state (`provider-unavailable`) whose labels differ, plus
#            the row that keeps `no-api` — a label that every refusal took would prove
#            nothing.
#   PART C — THE RUN SUMMARY, through the real parallel driver, which is also the only
#            place the verdict has to SURVIVE the driver's own park (worker_park
#            rewrites the record's phase, and a field it does not know must come
#            through untouched).
#   PART D — SABOTAGE: with 402 collapsed back into the credential bucket in a COPY of
#            the engine, PART A's credit assertions must go red and its credential
#            assertions must stay green. Without it, "call everything a credential
#            problem" passes this file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
holder=""
cleanup() {
  for p in $holder; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap 'rc=$?; cleanup; exit "$rc"' EXIT
# HERMETIC IN STATE IS NOT HERMETIC IN ENV — this suite may itself be running inside a
# chief worktree whose driver exported these.
unset CHIEF_PAUSE_FILE
unset CHIEF_PROVIDER CHIEF_TOOL CHIEF_MODEL CHIEF_PRESET
unset PROVIDER_BACKOFF PROVIDER_BACKOFF_CAP PROVIDER_NOTURN_LIMIT
unset CHIEF_RESEARCH CHIEF_RESEARCH_FILE CHIEF_RESEARCH_MAX_ATTEMPTS
export CHIEF_PROVIDER=claude CHIEF_TOOL=claude
export GIT_AUTHOR_NAME=pc GIT_AUTHOR_EMAIL=pc@test GIT_COMMITTER_NAME=pc GIT_COMMITTER_EMAIL=pc@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"   # hermetic: don't touch ~/.chief
fail() { echo "PROVIDER-CREDIT FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"
AGENT="$PREFIX/src/engine/agent.sh"

# ══ PART A — CLASSIFICATION ══════════════════════════════════════════════════
echo "provider-credit: part A — 402 is the account, 401/403 are the credential"

mkdir -p "$WORK/fixbin"
cat > "$WORK/fixbin/claude" <<'FIX'
#!/usr/bin/env bash
set -eu
cat >/dev/null
n=$(( $(cat "$PC_CALLS" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$PC_CALLS"
cat "$PC_TEXT"
exit 1
FIX
chmod +x "$WORK/fixbin/claude"

FIXREPO="$WORK/fixrepo"; mkdir -p "$FIXREPO/.chief/state"
git -C "$FIXREPO" init -q -b main 2>/dev/null || git -C "$FIXREPO" init -q
git -C "$FIXREPO" commit -q --allow-empty -m init
cat > "$FIXREPO/.chief/state/prd.json" <<'JSON'
{ "project":"pc","branchName":"chief/pc","userStories":[
  {"id":"US-1","title":"one","description":"","acceptanceCriteria":[],"passes":false,"notes":""}] }
JSON
export PC_CALLS="$WORK/calls" PC_TEXT="$WORK/text"

# Run ONE stop against one envelope. $1 is a tag; $2 the provider's output; $3 the
# agent.sh to drive (PART D hands it a mutated copy). Everything the operator is
# shown lands in files named after the tag.
#
# PROVIDER_BACKOFF is deliberately NON-zero: "not slept on" is the claim, and a knob
# that disables waiting for everyone would make it vacuous. The cap keeps the 529
# control's two waits at ~1s each.
refuse() {  # TAG OUTPUT AGENT
  local tag="$1" out="$2" agent="$3" rc=0
  printf '0' > "$PC_CALLS"; printf '%s\n' "$out" > "$PC_TEXT"
  rm -f "$WORK/live-$tag.json" "$WORK/ev-$tag.jsonl"
  ( cd "$FIXREPO" && PATH="$WORK/fixbin:$PATH" CHIEF_PROJECT="$FIXREPO" \
      CHIEF_LIVE_FILE="$WORK/live-$tag.json" CHIEF_EVENTS_FILE="$WORK/ev-$tag.jsonl" \
      CHIEF_TASKLIST="$tag" \
      RATE_LIMIT_RETRY=0 STALL_LIMIT=1 PROVIDER_NOTURN_LIMIT=3 \
      PROVIDER_BACKOFF=1 PROVIDER_BACKOFF_CAP=1 PROVIDER_BACKOFF_JITTER=0 \
      bash "$agent" 1 ) > "$WORK/log-$tag" 2>&1 || rc=$?
  cp "$FIXREPO/.chief/state/.provider-unavailable" "$WORK/why-$tag" 2>/dev/null || true
  echo "$rc" > "$WORK/rc-$tag"
  cat "$PC_CALLS" > "$WORK/n-$tag"
}
envelope() { printf 'API Error: %s {"type":"error","error":{"type":"%s","message":"x"}}' "$1" "$2"; }
why()     { cat "$WORK/why-$1" 2>/dev/null || echo ""; }
refusal() { jq -r '.refusal // ""' "$WORK/live-$1.json" 2>/dev/null || echo ""; }
evrefusal() {  # the verdict on the STOP event, which is the one a subscriber acts on
  jq -r 'select(.event=="tasklist.provider-unavailable" and .state=="provider-unavailable")
         | .refusal // ""' "$WORK/ev-$1.jsonl" 2>/dev/null | tail -1
}

refuse spent      "$(envelope 402 billing_error)"        "$AGENT"
refuse revoked    "$(envelope 401 authentication_error)" "$AGENT"
refuse forbidden  "$(envelope 403 permission_error)"     "$AGENT"
refuse overloaded "$(envelope 529 overloaded_error)"     "$AGENT"

# 1) ALL THREE STOP, AND NONE OF THEM SLEEPS. One provider call each is the assertion:
#    the retry is what the wait precedes, so a permanent refusal that waited would have
#    called twice. The wait announcement is checked too, because a sleep with no retry
#    would still be time an operator spent for nothing.
for tag in spent revoked forbidden; do
  [ "$(cat "$WORK/rc-$tag")" = "8" ] \
    || { tail -20 "$WORK/log-$tag" >&2; fail "$tag: agent exited $(cat "$WORK/rc-$tag"), want 8 (PROVIDER-UNAVAILABLE)"; }
  [ "$(cat "$WORK/n-$tag")" = "1" ] \
    || fail "$tag: the provider was called $(cat "$WORK/n-$tag") time(s) — a PERMANENT refusal is retried, so it was slept on"
  grep -q '^Waiting ' "$WORK/log-$tag" \
    && { grep -n '^Waiting ' "$WORK/log-$tag" >&2; fail "$tag: a permanent refusal announced a wait"; }
  grep -q 'provider-backoff' "$WORK/ev-$tag.jsonl" 2>/dev/null \
    && fail "$tag: a permanent refusal emitted a backoff event"
done
echo "   ok  402/401/403 all exit 8 after ONE call, with no wait announced and no backoff event"

# THE CONTROL that makes the line above mean something: the same loop, the same knobs,
# a TRANSIENT refusal — three calls and two waits. Without it, an engine that never
# waits for anything passes every assertion above.
[ "$(cat "$WORK/n-overloaded")" = "3" ] \
  || fail "control: a 529 was called $(cat "$WORK/n-overloaded") time(s), want 3 — the no-sleep assertion above is vacuous"
[ "$(grep -c '^Waiting ' "$WORK/log-overloaded" || true)" = "2" ] \
  || fail "control: a 529 announced $(grep -c '^Waiting ' "$WORK/log-overloaded" || true) wait(s), want 2 — the no-sleep assertion above is vacuous"
[ "$(refusal overloaded)" = "transient" ] \
  || fail "control: the 529's recorded verdict is '$(refusal overloaded)', want transient"
echo "   ok  control: a 529 on the same knobs is called 3× and waits twice"   # braced: × is multibyte

# 2) THE TWO VERDICTS ARE DIFFERENT, in every place the operator meets them.
#    The recorded reason is what the driver reports from and what the park message
#    quotes; the live record is what the row label reads; the event is what a
#    subscriber acts on.
case "$(why spent)" in
  *'no usage left'*) ;;
  *) fail "402: the recorded reason does not say the account is out of usage: $(why spent)" ;;
esac
case "$(why spent)" in
  *'add credit'*|*'point the run at one that has usage left'*) ;;
  *) fail "402: the recorded reason does not name the operator's action: $(why spent)" ;;
esac
case "$(why spent)" in
  *'credential is wrong'*) fail "402: a spent account was described as a bad credential: $(why spent)" ;;
esac
[ "$(refusal spent)" = "exhausted" ]   || fail "402: live record refusal='$(refusal spent)', want exhausted"
[ "$(evrefusal spent)" = "exhausted" ] || fail "402: the event carries refusal='$(evrefusal spent)', want exhausted"

for tag in revoked forbidden; do
  case "$(why $tag)" in
    *'credential is wrong, revoked, or not entitled'*) ;;
    *) fail "$tag: the recorded reason does not name the credential: $(why $tag)" ;;
  esac
  case "$(why $tag)" in
    *'no usage left'*) fail "$tag: a bad credential was described as a spent account: $(why $tag)" ;;
  esac
  [ "$(refusal $tag)" = "credential" ]   || fail "$tag: live record refusal='$(refusal $tag)', want credential"
  [ "$(evrefusal $tag)" = "credential" ] || fail "$tag: the event carries refusal='$(evrefusal $tag)', want credential"
done
echo "   ok  reason, live record and event all distinguish the account from the credential"

# 3) BOTH ARE STILL PERMANENT. The distinction may not become a reason to wait on one
#    of them — that is the fix wearing the bug it replaced.
for tag in spent revoked forbidden; do
  grep -q 'PERMANENT' "$WORK/why-$tag" || fail "$tag: the recorded reason no longer says PERMANENT"
done
echo "   ok  both verdicts are still permanent refusals"

# ══ PART B — THE RENDER ══════════════════════════════════════════════════════
echo "provider-credit: part B — chief ps, against a staged record"

MSTATE="$WORK/mon"; MPAR="$MSTATE/parallel"; MRUNS="$WORK/mruns"
mkdir -p "$MPAR" "$MRUNS" "$WORK/mrepo" "$WORK/mtasks" "$WORK/mwt"
# shellcheck source=engine/live.sh
. "$ROOT/engine/live.sh"            # the REAL writer, so the fixture cannot drift

sleep 60 & holder=$!                # the monitor prunes run files whose pid is dead

stage() {  # NAME REFUSAL
  echo provider-unavailable > "$MPAR/$1.state"
  live_set "$MPAR/$1.live.json" name="$1" state=provider-unavailable \
    phase=provider-unavailable story=US-2 iter=3 passing=1 total=4 \
    noturn=1 noturn_limit=3 refusal="$2"
}
stage spent-row     exhausted
stage badkey-row    credential
stage blip-row      transient    # retries spent on a transient refusal: still `no-api`
stage silent-row    ""           # no verdict recorded at all: also `no-api`

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
names=spent-row badkey-row blip-row silent-row
EOF

ps_out="$(CHIEF_RUNS="$MRUNS" bash "$ROOT/bin/chief" ps)" || fail "chief ps exited non-zero"
echo "--- chief ps (four refusals, one state) ---"; printf '%s\n' "$ps_out"
# ONE WHOLE ROW, not a fragment: `no-credit` contains no needle the other rows share,
# and matching the row means the label is in the column an operator scans.
row() { printf '%s\n' "$ps_out" | grep "$1 " | head -1; }
case "$(row spent-row)"  in *'no-credit'*) ;; *) fail "the spent account is not labelled 'no-credit': $(row spent-row)" ;; esac
case "$(row badkey-row)" in *'bad-key'*)   ;; *) fail "the bad credential is not labelled 'bad-key': $(row badkey-row)" ;; esac
case "$(row spent-row)"  in *'bad-key'*)   fail "the spent account borrowed the credential label: $(row spent-row)" ;; esac
case "$(row badkey-row)" in *'no-credit'*) fail "the bad credential borrowed the account label: $(row badkey-row)" ;; esac
# THE CONTROLS. A refusal chief could not name keeps the label it always had — if
# every provider-unavailable row moved, the two above would prove nothing.
for n in blip-row silent-row; do
  case "$(row $n)" in *'no-api'*) ;; *) fail "$n: an unnamed refusal lost the 'no-api' label: $(row $n)" ;; esac
  case "$(row $n)" in *'no-credit'*|*'bad-key'*) fail "$n: an unnamed refusal claimed a verdict: $(row $n)" ;; esac
done
# None of them is a failure: the glyph is the hold's, for all four.
for n in spent-row badkey-row blip-row silent-row; do
  case "$(row $n)" in *'✗'*|*'⤬'*) fail "$n: a refusal took a failure glyph: $(row $n)" ;; esac
  case "$(row $n)" in *'⏸'*) ;; *) fail "$n: a refusal is missing the hold glyph: $(row $n)" ;; esac
done
echo "   ok  no-credit · bad-key · no-api · no-api — one state, four rows, one glyph"

# ══ PART C — THE RUN SUMMARY, and the verdict surviving the park ═════════════
echo "provider-credit: part C — the run summary through the real driver"

mkdir -p "$WORK/runbin"
cat > "$WORK/runbin/claude" <<'RUN'
#!/usr/bin/env bash
set -eu
cat >/dev/null
name="$(jq -r '.branchName' .chief/state/prd.json | sed 's#^chief/##')"
case "$name" in
  spent) echo 'API Error: 402 {"type":"error","error":{"type":"billing_error","message":"credit balance is too low"}}' ;;
  *)     echo 'API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}' ;;
esac
exit 1
RUN
chmod +x "$WORK/runbin/claude"

REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null
rm -f tasks/chief/example.json
for n in spent revoked; do
  cat > "tasks/chief/$n.json" <<JSON
{ "project":"pc","branchName":"chief/$n","description":"a refusal that is $n",
  "iters":2,"dependsOn":[],"touches":[],"warmup":[],
  "userStories":[{"id":"US-1","title":"one","description":"","acceptanceCriteria":[],"passes":false,"notes":""}] }
JSON
done
printf '#!/usr/bin/env bash\nexit 0\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "provider-credit setup"

run_rc=0
PATH="$WORK/runbin:$PATH" PROVIDER_BACKOFF=0 \
  "$CHIEF" run -p 2 >"$WORK/run.log" 2>&1 || run_rc=$?
RL="$WORK/run.log"
[ "$run_rc" = "0" ] || { tail -40 "$RL" >&2; fail "a blocked run must not exit non-zero (got $run_rc)"; }

S="$REPO/.chief/state/parallel"
for n in spent revoked; do
  case "$(cat "$S/$n.status" 2>/dev/null || echo NONE)" in
    PROVIDER-UNAVAILABLE*) ;;
    *) tail -40 "$RL" >&2; fail "$n: status is '$(cat "$S/$n.status" 2>/dev/null)', want PROVIDER-UNAVAILABLE" ;;
  esac
done
grep -q 'PROVIDER UNAVAILABLE' "$RL" || { tail -40 "$RL" >&2; fail "the summary does not name the block"; }
# The per-tasklist line in the summary block carries the verdict, so the two reports
# differ by what the operator has to do rather than by an HTTP code alone.
sline() { grep "· *$1 " "$RL" | grep -v '^   - ' | head -1; }
case "$(sline spent)" in
  *'no usage left'*) ;;
  *) tail -40 "$RL" >&2; fail "the summary line for the spent account does not say so: $(sline spent)" ;;
esac
case "$(sline revoked)" in
  *'credential is wrong'*) ;;
  *) tail -40 "$RL" >&2; fail "the summary line for the bad credential does not say so: $(sline revoked)" ;;
esac
case "$(sline spent)" in *'credential is wrong'*) fail "the summary called a spent account a bad credential" ;; esac
grep -q 'no amount of topping up touches it' "$RL" \
  || fail "the summary block never explains that the two verdicts have different fixes"
echo "   ok  the summary names each verdict and the fix that lifts it"

# AND THE VERDICT SURVIVES THE PARK. worker_park rewrites the record's phase after the
# agent exits; a field it does not know must come through untouched, or the row label
# above is correct only until the driver writes next.
[ "$(jq -r '.refusal' "$S/spent.live.json")" = "exhausted" ] \
  || fail "the driver's park lost the verdict: refusal='$(jq -r '.refusal' "$S/spent.live.json")'"
[ "$(jq -r '.refusal' "$S/revoked.live.json")" = "credential" ] \
  || fail "the driver's park lost the verdict: refusal='$(jq -r '.refusal' "$S/revoked.live.json")'"
echo "   ok  the verdict survives worker_park's rewrite of the record"

# ══ PART D — SABOTAGE ════════════════════════════════════════════════════════
# Collapse 402 back into the credential bucket in a COPY of the engine. PART A's
# credit assertions must go red and its credential assertions must stay green — a file
# that cannot tell the difference is a file that would pass on the old engine.
echo "provider-credit: part D — collapsing 402 back into the credential bucket"

MUT="$WORK/mutant"; mkdir -p "$MUT"
cp -R "$PREFIX/src/engine" "$MUT/engine"
sed -i.bak 's/^    402) kind=exhausted ;;$/    402) kind=credential ;;/' "$MUT/engine/agent.sh"
rm -f "$MUT/engine/agent.sh.bak"
grep -q '402) kind=credential ;;' "$MUT/engine/agent.sh" \
  || fail "the mutation did not apply — the classification arm has moved, so PART D proves nothing"

refuse mut-spent   "$(envelope 402 billing_error)"        "$MUT/engine/agent.sh"
refuse mut-revoked "$(envelope 401 authentication_error)" "$MUT/engine/agent.sh"

case "$(why mut-spent)" in
  *'no usage left'*) fail "the mutation had no effect — PART A's credit assertion cannot fail, so it proves nothing" ;;
esac
[ "$(refusal mut-spent)" = "exhausted" ] \
  && fail "the mutation had no effect on the recorded verdict — PART A proves nothing"
echo "   ok  the credit case goes red under the collapse"
# …and ONLY the credit case. If the credential assertions fell over too, the file is
# asserting that the engine was edited rather than that 402 is classified apart.
case "$(why mut-revoked)" in
  *'credential is wrong, revoked, or not entitled'*) ;;
  *) fail "the collapse also broke the credential case: $(why mut-revoked)" ;;
esac
[ "$(refusal mut-revoked)" = "credential" ] \
  || fail "the collapse also broke the credential verdict: '$(refusal mut-revoked)'"
[ "$(cat "$WORK/rc-mut-spent")" = "8" ] \
  || fail "the collapsed engine stopped exiting 8 — the mutation changed more than the bucket"
echo "   ok  and the credential case stays green — exactly the credit cases move"

echo "PROVIDER-CREDIT PASS — a spent account and a bad credential are two permanent verdicts, told apart in the reason, the live record, the event, the row label and the run summary; neither is slept on"
