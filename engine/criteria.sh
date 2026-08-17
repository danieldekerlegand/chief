#!/usr/bin/env bash
# engine/criteria.sh — the SCOPE check on acceptance criteria.
#
# A story is run inside ONE worktree, and everything it is asked to do must be
# doable from there. A criterion that names another repo — "file `argos:82` under
# completed/", "unpark `argos:90`", "edit `../pinakes/tasks/…`" — is not a hard
# story; it is an UNSATISFIABLE one, and the agent's only honest move is to report
# it undone. What happened instead (2026-08-16/17, cuneiform:346/US-3 and
# cuneiform:347/US-4) is that both passed: nothing ever read the criterion, so a
# structurally impossible ask and a finished one look identical in the record.
#
# So the reference is detected from the criterion TEXT, in the one notation chief
# already publishes for naming work in another repo (docs/reference/cross-repo-dependencies.md):
#
#   1. `../<name>/…`        — an explicitly parent-relative path; outside by construction.
#   2. `<repo>:<stem>`      — chief's own cross-repo tasklist reference (`argos:82`).
#                             A repo name carries no dot, which is what keeps a
#                             `driver.sh:1075` line reference out of it.
#   3. `<repo>/…`           — a path rooted at a repo the tasklist has ALREADY named
#                             foreign: via (1)/(2) anywhere in its text, via a
#                             cross-repo `dependsOn`, or as a sibling checkout next
#                             to the project that does not exist in this worktree.
#
# Rules 1 and 2 are pure text and hold on any host. Rule 3 is the sibling-repo case
# the incident report names (`argos/tasks/…`), and it deliberately fires only for a
# repo something else already established as foreign — "first path component does not
# exist here" alone would fail every criterion that names a directory it is about to
# create.
#
# THE ESCAPE HATCH IS EXPLICIT. A tasklist that genuinely coordinates across repos
# declares it: `"crossRepo": ["argos"]` names the repos its criteria may reference,
# and that declaration is a reviewable line in the tasklist record. Silence is what
# produced these failures, so silence is what stops being allowed — not the
# coordination itself.
#
# THREE CALLERS, ONE RULE, three severities matched to what each can still do about it:
#   engine/gen.sh    authoring — WARNS, and still generates (the author is right there)
#   bin/chief lint   authoring — FAILS, so a repo can gate on it before a run
#   engine/driver.sh runtime   — FAILS the tasklist BEFORE the first agent turn
#                               (criteria_scope_stop), because by then nobody is
#                               reading warnings and every turn spent is wasted.
#
# bash 3.2: no associative arrays, no mapfile. jq is the only dependency.

# criteria_scope_report TASKLIST [ROOT] — print one block per criterion that names
# something outside ROOT (default: the tasklist's own directory tree — at runtime
# the worktree, at authoring time the project). Empty output = clean.
# Sibling checkouts: the repos that sit NEXT TO this project on disk and are not
# part of this worktree, one per line. Absent (a container, a lone clone) the rule
# simply does not fire — rules 1 and 2 do not depend on it.
criteria_siblings() {
  local proj="$1" root="${2:-}" self d n
  self="$(basename "${proj:-.}")"
  [ -n "$proj" ] && [ -d "$proj/.." ] || return 0
  for d in "$proj/.."/*/; do
    [ -e "$d.git" ] || continue
    n="$(basename "$d")"
    [ "$n" = "$self" ] && continue                    # the project is not foreign to itself
    [ -n "$root" ] && [ -e "$root/$n" ] && continue   # …nor is a name that resolves in here
    printf '%s\n' "$n"
  done
}

criteria_scope_report() {
  local tl="$1" root="${2:-}" proj self sibs
  proj="${CHIEF_PROJECT:-$root}"
  self="$(basename "${proj:-.}")"
  sibs="$(criteria_siblings "$proj" "$root")"
  jq -r --arg sibs "$sibs" --arg self "$self" '
    def toks: [ splits("[^A-Za-z0-9_./:~-]+") ] | map(sub("[./:-]+$"; "")) | map(select(length > 0));
    def clip: if (. | length) > 200 then .[0:197] + "..." else . end;
    # The repo a token names, or "" — rules 1 and 2, the host-independent half.
    def outside_ref:
      if   test("^\\.\\./[A-Za-z0-9._-]")   then (sub("^\\.\\./"; "") | sub("/.*$"; ""))
      elif test("^[a-z][a-z0-9_-]*:[0-9]") then sub(":.*$"; "")   # NB: no dot — `driver.sh:1075` is a line reference, not a repo
      else "" end;
    . as $t
    # The branch namespace of THIS repo, taken from the tasklist rather than hardcoded:
    # branchName is "<ns>/NN-slug", so a token "<ns>/63" names a BRANCH IN THIS REPO, not
    # a path into a sibling checkout that happens to share the name. Without this, the
    # sibling rule below fired on the universal chief branch convention in every repo that
    # cites one of its own tasklists: 83 such findings across 14 repos, none of them real.
    # The cross-repo form is the colon notation ("chief:290"), which rule 2 still catches.
    | ( $t.branchName // "" | sub("/.*$"; "") ) as $ns
    | ( [ $t.userStories[]? | (.title // ""), (.description // ""), ((.acceptanceCriteria // [])[]?) ]
        + [ $t.description // "" ] ) as $text
    | ( [ $text[] | toks[] | outside_ref ]
        + ( ($t.dependsOn // []) | map(select(type == "string" and test(":")) | sub(":.*$"; "") | sub("^.*/"; "")) )
        + ($sibs | split("\n"))
        | map(select(length > 0 and . != $self)) | unique ) as $foreign
    | ( ($t.crossRepo // []) | if type == "string" then [.] else . end ) as $declared
    | $t.userStories[]?
    | . as $us
    | (.acceptanceCriteria // [])[]?
    | . as $c
    | [ $c | toks[]
        | . as $tok
        | ( ($tok | outside_ref) as $r
            | if $r != "" then $r
              elif ($tok | test("^[A-Za-z0-9._-]+/")) and ($foreign | index($tok | sub("/.*$"; "")))
                     # …unless it is the branch namespace of this repo followed by a tasklist
                     # stem ("chief/63", "chief/33-collab-community-browser") or the literal
                     # placeholder the docs use ("chief/NN-slug").
                     and (($ns == "") or (($tok | test("^" + $ns + "/([0-9]|NN-slug)")) | not))
                     # …and unless EVERY later component is itself a repo name, which makes it
                     # prose listing repos with slashes ("koine/agora", "argos/cuneiform/formant"),
                     # not a path. The tail of a real path is directories and files, not repos.
                     and ((($tok | split("/"))[1:]
                            | map(select(. as $c | ($foreign + [$self]) | index($c))) | length)
                          < (($tok | split("/"))[1:] | length))
                then ($tok | sub("/.*$"; ""))
              else "" end ) as $repo
        | select($repo != "" and (($declared | index($repo)) | not))
        | { tok: $tok, repo: $repo } ] as $bad
    | select(($bad | length) > 0)
    | "   ✗ \($us.id // "?") — \($us.title // "(untitled)")\n"
      + ( [ $bad[] | "       outside this worktree: \(.tok)  (repo \"\(.repo)\")" ] | unique | join("\n") )
      + "\n       claimed: \"\($c | tostring | clip)\""
  ' "$tl" 2>/dev/null
}

# criteria_scope_stop REPORT — the driver's terminal stop on that report: status,
# event, and the report itself, printed BEFORE a single agent turn is spent.
#
# Not a park and not INCOMPLETE: neither more iterations nor a resume can make a
# criterion satisfiable from a worktree it does not live in, so this fails the
# tasklist and says what the author has to change. Reads $name/$branch/$live/$STATE/
# $wtstate from run_worker by dynamic scope — the same convention unverified_stop
# uses, and the reason this half lives next to the rule it reports on.
criteria_scope_stop() {
  local n total
  n="$(printf '%s\n' "$1" | grep -c '✗' 2>/dev/null || true)"
  total="$(jq '.userStories|length' "$wtstate/prd.json" 2>/dev/null || echo 0)"
  live_set "$live" phase=unsatisfiable
  event_emit tasklist.unsatisfiable name="$name" state=failed \
    detail="$n stor$([ "$n" = 1 ] && echo y || echo ies) name a path outside the worktree"
  echo "UNSATISFIABLE 0/${total:-0}" > "$STATE/$name.status"
  echo "!! $name UNSATISFIABLE — $n stor$([ "$n" = 1 ] && echo y claims something || echo ies claim things) this worktree cannot do:"
  printf '%s\n' "$1"
  echo "   No agent turn was spent. Rewrite the criterion for work that lives in THIS repo, or — if the tasklist really does coordinate across repos — declare it: \"crossRepo\": [\"<repo>\"]."
}
