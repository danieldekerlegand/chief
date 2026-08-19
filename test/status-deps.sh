#!/usr/bin/env bash
# test/status-deps.sh — `chief status`'s verdict IS the scheduler's verdict.
#
# THE POINT OF THIS TEST. `chief status` reports which tasklists can start now. If
# that answer is computed by anything other than the code `chief run` launches on,
# the two drift and the report becomes worse than no report — it names work as
# startable that a real run then refuses to start. So this asserts AGREEMENT rather
# than output: for every live tasklist in a fixture repo, status's runnable/blocked
# verdict must match whether the driver would launch it.
#
# The driver's answer is read from its own dry run (`chief run -n`), which prints the
# schedule waves from deps_of/is_recorded_done. WAVE 1 is exactly "startable with
# nothing else finishing first", which is what runnable means; everything else —
# a later wave, or UNSCHEDULABLE — is blocked at report time. PARALLEL is set high
# so wave 1 is bounded by dependencies alone and never by concurrency.
#
# Also asserted here: the RETIREMENT TRAP (a dep pointing at a completed record with
# no mergedToMain is permanently blocked, and says so), and that malformed input
# degrades into a `problems` section instead of aborting the report.
#
# Hermetic: a scaffolded git repo in a temp dir, its own CHIEF_RUNS/CHIEF_REPOS.
# No agent runs — this is scheduler + reporting logic only.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=status GIT_AUTHOR_EMAIL=status@test \
       GIT_COMMITTER_NAME=status GIT_COMMITTER_EMAIL=status@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"   # hermetic: never touch ~/.chief
CHIEF="$ROOT/bin/chief"
fail() { echo "STATUS FAIL: $*" >&2; exit 1; }
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

command -v jq >/dev/null || fail "jq is required"

REPO="$WORK/proj"
mkdir -p "$REPO"; ( cd "$REPO"
  git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
  git commit -q --allow-empty -m init
  "$CHIEF" init >/dev/null 2>&1 || exit 1
  rm -f tasks/chief/example.json ) || fail "scaffold failed"
: > "$CHIEF_REPOS"

tasklist() {   # $1 = name, $2 = extra JSON object merged in, $3… = dependsOn entries
  local name="$1" extra="$2"; shift 2
  local deps; deps="$(printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(length>0))')"
  jq -n --arg n "$name" --argjson d "$deps" --argjson x "$extra" \
    '{project:"t",branchName:("chief/"+$n),description:"x",iters:1,dependsOn:$d,touches:[],warmup:[],
      userStories:[{id:"US-1",title:"t",description:"",acceptanceCriteria:["x"],passes:false,notes:""}]} + $x' \
    > "$REPO/tasks/chief/$name.json" || fail "could not write tasklist $name"
}
record() { jq -n --argjson x "$2" '$x' > "$REPO/tasks/chief/completed/$1.json"; }

mkdir -p "$REPO/tasks/chief/completed"
record 08-unstamped '{"note":"retired but never stamped"}'      # the retirement trap
record 09-merged    '{"mergedToMain":"deadbee"}'

tasklist 10-free       '{}'                                     # runnable: no deps
tasklist 11-on-live    '{}' 10-free                             # blocked: dep is live, unmerged
tasklist 12-on-merged  '{}' 09-merged                           # runnable: dep merged on disk
tasklist 13-trap       '{}' 08-unstamped                        # blocked FOREVER
tasklist 14-ghost      '{}' "ghostrepo:whatever"                # blocked: repo unresolvable
tasklist 15-parked     '{"parked":true}'                        # neither live nor scheduled
# Absent dependsOn: legal to the driver (`.dependsOn // []`), a schema problem worth
# naming. Built by hand because the generator above always writes the key.
jq -n '{project:"t",branchName:"chief/16-nodeps",description:"x",iters:1,touches:[],warmup:[],
        userStories:[{id:"US-1",title:"t",description:"",acceptanceCriteria:["x"],passes:false,notes:""}]}' \
  > "$REPO/tasks/chief/16-nodeps.json"
printf 'this is not json {{{\n' > "$REPO/tasks/chief/17-broken.json"

status()  { ( cd "$REPO" && "$CHIEF" status "$@" 2>&1 ); }
dryrun()  { ( cd "$REPO" && "$CHIEF" run -n -p 99 2>&1 ); }

OUT="$(status)"; DRY="$(dryrun)"
[ -n "$OUT" ] || fail "chief status printed nothing"

# ── 1. Malformed input degrades, it does not abort ───────────────────────────
has "17-broken" "$OUT"  || fail "the unparseable tasklist was dropped instead of reported:\n$OUT"
has "problems"  "$OUT"  || fail "no problems section despite malformed input:\n$OUT"
has "16-nodeps" "$OUT"  || fail "absent dependsOn not flagged:\n$OUT"
has "ghostrepo" "$OUT"  || fail "a dep naming a nonexistent repo was not flagged:\n$OUT"
# ...and the rest of the report still rendered.
has "remaining" "$OUT"  || fail "totals missing — the report aborted on bad input:\n$OUT"
has "completed" "$OUT"  || fail "completed records not reported:\n$OUT"

# ── 2. THE AGREEMENT ASSERTION ───────────────────────────────────────────────
# status's runnable set, from the names it lists under `runnable`.
section() {   # $1 = heading word — the indented names under it, until the next heading
  printf '%s\n' "$OUT" | awk -v h="$1" '
    $0 ~ "^ +" h " " { grab=1; next }
    grab && /^ {6}[^ ]/ { print $1; next }
    grab { grab=0 }' | sort
}
status_runnable="$(section runnable)"
status_blocked="$(section blocked)"

# The driver's runnable set: wave 1 of its own schedule.
driver_wave1="$(printf '%s\n' "$DRY" | sed -n 's/^  wave 1 ([0-9]*\/[0-9]*)://p' | tr ' ' '\n' | grep . | sort)"
[ -n "$driver_wave1" ] || fail "the driver's dry run printed no wave 1:\n$DRY"

# 17-broken is excluded from BOTH sides on purpose: jq cannot parse it, so the
# driver reads it as dependency-free and would launch it while status refuses to
# issue a verdict it cannot compute. That divergence is reported (assertion 1
# above), not papered over, and comparing it here would assert the wrong thing.
driver_wave1="$(printf '%s\n' "$driver_wave1" | grep -v '^17-broken$')"

[ "$status_runnable" = "$driver_wave1" ] || fail \
  "status's runnable set disagrees with what the driver would launch.
  status:  $(echo "$status_runnable" | tr '\n' ' ')
  driver:  $(echo "$driver_wave1"    | tr '\n' ' ')"

# Sanity: the agreement above must be over a NON-TRIVIAL set, or a bug that reported
# nothing as runnable would pass it.
for n in 10-free 12-on-merged 16-nodeps; do
  grep -qx "$n" <<<"$status_runnable" || fail "$n should be runnable but is not:\n$OUT"
done
for n in 11-on-live 13-trap 14-ghost; do
  grep -qx "$n" <<<"$status_blocked" || fail "$n should be blocked but is not:\n$OUT"
  grep -qx "$n" <<<"$driver_wave1"   && fail "$n is in the driver's wave 1 — the fixture is wrong"
done

# Every live tasklist the driver would NOT launch first is blocked in the report.
for n in $(printf '%s\n' "$status_runnable" "$status_blocked" | grep .); do
  if grep -qx "$n" <<<"$driver_wave1"; then
    grep -qx "$n" <<<"$status_runnable" || fail "$n is in the driver's wave 1 but status calls it blocked"
  else
    grep -qx "$n" <<<"$status_blocked"  || fail "$n is not in the driver's wave 1 but status calls it runnable"
  fi
done

# ── 3. Parked is a split, not a verdict ──────────────────────────────────────
has "parked" "$OUT" || fail "no parked split in the report:\n$OUT"
grep -qx "15-parked" <<<"$status_runnable$status_blocked" && fail "a parked tasklist was given a runnable/blocked verdict:\n$OUT"
has "15-parked" "$OUT" || fail "the parked tasklist vanished from the report:\n$OUT"

# ── 4. The retirement trap is named as PERMANENT, not merely waiting ─────────
BLK="$(status --blocked)"
has "13-trap" "$BLK"              || fail "--blocked does not list the trapped tasklist:\n$BLK"
has "08-unstamped" "$BLK"         || fail "--blocked does not NAME the blocking edge:\n$BLK"
has "PERMANENTLY BLOCKED" "$BLK"  || fail "a dep on an unstamped completed record was not called permanent:\n$BLK"
has "mergedToMain" "$BLK"         || fail "--blocked does not say WHY the record can't satisfy the edge:\n$BLK"
# ...and an ordinary unmerged edge is NOT called permanent.
printf '%s\n' "$BLK" | grep '11-on-live' | grep -q 'PERMANENTLY' \
  && fail "an ordinary unmerged dep was wrongly reported as a permanent stall:\n$BLK"

# ── 5. It reports state; it never grades it ─────────────────────────────────
( cd "$REPO" && "$CHIEF" status >/dev/null 2>&1 ) || fail "chief status exited non-zero on a backlog with problems in it"

# ── 6. Outside a chief repo it explains itself instead of dying ─────────────
out="$( cd "$WORK" && "$CHIEF" status 2>&1 )"; rc=$?
[ "$rc" = 0 ]                      || fail "chief status outside a repo exited $rc"
has "chief init" "$out"            || fail "chief status outside a repo gave no usable message: $out"
case "$out" in *"no .chief/config found"*) fail "chief status went through load_project's hard exit: $out" ;; esac

# ── 7. `chief list` is untouched ────────────────────────────────────────────
out="$( cd "$REPO" && "$CHIEF" list 2>&1 )"
has "10-free" "$out"   || fail "chief list stopped listing tasklists:\n$out"
has "09-merged" "$out" || fail "chief list stopped listing completed records:\n$out"

echo "STATUS PASS — chief status agrees with the scheduler ($(echo "$status_runnable" | wc -l | tr -d ' ') runnable, $(echo "$status_blocked" | wc -l | tr -d ' ') blocked), degrades on bad input, and names the retirement trap"
