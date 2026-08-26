#!/usr/bin/env bash
# test/retire-negative.sh — `chief retire --negative`: the operator's path out of a
# tasklist whose answer was NO, and the three ways it must REFUSE.
#
# The incident: cuneiform `283-nixos-bare-metal-vpn-topology-target` ended with its
# agent writing "It needs MANUAL RETIREMENT" into its notes. There was no command for
# that, so the ask had nowhere to land.
#
# THE MUTATION IS THE TEST. Four tasklists, byte-identical apart from the thing being
# mutated, run through the SAME command:
#   rn-neg     delivered story passes, remaining story declares `terminalFalse` and
#              records its measurement            -> RETIRED, finding citable in the record
#   rn-open    the same tasklist with the declaration REMOVED (ordinary unfinished
#              story)                             -> REFUSED, and the story is named
#   rn-inert   the same tasklist with the MEASUREMENT removed (declared, never tried)
#                                                 -> REFUSED, and the story is named
#   rn-allpass every story passes, nothing negative -> REFUSED (that tasklist retires
#              by MERGING; this command is not that path)
# A retirement path that cannot be shown to refuse is a way to lose work, so each
# refusal is asserted to leave the tasklist exactly where it was.
#
# Plus the RETIREMENT TRAP, which is the second way this command can lose work: a
# completed/ record with no `mergedToMain` satisfies no dependency edge, so filing one
# under a live dependent blocks that dependent forever. Asserted both ways — refused
# while the dependent points at it, and stamped with a sha when the work IS in main.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=rn GIT_AUTHOR_EMAIL=rn@test GIT_COMMITTER_NAME=rn GIT_COMMITTER_EMAIL=rn@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos" CHIEF_WORKTREE_ROOT="$WORK/wt"  # hermetic
fail() { echo "RETIRE FAIL: $*" >&2; [ -f "$WORK/out" ] && sed 's/^/    /' "$WORK/out" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

# ── install chief from this checkout ─────────────────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# ── a repo with the four tasklists ───────────────────────────────────────────
REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null
rm -f tasks/chief/example.json

FINDING='Ran the commission->deploy flow: verdict maas-client-absent, 0 call sites across core/ services/ apps/. Do this instead: land a MaaS client in services/ first.'
# $1 = name · $2 = declare terminalFalse on US-2 · $3 = record a measurement on US-2 ·
# $4 = US-2 passes
mktasklist() {
  jq -n --arg n "$1" --argjson decl "$2" --arg notes "$3" --argjson pass "$4" --arg f "$FINDING" '
    {project:"rn", branchName:("chief/"+$n), description:"retire on a negative",
     iters:2, dependsOn:[], touches:[$n], warmup:[],
     userStories:[
       {id:"US-1", title:"build the seam", description:"",
        acceptanceCriteria:["the seam exists"], passes:true, notes:"built the seam; 3 checks green"},
       ({id:"US-2", title:"VERIFY the commission->deploy flow, honestly", description:"",
         acceptanceCriteria:["report whether the flow completes end to end"],
         passes:$pass, notes:(if $notes == "yes" then $f else "" end)}
        + (if $decl == 1 then {terminalFalse:true} else {} end))]}' > "tasks/chief/$1.json"
}
mktasklist rn-neg     1 yes false     # declared + measured  -> retire
mktasklist rn-open    0 yes false     # no declaration       -> refuse
mktasklist rn-inert   1 no  false     # declared, unmeasured -> refuse
mktasklist rn-allpass 0 no  true      # nothing negative     -> refuse
jq '.userStories |= map(if .id=="US-2" then .notes="every check green, 7 passed" else . end)' \
  tasks/chief/rn-allpass.json > "$WORK/t" && mv "$WORK/t" tasks/chief/rn-allpass.json
printf '#!/usr/bin/env bash\nexit 0\n' > .chief/verify.sh; chmod +x .chief/verify.sh
git add -A && git commit -q -m "rn setup"
"$CHIEF" lint >/dev/null 2>&1 || fail "the fixtures do not lint clean"

run() { "$CHIEF" "$@" >"$WORK/out" 2>&1; echo $?; }

# ── 0. --negative is required. This command has exactly one job. ─────────────
[ "$(run retire rn-neg)" != 0 ] || fail "a bare 'chief retire' retired something without --negative"
grep -q -- '--negative is required' "$WORK/out" || fail "the refusal does not say --negative is required"
[ -f tasks/chief/rn-neg.json ] || fail "a rejected invocation still removed the tasklist"

# ── 1. THE THREE REFUSALS, each leaving the tasklist exactly where it was ────
# (a) ordinary unfinished work. The distinction is the whole point: this is not the
# same thing as a measured negative, and a command that cannot tell them apart is a
# way to bury incomplete work.
[ "$(run retire --negative rn-open)" != 0 ] || fail "an ordinary unfinished tasklist was RETIRED"
grep -q 'REFUSED' "$WORK/out"   || fail "the refusal of unfinished work does not say REFUSED"
grep -q 'US-2'   "$WORK/out"    || fail "the refusal does not name the story that caused it"
grep -q 'ordinary unfinished work' "$WORK/out" || fail "the refusal does not say WHY (no declaration)"
[ -f tasks/chief/rn-open.json ]             || fail "a refused tasklist was removed from the backlog"
[ ! -f tasks/chief/completed/rn-open.json ] || fail "a refused tasklist was filed to completed/"

# (b) declared, but nothing measured. Without this half the field is a way to mark hard
# stories complete: write the declaration, never do the work, retire.
[ "$(run retire --negative rn-inert)" != 0 ] || fail "a declaration with NO measurement was retired"
grep -q 'records NO measurement' "$WORK/out" || fail "the refusal does not say the declaration is inert"
grep -q 'US-2' "$WORK/out"                    || fail "the inert refusal does not name the story"
[ -f tasks/chief/rn-inert.json ]              || fail "the inert tasklist was removed from the backlog"
[ ! -f tasks/chief/completed/rn-inert.json ]  || fail "the inert tasklist was filed to completed/"

# (c) nothing terminated negative — an ordinary completion, which retires by MERGING.
[ "$(run retire --negative rn-allpass)" != 0 ] || fail "an all-passing tasklist was retired outside the merge path"
grep -q 'no story here terminated' "$WORK/out" || fail "the refusal does not say there was no negative"
[ -f tasks/chief/rn-allpass.json ]             || fail "the all-passing tasklist was removed from the backlog"

# ── 2. THE RETIREMENT TRAP — a live dependent, and no merge to point it at ───
# A completed/ record with no mergedToMain satisfies no dependency edge, so filing this
# one would block the dependent forever on a record that can never be stamped.
jq '.dependsOn=["rn-neg"]' tasks/chief/rn-open.json > "$WORK/t" && cp "$WORK/t" tasks/chief/rn-dep.json
jq '.branchName="chief/rn-dep" | .touches=["rn-dep"]' "$WORK/t" > tasks/chief/rn-dep.json
[ "$(run retire --negative rn-neg)" != 0 ] || fail "a tasklist with a live dependent and no merge was retired anyway"
grep -q 'rn-dep' "$WORK/out"       || fail "the trap refusal does not name the dependent"
grep -q 'mergedToMain' "$WORK/out" || fail "the trap refusal does not explain the edge it would block"
[ -f tasks/chief/rn-neg.json ]     || fail "the trapped tasklist was retired despite the refusal"
rm -f tasks/chief/rn-dep.json

# ── 3. THE DRY RUN reports the verdict and writes nothing ────────────────────
[ "$(run retire --negative -n rn-neg)" = 0 ] || fail "the dry run refused a retirable tasklist"
grep -q 'dry run' "$WORK/out"              || fail "the dry run does not say it wrote nothing"
grep -q 'maas-client-absent' "$WORK/out"   || fail "the dry run does not show the finding being retired"
[ -f tasks/chief/rn-neg.json ]             || fail "the dry run removed the tasklist"
[ ! -f tasks/chief/completed/rn-neg.json ] || fail "the dry run wrote a completed record"

# ── 4. THE RETIREMENT ITSELF ────────────────────────────────────────────────
# Its branch is now contained in main (the work landed), so the record can be stamped
# and there is no trap to warn about.
git branch chief/rn-neg main
[ "$(run retire --negative rn-neg)" = 0 ] || fail "a delivered-plus-measured-negative tasklist was not retired"
REC=tasks/chief/completed/rn-neg.json
[ -f "$REC" ]                     || fail "no completed/ record was filed"
[ ! -f tasks/chief/rn-neg.json ]  || fail "the tasklist is still live — it will be scheduled again"
grep -q 'US-2' "$WORK/out"        || fail "the report does not name the story that terminated negative"

# The ANSWER survives: `passes` is still false, because the answer really is false.
[ "$(jq -r '.userStories[]|select(.id=="US-2")|.passes' "$REC")" = false ] \
  || fail "the negative was rewritten to true in the completed record"
[ "$(jq -r '.userStories[]|select(.id=="US-1")|.passes' "$REC")" = true ] \
  || fail "the delivered story is not recorded as passing"
# The FINDING survives, in a form a successor tasklist can cite WITHOUT knowing the
# predicate: which story terminated negative, and what it found.
[ "$(jq -r '.retiredOnNegative.stories[0].id' "$REC")" = "US-2" ] \
  || fail "the record does not record WHICH story terminated negative"
jq -r '.retiredOnNegative.stories[0].finding' "$REC" | grep -q 'maas-client-absent' \
  || fail "the record does not carry the finding a successor tasklist would cite"
jq -r '.retiredOnNegative.stories[0].finding' "$REC" | grep -q 'Do this instead' \
  || fail "the closing action — the most valuable output of the tasklist — was dropped"
jq -r '.userStories[]|select(.id=="US-2")|.notes' "$REC" | grep -q 'maas-client-absent' \
  || fail "the story's own notes lost the finding"
# The work is in main, so the edge a dependent needs is stamped.
[ "$(jq -r '.mergedToMain // ""' "$REC")" != "" ] \
  || fail "the work is in main but the record carries no mergedToMain — a dependent would block forever"

# It is retired IN GIT, not just on disk — an uncommitted retirement is one `git
# checkout` away from coming back.
git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet \
  || fail "the retirement was left uncommitted in the working tree"
git -C "$REPO" log -1 --pretty=%s | grep -q 'retired on a NEGATIVE finding' \
  || fail "the retirement commit does not say what it was: $(git -C "$REPO" log -1 --pretty=%s)"

# ── 5. IT STOPS BEING DRIVEN, and saying so twice is not an error ────────────
PATH="$WORK/nobin:$PATH" "$CHIEF" run -n >"$WORK/out" 2>&1
grep -q 'rn-neg' "$WORK/out" && fail "a retired tasklist is still in the schedule"
[ "$(run retire --negative rn-neg)" = 0 ] || fail "retiring an already-retired tasklist is an error"
grep -q 'already retired' "$WORK/out"     || fail "the second retirement does not say it was already done"

# ── 6. THE UNMERGED CASE with nothing depending on it: filed, and SAID ───────
# 283's own shape — the branch never merged. It files, because nothing is waiting on
# the edge, and the report states plainly that the record satisfies no dependency.
mktasklist rn-solo 1 yes false
git add -A && git commit -q -m "rn-solo"
[ "$(run retire --negative rn-solo)" = 0 ] || fail "an unmerged negative with no dependents was refused"
grep -q 'NOT in main' "$WORK/out" || fail "the report does not say the work never reached main"
[ "$(jq -r '.mergedToMain // ""' tasks/chief/completed/rn-solo.json)" = "" ] \
  || fail "chief stamped a mergedToMain sha for work that is not in main"
[ "$(jq -r '.retiredOnNegative.merged' tasks/chief/completed/rn-solo.json)" = false ] \
  || fail "the record claims it merged"

# ── 7. THE DECLARATION AND THE MEASUREMENT LIVE IN DIFFERENT FILES ──────────
# 283's actual shape. The run recorded the finding (snapshot); the operator added the
# declaration to the tasklist afterwards, having been told to by the stop report.
# Neither file settles the story alone, and the union is what this command reads.
mktasklist rn-union 1 no false                       # declared here, nothing measured
mkdir -p .chief/state/snapshots
jq --arg f "$FINDING" 'del(.userStories[].terminalFalse)
   | .userStories |= map(if .id=="US-2" then .notes=$f else . end)' \
  tasks/chief/rn-union.json > .chief/state/snapshots/rn-union.json  # measured there, undeclared
git add -A && git commit -q -m "rn-union"
[ "$(run retire --negative rn-union)" = 0 ] \
  || fail "a story declared in the tasklist and measured in the run record was not retired"
grep -q 'snapshots/rn-union.json' "$WORK/out" \
  || fail "the report does not say which file supplied the measurement"
jq -r '.retiredOnNegative.stories[0].finding' tasks/chief/completed/rn-union.json \
  | grep -q 'maas-client-absent' || fail "the union dropped the finding the run recorded"

echo "RETIRE PASS — a delivered-plus-measured-negative tasklist retires with its finding citable in"
echo "              completed/; unfinished work, an unmeasured declaration, an all-passing tasklist"
echo "              and a trapped dependent are each REFUSED with the story named."
