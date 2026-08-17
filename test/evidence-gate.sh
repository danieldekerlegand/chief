#!/usr/bin/env bash
# test/evidence-gate.sh — prove a story chief passes on the agent's behalf must say HOW.
#
# The failure it guards against: the COMPLETE path force-passes every story an agent
# left false as long as SOME commit exists, so a story can report green against a
# criterion nothing ever read. The signal separating a silent promotion from finished
# work is already in the record — the force-passed stories carry an EMPTY `notes`.
#
# Two tasklists, one run, one fake agent, so both halves of the rule are proven at
# once — a gate that fails honest work is worse than no gate:
# The fixtures name only LOCAL work on purpose: a criterion naming another repo is
# stopped earlier and for a different reason (test/criteria-scope.sh), and this test
# has to reach the evidence gate to say anything about it.
#   ev-bad   commits real work, emits COMPLETE, leaves its stories false with an empty
#            `notes` → UNVERIFIED, nothing merged or retired, and the message names the
#            story and quotes the criterion it claimed.
#   ev-good  commits real work and reports itself honestly — US-1 marked passing by the
#            agent (empty notes, deliberately: self-reported work owes no ceremony),
#            US-2 left false but WITH evidence in `notes` → promoted, verified, merged.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=ev GIT_AUTHOR_EMAIL=ev@test GIT_COMMITTER_NAME=ev GIT_COMMITTER_EMAIL=ev@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos" CHIEF_WORKTREE_ROOT="$WORK/wt"  # hermetic: don't touch ~/.chief
fail() { echo "EVIDENCE FAIL: $*" >&2; [ -f "$WORK/run.log" ] && tail -40 "$WORK/run.log" >&2
         [ -f "$WORK/repo/.chief/state/parallel/ev-bad.log" ] && tail -40 "$WORK/repo/.chief/state/parallel/ev-bad.log" >&2
         exit 1; }
command -v jq >/dev/null || fail "jq required"

# ── install chief from this checkout ──────────────────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# ── fake `claude`: behaviour keyed off which tasklist it was handed ────────────
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null                                   # drain the prompt
PRD=".chief/state/prd.json"                      # cwd = the worktree
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
mkdir -p out; printf 'impl %s\n' "$name" > "out/$name.txt"
if [ "$name" = "ev-good" ]; then
  # Honest self-report: US-1 marked passing by the agent itself (notes left empty on
  # purpose), US-2 left for chief to promote but carrying its evidence.
  t="$(mktemp)"
  jq '(.userStories[]|select(.id=="US-1").passes)=true
      | (.userStories[]|select(.id=="US-2").notes)="wrote out/ev-good.txt and re-ran the hook"' \
     "$PRD" > "$t" && mv "$t" "$PRD"
fi
git add -A >/dev/null 2>&1 || true
git commit -q -m "feat: US-1 - $name" >/dev/null 2>&1 || true
echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── scaffold a repo with the two tasklists + a verify hook that would PASS ─────
REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null
rm -f tasks/chief/example.json
cat > tasks/chief/ev-bad.json <<'JSON'
{ "project":"ev","branchName":"chief/ev-bad","description":"silent promotion",
  "iters":2,"dependsOn":[],"touches":["bad"],"warmup":[],
  "userStories":[
    {"id":"US-1","title":"file 82-some-work to completed/","description":"",
     "acceptanceCriteria":["the tasklist 82-some-work is filed under completed/"],"passes":false,"notes":""},
    {"id":"US-2","title":"reach GREEN acceptance","description":"",
     "acceptanceCriteria":["the baseline to beat is 77 failed"],"passes":false,"notes":""}
  ] }
JSON
cat > tasks/chief/ev-good.json <<'JSON'
{ "project":"ev","branchName":"chief/ev-good","description":"honest work",
  "iters":2,"dependsOn":[],"touches":["good"],"warmup":[],
  "userStories":[
    {"id":"US-1","title":"agent marks this one itself","description":"",
     "acceptanceCriteria":["out/ev-good.txt exists"],"passes":false,"notes":""},
    {"id":"US-2","title":"stale-false but evidenced","description":"",
     "acceptanceCriteria":["out/ev-good.txt exists"],"passes":false,"notes":""}
  ] }
JSON
printf '#!/usr/bin/env bash\nset -eu\necho "verify: (would pass)"\nexit 0\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "ev setup"

PATH="$WORK/fakebin:$PATH" "$CHIEF" run >"$WORK/run.log" 2>&1 || { cat "$WORK/run.log"; fail "run exited non-zero"; }
status() { cat "$REPO/.chief/state/parallel/$1.status" 2>/dev/null || echo MISSING; }

# ── 1. the silent promotion is caught, and nothing of it lands ────────────────
case "$(status ev-bad)" in UNVERIFIED*) ;; *) fail "expected UNVERIFIED for the evidence-free branch, got: '$(status ev-bad)'" ;; esac
git checkout -q main
[ ! -f out/ev-bad.txt ]                || fail "the evidence-free branch was merged to main"
[ -f tasks/chief/ev-bad.json ]         || fail "the evidence-free tasklist was retired"
[ ! -f tasks/chief/completed/ev-bad.json ] || fail "a completed record was written for an evidence-free run"

# ── 2. the operator is told WHAT was claimed, not that a count did not match ──
# The detail lands in the worker log (the run summary carries the status line).
LOG="$REPO/.chief/state/parallel/ev-bad.log"
[ -f "$LOG" ]                          || fail "no worker log at $LOG"
grep -q 'UNVERIFIED' "$WORK/run.log"   || fail "the run summary never surfaces the UNVERIFIED status"
grep -q '✗ US-1 — file 82-some-work to completed/' "$LOG" || fail "the failure never names the story (id + title)"
grep -q 'the tasklist 82-some-work is filed under completed/' "$LOG" \
  || fail "the failure never quotes the criterion the story claimed"
grep -q 'the baseline to beat is 77 failed' "$LOG"  || fail "only the first unevidenced story was reported"
# Not INCOMPLETE: the iteration budget did not run out, the evidence did, and the two
# are fixed by different things (raise `iters` vs. read what was claimed).
case "$(status ev-bad)" in *INCOMPLETE*) fail "reported as INCOMPLETE rather than UNVERIFIED" ;; *) ;; esac

# ── 3. honest work is NOT held back — no ceremony for a self-reported pass ────
case "$(status ev-good)" in MERGED*) ;; *) fail "the honest branch did not merge, got: '$(status ev-good)'" ;; esac
[ -f out/ev-good.txt ]                     || fail "the honest branch's work is not on main"
[ -f tasks/chief/completed/ev-good.json ]  || fail "the honest tasklist was not retired"

echo "EVIDENCE PASS — a force-passed story with empty notes fails as UNVERIFIED (story + criterion quoted); self-reported and evidenced work still merges"
