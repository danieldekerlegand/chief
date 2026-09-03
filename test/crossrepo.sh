#!/usr/bin/env bash
# test/crossrepo.sh — qualified cross-repo deps + the blocked-dep diagnostics.
#
# Two scaffolded repos, "upstream" and "downstream". The downstream tasklist
# depends on an upstream one via "upstream:<tasklist>". Asserts:
#   • the dep blocks while the upstream work is unmerged, with a reason that
#     names the upstream repo (not a bare "pending"),
#   • a run that launches nothing exits non-zero,
#   • it schedules once the upstream record exists — resolved by registry name,
#     by relative path, and by absolute path,
#   • unresolvable repo / misspelled tasklist / bare-name-that-lives-elsewhere
#     each produce their own distinguishable message,
#   • a dep qualified with the CURRENT repo is treated as a local dep.
#
# Scheduler-only: no agent runs, so this drives `chief run -n` plus one real
# `chief run` for the exit-code check. Uses the checkout in place (no install).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=xrepo GIT_AUTHOR_EMAIL=xrepo@test \
       GIT_COMMITTER_NAME=xrepo GIT_COMMITTER_EMAIL=xrepo@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"   # hermetic: never touch ~/.chief
CHIEF="$ROOT/bin/chief"
fail() { echo "XREPO FAIL: $*" >&2; exit 1; }

command -v jq >/dev/null || fail "jq is required"

scaffold() {   # $1 = repo dir
  mkdir -p "$1"; ( cd "$1"
    git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
    git commit -q --allow-empty -m init
    "$CHIEF" init >/dev/null 2>&1 || exit 1
    rm -f tasks/chief/example.json
    git add -A && git commit -q -m scaffold ) || fail "scaffold $1 failed"
}

tasklist() {   # $1 = repo, $2 = name, $3… = dependsOn entries
  local repo="$1" name="$2"; shift 2
  local deps; deps="$(printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(length>0))')"
  jq -n --arg n "$name" --argjson d "$deps" \
    '{project:"t",branchName:("chief/"+$n),description:"x",iters:1,dependsOn:$d,touches:[],warmup:[],
      userStories:[{id:"US-1",title:"t",description:"",acceptanceCriteria:["x"],passes:false,notes:""}]}' \
    > "$repo/tasks/chief/$name.json" || fail "could not write tasklist $name"
}

UP="$WORK/upstream"; DOWN="$WORK/downstream"
scaffold "$UP"; scaffold "$DOWN"
tasklist "$UP"   up-work
tasklist "$DOWN" down-work "upstream:up-work"
# Register both repos by name (what `chief init`/`chief run` normally does).
printf '%s\n%s\n' "$UP" "$DOWN" > "$CHIEF_REPOS"

plan() { ( cd "$DOWN" && "$CHIEF" run -n 2>&1 ); }
has()  { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# ── 1. Unmerged upstream: blocked, and the reason names the upstream repo ─────
out="$(plan)"
has "UNSCHEDULABLE" "$out"       || fail "unmerged cross-repo dep did not block:\n$out"
has "not merged in $UP yet" "$out" || fail "reason doesn't name the upstream repo:\n$out"

# ── 2. A real run that launches nothing must exit non-zero and say why ────────
out="$( cd "$DOWN" && "$CHIEF" run 2>&1 )"; rc=$?
[ "$rc" -ne 0 ]                  || fail "a run that launched nothing exited 0"
has "BLOCKED" "$out"             || fail "real run didn't report the block:\n$out"
has "Nothing ran" "$out"         || fail "real run didn't summarize the no-op:\n$out"
case "$out" in *"pending"*) fail "tasklist still reported as bare 'pending':\n$out" ;; esac

# ── 3. Misspelled upstream tasklist is distinguished from unmerged work ───────
tasklist "$DOWN" down-work "upstream:no-such-work"
has 'has no tasklist "no-such-work"' "$(plan)" || fail "typo'd tasklist not diagnosed as missing"

# ── 4. Unresolvable repo half ────────────────────────────────────────────────
tasklist "$DOWN" down-work "ghostrepo:up-work"
has 'repo "ghostrepo" could not be resolved' "$(plan)" || fail "unknown repo not diagnosed"

# ── 5. A bare dep that actually lives in another repo says so ────────────────
tasklist "$DOWN" down-work "up-work"
has 'qualify it: "<repo>:up-work"' "$(plan)" || fail "bare cross-repo dep didn't suggest qualifying"

# ── 6. Merge upstream → the dep resolves, by name AND by path ────────────────
mkdir -p "$UP/tasks/chief/completed"
jq -n '{mergedToMain:"deadbee"}' > "$UP/tasks/chief/completed/up-work.json"
rm -f "$UP/tasks/chief/up-work.json"
for spec in "upstream:up-work" "../upstream:up-work" "$UP:up-work"; do
  tasklist "$DOWN" down-work "$spec"
  has "wave 1" "$(plan)" || fail "dep '$spec' did not resolve after the upstream record landed"
done

# ── 7. An unstamped record does NOT satisfy the dep (mergedToMain is the test) ─
jq -n '{note:"no stamp"}' > "$UP/tasks/chief/completed/up-work.json"
tasklist "$DOWN" down-work "upstream:up-work"
has 'no "mergedToMain"' "$(plan)" || fail "record without mergedToMain wrongly satisfied the dep"
jq -n '{mergedToMain:"deadbee"}' > "$UP/tasks/chief/completed/up-work.json"

# ── 8. Self-qualified dep = a local dep (satisfiable within this run) ─────────
tasklist "$DOWN" local-a
tasklist "$DOWN" down-work "downstream:local-a"
out="$(plan)"
has ": local-a"   "$out" || fail "local-a should be scheduled:\n$out"
has "2 wave(s)"   "$out" || fail "self-qualified dep not treated as local ordering (expected 2 waves):\n$out"
case "$out" in *"local-a"*"down-work"*) ;; *) fail "down-work should follow local-a:\n$out" ;; esac

# ── 9. The MARKER LINK: `downstreamCounterpart` resolves through the SAME lookup ──
# A tasklist may declare the downstream tasklist that completes it. `chief lint`
# follows it with the resolver above (engine/crossrepo.sh), so a bad declaration gets
# the same sentence a bad dep edge does — and a counterpart named only in PROSE is
# not detected, which the gate says out loud rather than reporting clean.
counterpart() {   # $1 = repo, $2 = tasklist, $3 = jq value for the field (null = drop it)
  local tmp="$1/tasks/chief/$2.json.tmp"
  jq --argjson cp "$3" \
     'if $cp == null then del(.downstreamCounterpart) else .downstreamCounterpart = $cp end' \
     "$1/tasks/chief/$2.json" > "$tmp" && mv "$tmp" "$1/tasks/chief/$2.json" \
     || fail "could not set downstreamCounterpart on $2"
}
lint() { ( cd "$DOWN" && "$CHIEF" lint 2>&1 ); }

tasklist "$DOWN" down-work                       # drop the dep; this section is about the field
tasklist "$UP"   up-work                         # a live tasklist to point at

counterpart "$DOWN" down-work '["upstream:up-work"]'
out="$(lint)"
has "clean" "$out"          || fail "a resolvable counterpart was reported as a finding:\n$out"
# The "what the gate SAW" sentence carries BOTH declared links now (engine/claims.sh
# added the document-claim half), and this repo declares no claims — so the counterpart
# count is asserted where it actually appears rather than as a fragment that a second
# declaration silently splits in two.
has '1 "downstreamCounterpart" + 0 document-claim declaration(s) checked' "$out" \
                            || fail "lint did not report what it saw:\n$out"

counterpart "$DOWN" down-work '["ghostrepo:up-work"]'
out="$(lint)"
has 'repo "ghostrepo" could not be resolved' "$out" || fail "unresolvable counterpart repo not diagnosed:\n$out"

counterpart "$DOWN" down-work '["upstream:no-such-work"]'
out="$(lint)"
has 'has no tasklist "no-such-work"' "$out" || fail "counterpart with a bad stem not diagnosed:\n$out"

# A merged counterpart resolves too — the field points at the WORK, not at its state.
counterpart "$DOWN" down-work '["upstream:merged-work"]'
jq -n '{mergedToMain:"deadbee"}' > "$UP/tasks/chief/completed/merged-work.json"
has "clean" "$(lint)" || fail "a counterpart that has already merged should still resolve"

# PROSE IS NOT THE MECHANISM: the same reference in the description is invisible, and
# the gate says so instead of reporting a link it never checked.
counterpart "$DOWN" down-work null
tmp="$DOWN/tasks/chief/down-work.json"
jq '.description="DOWNSTREAM COUNTERPART: upstream:up-work"' "$tmp" > "$tmp.t" && mv "$tmp.t" "$tmp"
out="$(lint)"
has '0 "downstreamCounterpart" + 0 document-claim declaration(s) checked' "$out" \
    || fail "a prose-only counterpart must not be counted as a declaration:\n$out"
has "only in prose is invisible" "$out" \
    || fail "lint must state that prose counterparts are not detected:\n$out"

# ── 10. The CHECK: a counterpart that MERGED while its marker is still live ──
# The failure the field exists for. Four states, and only one of them is a finding.
shipped() { lint | grep '⚑' ; }

# (a) counterpart merged, marker live -> REPORTED, by name and with the merge sha, so
#     acting on it needs no second investigation.
counterpart "$DOWN" down-work '["upstream:merged-work"]'
out="$(shipped)"
has "down-work" "$out"                  || fail "a merged counterpart with a live marker was not reported:\n$(lint)"
has "upstream:merged-work" "$out"       || fail "the report does not name the counterpart:\n$out"
has "@deadbee" "$out"                   || fail "the report does not carry the merge sha:\n$out"

# (b) counterpart still in flight -> SILENT. The normal state of a marker whose
#     downstream work has not landed; reporting it would be noise.
tasklist "$UP" inflight-work                     # live upstream, no completed record
counterpart "$DOWN" down-work '["upstream:inflight-work"]'
[ -z "$(shipped)" ] || fail "an UNMERGED counterpart was reported as shipped:\n$(shipped)"

# (b′) a counterpart FILED without mergedToMain is unmerged too — it can satisfy no
#      dependency edge, and it is the retirement trap, not shipped work.
jq -n '{}' > "$UP/tasks/chief/completed/filed-work.json"
counterpart "$DOWN" down-work '["upstream:filed-work"]'
[ -z "$(shipped)" ] || fail "a completed record with no mergedToMain was reported as shipped:\n$(shipped)"

# (c) marker already retired -> SILENT even though the counterpart merged. The human acted.
counterpart "$DOWN" down-work '["upstream:merged-work"]'
tmp="$DOWN/tasks/chief/down-work.json"
jq '.supersededBy="upstream:merged-work"' "$tmp" > "$tmp.t" && mv "$tmp.t" "$tmp"
[ -z "$(shipped)" ] || fail "a retired marker (supersededBy set) was still reported:\n$(shipped)"
jq 'del(.supersededBy)' "$tmp" > "$tmp.t" && mv "$tmp.t" "$tmp"

# (d) a counterpart in a repo that is NOT checked out here DEGRADES: it is reported as
#     unresolvable, and every other marker is still checked. A partial checkout is the
#     common case, and it must not cost the rest of the findings.
tasklist "$DOWN" other-work
counterpart "$DOWN" other-work '["ghostrepo:whatever"]'
out="$(lint)"
has "could not be checked" "$out"       || fail "an unresolvable counterpart was not reported as such:\n$out"
has "ghostrepo" "$out"                  || fail "the unresolvable report does not name the repo:\n$out"
out="$(shipped)"
has "down-work" "$out"                  || fail "an unresolvable counterpart aborted the rest of the check:\n$(lint)"
[ "$(printf '%s\n' "$out" | grep -c '⚑')" = "1" ] || fail "expected exactly one shipped finding, got:\n$out"
rm -f "$DOWN/tasks/chief/other-work.json"

# ── 11. WIRED WHERE THE BACKLOG IS READ, and it REPORTS ──────────────────
# A check nobody runs catches nothing: all five of koine's shipped markers sat in
# `chief list` for months. So the same scan runs there — the row's reason is marked and
# the block underneath carries the sha and the retirement ORDERING — and it stays a
# report: neither `chief list`, `chief lint` nor a run's schedule changes because of it.
list() { ( cd "$DOWN" && "$CHIEF" list 2>&1 ); }
flags() { list | LC_ALL=C grep -c 'counterpart has MERGED' ; }

# (a) counterpart merged, marker live -> flagged in the backlog itself, with the sha
#     and the ordering that silently breaks a queue.
counterpart "$DOWN" down-work '["upstream:merged-work"]'
out="$(list)"
has "counterpart merged" "$out" || fail "chief list did not flag the marker row:\n$out"
has "downstream work has landed" "$out" || fail "chief list did not report the shipped counterpart:\n$out"
has "upstream:merged-work" "$out"      || fail "the list report does not name the counterpart:\n$out"
has "@deadbee" "$out"                  || fail "the list report does not carry the merge sha:\n$out"
has "repoint anything whose dependsOn names the" "$out" \
    || fail "the report does not state the retirement ORDERING:\n$out"
has 'no "mergedToMain" satisfies no' "$out" \
    || fail "the report does not name the retirement trap next to the finding:\n$out"
[ "$(flags)" = "1" ] || fail "expected exactly one finding in chief list, got $(flags):\n$out"

# It REPORTS. Retiring a marker is a judgement call, so nothing here may fail: both
# commands exit 0 and the marker is still scheduled like any other live tasklist.
( cd "$DOWN" && "$CHIEF" list >/dev/null 2>&1 ) || fail "chief list failed on a shipped-counterpart finding"
( cd "$DOWN" && "$CHIEF" lint >/dev/null 2>&1 ) || fail "chief lint failed on a shipped-counterpart finding"
( cd "$DOWN" && "$CHIEF" run -n >/dev/null 2>&1 ) || fail "a shipped counterpart made the schedule fail"
out="$(plan)"
has "down-work" "$out"        || fail "a shipped counterpart dropped the marker from the schedule:\n$out"
case "$out" in *UNSCHEDULABLE*) fail "a shipped counterpart made the marker unschedulable:\n$out" ;; esac

# (b) counterpart unmerged -> silent, and no block at all.
counterpart "$DOWN" down-work '["upstream:inflight-work"]'
out="$(list)"
[ "$(flags)" = "0" ]                   || fail "an UNMERGED counterpart was flagged in chief list:\n$out"
case "$out" in *"downstream work has landed"*) fail "chief list printed the block with nothing to report:\n$out" ;; esac
case "$out" in *"retire by hand"*) fail "the retirement note printed with no finding to act on:\n$out" ;; esac

# (c) marker already retired -> silent even though the counterpart merged.
counterpart "$DOWN" down-work '["upstream:merged-work"]'
tmp="$DOWN/tasks/chief/down-work.json"
jq '.supersededBy="upstream:merged-work"' "$tmp" > "$tmp.t" && mv "$tmp.t" "$tmp"
out="$(list)"
[ "$(flags)" = "0" ]                   || fail "a retired marker was flagged in chief list:\n$out"
has "down-work" "$out"                 || fail "the retired marker vanished from the backlog listing:\n$out"
jq 'del(.supersededBy)' "$tmp" > "$tmp.t" && mv "$tmp.t" "$tmp"

# (d) counterpart in a repo that is not checked out -> reported as UNCHECKED, under a
#     heading that does not claim work has landed, and nothing else is disturbed.
counterpart "$DOWN" down-work '["ghostrepo:whatever"]'
out="$(list)"
has "could not be checked" "$out"      || fail "chief list did not report an unresolvable counterpart:\n$out"
has "ghostrepo" "$out"                 || fail "the unresolvable report does not name the repo:\n$out"
[ "$(flags)" = "0" ]                   || fail "an unresolvable counterpart produced a false finding:\n$out"
case "$out" in *"downstream work has landed"*) fail "an unchecked counterpart was reported as landed work:\n$out" ;; esac
( cd "$DOWN" && "$CHIEF" list >/dev/null 2>&1 ) || fail "chief list failed on an unresolvable counterpart"

echo "XREPO PASS — cross-repo dep resolution (name/path/self) + blocked-dep diagnostics + counterpart lint + the merged-counterpart check, reported in chief list"
