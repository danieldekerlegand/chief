#!/usr/bin/env bash
# engine/gen.sh — ROADMAP → TASKLISTS. Turn a structured roadmap document into one
# schema-valid `tasks/chief/NN-slug.json` per roadmap item (docs/tasklist-schema.md).
#
# This is the operation an EMBEDDING HOST calls (Cuneiform's Chief-in-Riju operator
# loop, chief-cloud, a CI job) to author tasklists programmatically instead of
# hand-writing JSON and hoping the numbered band, `branchName`, `dependsOn` and
# `touches` conventions came out right. So the INPUT SHAPE IS A PUBLISHED CONTRACT,
# not an internal detail — see docs/roadmap-input.md.
#
#   {
#     "phases": [
#       { "name": "Phase name",
#         "items": [
#           { "title":       "Short imperative title",   // required
#             "description":  "What this delivers and why", // required
#             "scope":        "…what's in/out of scope",  // optional
#             "deps":        ["82-some-tasklist",         // optional (stem, or
#                             "pinakes:10-their-work"],   //   <repo>:<stem>)
#             "touches":     ["engine"],                  // optional
#             "iters":        6 }                         // optional
#         ] }
#     ]
#   }
#
# Invariants this script owns, because they are the ones hand-authoring gets wrong:
#   - Numbering NEVER collides: the next band starts ABOVE the max NN already present
#     in the tasks dir AND in completed/ (a retired tasklist still owns its number).
#   - `branchName` is always `chief/<NN-slug>` — the same stem as the filename.
#   - `dependsOn` carries filename stems, never branch names (a `chief/…` or a
#     `….json` dep is rejected with the correction), and a dep naming a SIBLING item
#     of the same roadmap by its slug is resolved to that item's generated stem —
#     the number isn't knowable to the host writing the roadmap.
#   - `mergedToMain` is never emitted (an unmerged tasklist must not claim to be
#     merged), and every emitted file is re-checked against the tasklist gate
#     (valid JSON · branchName == chief/<filename stem> · no mergedToMain) before
#     chief calls it generated.
#   - Nothing is overwritten without --force, and --dry-run writes nothing at all.
#
# bash 3.2: no associative arrays, no ${var^^}, no mapfile. jq is the only dependency
# (already required by the engine).
set -uo pipefail

SLUG_MAX=48          # slug length cap, cut back to a word boundary
DEFAULT_ITERS=5      # docs/tasklist-schema.md default when the item omits `iters`

usage() {
  cat <<EOF
chief gen — generate tasklists from a roadmap JSON document.

Usage:
  chief gen <roadmap.json> [--dry-run] [--force] [--out DIR] [--project NAME]

  <roadmap.json>   the roadmap contract document ("-" reads stdin):
                   {"phases":[{"name":…,"items":[{"title":…,"description":…,
                    "scope":…,"deps":[…],"touches":[…],"iters":N}]}]}
                   title + description are required; the rest are optional.

  -n, --dry-run    emit the tasklists to stdout as NDJSON ({"path":…,"tasklist":…})
                   and write nothing — the review mode for an embedding host
  -f, --force      overwrite an existing tasklist file (default: refuse, write none)
  -o, --out DIR    write into DIR instead of the project's tasks dir (numbering is
                   still taken from the project's tasks dir, so a staged batch keeps
                   its band)
  --project NAME   value for the emitted "project" field (default: the repo name)
  -h, --help       this text

Each roadmap item becomes one tasklist: title → slug + seed story, description(+scope)
→ description, deps → dependsOn, touches → touches, iters → iters. The single seeded
user story is a STARTING POINT — review and split it before running.

A dep is a tasklist name (the filename minus .json), NEVER a branch name; qualify
another repo as "<repo>:<stem>". A dep that matches a sibling roadmap item's slug is
rewritten to that item's generated "NN-slug" stem, so a roadmap can order its own
items without knowing the band in advance.
Contract + worked example: docs/roadmap-input.md   Schema: docs/tasklist-schema.md
EOF
}

die() { echo "chief gen: $*" >&2; exit 1; }

# ── argv ─────────────────────────────────────────────────────────────────────
roadmap=""; dry=0; force=0; outdir=""; project=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)     usage; exit 0 ;;
    -n|--dry-run)  dry=1; shift ;;
    -f|--force)    force=1; shift ;;
    -o|--out)      outdir="${2:-}"; shift 2 ;;
    --out=*)       outdir="${1#*=}"; shift ;;
    --project)     project="${2:-}"; shift 2 ;;
    --project=*)   project="${1#*=}"; shift ;;
    -)             [ -z "$roadmap" ] || die "more than one roadmap file given ('$roadmap', '-')"
                   roadmap="-"; shift ;;
    -*)            echo "chief gen: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)             [ -z "$roadmap" ] || die "more than one roadmap file given ('$roadmap', '$1')"
                   roadmap="$1"; shift ;;
  esac
done
[ -n "$roadmap" ] || { echo "chief gen: a roadmap JSON file is required." >&2; usage >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die "jq is required"

: "${CHIEF_PROJECT:?chief gen must run inside a chief project (no .chief/config found)}"
TASKS_DIR="$CHIEF_PROJECT/${CHIEF_TASKS_DIR:-tasks/chief}"
[ -d "$TASKS_DIR" ] || die "tasks dir not found: $TASKS_DIR (run 'chief init' first)"
[ -n "$outdir" ] || outdir="$TASKS_DIR"
case "$outdir" in /*) ;; *) outdir="$CHIEF_PROJECT/$outdir" ;; esac

# The project name defaults to the repo's own directory name — resolved through the
# git common dir so a run inside a WORKTREE reports the repo, not the worktree's
# throwaway branch-named directory.
if [ -z "$project" ]; then
  common="$(git -C "$CHIEF_PROJECT" rev-parse --git-common-dir 2>/dev/null || true)"
  case "$common" in
    "")  project="$(basename "$CHIEF_PROJECT")" ;;
    /*)  project="$(basename "$(dirname "$common")")" ;;
    *)   project="$(basename "$(cd "$CHIEF_PROJECT/$common/.." 2>/dev/null && pwd || echo "$CHIEF_PROJECT")")" ;;
  esac
fi

# ── read + parse ─────────────────────────────────────────────────────────────
if [ "$roadmap" = "-" ]; then
  ROADMAP_JSON="$(cat)"
else
  [ -f "$roadmap" ] || die "no such roadmap file: $roadmap"
  ROADMAP_JSON="$(cat "$roadmap")"
fi
jq -e . >/dev/null 2>&1 <<<"$ROADMAP_JSON" || die "roadmap is not valid JSON: $roadmap"

# ── validate the contract ────────────────────────────────────────────────────
# Every violation is reported at once (with its phases[i].items[j] address) so a
# host fixing a generated roadmap gets one full list, not one error per round-trip.
problems="$(jq -r '
  def nonempty_string: type == "string" and (gsub("^\\s+|\\s+$"; "") | length) > 0;

  # dependsOn is the convention hand-authoring gets wrong most often
  # (docs/cross-repo-dependencies.md), so each entry is checked on its own and the
  # message carries the correction, not just the complaint.
  def dep_problem($at):
    if type != "string"
      then "\($at): must be a string — a tasklist name (\"82-some-work\"), or \"<repo>:<stem>\""
    else (gsub("^\\s+|\\s+$"; "")) as $t
      | (if ($t|test(":")) then ($t|sub(":[^:]*$"; "")) else "" end) as $repo
      | (if ($t|test(":")) then ($t|sub("^.*:"; "")) else $t end) as $stem
      | if ($t|length) == 0
          then "\($at): must be a non-empty string — a tasklist name (\"82-some-work\"), or \"<repo>:<stem>\""
        elif ($t|test(":")) and ($repo|length) == 0
          then "\($at): \"\($t)\" — a cross-repo dep is \"<repo>:<stem>\"; the repo part is empty"
        elif ($stem|length) == 0
          then "\($at): \"\($t)\" — a cross-repo dep is \"<repo>:<stem>\"; the tasklist part is empty"
        elif ($stem|endswith(".json"))
          then "\($at): \"\($t)\" — dependsOn takes the filename MINUS .json (\"\($stem|sub("\\.json$"; ""))\")"
        elif ($stem|test("/"))
          then "\($at): \"\($t)\" — dependsOn takes a tasklist name, never a branch name (\"\($stem|sub("^.*/"; ""))\"); qualify another repo as \"<repo>:<stem>\""
        else empty end
      end;

  def item_problems($pi; $ii):
    . as $it
    | if type != "object" then ["phases[\($pi)].items[\($ii)]: must be a JSON object"]
      else
        [ (if ($it|has("title")) and ($it.title|nonempty_string) then empty
           else "phases[\($pi)].items[\($ii)]: \"title\" is required and must be a non-empty string" end),
          (if ($it|has("description")) and ($it.description|nonempty_string) then empty
           else "phases[\($pi)].items[\($ii)]: \"description\" is required and must be a non-empty string" end),
          (if ($it|has("scope")|not) or ($it.scope|type == "string") then empty
           else "phases[\($pi)].items[\($ii)]: \"scope\" must be a string" end),
          (if ($it|has("deps")|not) then empty
           elif ($it.deps|type) != "array"
             then "phases[\($pi)].items[\($ii)]: \"deps\" must be an array of tasklist names (\"<stem>\", or \"<repo>:<stem>\")"
           else ($it.deps | to_entries[] | .key as $di | .value
                 | dep_problem("phases[\($pi)].items[\($ii)].deps[\($di)]")) end),
          (if ($it|has("touches")|not)
              or (($it.touches|type == "array") and ([$it.touches[] | select(nonempty_string|not)]|length) == 0) then empty
           else "phases[\($pi)].items[\($ii)]: \"touches\" must be an array of non-empty strings" end),
          (if ($it|has("iters")|not)
              or (($it.iters|type == "number") and ($it.iters == ($it.iters|floor)) and ($it.iters > 0)) then empty
           else "phases[\($pi)].items[\($ii)]: \"iters\" must be a positive integer" end)
        ]
      end;

  if type != "object" then ["roadmap: the top level must be a JSON object with a \"phases\" array"]
  elif (has("phases")|not) then ["roadmap: missing the required top-level \"phases\" array"]
  elif (.phases|type) != "array" then ["roadmap: \"phases\" must be an array"]
  elif (.phases|length) == 0 then ["roadmap: \"phases\" is empty — nothing to generate"]
  else
    [ .phases
      | to_entries[]
      | .key as $pi
      | .value as $p
      | if ($p|type) != "object" then "phases[\($pi)]: must be a JSON object"
        elif ($p|has("name")|not) or (($p.name|nonempty_string)|not)
          then "phases[\($pi)]: \"name\" is required and must be a non-empty string"
        elif ($p|has("items")|not) or (($p.items|type) != "array")
          then "phases[\($pi)]: \"items\" is required and must be an array"
        else ($p.items | to_entries[] | .key as $ii | .value | item_problems($pi; $ii) | .[])
        end
    ]
    + (if ([.phases[]? | select(type == "object") | .items[]?] | length) == 0
       then ["roadmap: no items in any phase — nothing to generate"] else [] end)
  end
  | .[]
' <<<"$ROADMAP_JSON" 2>/dev/null)"
if [ -n "$problems" ]; then
  { echo "chief gen: the roadmap does not match the input contract (docs/roadmap-input.md):"
    printf '%s\n' "$problems" | sed 's/^/  - /' ; } >&2
  exit 2
fi

# ── next free band ───────────────────────────────────────────────────────────
# A number is owned by any tasklist that carries it — pending OR completed. Retired
# tasklists keep their band so history stays readable, so both dirs are scanned.
max=0
for f in "$TASKS_DIR"/*.json "$TASKS_DIR"/completed/*.json; do
  [ -e "$f" ] || continue
  n="$(basename "$f" .json)"; n="${n%%-*}"
  case "$n" in ''|*[!0-9]*) continue ;; esac
  n="$((10#$n))"
  [ "$n" -gt "$max" ] && max="$n"
done
start="$((max + 1))"

# ── build the plan ───────────────────────────────────────────────────────────
PLAN="$(jq -c \
  --arg project "$project" --arg dir "$outdir" \
  --argjson start "$start" --argjson maxslug "$SLUG_MAX" --argjson defiters "$DEFAULT_ITERS" '
  def trim: gsub("^\\s+|\\s+$"; "");
  def slugify:
    ascii_downcase
    | gsub("[^a-z0-9]+"; "-")
    | gsub("^-+|-+$"; "")
    | (if length > $maxslug then (.[0:$maxslug] | sub("-[^-]*$"; "")) else . end)
    | gsub("^-+|-+$"; "");
  def pad2: tostring | if length < 2 then "0" + . else . end;

  [ .phases[] | .name as $phase | .items[] | {phase: $phase, item: .} ]
  | to_entries
  | map(
      .key as $i | .value.item as $it | .value.phase as $phase
      | ($start + $i) as $n
      | ($it.title | trim | slugify) as $slug
      | "\($n|pad2)-\($slug)" as $name
      | (($it.scope // "") | trim) as $scope
      | ($it.description | trim) as $desc
      | { path: "\($dir)/\($name).json",
          name: $name,
          slug: $slug,
          phase: $phase,
          tasklist: {
            project:     $project,
            branchName:  "chief/\($name)",
            description: ($desc + (if $scope != "" then " Scope: \($scope)" else "" end)),
            parked:      false,
            # defaults when the roadmap item is silent: no deps, no conflict domain
            # (free to co-schedule), and the schema's own iteration budget.
            dependsOn:   ([($it.deps // [])[] | trim]),
            touches:     ($it.touches // []),
            iters:       ($it.iters // $defiters),
            warmup:      [],
            userStories: [
              { id: "US-1",
                title: ($it.title | trim),
                description: $desc,
                acceptanceCriteria: ([$desc] + (if $scope != "" then ["Scope: \($scope)"] else [] end)),
                passes: false,
                notes: "" }
            ]
          } }
    )
  # A host writing the roadmap cannot know the band it will land in, so an item may
  # order itself after a SIBLING by the slug of that sibling; rewrite those to the stem
  # that was actually generated. First slug wins if two titles collide. A qualified
  # <repo>:<stem> dep is never rewritten — it names work in another repo.
  | . as $plan
  | (reduce $plan[] as $p ({}; if has($p.slug) then . else .[$p.slug] = $p.name end)) as $bystem
  | map(.tasklist.dependsOn |= map(if test(":") then . else ($bystem[.] // .) end))
' <<<"$ROADMAP_JSON")" || die "could not build the tasklists from the roadmap"

count="$(jq 'length' <<<"$PLAN")"
[ "${count:-0}" -gt 0 ] || die "the roadmap produced no tasklists"

# A title with no slug-able characters would yield "NN-" — a filename and a branch
# name that are both wrong. Catch it here rather than writing it.
empty_slugs="$(jq -r '.[] | select(.slug == "") | .tasklist.userStories[0].title' <<<"$PLAN")"
if [ -n "$empty_slugs" ]; then
  { echo "chief gen: cannot derive a slug from these titles (no letters or digits):"
    printf '%s\n' "$empty_slugs" | sed 's/^/  - /' ; } >&2
  exit 2
fi

# ── audit the plan against the tasklist gate (docs/tasklist-schema.md) ───────
# The generator's whole point is that the conventions come out right, so it checks
# its OWN output rather than trusting the transform above: filename stem is NN-slug,
# branchName is that stem under chief/, no mergedToMain on unmerged work, and every
# seeded story is a well-formed, not-yet-passing story. A hit here is a chief bug.
audit="$(jq -r '
  def bad($path; $msg): "\($path): \($msg)";
  [ .[]
    | .name as $name | .path as $path | .tasklist as $t
    | (if ($name|test("^[0-9][0-9]+-[a-z0-9]+(-[a-z0-9]+)*$")) then empty
       else bad($path; "filename stem \"\($name)\" is not NN-slug") end),
      (if $t.branchName == "chief/\($name)" then empty
       else bad($path; "branchName \"\($t.branchName // "")\" != \"chief/\($name)\"") end),
      (if ($t|has("mergedToMain")|not) then empty
       else bad($path; "carries mergedToMain — an unmerged tasklist must not claim to be merged") end),
      (if ($t.project|type) == "string" and (($t.project|length) > 0) then empty
       else bad($path; "\"project\" must be a non-empty string") end),
      (if ($t.description|type) == "string" and (($t.description|length) > 0) then empty
       else bad($path; "\"description\" must be a non-empty string") end),
      (if ($t.dependsOn|type) == "array"
          and all($t.dependsOn[];
                  type == "string" and length > 0
                  # only the STEM is a filename; the repo half of a cross-repo dep is
                  # allowed to be a path (../pinakes:10-work) — see docs/cross-repo-dependencies.md
                  and ((if test(":") then sub("^.*:"; "") else . end)
                       | length > 0 and (test("/")|not) and (endswith(".json")|not)))
       then empty else bad($path; "\"dependsOn\" must be tasklist names, never branch names (\"<stem>\", or \"<repo>:<stem>\")") end),
      (if ($t.touches|type) == "array" and all($t.touches[]; type == "string" and length > 0)
       then empty else bad($path; "\"touches\" must be an array of non-empty strings") end),
      (if ($t.iters|type) == "number" and ($t.iters == ($t.iters|floor)) and ($t.iters > 0)
       then empty else bad($path; "\"iters\" must be a positive integer") end),
      (if ($t.userStories|type) == "array" and (($t.userStories|length) > 0) then empty
       else bad($path; "\"userStories\" must be a non-empty array") end),
      ( $t.userStories[]?
        | . as $us
        | (if ($us.id|type) == "string" and (($us.id|length) > 0) then empty
           else bad($path; "a user story has no \"id\"") end),
          (if ($us.title|type) == "string" and (($us.title|length) > 0) then empty
           else bad($path; "story \($us.id // "?") has no \"title\"") end),
          (if ($us.acceptanceCriteria|type) == "array" and (($us.acceptanceCriteria|length) > 0)
              and all($us.acceptanceCriteria[]; type == "string" and length > 0) then empty
           else bad($path; "story \($us.id // "?") needs a non-empty acceptanceCriteria array") end),
          (if $us.passes == false then empty
           else bad($path; "story \($us.id // "?") must start with passes:false") end) )
  ] | unique | .[]
' <<<"$PLAN")"
if [ -n "$audit" ]; then
  { echo "chief gen: generated tasklists violate chief's own conventions (this is a bug in chief gen):"
    printf '%s\n' "$audit" | sed 's/^/  - /' ; } >&2
  exit 1
fi

# The tasklist gate as the verify hook / CLAUDE.md state it, re-applied to a file on
# disk: valid JSON, branchName == chief/<its own filename stem>, no mergedToMain.
gate_file() {
  gf_n="$(basename "$1" .json)"
  jq -e --arg n "$gf_n" '
    (.branchName == "chief/\($n)") and (has("mergedToMain")|not)
  ' "$1" >/dev/null 2>&1
}

# ── dry run: emit, write nothing ─────────────────────────────────────────────
if [ "$dry" = 1 ]; then
  jq -c '.[] | {path, name, tasklist}' <<<"$PLAN"
  exit 0
fi

# ── refuse to clobber (all-or-nothing: check every target before writing any) ─
if [ "$force" != 1 ]; then
  existing=""
  i=0
  while [ "$i" -lt "$count" ]; do
    p="$(jq -r --argjson i "$i" '.[$i].path' <<<"$PLAN")"
    [ -e "$p" ] && existing="$existing$p
"
    i="$((i + 1))"
  done
  if [ -n "$existing" ]; then
    { echo "chief gen: refusing to overwrite an existing tasklist (pass --force to replace):"
      printf '%s' "$existing" | sed 's/^/  - /' ; } >&2
    exit 1
  fi
fi

# ── write ────────────────────────────────────────────────────────────────────
mkdir -p "$outdir" || die "cannot create output dir: $outdir"
i=0
while [ "$i" -lt "$count" ]; do
  p="$(jq -r --argjson i "$i" '.[$i].path' <<<"$PLAN")"
  jq --argjson i "$i" '.[$i].tasklist' <<<"$PLAN" > "$p" || die "write failed: $p"
  jq -e . "$p" >/dev/null 2>&1 || die "generated invalid JSON: $p"
  gate_file "$p" || die "generated file fails the tasklist gate: $p"
  echo "  gen  ${p#"$CHIEF_PROJECT"/}"
  i="$((i + 1))"
done
last="$((start + count - 1))"
echo "✓ $count tasklist$([ "$count" = 1 ] || echo s) generated, band ${start}..${last}. Review the seeded stories, then: chief run -n"
