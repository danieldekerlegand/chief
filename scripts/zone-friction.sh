#!/usr/bin/env bash
# scripts/zone-friction.sh — DOES A NARROWED ZONE EARN ITS FRICTION? Measured against
# recorded merge history, read-only, in BOTH directions.
#
# tasks/chief/910-the-approval-flow-earns-its-friction-back. The claim that sent two
# downstream registries to `serialize` on 2026-09-10 was that the holds were noise, and
# the claim made for `surface:<glob>:<ere>` (engine/surface.sh) is that it holds the
# same designs while releasing the noise. Both are claims ABOUT A CORPUS, and neither
# is checkable by reading the matcher. So: take the rule as it fired, take the rule as
# narrowed, replay both over the merges a repo actually made, and report the two
# numbers that matter —
#
#   STILL HELD   the holds that survive the narrowing. If this is 0 the rule holds
#                nothing, and a rule that holds nothing is ignored exactly as a rule
#                that holds everything is. Both numbers are failures; only one of them
#                looks like an improvement.
#   RELEASED     the holds that now pass unheld. This is the friction returned.
#
# NEWLY HELD is reported too, and should be 0: `surface:` is a NARROWING of the same
# glob, so a merge the coarse rule let through cannot be caught by the fine one. A
# non-zero count there means the two registries are not the same rule at two
# resolutions and the comparison is measuring something else.
#
# IT REUSES THE GATE'S OWN MATCHER — it sources engine/zones.sh and engine/surface.sh
# and calls `zones_match`, the function the merge phase calls. A measurement with its
# own copy of the rule measures the copy: it is the second-evaluator bug class this
# repo already names, wearing a lab coat. The cost is that this script must set up what
# the driver sets up (surface_scope, in the PARENT of the `$( )` that evaluates a zone)
# and nothing else.
#
# IT IS READ-ONLY. Every git command here is a query — rev-list, rev-parse, diff, log —
# against `git -C <repo>`. It never checks anything out, never writes inside the repo,
# and needs no worktree: the corpus is history, and history is already there.
#
# THE CORPUS IS THE BASE BRANCH'S FIRST-PARENT MERGES, which for a chief-run repo is
# exactly one merge per tasklist: the floor merges `--no-ff`, so a tasklist's whole
# change is `<merge>^1..<merge>`. That range is both what the zone would have matched
# on (its changed files) and what a `surface:` rule reads (its diff), so the replay
# asks the registry the same question the merge phase asked.
#
# Bash 3.2 only: no associative arrays, no `declare -A`, no process substitution.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="" ; REV="main" ; MAX=0 ; EXAMPLES=3

usage() {
  cat <<'EOF'
usage: scripts/zone-friction.sh [options] BEFORE.conf AFTER.conf

  Replays two overlap-zone registries over a repo's merge history and reports, for the
  `review` zones in each, how many holds SURVIVE the narrowing and how many are RELEASED.

  BEFORE.conf   the registry as it fires today (typically `path:` rules)
  AFTER.conf    the same rules narrowed (typically `surface:<glob>:<ere>`)

  --repo DIR      repo to measure (default: this checkout)
  --rev REF       branch whose first-parent merges are the corpus (default: main)
  --max N         cap the corpus at the N most recent merges (default: all)
  --examples N    examples printed per direction (default: 3)

  Read-only: it queries history and changes nothing. Exit 0 on a completed measurement.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     REPO="${2:-}"; shift 2 ;;
    --rev)      REV="${2:-}"; shift 2 ;;
    --max)      MAX="${2:-0}"; shift 2 ;;
    --examples) EXAMPLES="${2:-3}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    --*)        echo "zone-friction: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    *)          break ;;
  esac
done
[ $# -eq 2 ] || { usage >&2; exit 2; }
BEFORE="$1"; AFTER="$2"
[ -z "$REPO" ] && REPO="$ROOT"
for f in "$BEFORE" "$AFTER"; do
  [ -f "$f" ] || { echo "zone-friction: no such registry: $f" >&2; exit 2; }
done
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "zone-friction: not a git repo: $REPO" >&2; exit 2; }
git -C "$REPO" rev-parse --verify "$REV" >/dev/null 2>&1 || { echo "zone-friction: no such rev: $REV" >&2; exit 2; }

# The gate's own matcher, sourced the way engine/driver.sh sources it — surface.sh
# first, because zones_match's `surface)` arm calls into it and an unsourced module is
# the rc 127 that falls back to the coarse rule (which here would silently measure the
# BEFORE registry twice).
# shellcheck source=../engine/surface.sh
. "$ROOT/engine/surface.sh"
# shellcheck source=../engine/zones.sh
. "$ROOT/engine/zones.sh"

# A `touches:` matcher is UNEVALUABLE against history and is reported, never quietly
# counted as "did not hold": a merge commit carries no tasklist, so its domains are not
# in the corpus at all. Same rule as engine/status.sh's `problems` — a registry line
# missing from a total reads exactly like a registry line that matched nothing.
# PIPED THROUGH `tr`, never `|| echo 0`: `grep -c` with no match PRINTS 0 and exits 1,
# so the fallback fires on the zero case and the count reads "0\n0".
count_review()  { LC_ALL=C grep -cE '^[[:space:]]*review[[:space:]]' "$1" 2>/dev/null | tr -d ' \n'; }
count_touches() { LC_ALL=C grep -cE '^[[:space:]]*review[[:space:]]+touches:' "$1" 2>/dev/null | tr -d ' \n'; }

printf 'zone-friction — does the narrowed rule earn its friction?\n\n'
printf '  repo      %s\n' "$REPO"
printf '  corpus    first-parent merges on %s\n' "$REV"
printf '  before    %s (%s review zone(s))\n' "$BEFORE" "$(count_review "$BEFORE")"
printf '  after     %s (%s review zone(s))\n' "$AFTER"  "$(count_review "$AFTER")"
for f in "$BEFORE" "$AFTER"; do
  n="$(count_touches "$f")"
  [ "$n" = 0 ] || printf '  note      %s has %s `touches:` zone(s), NOT evaluated — a merge commit carries no tasklist\n' "$f" "$n"
done

total=0; hb=0; ha=0; both=0; released=0; newly=0
ex_both=""; ex_rel=""; ex_new=""; n_both=0; n_rel=0; n_new=0
first=""; last=""

merges="$(git -C "$REPO" rev-list --merges --first-parent "$REV" 2>/dev/null)"
[ -n "$merges" ] || { echo "zone-friction: no merge commits on $REV — nothing to measure" >&2; exit 1; }

while IFS= read -r m; do
  [ -n "$m" ] || continue
  [ "$MAX" -gt 0 ] && [ "$total" -ge "$MAX" ] && break
  p="$(git -C "$REPO" rev-parse --verify "$m^1" 2>/dev/null)" || continue
  total=$((total + 1))
  files="$(git -C "$REPO" diff --name-only "$p".."$m" 2>/dev/null)"
  # SET IN THE PARENT: zones_match's surface arm reads these two globals, and the calls
  # below run in a `$( )` whose own assignments would be thrown away.
  surface_scope "$REPO" "$p..$m"
  b="$(zones_match review "$BEFORE" "$files" "" 2>/dev/null)"
  a="$(zones_match review "$AFTER"  "$files" "" 2>/dev/null)"
  desc="$(git -C "$REPO" log -1 --format='%h %ad %s' --date=short "$m" 2>/dev/null)"
  [ -n "$first" ] || first="$(git -C "$REPO" log -1 --format='%ad' --date=short "$m" 2>/dev/null)"
  last="$(git -C "$REPO" log -1 --format='%ad' --date=short "$m" 2>/dev/null)"
  if [ -n "$b" ]; then hb=$((hb + 1)); fi
  if [ -n "$a" ]; then ha=$((ha + 1)); fi
  # The example carries the line the rule matched on, not just the sha: "this merge was
  # held" is unreadable and "this merge was held on `engine/driver.sh: +AGENT_RC_HOLD=9`"
  # is the whole finding.
  if [ -n "$b" ] && [ -n "$a" ]; then
    both=$((both + 1))
    if [ "$n_both" -lt "$EXAMPLES" ]; then
      n_both=$((n_both + 1))
      ex_both="$ex_both    $desc
      after: $(printf '%s' "$a" | head -1 | cut -f2,3 | tr '\t' ' ')
"
    fi
  elif [ -n "$b" ]; then
    released=$((released + 1))
    if [ "$n_rel" -lt "$EXAMPLES" ]; then
      n_rel=$((n_rel + 1))
      ex_rel="$ex_rel    $desc
      before: $(printf '%s' "$b" | head -1 | cut -f2,3 | tr '\t' ' ')
"
    fi
  elif [ -n "$a" ]; then
    newly=$((newly + 1))
    if [ "$n_new" -lt "$EXAMPLES" ]; then
      n_new=$((n_new + 1))
      ex_new="$ex_new    $desc
      after: $(printf '%s' "$a" | head -1 | cut -f2,3 | tr '\t' ' ')
"
    fi
  fi
done <<EOF
$merges
EOF

pct() { [ "${2:-0}" -gt 0 ] && printf '%s%%' "$(( $1 * 100 / $2 ))" || printf 'n/a'; }

printf '  span      %s … %s (%s merges)\n\n' "$last" "$first" "$total"
printf '  held by BEFORE        %4d  (%s of the corpus)\n' "$hb" "$(pct "$hb" "$total")"
printf '  held by AFTER         %4d  (%s of the corpus)\n' "$ha" "$(pct "$ha" "$total")"
printf '    still held           %4d  (%s of the holds that fired)\n' "$both" "$(pct "$both" "$hb")"
printf '    RELEASED             %4d  (%s of the holds that fired)\n' "$released" "$(pct "$released" "$hb")"
printf '    newly held           %4d  (expected 0 — a narrowing cannot catch what the glob missed)\n\n' "$newly"

[ -n "$ex_both" ] && printf '  examples — STILL HELD (the friction kept):\n%s\n' "$ex_both"
[ -n "$ex_rel" ]  && printf '  examples — RELEASED (the friction returned):\n%s\n' "$ex_rel"
[ -n "$ex_new" ]  && printf '  examples — NEWLY HELD (a narrowing should produce none):\n%s\n' "$ex_new"

# THE JUDGEMENT IS PRINTED, not left to the reader, because the failure mode this whole
# tasklist is repairing is a report nobody acts on. Both directions are failures.
if [ "$hb" -eq 0 ]; then
  printf '  VERDICT  the BEFORE registry never fired over this corpus — there is no friction to measure.\n'
elif [ "$both" -eq 0 ]; then
  printf '  VERDICT  the narrowed rule holds NOTHING over this corpus. A rule that never fires is\n'
  printf '           ignored exactly as one that always fires is; narrow the ERE less, or drop the zone.\n'
elif [ "$released" -eq 0 ]; then
  printf '  VERDICT  the narrowing released nothing — every hold that fired still fires. The ERE is not\n'
  printf '           discriminating over this corpus; it is the coarse rule spelled longer.\n'
elif [ $((released * 100 / hb)) -lt 25 ]; then
  # THE BAND EXISTS BECAUSE "RELEASED > 0" IS NOT THE QUESTION. A narrowing that returns
  # a twentieth of the friction still delivers the reader a hold on almost every merge,
  # and a hold on almost every merge is the rubber stamp this layer is being repaired
  # from. Measured here: "any function declaration under engine/" released 4 of 47 —
  # in a repo whose every tasklist authors engine functions, that ERE is the glob again.
  printf '  VERDICT  only %s of %s holds released (%s). The narrowing barely moves: over this corpus the\n' \
    "$released" "$hb" "$(pct "$released" "$hb")"
  printf '           ERE is nearly as broad as the glob, and a hold on %s of merges is still a hold\n' "$(pct "$ha" "$total")"
  printf '           nobody reads. Name the CONTENDED declaration, not every declaration.\n'
else
  printf '  VERDICT  %s of %s holds released (%s), %s kept. The rule discriminates over this corpus:\n' \
    "$released" "$hb" "$(pct "$released" "$hb")" "$both"
  printf '           it asks about %s of merges instead of %s, and what it still asks about is the\n' \
    "$(pct "$ha" "$total")" "$(pct "$hb" "$total")"
  printf '           surface itself. It holds neither everything nor nothing.\n'
fi
exit 0
