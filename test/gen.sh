#!/usr/bin/env bash
# test/gen.sh — ROADMAP → TASKLISTS GENERATOR (tasklist 83, US-3).
#
# `chief gen` is the operation an EMBEDDING HOST calls to author tasklists
# programmatically (docs/roadmap-input.md is the published input contract), so the
# things that must not drift are the CONVENTIONS of what it emits and the HONESTY of
# what it rejects. Both are pinned here against one fixture roadmap.
#
# The fixture repo already owns band 07 (pending) and band 41 (retired to
# completed/) — so a correct generator starts at 42, not at 08 and not at 01.
#
#   roadmap.json                                   emitted
#   ─────────────────────────────────────────────  ─────────────────────────────────
#   Foundations / "Widget store schema"            42-widget-store-schema.json
#     (title+description only)                       every optional field defaulted
#   Foundations / "Widget read API"                43-widget-read-api.json
#     deps: sibling slug + <repo>:<stem>             dependsOn 42-… + koine:12-…
#     touches/iters/scope given                      carried through
#   Polish / "Docs & polish!!"                     44-docs-polish.json
#     (punctuation-heavy title)                      slug is filename-safe
#
# Asserted: the band, the filenames, `branchName == chief/<stem>`, no mergedToMain,
# `passes:false`, jq round-trip, sibling-dep resolution, cross-repo dep passthrough,
# the defaults, --dry-run writing nothing, the no-clobber refusal + --force, and the
# rejections (missing title · branch-name dep · unknown field, with --allow-unknown
# downgrading that one to a warning).
#
# Installs the COMMITTED state of this checkout (install.sh git-clones) — commit
# engine changes before trusting a green run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=gen GIT_AUTHOR_EMAIL=gen@test GIT_COMMITTER_NAME=gen GIT_COMMITTER_EMAIL=gen@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos"   # hermetic: never touch ~/.chief

fail() { echo "GEN FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok — $*"; }

command -v jq  >/dev/null || fail "jq is required"
command -v git >/dev/null || fail "git is required"

# ── 1. Install chief from THIS checkout ───────────────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install.sh failed"
CHIEF="$BIN/chief"
[ -x "$CHIEF" ] || fail "shim not installed at $CHIEF"

# ── 2. A project whose bands 07 (pending) and 41 (retired) are already taken ──
REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO" || fail "cannot cd $REPO"
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
git commit -q --allow-empty -m init
"$CHIEF" init >/dev/null || fail "chief init failed"
rm -f tasks/chief/example.json
cat > tasks/chief/07-early-work.json <<'JSON'
{ "project":"gen","branchName":"chief/07-early-work","description":"pending work",
  "userStories":[{"id":"US-1","title":"x","acceptanceCriteria":["x"],"passes":false,"notes":""}] }
JSON
cat > tasks/chief/completed/41-old-thing.json <<'JSON'
{ "project":"gen","branchName":"chief/41-old-thing","description":"retired work",
  "mergedToMain":"deadbeef",
  "userStories":[{"id":"US-1","title":"x","acceptanceCriteria":["x"],"passes":true,"notes":""}] }
JSON

# ── 3. The fixture roadmap (the contract shape, docs/roadmap-input.md) ────────
cat > "$WORK/roadmap.json" <<'JSON'
{
  "phases": [
    { "name": "Foundations",
      "items": [
        { "title": "Widget store schema",
          "description": "Create the widgets table and the migration that lands it." },
        { "title": "Widget read API",
          "description": "Serve GET /widgets from the new store.",
          "scope": "Reads only.",
          "deps": ["widget-store-schema", "koine:12-widget-contract"],
          "touches": ["api", "db-schema"],
          "iters": 8 }
      ] },
    { "name": "Polish",
      "items": [
        { "title": "Docs & polish!!",
          "description": "Write the docs." }
      ] }
  ]
}
JSON

# ── 4. --dry-run: emits the plan, writes NOTHING ─────────────────────────────
before="$(ls tasks/chief | sort | tr '\n' ' ')"
dry="$("$CHIEF" gen "$WORK/roadmap.json" --dry-run)" || fail "--dry-run exited non-zero"
[ "$(printf '%s\n' "$dry" | wc -l | tr -d ' ')" = 3 ] || fail "--dry-run: expected 3 NDJSON lines, got: $dry"
printf '%s\n' "$dry" | while IFS= read -r line; do
  jq -e . >/dev/null 2>&1 <<<"$line" || exit 1
done || fail "--dry-run emitted a line that is not valid JSON"
[ "$(printf '%s\n' "$dry" | jq -r -s 'map(.name) | join(",")')" \
  = "42-widget-store-schema,43-widget-read-api,44-docs-polish" ] \
  || fail "--dry-run names wrong: $(printf '%s\n' "$dry" | jq -r -s 'map(.name)|join(",")')"
[ "$(ls tasks/chief | sort | tr '\n' ' ')" = "$before" ] || fail "--dry-run wrote files"
ok "--dry-run emits the plan as NDJSON and writes nothing"

# Stdin ("-") is the same document by another route — a host pipes the roadmap in.
"$CHIEF" gen - --dry-run < "$WORK/roadmap.json" >/dev/null 2>&1 || fail "reading the roadmap from stdin failed"
ok "the roadmap can be piped in on stdin"

# ── 5. Generate for real ─────────────────────────────────────────────────────
"$CHIEF" gen "$WORK/roadmap.json" >"$WORK/gen.log" 2>&1 || { cat "$WORK/gen.log"; fail "chief gen failed"; }
grep -q "band 42..44" "$WORK/gen.log" || { cat "$WORK/gen.log"; fail "the reported band is not 42..44"; }

A="tasks/chief/42-widget-store-schema.json"
B="tasks/chief/43-widget-read-api.json"
C="tasks/chief/44-docs-polish.json"
for f in "$A" "$B" "$C"; do [ -f "$f" ] || fail "not generated: $f"; done
# Non-colliding: nothing landed on 07, on 41, or below the existing max.
[ -f tasks/chief/07-early-work.json ] || fail "the existing 07 tasklist was clobbered"
[ "$(ls tasks/chief/*.json | wc -l | tr -d ' ')" = 4 ] || fail "unexpected tasklist count: $(ls tasks/chief)"
ok "one file per item, numbered 42..44 — above BOTH the pending 07 and the retired 41"

# The tasklist gate, applied to every generated file (CLAUDE.md / .chief/verify.sh).
for f in "$A" "$B" "$C"; do
  jq -e . "$f" >/dev/null 2>&1 || fail "not valid JSON: $f"
  n="$(basename "$f" .json)"
  [ "$(jq -r '.branchName' "$f")" = "chief/$n" ] || fail "$f: branchName != chief/$n"
  [ "$(jq -r 'has("mergedToMain")' "$f")" = false ] || fail "$f: carries mergedToMain"
  [ "$(jq -r '.userStories|length' "$f")" -ge 1 ] || fail "$f: no user stories"
  [ "$(jq -r '[.userStories[]|select(.passes==false)]|length' "$f")" \
    = "$(jq -r '.userStories|length' "$f")" ] || fail "$f: a story does not start passes:false"
  [ "$(jq -r '[.userStories[]|select((.acceptanceCriteria|length)==0)]|length' "$f")" = 0 ] \
    || fail "$f: a story has no acceptance criteria"
  # round-trip: the file IS jq output, so reserialising it must reproduce it exactly
  [ "$(jq . "$f")" = "$(cat "$f")" ] || fail "$f: does not round-trip through jq unchanged"
done
ok "every generated file is schema-valid, gate-clean, and round-trips through jq"

# ── 6. Conventions: deps, defaults, slug ─────────────────────────────────────
[ "$(jq -c '.dependsOn' "$B")" = '["42-widget-store-schema","koine:12-widget-contract"]' ] \
  || fail "B dependsOn wrong: $(jq -c '.dependsOn' "$B")  (sibling slug must resolve, <repo>:<stem> must pass through)"
[ "$(jq -c '.touches' "$B")" = '["api","db-schema"]' ] || fail "B touches wrong"
[ "$(jq -r '.iters' "$B")" = 8 ]                       || fail "B iters wrong"
jq -e '.description | test("Scope: Reads only\\.")' "$B" >/dev/null || fail "B scope not folded into the description"
ok "deps/touches/iters/scope carried through (sibling dep resolved to its generated stem)"

[ "$(jq -c '.dependsOn' "$A")" = '[]' ]  || fail "A dependsOn should default to []"
[ "$(jq -c '.touches' "$A")" = '[]' ]    || fail "A touches should default to []"
[ "$(jq -r '.iters' "$A")" = 5 ]         || fail "A iters should default to 5"
[ "$(jq -r '.parked' "$A")" = false ]    || fail "A parked should be false"
[ "$(jq -r '.userStories[0].title' "$A")" = "Widget store schema" ] || fail "A story title not seeded from the item title"
ok "omitted optional fields take their documented defaults"

# A punctuation-heavy title must still yield a filename/branch-safe slug.
[ "$(jq -r '.branchName' "$C")" = "chief/44-docs-polish" ] || fail "C slug not sanitised: $(jq -r '.branchName' "$C")"
ok "titles are slugified into filename-safe stems"

# ── 7. No clobber without --force (all-or-nothing) ───────────────────────────
"$CHIEF" gen "$WORK/roadmap.json" >"$WORK/clobber.log" 2>&1 && fail "regenerating over existing files should have failed"
grep -q "refusing to overwrite" "$WORK/clobber.log" || { cat "$WORK/clobber.log"; fail "no refusal message"; }
ok "an existing tasklist is never overwritten without --force"

# --force onto a staging dir proves the flag works without disturbing the real band.
mkdir -p "$WORK/stage"
cp "$A" "$WORK/stage/42-widget-store-schema.json"
"$CHIEF" gen "$WORK/roadmap.json" --out "$WORK/stage" --force >/dev/null 2>&1 \
  || fail "--force did not overwrite"
[ -f "$WORK/stage/43-widget-read-api.json" ] || fail "--force did not write the batch"
ok "--force overwrites; --out stages elsewhere while keeping the project band"

# ── 8. Rejections — the contract is enforced, not assumed ────────────────────
reject() {  # $1 = label, $2 = roadmap JSON, $3 = expected substring
  printf '%s' "$2" > "$WORK/bad.json"
  out="$("$CHIEF" gen "$WORK/bad.json" --dry-run 2>&1)"; rc=$?
  [ "$rc" = 2 ] || fail "$1: expected exit 2, got $rc — $out"
  grep -q "$3" <<<"$out" || fail "$1: message did not mention '$3' — $out"
  ok "rejected: $1"
}
reject "an item with no title" \
  '{"phases":[{"name":"P","items":[{"description":"d"}]}]}' \
  '"title" is required'
reject "a dep given as a branch name" \
  '{"phases":[{"name":"P","items":[{"title":"T","description":"d","deps":["chief/41-old-thing"]}]}]}' \
  'never a branch name'
reject "a dep given as a filename" \
  '{"phases":[{"name":"P","items":[{"title":"T","description":"d","deps":["41-old-thing.json"]}]}]}' \
  'MINUS .json'
reject "an unknown item field" \
  '{"phases":[{"name":"P","items":[{"title":"T","description":"d","touched":["api"]}]}]}' \
  'unknown field "touched"'
reject "an unknown top-level field" \
  '{"version":1,"phases":[{"name":"P","items":[{"title":"T","description":"d"}]}]}' \
  'unknown field "version"'
reject "a document with no phases" \
  '{"items":[]}' \
  'phases'

# --allow-unknown downgrades exactly that class to a warning and still generates.
printf '%s' '{"version":1,"phases":[{"name":"P","items":[{"title":"Extra field item","description":"d","touched":["api"]}]}]}' > "$WORK/unknown.json"
out="$("$CHIEF" gen "$WORK/unknown.json" --dry-run --allow-unknown 2>"$WORK/warn.log")" \
  || { cat "$WORK/warn.log"; fail "--allow-unknown should still generate"; }
grep -q "warning" "$WORK/warn.log" || { cat "$WORK/warn.log"; fail "--allow-unknown did not warn"; }
[ "$(jq -r '.name' <<<"$out")" = "45-extra-field-item" ] || fail "--allow-unknown emitted the wrong plan: $out"
ok "--allow-unknown warns instead of failing, and the unknown field is not smuggled in"

# A roadmap that is not JSON at all fails loudly rather than emitting a half-batch.
printf 'not json' > "$WORK/bad.json"
"$CHIEF" gen "$WORK/bad.json" --dry-run >/dev/null 2>&1 && fail "invalid JSON should not generate"
ok "a non-JSON roadmap is refused"

echo "GEN OK — the roadmap contract generates conventional, gate-clean tasklists"
