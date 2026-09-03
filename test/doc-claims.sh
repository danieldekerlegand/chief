#!/usr/bin/env bash
# test/doc-claims.sh — the DOCUMENT CLAIM (engine/claims.sh) against the incident
# that motivated it, and against the ways a checker like it goes wrong.
#
# THE 49-MINUTE CASE, reconstructed. koine's KCS encoding-gate verification document
# recorded that three agora pressure tests had no encoding. agora encoded all three
# 49 minutes after that document was last written; koine did not learn for a week,
# repeated the claim in its promotability ladder, and carried it into two tasklists
# authored a week later. The obligation runs DOWNSTREAM-TO-UPSTREAM and nothing
# carried it — agora had no reason to know koine had written a gate against its tree.
# So: a document here, a claim about a path there, and the tree disagreeing.
#
# A checker that flags everything is as useless as one that flags nothing, and this
# one runs against sibling repos that legitimately drift, so the negative controls
# are the other half of the test:
#   • a claim that still HOLDS prints nothing — and the count sentence still proves
#     it was READ, or a silent checker would pass this by doing no work at all,
#   • a repo that is not checked out here reports as UNRESOLVABLE, never as a false
#     claim — a partial checkout must not read as a wall of stale documents,
#   • a repo declaring NO claims pays nothing: no registry, no jq, no output. That
#     is measured by counting the jq invocations the reader actually makes, not by
#     reading the absence of a line.
#
# Hermetic: two scaffolded repos under a temp dir, its own $CHIEF_RUNS/$CHIEF_REPOS,
# no agent (this is `chief lint` plus the module's own reader). Needs git + jq.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; export ROOT
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=claims GIT_AUTHOR_EMAIL=claims@test \
       GIT_COMMITTER_NAME=claims GIT_COMMITTER_EMAIL=claims@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"   # hermetic: never touch ~/.chief
CHIEF="$ROOT/bin/chief"
fail() { echo "CLAIMS FAIL: $*" >&2; exit 1; }
has()  { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
hasnt(){ case "$2" in *"$1"*) return 1 ;; *) return 0 ;; esac; }

command -v jq >/dev/null || fail "jq is required"

scaffold() {   # $1 = repo dir
  mkdir -p "$1"; ( cd "$1"
    git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
    git commit -q --allow-empty -m init
    "$CHIEF" init >/dev/null 2>&1 || exit 1
    rm -f tasks/chief/example.json
    git add -A && git commit -q -m scaffold ) || fail "scaffold $1 failed"
}

tasklist() {   # $1 = repo, $2 = name — lint returns early with no tasklists to read
  jq -n --arg n "$2" \
    '{project:"t",branchName:("chief/"+$n),description:"x",iters:1,dependsOn:[],touches:[],warmup:[],
      userStories:[{id:"US-1",title:"t",description:"",acceptanceCriteria:["x"],passes:false,notes:""}]}' \
    > "$1/tasks/chief/$2.json" || fail "could not write tasklist $2"
}

KOINE="$WORK/koine"; AGORA="$WORK/agora"
scaffold "$KOINE"; scaffold "$AGORA"
tasklist "$KOINE" ladder-work
printf '%s\n%s\n' "$KOINE" "$AGORA" > "$CHIEF_REPOS"

# The incident's real names. The document path is assembled from two pieces because a
# literal `<dir>/<file>.md` in a tracked file is a reference chief's own doc-link gate
# resolves against THIS repo, and this one names a document in koine.
DOCDIR="docs/reference"
DOC="$DOCDIR/kcs-encoding-gate-verification.md"
SCEN="console/src/kcs/scenarios"
ENCODED="$SCEN/resume-checkpoint.ts"          # agora encoded it; koine's doc says it does not exist
PROJECTION="console/src/kgp/projection.ts"    # the same failure with the sign reversed

mkdir -p "$KOINE/$DOCDIR"
cat > "$KOINE/$DOC" <<'MD'
# KCS encoding gate — verification

Three KCS pressure tests have no encoding. Three encodings now wait on nobody.
MD

# claims '<jq array>' — write the registry the module reads.
claims() { jq -n --argjson c "$1" '{claims:$c}' > "$KOINE/.chief/claims.json" \
             || fail "could not write the claims registry"; }
claim()  { jq -n --arg d "$1" --arg c "$2" --arg r "$3" --arg p "$4" \
             '{document:$d,claim:$c,repo:$r,path:$p}'; }
lint()   { ( cd "$KOINE" && "$CHIEF" lint 2>&1 ); }
flags()  { lint | LC_ALL=C grep -c '⚑' ; }

# ── 1. THE INCIDENT: a document says ABSENT, the downstream tree says otherwise ──
mkdir -p "$AGORA/$SCEN"
: > "$AGORA/$ENCODED"                                   # agora encoded it, 49 minutes later
claims "[$(claim "$DOC" absent agora "$ENCODED")]"

out="$(lint)"
has "⚑" "$out"                  || fail "the stale claim was not reported at all:\n$out"
has "$DOC" "$out"               || fail "the report does not name the DOCUMENT that made the claim:\n$out"
has "$ENCODED" "$out"           || fail "the report does not name the downstream PATH:\n$out"
has "is ABSENT" "$out"          || fail "the report does not state the claim that was made:\n$out"
has "it EXISTS" "$out"          || fail "the report does not say what the downstream tree shows:\n$out"
has "$AGORA/$ENCODED" "$out"    || fail "the report does not resolve the path in the other repo:\n$out"
has "does not support" "$out"   || fail "the finding has no heading naming what it is:\n$out"
has "read the downstream change FIRST" "$out" \
    || fail "the correction note did not print beside a finding:\n$out"
[ "$(flags)" = "1" ]            || fail "expected exactly one finding, got $(flags):\n$out"

# It REPORTS. Correcting a stale document is a judgement about somebody else's merge,
# so the lint that carries the finding still exits 0.
( cd "$KOINE" && "$CHIEF" lint >/dev/null 2>&1 ) || fail "chief lint failed on a stale-claim finding"

# ── 2. THE SIGN REVERSED: a deliverable believed to have LANDED that has not ────
# The KGP shape. Same mechanism, other predicate, so neither half can rot unnoticed.
claims "[$(claim "$DOC" present agora "$PROJECTION")]"
out="$(lint)"
has "is PRESENT" "$out"         || fail "a \"present\" claim was not reported:\n$out"
has "it is MISSING" "$out"      || fail "the report does not say the path is missing:\n$out"
has "$PROJECTION" "$out"        || fail "the report does not name the missing path:\n$out"

# ── 3. NEGATIVE CONTROL: claims that still HOLD produce NO output ───────────────
# Both predicates, both true. The count sentence is asserted in the same breath: a
# checker that silently read nothing would pass a silence assertion for free.
claims "[$(claim "$DOC" present agora "$SCEN"), $(claim "$DOC" absent agora "$SCEN/no-such-thing.ts")]"
out="$(lint)"
[ "$(flags)" = "0" ]            || fail "a claim that still holds was reported as a finding:\n$out"
hasnt "does not support" "$out" || fail "the finding heading printed with nothing to report:\n$out"
hasnt "could not be checked" "$out" || fail "a checkable claim was reported as unresolvable:\n$out"
hasnt "read the downstream change FIRST" "$out" \
    || fail "the correction note printed with nothing to correct:\n$out"
has "2 document-claim declaration(s) checked" "$out" \
    || fail "the two holding claims were not READ — the silence above proves nothing:\n$out"
has "clean" "$out"              || fail "holding claims disturbed the lint verdict:\n$out"

# ── 4. UNRESOLVABLE IS NOT A VIOLATION ─────────────────────────────────────────
# A sibling repo that is not checked out on this host is the common case, and it must
# not read as a false claim — nor may it cost the findings that CAN be checked.
claims "[$(claim "$DOC" absent ghostrepo "$ENCODED"), $(claim "$DOC" absent agora "$ENCODED")]"
out="$(lint)"
has "could not be checked" "$out" || fail "an unresolvable repo was not reported as such:\n$out"
has "ghostrepo" "$out"            || fail "the unresolvable report does not name the repo:\n$out"
[ "$(flags)" = "1" ]              || fail "an unresolvable repo aborted or inflated the scan:\n$out"

# A document that no longer exists is unresolvable too, never verified: a claim whose
# SUBJECT is gone has been checked by nobody.
claims "[$(claim "$DOCDIR/gone.md" absent agora "$ENCODED")]"
out="$(lint)"
has "no such document in this repo" "$out" || fail "a claim on a deleted document read as checked:\n$out"
[ "$(flags)" = "0" ]                       || fail "a missing document was reported as a violated claim:\n$out"

# ── 5. A DOCUMENT WITH NO DECLARED CLAIMS COSTS NOTHING ────────────────────────
# Almost every document will never declare one, so the measurement is the number of
# jq invocations the reader makes — not the absence of a line, which a broken reader
# also produces. A shimmed jq counts them, and the with-registry probe proves the
# counter is live before the without-registry probe is believed.
SHIM="$WORK/shim"; mkdir -p "$SHIM"; JQ_LOG="$WORK/jq.calls"; REAL_JQ="$(command -v jq)"
{ echo '#!/usr/bin/env bash'; printf 'echo x >> %s\n' "$JQ_LOG"; printf 'exec %s "$@"\n' "$REAL_JQ"; } > "$SHIM/jq"
chmod +x "$SHIM/jq"
probe() {   # -> how many times claims_records reached for jq
  : > "$JQ_LOG"
  PATH="$SHIM:$PATH" CHIEF_PROJECT="$KOINE" bash -c \
    '. "$ROOT/engine/crossrepo.sh"; . "$ROOT/engine/claims.sh"; claims_records >/dev/null' \
    || fail "the claims reader failed under the jq shim"
  wc -l < "$JQ_LOG" | tr -d ' '
}
claims "[$(claim "$DOC" absent agora "$ENCODED")]"
[ "$(probe)" -ge 1 ] || fail "the jq counter measured nothing with a registry present — the probe is dead"

rm -f "$KOINE/.chief/claims.json"
[ "$(probe)" = "0" ] || fail "a repo declaring no claims still paid for jq ($(probe) invocation(s))"
out="$(lint)"
[ "$(flags)" = "0" ]                || fail "a repo with no registry produced a finding:\n$out"
hasnt "does not support" "$out"     || fail "the finding heading printed with no registry at all:\n$out"
hasnt "could not be checked" "$out" || fail "a missing registry was reported as an unchecked claim:\n$out"
has "0 document-claim declaration(s) checked" "$out" \
    || fail "the gate did not say it saw no declarations:\n$out"

# And PROSE IS NOT THE MECHANISM, one register up from the counterpart rule: the same
# assertion written into the document's text is invisible, and the gate says so rather
# than reporting a document it never checked.
cat >> "$KOINE/$DOC" <<'MD'

agora console/src/kcs/scenarios/resume-checkpoint.ts does not exist.
MD
out="$(lint)"
[ "$(flags)" = "0" ] || fail "a claim made only in prose was somehow reported:\n$out"
has "named only in prose is invisible to this gate" "$out" \
    || fail "the gate does not state that a prose-only claim is undetected:\n$out"

echo "CLAIMS PASS — the 49-minute case reported by document+path, both predicates, holding claims silent, unresolvable kept apart, and no registry costing nothing"
