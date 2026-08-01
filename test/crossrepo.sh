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

echo "XREPO PASS — cross-repo dep resolution (name/path/self) + blocked-dep diagnostics"
