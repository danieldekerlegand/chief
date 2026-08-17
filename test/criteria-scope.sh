#!/usr/bin/env bash
# test/criteria-scope.sh — a criterion that names ANOTHER repo must fail the tasklist
# before a single agent turn is spent, and honest work must not pay for it.
#
# The failure it guards against (2026-08-16/17): cuneiform:346/US-3 asked a cuneiform
# worktree to file `argos:82` under completed/, and 347/US-4 asked it to unpark
# `argos:90`. Neither is doable from where the run executes — and both PASSED,
# because nothing ever read the criterion.
#
# Four tasklists, one run, one fake agent — the gate and its escape hatch at once:
#   sc-ref       a criterion naming `argos:82`         → UNSATISFIABLE, agent never run
#   sc-path      a criterion naming `argos/tasks/…`    → UNSATISFIABLE (sibling checkout)
#   sc-declared  the SAME criterion as sc-ref, with "crossRepo":["argos"] → merges
#   sc-clean     ordinary local criteria               → merges (no false positive)
# plus the authoring-time half: `chief lint` fails on the undeclared one and passes
# on the declared one, and `chief gen` WARNS while still generating.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=sc GIT_AUTHOR_EMAIL=sc@test GIT_COMMITTER_NAME=sc GIT_COMMITTER_EMAIL=sc@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos" CHIEF_WORKTREE_ROOT="$WORK/wt"  # hermetic: don't touch ~/.chief
fail() { echo "SCOPE FAIL: $*" >&2; [ -f "$WORK/run.log" ] && tail -40 "$WORK/run.log" >&2
         [ -f "$WORK/repo/.chief/state/parallel/sc-ref.log" ] && tail -30 "$WORK/repo/.chief/state/parallel/sc-ref.log" >&2
         exit 1; }
command -v jq >/dev/null || fail "jq required"

# ── install chief from this checkout ──────────────────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# ── a SIBLING checkout next to the project — the `argos/tasks/…` half of the rule ──
mkdir -p "$WORK/argos"; git -C "$WORK/argos" init -q 2>/dev/null || fail "could not init the sibling repo"
# `chief`, `koine`, `agora` as siblings too. `chief` is the one that matters: every
# tasklist in every repo has branchName "chief/NN-slug", so without the own-namespace
# carve-out the sibling rule reads a repo citing ITS OWN branches as cross-repo work.
# That misfire produced 83 findings across 14 real repos, none of them real.
for sib in chief koine agora cuneiform formant; do
  mkdir -p "$WORK/$sib"; git -C "$WORK/$sib" init -q 2>/dev/null || fail "could not init sibling $sib"
done

# ── fake `claude`: records every tasklist it was ever handed ──────────────────
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<FAKE
#!/usr/bin/env bash
set -eu
cat >/dev/null                                   # drain the prompt
PRD=".chief/state/prd.json"                      # cwd = the worktree
name="\$(jq -r '.branchName' "\$PRD" | sed 's#^chief/##')"
echo "\$name" >> "$WORK/agent-turns.txt"         # the ledger the gate must keep empty
mkdir -p out; printf 'impl %s\n' "\$name" > "out/\$name.txt"
t="\$(mktemp)"; jq '.userStories |= map(.passes=true | .notes="did the work and re-ran the hook")' "\$PRD" > "\$t" && mv "\$t" "\$PRD"
git add -A >/dev/null 2>&1 || true
git commit -q -m "feat: US-1 - \$name" >/dev/null 2>&1 || true
echo "<promise>COMPLETE</promise>"
exit 0
FAKE
chmod +x "$WORK/fakebin/claude"
: > "$WORK/agent-turns.txt"

# ── scaffold the project ──────────────────────────────────────────────────────
REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null
rm -f tasks/chief/example.json
cat > tasks/chief/sc-ref.json <<'JSON'
{ "project":"sc","branchName":"chief/sc-ref","description":"fold the neighbours work",
  "iters":2,"dependsOn":[],"touches":["ref"],"warmup":[],
  "userStories":[
    {"id":"US-3","title":"file argos:82 to completed/","description":"",
     "acceptanceCriteria":["the tasklist `argos:82` is filed under `completed/` with mergedToMain set"],"passes":false,"notes":""}
  ] }
JSON
cat > tasks/chief/sc-path.json <<'JSON'
{ "project":"sc","branchName":"chief/sc-path","description":"unpark the neighbour",
  "iters":2,"dependsOn":[],"touches":["path"],"warmup":[],
  "userStories":[
    {"id":"US-4","title":"unpark the parked tasklist","description":"",
     "acceptanceCriteria":["`argos/tasks/chief/90-seam.json` no longer reads parked:true"],"passes":false,"notes":""}
  ] }
JSON
cat > tasks/chief/sc-declared.json <<'JSON'
{ "project":"sc","branchName":"chief/sc-declared","description":"cross-repo work, declared",
  "iters":2,"dependsOn":[],"touches":["declared"],"warmup":[],"crossRepo":["argos"],
  "userStories":[
    {"id":"US-3","title":"file argos:82 to completed/","description":"",
     "acceptanceCriteria":["the tasklist `argos:82` is filed under `completed/` with mergedToMain set"],"passes":false,"notes":""}
  ] }
JSON
cat > tasks/chief/sc-clean.json <<'JSON'
{ "project":"sc","branchName":"chief/sc-clean","description":"ordinary local work",
  "iters":2,"dependsOn":[],"touches":["clean"],"warmup":[],
  "userStories":[
    {"id":"US-1","title":"local paths only","description":"",
     "acceptanceCriteria":["`out/sc-clean.txt` exists and `docs/reference/verify-hook.md` still resolves","the hermetic suite never touches your real ~/.chief; pass/fail is reported by test/all.sh"],"passes":false,"notes":""}
  ] }
JSON
cat > tasks/chief/sc-ownbranch.json <<'JSON'
{ "project":"sc","branchName":"chief/sc-ownbranch","description":"cites its own branches and lists repos in prose",
  "iters":2,"dependsOn":[],"touches":["own"],"warmup":[],
  "userStories":[
    {"id":"US-1","title":"cite this repo own branches","description":"",
     "acceptanceCriteria":["the index that `chief/33-collab-community-browser` mounts against is written on sync, per `chief/60` and the convention `chief/NN-slug`","the fabric spans koine/agora and argos/cuneiform/formant, named in prose rather than as paths"],"passes":false,"notes":""}
  ] }
JSON
cat > tasks/chief/sc-colon.json <<'JSON'
{ "project":"sc","branchName":"chief/sc-colon","description":"the colon form is a real cross-repo reference",
  "iters":2,"dependsOn":[],"touches":["colon"],"warmup":[],
  "userStories":[
    {"id":"US-1","title":"depend on the chief repo tasklist","description":"",
     "acceptanceCriteria":["the builder consumes the machinery `chief:290` produces"],"passes":false,"notes":""}
  ] }
JSON
printf '#!/usr/bin/env bash\nset -eu\necho "verify: (would pass)"\nexit 0\n' > .chief/verify.sh
chmod +x .chief/verify.sh
git add -A && git commit -q -m "sc setup"

# ── authoring time: lint fails on the undeclared one, passes on the rest ──────
"$CHIEF" lint sc-declared >"$WORK/lint-ok.log" 2>&1 \
  || { cat "$WORK/lint-ok.log"; fail "chief lint rejected a DECLARED cross-repo tasklist"; }
"$CHIEF" lint sc-clean >>"$WORK/lint-ok.log" 2>&1 \
  || { cat "$WORK/lint-ok.log"; fail "chief lint rejected an ordinary local tasklist"; }
if "$CHIEF" lint sc-ref >"$WORK/lint-bad.log" 2>&1; then
  cat "$WORK/lint-bad.log"; fail "chief lint passed a criterion naming another repo"
fi
grep -q 'argos:82' "$WORK/lint-bad.log" || fail "chief lint never names the offending reference"
grep -q 'crossRepo' "$WORK/lint-bad.log" || fail "chief lint never names the escape hatch"
# The own-branch namespace and prose repo-lists are NOT cross-repo work. `chief/60` is a
# branch in THIS repo; `koine/agora` is prose. Only the colon form crosses a repo boundary.
"$CHIEF" lint sc-ownbranch >"$WORK/lint-own.log" 2>&1 \
  || { cat "$WORK/lint-own.log"; fail "chief lint flagged a repo citing its OWN chief/NN branches"; }
if "$CHIEF" lint sc-colon >"$WORK/lint-colon.log" 2>&1; then
  cat "$WORK/lint-colon.log"; fail "chief lint passed the colon form chief:290, which IS cross-repo"
fi
grep -q 'chief:290' "$WORK/lint-colon.log" || fail "chief lint never names the colon-form reference"

# ── authoring time: chief gen WARNS but still generates ──────────────────────
cat > "$WORK/roadmap.json" <<'JSON'
{ "phases":[ { "name":"P","items":[
    {"title":"Retire the neighbour tasklist","description":"File argos:82 under completed/ once it merges."},
    {"title":"Declared neighbour work","description":"File argos:82 under completed/ once it merges.","crossRepo":["argos"]}
] } ] }
JSON
"$CHIEF" gen "$WORK/roadmap.json" --out "$WORK/gen-out" >"$WORK/gen.log" 2>&1 \
  || { cat "$WORK/gen.log"; fail "chief gen refused a roadmap it should only warn about"; }
grep -q 'warning' "$WORK/gen.log"  || fail "chief gen never warned about the cross-repo criterion"
grep -q 'argos'   "$WORK/gen.log"  || fail "chief gen never named the repo it warned about"
[ "$(grep -c '✗' "$WORK/gen.log")" = 1 ] || fail "chief gen warned about the DECLARED item too"
ls "$WORK/gen-out"/*.json >/dev/null 2>&1 || fail "chief gen warned and then generated nothing"
jq -e '.crossRepo == ["argos"]' "$(grep -l 'crossRepo' "$WORK/gen-out"/*.json | head -1)" >/dev/null \
  || fail "chief gen dropped the crossRepo declaration from the generated tasklist"

# ── run time ─────────────────────────────────────────────────────────────────
PATH="$WORK/fakebin:$PATH" "$CHIEF" run >"$WORK/run.log" 2>&1 || { cat "$WORK/run.log"; fail "run exited non-zero"; }
status() { cat "$REPO/.chief/state/parallel/$1.status" 2>/dev/null || echo MISSING; }

# 1. both unsatisfiable shapes fail, and NOTHING of them lands
for n in sc-ref sc-path; do
  case "$(status $n)" in UNSATISFIABLE*) ;; *) fail "expected UNSATISFIABLE for $n, got: '$(status $n)'" ;; esac
  git checkout -q main
  [ ! -f "out/$n.txt" ]                      || fail "$n was merged to main"
  [ -f "tasks/chief/$n.json" ]                || fail "$n was retired"
  [ ! -f "tasks/chief/completed/$n.json" ]    || fail "a completed record was written for $n"
done

# 2. loudly and EARLY: not one agent turn was spent on either
for n in sc-ref sc-path; do
  if grep -qx "$n" "$WORK/agent-turns.txt"; then fail "an agent turn was spent on the unsatisfiable tasklist $n"; fi
done

# 3. the operator is told WHICH story, WHAT it claimed, and how to declare it
LOG="$REPO/.chief/state/parallel/sc-ref.log"
[ -f "$LOG" ] || fail "no worker log at $LOG"
grep -q 'UNSATISFIABLE' "$WORK/run.log" || fail "the run summary never surfaces the UNSATISFIABLE status"
grep -q '✗ US-3 — file argos:82 to completed/' "$LOG" || fail "the failure never names the story (id + title)"
grep -q 'argos:82' "$LOG"    || fail "the failure never names the offending cross-repo reference"
grep -q 'crossRepo' "$LOG"   || fail "the failure never states the escape hatch"
grep -q 'argos/tasks/chief/90-seam.json' "$REPO/.chief/state/parallel/sc-path.log" \
  || fail "the sibling-repo PATH shape was not reported by the path it named"

# 3b. the colon form still stops the run; the own-namespace one still runs
case "$(status sc-colon)" in UNSATISFIABLE*) ;; *) fail "expected UNSATISFIABLE for sc-colon, got: '$(status sc-colon)'" ;; esac
if grep -qx "sc-colon" "$WORK/agent-turns.txt"; then fail "an agent turn was spent on sc-colon"; fi

# 4. declared coordination, ordinary local work, and own-branch citations are NOT held back
for n in sc-declared sc-clean sc-ownbranch; do
  case "$(status $n)" in MERGED*) ;; *) fail "$n did not merge, got: '$(status $n)'" ;; esac
  [ -f "out/$n.txt" ]                      || fail "$n's work is not on main"
  [ -f "tasks/chief/completed/$n.json" ]   || fail "$n was not retired"
done

echo "SCOPE PASS — an undeclared cross-repo criterion fails as UNSATISFIABLE before any agent turn (story + criterion + hatch named); declared and local work still merges"
