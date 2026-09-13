#!/usr/bin/env bash
# test/zone-friction.sh — THE DISTINCTION THIS WHOLE TASKLIST EXISTS FOR, through the
# real driver, plus the measurement that says whether it was worth making.
# (engine/surface.sh · engine/zones.sh · scripts/zone-friction.sh ·
#  docs/reference/overlap-zones.md)
#
# tasks/chief/910-the-approval-flow-earns-its-friction-back. On 2026-09-10 every
# `review` rule in two downstream registries was rewritten to `serialize` in one day,
# each file carrying a dated DISARMED banner: a `path:` glob cannot tell "added a
# routine consumer under a watched path" from "changed the surface that path guards",
# so every hold read as noise and every hold was approved unread. test/zone-surface.sh
# asserts the matcher's own output; this file asserts the OUTCOME, which is a different
# claim — "the rule does not match" and "the branch merged without anybody being asked"
# are not the same sentence, and only the second one is the feature.
#
#   PART A  THE DISCRIMINATION, END TO END. One registry, one run, two tasklists. The
#           branch that only adds a consumer under the watched path MERGES with nothing
#           asked and nothing written; the branch that renames a declaration in the same
#           directory is HELD, and the hold NAMES THE SURFACE — both signs of the rename,
#           by file and line — in all four report sites. One `chief approve` merges it.
#   PART B  THE MUTATION RUN. The same consumer fixture against a COPY of this engine
#           with the narrowing neutered: `surface_match` unevaluable, which is the
#           engine's own documented fall-back to the coarse `path:` rule — the pre-910
#           rule. That branch is HELD. Without this part PART A would be indistinguishable
#           from a test that never armed a zone at all.
#   PART C  THE MEASUREMENT, and that it is READ-ONLY. scripts/zone-friction.sh replays
#           a before/after registry pair over PART A's own merge history and reports both
#           directions — how many holds survive, how many are released. The repo it
#           measured is byte-identical afterwards: a corpus tool that mutates the corpus
#           is not a measurement.
#
# Hermetic: a scripted fake `claude` on PATH, temp prefixes ($CHIEF_PREFIX included),
# never touches the real ~/.chief. Drives bin/chief straight out of this checkout, so it
# tests uncommitted work.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rc=$?; rm -rf "$WORK"; exit "$rc"' EXIT
export GIT_AUTHOR_NAME=zf GIT_AUTHOR_EMAIL=zf@test GIT_COMMITTER_NAME=zf GIT_COMMITTER_EMAIL=zf@test
export CHIEF_PREFIX="$WORK/ch" CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
# The budget and the registry path both read from the ENVIRONMENT. An inherited value
# would quietly add a second hold to every branch below and PART A's "nothing was asked"
# would be asserting something else.
unset CHIEF_ZONES CHIEF_DIFF_BUDGET CHIEF_DIFF_BUDGET_LINES CHIEF_DIFF_BUDGET_FILES 2>/dev/null || true
CHIEF="$ROOT/bin/chief"
LOG=""
fail() { echo "ZONE-FRICTION FAIL: $*" >&2; [ -n "$LOG" ] && [ -f "$LOG" ] && tail -60 "$LOG" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"
export ZF_WORK="$WORK"

# THE REGISTRY, shared by both tasklists and by both parts. `lib/*.sh` is the watched
# path; the declarations inside it are the watched SURFACE. A `path:lib/*.sh` rule would
# hold both branches below — that is the defect being repaired, and PART B proves it by
# putting that rule back.
ZONES_CONF='review  surface:lib/*.sh:^[a-z_][a-z_0-9]*\(\)   the declared contracts, not their callers'

# ── the fake agent ────────────────────────────────────────────────────────────
# Per-tasklist behaviour, because the two branches have to differ in KIND and not in
# size: `consumer` writes a caller and edits a function BODY (the shape that produced
# the noise), `contract` renames a declaration (the shape the hold exists for). Neither
# touches the other's files, so both can merge — a rebase conflict here would end the
# test on the floor, one layer below the thing under test.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
: "${ZF_WORK:?}"
cat >/dev/null
PRD=".chief/state/prd.json"
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"; TRACKED="tasks/chief/$name.json"
n=$(( $(cat "$ZF_WORK/calls.$name" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$ZF_WORK/calls.$name"
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
[ -n "$id" ] || exit 0
case "$name" in
  contract*)
    # THE SURFACE ITSELF: a declaration removed and a declaration added. Both signs, in
    # one edit, because that is what a rename is and the hold has to be able to say so.
    cat > lib/api.sh <<'A'
#!/usr/bin/env bash
api_fetch() {
  echo read
}
A
    ;;
  *)
    # A ROUTINE CONSUMER: a new file under the same watched path that CALLS the surface,
    # plus a change to a function BODY in another watched file. The calls sit at column 0
    # on purpose — `api_read` is then a line the declaration regex must reject on the
    # strength of its `\(\)` alone, which is the escape trap engine/surface.sh documents.
    cat > "lib/use_$id.sh" <<'C'
#!/usr/bin/env bash
api_read
helper_run
C
    cat > lib/helper.sh <<'H'
#!/usr/bin/env bash
helper_run() {
  echo one
  echo two
}
H
    ;;
esac
for f in "$PRD" "$TRACKED"; do
  [ -f "$f" ] || continue
  t="$(mktemp)"; jq --arg id "$id" '(.userStories[]|select(.id==$id)|.passes)=true
    | (.userStories[]|select(.id==$id)|.notes)="artifact written; verify green"' "$f" > "$t" && mv "$t" "$f"
done
git add -A >/dev/null 2>&1 || true
git commit -q -m "feat: [$id] - story $id of $name" >/dev/null 2>&1 || true
if [ "$(jq '[.userStories[]|select(.passes==false)]|length' "$PRD")" = "0" ]; then echo "<promise>COMPLETE</promise>"; fi
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"

# ── the fixture, built by a function so PART B gets the SAME one ──────────────
repo_of() { printf '%s/repo.%s' "$WORK" "$1"; }
state_of() { cat "$(repo_of "$1")/.chief/state/parallel/$2.state" 2>/dev/null || echo MISSING; }
req_of()   { printf '%s/.chief/state/parallel/%s.zone-request.json' "$(repo_of "$1")" "$2"; }
log_of()   { printf '%s/.chief/state/parallel/%s.log' "$(repo_of "$1")" "$2"; }
on_main()  { ( cd "$(repo_of "$1")" && git show "main:$2" >/dev/null 2>&1 ); }

fixture() {   # $1 = arm name; rest = tasklist stems to author
  local arm="$1"; shift
  local repo; repo="$(repo_of "$arm")"
  mkdir -p "$repo/lib"
  ( cd "$repo"
    git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
    git commit -q --allow-empty -m init
    "$CHIEF" init >/dev/null
    rm -f tasks/chief/example.json
    printf '#!/usr/bin/env bash\nset -eu\necho "verify: ok"\nexit 0\n' > .chief/verify.sh
    chmod +x .chief/verify.sh
    printf '%s\n' "$ZONES_CONF" > .chief/zones.conf
    cat > lib/api.sh <<'A'
#!/usr/bin/env bash
api_read() {
  echo read
}
A
    cat > lib/helper.sh <<'H'
#!/usr/bin/env bash
helper_run() {
  echo one
}
H
    for t in "$@"; do
      jq -n --arg n "$t" '
        { project:"zf", branchName:("chief/" + $n), description:("friction fixture " + $n),
          iters:3, dependsOn:[], touches:["design-" + $n], warmup:[],
          userStories:[ { id:"US-1", title:("story of " + $n), description:"",
                          acceptanceCriteria:[("the " + $n + " change is written")], passes:false, notes:"" } ] }' \
        > "tasks/chief/$t.json"
    done
    git add -A && git commit -q -m setup ) >/dev/null
}

run_arm() {   # $1 = arm, $2 = log, $3 = tool root, rest = `chief run` args
  local arm="$1" log="$2" tool="$3"; shift 3
  ( cd "$(repo_of "$arm")" && PATH="$WORK/fakebin:$PATH" POLL_SECONDS=1 \
      "$tool/bin/chief" run "$@" ) >"$log" 2>&1
}

# ══ PART A — one registry, one run: the consumer merges, the contract is held ═
echo "zone-friction: PART A — a consumer under a watched path merges unheld; the surface it calls is held"
fixture fix consumer contract
LOG="$WORK/a.log"
run_arm fix "$LOG" "$ROOT" -p 2 consumer contract \
  || fail "A: a run that held a branch for approval exited non-zero (AWAITING-APPROVAL is not a failure)"

# --- the RELEASE: this is the hold that used to fire and no longer does. ------
[ "$(state_of fix consumer)" = "done" ] || fail "A: consumer state is '$(state_of fix consumer)', want done — a routine consumer under a watched path must not be held"
on_main fix "lib/use_US-1.sh" || fail "A: the consumer branch did not merge"
if [ -f "$(req_of fix consumer)" ]; then fail "A: the consumer branch wrote an approval request — nothing about the surface changed"; fi
if grep -q 'HELD BY THE MERGE POLICY LAYER' "$(log_of fix consumer)"; then fail "A: the consumer branch was held"; fi
# IT REALLY DID BRUSH THE WATCHED PATH — read off main, because the merged branch is
# deleted by the retire step. Without this the part proves nothing about granularity:
# a branch that never matched the glob would merge unheld under any rule at all.
( cd "$(repo_of fix)" && git show main:lib/helper.sh | grep -q 'echo two' ) \
  || fail "A: the consumer branch did not change a function BODY under lib/ — the fixture does not exercise the glob"
echo "   ok  consumer: touched lib/, merged, nothing asked, nothing written"

# --- the HOLD, and what it says. ---------------------------------------------
[ "$(state_of fix contract)" = "awaiting-approval" ] || fail "A: contract state is '$(state_of fix contract)', want awaiting-approval"
R="$(req_of fix contract)"; [ -s "$R" ] || fail "A: no approval request was written at $R"
grep -q 'verify: ok' "$(log_of fix contract)" || fail "A: the held branch's verify was not green — the hold must come AFTER the floor"
matched="$(jq -r '.zones[].matched' "$R")"
case "$matched" in *"lib/api.sh: -api_read() {"*) ;; *) fail "A: the hold does not name the REMOVED declaration (matched: $matched)" ;; esac
case "$matched" in *"lib/api.sh: +api_fetch() {"*) ;; *) fail "A: the hold does not name the ADDED declaration (matched: $matched)" ;; esac
[ "$(jq -r '.zones[0].zone' "$R")" = "surface:lib/*.sh:^[a-z_][a-z_0-9]*\(\)" ] \
  || fail "A: the request names zone '$(jq -r '.zones[0].zone' "$R")' — the matcher must survive the registry verbatim"
# The same detail in the other three report sites.
grep -q 'lib/api.sh: +api_fetch() {' "$(log_of fix contract)" || { tail -30 "$(log_of fix contract)" >&2; fail "A: the worker log does not name the surface"; }
grep -q 'lib/api.sh: +api_fetch() {' "$LOG" || fail "A: the run summary's awaiting-approval block does not name the surface"
( cd "$(repo_of fix)" && "$CHIEF" approve --list ) > "$WORK/list.txt" 2>&1 || fail "A: chief approve --list exited non-zero"
grep -q 'lib/api.sh: +api_fetch() {' "$WORK/list.txt" || { cat "$WORK/list.txt" >&2; fail "A: chief approve --list does not name the surface"; }
if grep -q '^  *consumer ' "$WORK/list.txt"; then fail "A: chief approve --list reported the branch that was never held"; fi
# AND THE ZONE ITSELF SURVIVES THE ROUND TRIP VERBATIM. The two sites that read the
# request file back render it through jq, and jq's `@tsv` escapes backslashes — of
# which a `surface:` ERE is made. Rendered `^[a-z_][a-z_0-9]*\\(\\)` it is a different
# regex (one matching a literal backslash), so an operator copying the zone out of
# `chief approve --list` into zones.conf gets a rule that cannot fire. Invisible until
# `surface:` existed: no `path:` glob contains a backslash.
for site in "$LOG" "$WORK/list.txt"; do
  grep -qF 'surface:lib/*.sh:^[a-z_][a-z_0-9]*\(\)' "$site" \
    || { grep -n 'surface:' "$site" >&2; fail "A: $site does not carry the zone verbatim"; }
  if grep -qF '\\(' "$site"; then grep -n 'surface:' "$site" >&2; fail "A: $site double-escaped the zone's ERE — the matcher it prints is not the matcher that fired"; fi
done
if on_main fix "lib/api.sh" && ( cd "$(repo_of fix)" && git show main:lib/api.sh | grep -q api_fetch ); then
  fail "A: the held branch was merged anyway"
fi
echo "   ok  contract: rebased, green, then HELD — both signs of the rename named in log, request, summary and --list"

# --- one approve releases it, and the merge is the ordinary one. -------------
( cd "$(repo_of fix)" && "$CHIEF" approve contract -m "the rename is the intended contract change" ) >/dev/null 2>&1 \
  || fail "A: chief approve contract failed"
LOG="$WORK/a2.log"
run_arm fix "$LOG" "$ROOT" contract || fail "A: the approved run exited non-zero"
[ "$(state_of fix contract)" = "done" ] || fail "A: contract state is '$(state_of fix contract)' after approval, want done"
( cd "$(repo_of fix)" && git show main:lib/api.sh | grep -q api_fetch ) || fail "A: the approved branch did not merge"
echo "   ok  one chief approve merged it — the flow is the existing one, asked once"

# ══ PART B — the mutation run: neuter the narrowing and the consumer is held ══
# The claim PART A makes is worth exactly what this part proves. A COPY of this engine
# (never `git show HEAD~N`: CI clones shallow) with surface_match reporting its diff
# UNEVALUABLE, which is the engine's own documented fail-closed fall-back to the coarse
# `path:` half — i.e. the pre-910 rule, restored. The same consumer fixture then holds.
echo "zone-friction: PART B — with the narrowing neutered, the consumer branch is held again (the defect, reproduced)"
mkdir -p "$WORK/unfixed"
cp -R "$ROOT/bin" "$ROOT/engine" "$ROOT/templates" "$WORK/unfixed/" || fail "B: could not copy the tool root"
cp "$ROOT/VERSION" "$WORK/unfixed/VERSION"
OLD="$WORK/unfixed/engine/surface.sh"
LC_ALL=C grep -q '^surface_match() {' "$OLD" \
  || fail "B: surface_match() is not where this file expects it — the 'unfixed' arm would silently be a copy of the FIXED engine. Update the rewrite below, do not delete the reproduction."
LC_ALL=C awk '
  /^surface_match\(\) \{/ {
    print; print "  return 2   # CHIEF-TEST-UNFIXED — no narrowing: fall back to the coarse path rule"
    inf = 1; next
  }
  inf && /^\}/ { print; inf = 0; next }
  inf { next }
  { print }' "$OLD" > "$OLD.new"
mv "$OLD.new" "$OLD"
LC_ALL=C grep -q 'CHIEF-TEST-UNFIXED' "$OLD" || fail "B: the neuter did not apply"
bash -n "$OLD" || fail "B: the neutered surface.sh does not parse"

fixture mut consumer
LOG="$WORK/b.log"
run_arm mut "$LOG" "$WORK/unfixed" consumer || fail "B: the neutered run exited non-zero"
[ "$(state_of mut consumer)" = "awaiting-approval" ] \
  || fail "B: the neutered engine did NOT hold the consumer branch (state '$(state_of mut consumer)') — PART A is not testing the discrimination it claims to test"
if on_main mut "lib/use_US-1.sh"; then fail "B: the neutered run held the branch and merged it anyway"; fi
grep -q 'holding on the path half alone' "$(log_of mut consumer)" \
  || { tail -30 "$(log_of mut consumer)" >&2; fail "B: the fall-back did not announce itself — a review gate that stops narrowing must say so"; }
echo "   ok  neutered: the same consumer branch is HELD on the coarse path rule — that is the hold that was approved unread"

# ══ PART C — the measurement, and that it changes nothing ════════════════════
# Both directions over a real corpus: PART A's own two merges, replayed through the
# gate's own matcher by scripts/zone-friction.sh.
echo "zone-friction: PART C — the friction is measured in both directions, read-only"
printf 'review  path:lib/*.sh   the watched path, coarse\n' > "$WORK/before.conf"
printf '%s\n' "$ZONES_CONF" > "$WORK/after.conf"
FIXREPO="$(repo_of fix)"
before_head="$( cd "$FIXREPO" && git rev-parse main )"
before_status="$( cd "$FIXREPO" && git status --porcelain )"
bash "$ROOT/scripts/zone-friction.sh" --repo "$FIXREPO" "$WORK/before.conf" "$WORK/after.conf" > "$WORK/friction.txt" 2>"$WORK/friction.err" \
  || { cat "$WORK/friction.err" >&2; fail "C: the measurement exited non-zero"; }
grep -qE 'held by BEFORE +2' "$WORK/friction.txt" \
  || { cat "$WORK/friction.txt" >&2; fail "C: the coarse rule did not hold both merges — the corpus does not contain the case being measured"; }
grep -qE 'held by AFTER +1' "$WORK/friction.txt" \
  || { cat "$WORK/friction.txt" >&2; fail "C: the narrowed rule did not hold exactly the one merge that changed the surface"; }
grep -qE 'RELEASED +1' "$WORK/friction.txt" \
  || { cat "$WORK/friction.txt" >&2; fail "C: the released direction is not reported"; }
grep -qE 'newly held +0' "$WORK/friction.txt" \
  || { cat "$WORK/friction.txt" >&2; fail "C: a narrowing reported holds the glob never caught"; }
grep -q 'VERDICT' "$WORK/friction.txt" || { cat "$WORK/friction.txt" >&2; fail "C: the measurement reports numbers but never judges them"; }
# The example carries the LINE, not just the sha: "this merge was held" is unreadable,
# and "this merge was held on lib/api.sh: -api_read() {" is the whole finding. The
# removed declaration is the first hit in diff order, which is what the example prints.
grep -q 'lib/api.sh: -api_read() {' "$WORK/friction.txt" \
  || { cat "$WORK/friction.txt" >&2; fail "C: the STILL HELD example does not name the surface that kept it"; }
# READ-ONLY. A corpus tool that mutates the corpus is not a measurement.
[ "$( cd "$FIXREPO" && git rev-parse main )" = "$before_head" ] || fail "C: the measurement moved the base branch"
[ "$( cd "$FIXREPO" && git status --porcelain )" = "$before_status" ] || fail "C: the measurement dirtied the repo it measured"
echo "   ok  2 held before, 1 after, 1 released, 0 newly held, judged — and the repo is untouched"

echo
echo "ZONE-FRICTION PASS — a routine consumer under a watched path merges with nobody asked, the declaration it calls is HELD with both signs of the rename named in all four report sites and released by one approve; with the narrowing neutered the same consumer is held again; and the friction is measured over real history in both directions without touching it"
