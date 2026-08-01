#!/usr/bin/env bash
# test/touches-audit.sh — UNDER-TAGGED `touches` AUDIT (tasklist 70, US-4).
#
# `touches` fails asymmetrically. Over-tagging costs parallelism and shows up in
# the wave plan; UNDER-tagging — two tasklists that edit the same file while
# sharing no domain — is invisible until it burns a run on a rebase conflict, and
# even then nothing names the mis-tagged PAIR. The audit crosses two facts a run
# already has (who ran concurrently × what each branch changed) and reports the
# overlap. It is reporting only: no scheduling, merge or status change.
#
# One real `-p 3` run with a scripted fake `claude`, five tasklists:
#
#   ta-a  touches [dom-a]  edits shared.txt line 2    ─┐ co-scheduled, no shared
#   ta-b  touches [dom-b]  edits shared.txt line 30   ─┘ domain → THE FINDING
#   ta-c  touches [dom-c]  edits nothing shared         co-scheduled, no overlap
#   ta-d  touches [dom-de] edits shared2.txt line 10  ─┐ shares a domain, so the
#   ta-e  touches [dom-de] edits shared2.txt line 20  ─┘ scheduler serializes them
#
# Asserted: exactly ONE warning block, naming ta-a + ta-b, shared.txt and both
# touches arrays with the fix suggestion; silence for the correctly-tagged d/e
# pair and for the overlap-free ta-c; every tasklist still MERGED (the audit
# changed nothing). Edits are on far-apart lines so the overlap is real but the
# rebases stay clean — the exact case that is invisible today.
#
# A second run (ta-f + ta-g, one shared domain, one shared file) is the
# zero-findings control: a run with no under-tagging must print nothing new.
#
# Installs the COMMITTED state of this checkout (install.sh git-clones) — commit
# engine changes before trusting a green run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=ta GIT_AUTHOR_EMAIL=ta@test GIT_COMMITTER_NAME=ta GIT_COMMITTER_EMAIL=ta@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"     # hermetic: never touch ~/.chief
export STALL_LIMIT=1 HARD_MAX=3 POLL_SECONDS=1
REPO="$WORK/repo"
NAMES="ta-a ta-b ta-c ta-d ta-e"
fail() {
  echo "TOUCHES-AUDIT FAIL: $*" >&2
  [ -f "$WORK/run.log" ] && { echo "--- run.log"; tail -60 "$WORK/run.log"; } >&2
  exit 1
}
command -v jq  >/dev/null || fail "jq is required"
command -v git >/dev/null || fail "git is required"

# ── 1. Install chief from THIS checkout ───────────────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install.sh failed"
CHIEF="$BIN/chief"

# ── 2. The scripted agent ─────────────────────────────────────────────────────
# One turn: implement the single story, edit this tasklist's own file plus (for
# four of the five) ONE line of a file it shares with a sibling, flip the pass
# flags, commit, report COMPLETE. The per-tasklist line assignment is what makes
# the overlaps real and the rebases clean.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
cat >/dev/null                                   # drain the prompt on stdin
PRD=".chief/state/prd.json"                      # cwd = the worktree (set by the driver)
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"
TRACKED="tasks/chief/$name.json"
case "$name" in
  ta-a) SHARED=shared.txt;  LINE=2  ;;
  ta-b) SHARED=shared.txt;  LINE=30 ;;
  ta-d) SHARED=shared2.txt; LINE=10 ;;
  ta-e) SHARED=shared2.txt; LINE=20 ;;
  ta-f) SHARED=shared3.txt; LINE=5  ;;
  ta-g) SHARED=shared3.txt; LINE=25 ;;
  *)    SHARED=;            LINE=   ;;           # ta-c shares nothing
esac

id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
if [ -n "$id" ]; then
  mkdir -p out; printf 'impl %s by %s\n' "$id" "$name" > "out/$name.txt"
  if [ -n "$SHARED" ] && [ -f "$SHARED" ]; then
    awk -v n="$LINE" -v who="$name" 'NR==n{print who " edited line " n; next} {print}' \
      "$SHARED" > "$SHARED.tmp" && mv "$SHARED.tmp" "$SHARED"
  fi
  for f in "$PRD" "$TRACKED"; do
    [ -f "$f" ] || continue
    t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id).passes)=true' "$f" > "$t" && mv "$t" "$f"
  done
  git add -A >/dev/null 2>&1 || true
  git commit -q -m "feat: $id - $name" >/dev/null 2>&1 || true
fi

[ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ] && echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── 3. The fixture ────────────────────────────────────────────────────────────
mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null || fail "chief init failed"
rm -f tasks/chief/example.json
for f in shared.txt shared2.txt shared3.txt; do
  i=1; : > "$f"
  while [ "$i" -le 40 ]; do printf 'line %d\n' "$i" >> "$f"; i=$(( i + 1 )); done
done
mk() {   # mk <name> <touches-domain>
  jq -n --arg b "chief/$1" --arg d "$2" \
     '{project:"ta",branchName:$b,description:"touches-audit fixture",iters:2,
       dependsOn:[],touches:[$d],warmup:[],
       userStories:[{id:"US-1",title:"story",description:"",
                     acceptanceCriteria:["out/x.txt"],passes:false,notes:""}]}' \
     > "tasks/chief/$1.json"
}
mk ta-a dom-a; mk ta-b dom-b; mk ta-c dom-c; mk ta-d dom-de; mk ta-e dom-de
mk ta-f dom-fg; mk ta-g dom-fg          # the zero-findings control run (arm 5)
printf '#!/usr/bin/env bash\nset -eu\necho "verify: ok"\nexit 0\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "fixture"

# ── 4. The run ────────────────────────────────────────────────────────────────
# shellcheck disable=SC2086
( cd "$REPO" && PATH="$WORK/fakebin:$PATH" WT_ROOT="$WORK/wt" \
    "$CHIEF" run -p 3 $NAMES ) >"$WORK/run.log" 2>&1 || true

status_of() { cat "$REPO/.chief/state/parallel/$1.status" 2>/dev/null || echo MISSING; }
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }   # substring, SIGPIPE-safe

# The audit is REPORTING ONLY: the run must be exactly the run it always was.
for n in $NAMES; do
  case "$(status_of "$n")" in
    MERGED*) ;;
    *) fail "$n did not merge (status '$(status_of "$n")') — the fixture is meant to be a clean, fully-merged run" ;;
  esac
done

# The audit section of the summary, so an assertion can never match a tasklist
# name from the ordinary per-tasklist listing above it.
audit="$(awk '/Co-scheduled tasklists changed the same file/,/^===/' "$WORK/run.log")"
[ -n "$audit" ] || fail "the end-of-run summary has no under-tagged-touches audit section"
pairs="$(printf '%s\n' "$audit" | grep 'under-tagged touches' || true)"
n_pairs="$(printf '%s\n' "$pairs" | grep -c 'under-tagged touches' || true)"
[ "$n_pairs" = "1" ] || fail "expected exactly ONE warning block, got $n_pairs:
$pairs"

# 1) The finding — both names, the overlapping path, both touches arrays, the fix.
has WARNING "$pairs"  || fail "the finding is not flagged as a WARNING: $pairs"
has ta-a "$pairs"     || fail "the warning does not name ta-a: $pairs"
has ta-b "$pairs"     || fail "the warning does not name ta-b: $pairs"
has "· shared.txt" "$audit" \
  || fail "the warning does not list the overlapping path shared.txt:
$audit"
has "ta-a touches: [dom-a]" "$audit" || fail "the warning does not print ta-a's touches array:
$audit"
has "ta-b touches: [dom-b]" "$audit" || fail "the warning does not print ta-b's touches array:
$audit"
has "dependsOn" "$audit" || fail "the warning suggests no fix (shared domain / dependsOn):
$audit"

# 2) Silence for the control pair: ta-d + ta-e share dom-de, so the scheduler
#    never co-scheduled them — their identical overlap on shared2.txt is correct.
has shared2.txt "$audit" && fail "the audit warned about the CORRECTLY-tagged pair's file (shared2.txt):
$audit"
has ta-d "$audit" && fail "the audit named ta-d, which shares a touches domain with its only overlap:
$audit"
has ta-e "$audit" && fail "the audit named ta-e, which shares a touches domain with its only overlap:
$audit"

# 3) Silence for a co-scheduled pair with no file overlap.
has ta-c "$audit" && fail "the audit named ta-c, which overlaps with nobody:
$audit"

# 4) The same finding reaches the worker log at merge time (the last of the pair
#    to merge is the first moment both file sets exist).
wlogs="$(cat "$REPO/.chief/state/parallel/ta-a.log" "$REPO/.chief/state/parallel/ta-b.log" 2>/dev/null || echo)"
has "under-tagged touches" "$wlogs" \
  || fail "neither ta-a's nor ta-b's worker log reported the overlap at merge time"

# 5) A run with zero findings prints nothing new: ta-f + ta-g overlap on
#    shared3.txt but share dom-fg, so the scheduler serialized them.
( cd "$REPO" && PATH="$WORK/fakebin:$PATH" WT_ROOT="$WORK/wt" \
    "$CHIEF" run -p 3 ta-f ta-g ) >"$WORK/run2.log" 2>&1 || true
for n in ta-f ta-g; do
  case "$(status_of "$n")" in
    MERGED*) ;;
    *) fail "control run: $n did not merge (status '$(status_of "$n")')" ;;
  esac
done
grep -q 'under-tagged touches' "$WORK/run2.log" \
  && fail "a run whose only overlap is correctly tagged printed a warning:
$(tail -30 "$WORK/run2.log")"
grep -q 'Co-scheduled tasklists changed the same file' "$WORK/run2.log" \
  && fail "the audit printed its header with zero findings"

echo "TOUCHES-AUDIT PASS — a co-scheduled pair sharing no touches domain that edited the same file is reported by name, path and touches arrays in the run summary and at merge time; correctly-tagged and non-overlapping pairs stay silent, and nothing about the run changed"
