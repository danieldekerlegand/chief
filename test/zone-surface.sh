#!/usr/bin/env bash
# test/zone-surface.sh — the `surface:<glob>:<ere>` matcher (engine/surface.sh +
# engine/zones.sh's dispatch · docs/reference/overlap-zones.md).
#
# tasks/chief/910-the-approval-flow-earns-its-friction-back. The thing being fixed is
# GRANULARITY, not the hold: a `path:` zone cannot tell "added a routine consumer under
# a watched path" from "changed the surface that path guards", so every hold read as
# noise and every hold was approved unread — and on 2026-09-10 every `review` rule in
# two downstream registries was rewritten to `serialize`. A narrowed matcher is only
# worth having if it makes exactly that distinction and breaks nothing that already
# works, so both halves are asserted here:
#
#   PART A  THE DISCRIMINATION. Against one registry and one base: a branch that only
#           adds a consumer under the watched path does NOT match; a branch that
#           rewrites a declaration in the same directory DOES, and the hit names the
#           file and the line rather than the glob.
#   PART B  BACKWARD COMPATIBILITY, pinned to exact output. A registry using only
#           `path:` and `touches:` produces the same TSV it produced before this
#           matcher existed, byte for byte; no registry at all still matches nothing;
#           and re-arming a disarmed rule is still the one-word `serialize` -> `review`
#           edit, with nothing else about the line changed.
#   PART C  A TYPO NEVER TAKES DOWN A RUN, and NOGLOB. Five ways to misspell the new
#           form are each reported on stderr and skipped while the good rule on the
#           next line still matches; an unreadable diff FAILS CLOSED onto the coarse
#           path rule rather than silently holding nothing; and a matcher token that
#           WOULD expand against the cwd is proved to expand and then proved not to.
#   PART D  THE SAME TYPO THROUGH THE REAL DRIVER: a run whose registry carries it
#           completes and merges, with the note in the worker log. Plus the property
#           test/overlap-zones.sh PART A guards at the other end — a repo with NO
#           zones.conf merges with nothing asked and nothing written.
#
# PARTS A-C source the two modules directly against a scratch repo: no driver, under a
# second, and the assertion is the matcher's own output rather than a log line. PART D
# is the one that needs a run, because "the rule was skipped" and "the run survived it"
# are different claims.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=zs GIT_AUTHOR_EMAIL=zs@test GIT_COMMITTER_NAME=zs GIT_COMMITTER_EMAIL=zs@test
export CHIEF_PREFIX="$WORK/ch" CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"
unset CHIEF_ZONES CHIEF_DIFF_BUDGET CHIEF_DIFF_BUDGET_LINES CHIEF_DIFF_BUDGET_FILES 2>/dev/null || true

note() { printf 'zone-surface: %s\n' "$*"; }
fail() { echo "ZONE-SURFACE FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

# ── the modules under test, sourced the way driver.sh sources them ───────────
# shellcheck source=/dev/null
source "$ROOT/engine/surface.sh"
# shellcheck source=/dev/null
source "$ROOT/engine/zones.sh"

# ══ the fixture: one watched directory, one declaration, two branches ═════════
# `engine/a.sh` is the watched surface. `consumer` adds a whole new file under the same
# directory and edits a function BODY — the shape that produced the noise. `contract`
# renames a declaration, which is the shape the hold exists for. Both change files the
# same `path:engine/` glob matches, which is the entire point.
REPO="$WORK/repo"
mkdir -p "$REPO/engine"
( cd "$REPO"
  git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
  cat > engine/a.sh <<'A'
#!/usr/bin/env bash
alpha() {
  echo one
}
beta() {
  echo two
}
A
  git add -A && git commit -q -m base

  git checkout -q -b consumer
  cat > engine/c.sh <<'C'
#!/usr/bin/env bash
# A routine consumer: it CALLS the surface, it does not declare one. The calls sit at
# column 0 deliberately — `alpha` is then a line the declaration regex must reject on
# the strength of its `\(\)` alone, which is what catches the ESCAPE trap: passed to
# awk as `-v re=...` instead of through ENVIRON, `^[a-z_][a-z_0-9]*\(\)` arrives as
# `^[a-z_][a-z_0-9]*()`, an empty group that matches this line and holds the branch.
alpha
beta
C
  cat > engine/a.sh <<'A'
#!/usr/bin/env bash
alpha() {
  echo one
}
beta() {
  echo two
  echo two-and-a-half
}
A
  git add -A && git commit -q -m "add a consumer"

  git checkout -q main
  git checkout -q -b contract
  cat > engine/a.sh <<'A'
#!/usr/bin/env bash
alpha2() {
  echo one
}
beta() {
  echo two
}
A
  git add -A && git commit -q -m "rename a declaration" )

CONF="$WORK/zones.conf"
cat > "$CONF" <<'CONF'
# the narrowed rule: the declarations in engine/, not everything under it
review     surface:engine/*.sh:^[a-z_][a-z_0-9]*\(\)   the function contracts two agents must not diverge on
CONF

changed() { git -C "$REPO" diff --name-only "main...$1"; }
match()   { surface_scope "$REPO" "main...$1"; zones_match review "$CONF" "$(changed "$1")" ""; }

# ══ PART A — the discrimination ══════════════════════════════════════════════
note "PART A — a consumer under the watched path passes; the declaration it calls holds"
# The premise first: the OLD rule cannot tell these apart. Both branches change files
# the coarse glob matches, so a `path:` zone holds both — if that were not true, the
# narrowed rule would have nothing to be better than.
COARSE="$WORK/coarse.conf"; printf 'review     path:engine/*.sh   the coarse rule\n' > "$COARSE"
for b in consumer contract; do
  surface_scope "$REPO" "main...$b"
  [ -n "$(zones_match review "$COARSE" "$(changed "$b")" "")" ] \
    || fail "the coarse path rule did not hold '$b' — the fixture does not reproduce the defect this narrows"
done
note "   premise: the coarse path:engine/*.sh rule holds BOTH branches"

OUT="$(match consumer)"
[ -z "$OUT" ] || fail "the consumer branch was HELD by a surface rule it never touched: $OUT"
# ...and not because the branch changed nothing the glob sees.
changed consumer | grep -q '^engine/' || fail "the consumer fixture changed nothing under engine/"
note "   ok  consumer branch (new file + a body edit under engine/): not held"

OUT="$(match contract)"
[ -n "$OUT" ] || fail "the contract branch was NOT held — a rewritten declaration is the surface"
HIT="$(printf '%s' "$OUT" | cut -f3)"
case "$HIT" in
  engine/a.sh:*alpha*) ;;
  *) fail "the hit is '$HIT' — it must name the FILE and the LINE that matched, not just the glob" ;;
esac
[ "$(printf '%s' "$OUT" | cut -f2)" = 'surface:engine/*.sh:^[a-z_][a-z_0-9]*\(\)' ] \
  || fail "the matched zone is reported as '$(printf '%s' "$OUT" | cut -f2)'"
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] || fail "one rule matched more than once"
note "   ok  contract branch (a renamed declaration): held, hit = $HIT"

# ══ PART B — the old syntax keeps its meaning ════════════════════════════════
note "PART B — path: and touches: are byte-identical, and the one-word re-arm still works"
OLD="$WORK/old.conf"
cat > "$OLD" <<'CONF'
review     path:engine/*.sh     the coarse rule
review     touches:engine       the tag rule
serialize  path:engine/         documented, not held
CONF
# EXACT output, not a grep: "behaves as it did today" is a claim about the whole line,
# including which zone is named and what it says matched.
surface_scope "$REPO" "main...consumer"
GOT="$(zones_match review "$OLD" "$(changed consumer)" "engine render")"
WANT="$(printf 'review\tpath:engine/*.sh\tengine/a.sh\tthe coarse rule\nreview\ttouches:engine\ttouches:engine\tthe tag rule')"
[ "$GOT" = "$WANT" ] || { printf 'got:\n%s\nwant:\n%s\n' "$GOT" "$WANT" >&2
  fail "an old-syntax registry no longer produces the output it produced before surface: existed"; }
# The same registry with NO scope set at all — the state every pre-feature caller was
# in — must give the same answer, or `surface:`'s plumbing has leaked into `path:`.
surface_scope "" ""
[ "$(zones_match review "$OLD" "$(changed consumer)" "engine render")" = "$WANT" ] \
  || fail "path:/touches: matching now depends on a surface scope being set"
note "   ok  path: and touches: unchanged, with and without a diff scope"

# No registry at all: zones_file finds nothing, and nothing matches.
[ -z "$(zones_file "$REPO")" ] || fail "zones_file invented a registry for a repo that declares none"
[ -z "$(zones_match review "" "$(changed contract)" "engine")" ] \
  || fail "a repo with no zones.conf matched a zone"
note "   ok  no zones.conf: nothing matched, nothing asked"

# THE ONE-WORD RE-ARM. A disarmed rule is `serialize`; re-arming it is the single word
# `review` and nothing else. Both spellings of the SAME line, diffed as one word.
DIS="$WORK/disarmed.conf"; ARM="$WORK/armed.conf"
printf 'serialize  surface:engine/*.sh:^[a-z_][a-z_0-9]*\\(\\)   the function contracts\n' > "$DIS"
sed 's/^serialize /review    /' "$DIS" > "$ARM"
[ "$(sed 's/^[a-z]*  *//' "$DIS")" = "$(sed 's/^[a-z]*  *//' "$ARM")" ] \
  || fail "re-arming changed more than the policy word"
surface_scope "$REPO" "main...contract"
[ -z "$(zones_match review "$DIS" "$(changed contract)" "")" ] || fail "a serialize rule held a branch"
[ -n "$(zones_match review "$ARM" "$(changed contract)" "")" ] || fail "the re-armed rule did not hold"
note "   ok  serialize -> review is still the whole re-arm, on a narrowed rule too"

# ══ PART C — a typo is reported and skipped; NOGLOB ══════════════════════════
note "PART C — five misspellings are each reported and skipped, and the good rule still fires"
BAD="$WORK/bad.conf"
cat > "$BAD" <<'CONF'
review     surfce:engine/*.sh:^alpha        misspelled kind
review     surface:engine/*.sh              no regex half at all
review     surface::^alpha                  no glob half
review     surface:engine/*.sh:[            an ERE that does not compile
revue      surface:engine/*.sh:^alpha       misspelled policy
review     surface:engine/*.sh:^[a-z_][a-z_0-9]*\(\)   the good rule, last
CONF
surface_scope "$REPO" "main...contract"
ERR="$WORK/bad.err"
GOT="$(zones_match review "$BAD" "$(changed contract)" "" 2>"$ERR")" \
  || fail "a malformed registry made zones_match exit non-zero — a typo must never take down a run"
[ "$(printf '%s\n' "$GOT" | grep -c .)" = 1 ] \
  || { cat "$ERR" >&2; fail "expected exactly the good rule to match, got: $GOT"; }
[ "$(grep -c '^zones: ' "$ERR")" = 5 ] || { cat "$ERR" >&2; fail "expected 5 notes on stderr, got $(grep -c '^zones: ' "$ERR")"; }
grep -q 'surface:<glob>:<ere>' "$ERR" || { cat "$ERR" >&2; fail "the note never names the form the operator should have used"; }
note "   ok  5 reported, 5 skipped, the good rule on the next line still held"

# FAIL CLOSED. With no readable diff the narrowing cannot be evaluated, and the answer
# to that is the coarse rule it refines — never no rule at all. A review gate that
# stops holding when git has a bad day has disarmed itself.
surface_scope "$REPO" "no-such-ref...also-not-a-ref"
ERR="$WORK/closed.err"
GOT="$(zones_match review "$CONF" "$(changed consumer)" "" 2>"$ERR")"
[ -n "$GOT" ] || { cat "$ERR" >&2; fail "an unevaluable surface rule held NOTHING — it must fall back to the path half"; }
grep -q 'could not be evaluated' "$ERR" || { cat "$ERR" >&2; fail "the fallback was silent"; }
note "   ok  unreadable diff: fell back to the path half and said so"

# NOGLOB. The splitter runs with `set -f` so a matcher survives word splitting as the
# literal pattern. The decoy below is a real file whose NAME is what the token would
# expand to, so the guard is the only thing standing between them — and the expansion
# is PROVED first, or this assertion would pass against any token at all.
GLOBDIR="$WORK/globdir"; mkdir -p "$GLOBDIR/surface:engine"
# The decoy names a file the `contract` branch never touched, so an expanded matcher
# would narrow onto the wrong file and match NOTHING — the failure is visible.
: > "$GLOBDIR/surface:engine/zzz.sh:^alpha2"
NG="$WORK/ng.conf"
printf 'review     surface:engine/%s.sh:^alpha2   noglob\n' '*' > "$NG"
EXPANDS="$( cd "$GLOBDIR" && set -- $(sed -n '1s/^review  *//p' "$NG") && printf '%s' "$1" )"
[ "$EXPANDS" != 'surface:engine/*.sh:^alpha2' ] \
  || fail "the decoy does not expand — this assertion would pass with the NOGLOB guard removed"
surface_scope "$REPO" "main...contract"
GOT="$( cd "$GLOBDIR" && zones_match review "$NG" "$(changed contract)" "" )"
[ -n "$GOT" ] || fail "the matcher was expanded against the cwd — NOGLOB did not hold"
[ "$(printf '%s' "$GOT" | cut -f2)" = 'surface:engine/*.sh:^alpha2' ] \
  || fail "the zone is reported as '$(printf '%s' "$GOT" | cut -f2)' — the pattern did not survive word splitting"
note "   ok  a token that provably expands survived the splitter as a literal"

# ══ PART D — the same typo, through the real driver ══════════════════════════
# PART C proved the matcher skips a misspelled rule. That is not the same claim as "a
# run survives one": the note goes to stderr from inside the merge gate, and a registry
# typo that aborted there would strand a green branch. So it is driven end to end.
note "PART D — a run whose registry carries a misspelled surface rule completes anyway"
CHIEF="$ROOT/bin/chief"
R2="$WORK/repo2"; S="$R2/.chief/state/parallel"
mkdir -p "$WORK/fakebin"
export ZS_WORK="$WORK"
cat > "$WORK/fakebin/claude" <<'FAKE'
#!/usr/bin/env bash
set -eu
: "${ZS_WORK:?}"
cat >/dev/null
PRD=".chief/state/prd.json"
name="$(jq -r '.branchName' "$PRD" | sed 's#^chief/##')"; TRACKED="tasks/chief/$name.json"
id="$(jq -r 'first(.userStories[]|select(.passes==false)).id // empty' "$PRD")"
[ -n "$id" ] || exit 0
out="out/$name/$id.txt"; mkdir -p "$(dirname "$out")"; echo "artifact" > "$out"
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

mkdir -p "$R2"
( cd "$R2"
  git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
  git commit -q --allow-empty -m init
  "$CHIEF" init >/dev/null
  rm -f tasks/chief/example.json
  printf '#!/usr/bin/env bash\nset -eu\necho "verify: ok"\nexit 0\n' > .chief/verify.sh
  chmod +x .chief/verify.sh
  cat > .chief/zones.conf <<'CONF'
review     surfce:out/*:^x                misspelled kind — reported, skipped, never fatal
review     surface:out/ok1/*.txt:^zzz     a narrowed rule this branch does not trip
serialize  path:out/                      documented, scheduled apart, merged as usual
CONF
  for t in ok1 ok2; do
    jq -n --arg n "$t" '
      { project:"zs", branchName:("chief/" + $n), description:("surface fixture " + $n),
        iters:2, dependsOn:[], touches:["design-" + $n], warmup:[],
        userStories:[ { id:"US-1", title:("story of " + $n), description:"",
                        acceptanceCriteria:[("out/" + $n + "/US-1.txt exists")], passes:false, notes:"" } ] }' \
      > "tasks/chief/$t.json"
  done
  git add -A && git commit -q -m setup )

LOG="$WORK/d1"; ( cd "$R2" && PATH="$WORK/fakebin:$PATH" POLL_SECONDS=1 "$CHIEF" run ok1 ) >"$LOG" 2>&1 \
  || { tail -40 "$LOG" >&2; fail "a run whose registry carries a misspelled surface rule exited non-zero"; }
[ "$(cat "$S/ok1.state" 2>/dev/null || echo MISSING)" = done ] \
  || { tail -40 "$S/ok1.log" 2>/dev/null >&2; fail "ok1 state is '$(cat "$S/ok1.state" 2>/dev/null)', want done"; }
( cd "$R2" && git show main:out/ok1/US-1.txt >/dev/null 2>&1 ) || fail "the branch never merged"
grep -q "zones: ignoring .* 'surfce:out/\*:\^x'" "$S/ok1.log" \
  || { grep -n 'zones:' "$S/ok1.log" >&2 || true; fail "the worker log does not report the skipped rule"; }
if grep -q 'HELD BY THE MERGE POLICY LAYER' "$S/ok1.log"; then fail "a narrowed rule the branch never tripped held it anyway"; fi
note "   ok  rule skipped and reported in the worker log; the branch merged"

# The other end of the same property, and the one test/overlap-zones.sh PART A guards
# at the merge phase: no registry at all is not a degraded registry. Nothing is read,
# nothing is said, nothing is written.
rm -f "$R2/.chief/zones.conf"
( cd "$R2" && git add -A && git commit -q -m "no registry" )
LOG="$WORK/d2"; ( cd "$R2" && PATH="$WORK/fakebin:$PATH" POLL_SECONDS=1 "$CHIEF" run ok2 ) >"$LOG" 2>&1 \
  || { tail -40 "$LOG" >&2; fail "a run in a repo with no zones.conf exited non-zero"; }
[ "$(cat "$S/ok2.state" 2>/dev/null || echo MISSING)" = done ] || fail "ok2 did not reach done with no registry"
if grep -q '^zones: ' "$S/ok2.log"; then fail "a repo with no zones.conf said something about zones"; fi
if ls "$S"/ok2.zone-*.json >/dev/null 2>&1; then fail "a repo with no zones.conf wrote an approval artifact"; fi
note "   ok  no zones.conf: merged with nothing read, nothing said, nothing written"

note "OK — the narrowed matcher discriminates, the old syntax is untouched, a typo is survivable"
