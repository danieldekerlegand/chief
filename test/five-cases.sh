#!/usr/bin/env bash
# test/five-cases.sh — the proving run for tasklist 98: replay the five stories that
# reported green against criteria they had not met (2026-08-16/17), and prove each one
# now FAILS; then replay three tasklists that were genuinely green and prove they still
# merge. Both halves in ONE run, because a gate that fails honest work is worse than no
# gate — it gets switched off, and then the five come back.
#
# FIXTURES, NOT RE-RUNS. Each fixture carries the recorded SHAPE of its case — the
# deciding acceptance criteria verbatim from the filed tasklist, and the agent
# behaviour the record shows (self-marked or force-passed, notes present or empty).
# Re-running the originals would need three sibling repos and their toolchains, and
# would prove that today's code passes rather than that the gate catches the shape.
#
# THE FIVE (from the incident table in tasks/chief/98-…):
#   fc-346-us3   cuneiform:346/US-3 — "file `argos:82` to completed/"; still active
#                → UNSATISFIABLE (scope, engine/criteria.sh), before any agent turn
#   fc-347-us4   cuneiform:347/US-4 — "unpark `argos:90`"; neither done
#                → UNSATISFIABLE (scope), before any agent turn
#   fc-347-us1   cuneiform:347/US-1 — "renders BYTE-IDENTICALLY"; it did not render
#                → UNVERIFIED (bar, engine/measure.sh)
#   fc-348-us2   cuneiform:348/US-2 — "GREEN acceptance, baseline 77 failed"; got 25
#                → UNVERIFIED (bar)
#   fc-164       insimul:164 — restarted at 0/3 with work committed, notes empty
#                → UNVERIFIED (evidence, driver.sh evidence_gate)
#   fc-347-us1 carries US-1's own two criteria only: the story's third criterion names
#   `argos:90`, so the real 347 would have been stopped by the SCOPE gate first. The
#   fixture isolates the bar so the byte-identical claim is proven on its own merits.
#
# THE THREE GREEN ONES (US-4's regression half), replayed with the notes AS RECORDED:
#   gr-344       cuneiform:344 — bars in its criteria (BYTE-IDENTICAL), notes full of
#                measured values → MERGED. The gate fires and the honest record clears it.
#   gr-349       cuneiform:349 — no bar claimed, notes EMPTY on all three stories, all
#                self-marked → MERGED. An honest self-reporting run pays nothing.
#   gr-104       pinakes:104 — bars ("reports zero errors", "stays green") with EMPTY
#                notes → UNVERIFIED. THE ONE MEASURED COST, asserted here so it stays
#                visible: the work was done, the record does not say so, and from the
#                record chief cannot tell it from cuneiform:348. Remedy proven below.
#   gr-104-fix   the same criteria with the observed values written down → MERGED.
#                One line of notes is the whole price.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=fc GIT_AUTHOR_EMAIL=fc@test GIT_COMMITTER_NAME=fc GIT_COMMITTER_EMAIL=fc@test
export CHIEF_RUNS="$WORK/runs" CHIEF_REPOS="$WORK/repos" CHIEF_WORKTREE_ROOT="$WORK/wt"  # hermetic: don't touch ~/.chief
fail() { echo "FIVE-CASES FAIL: $*" >&2; [ -f "$WORK/run.log" ] && tail -40 "$WORK/run.log" >&2; exit 1; }
logof() { echo "$WORK/repo/.chief/state/parallel/$1.log"; }
command -v jq >/dev/null || fail "jq required"

# ── install chief from this checkout ──────────────────────────────────────────
PREFIX="$WORK/ch"; BIN="$WORK/bin"
CHIEF_REPO="file://$ROOT" CHIEF_VERSION="$(git -C "$ROOT" rev-parse HEAD)" \
  CHIEF_PREFIX="$PREFIX" CHIEF_BINDIR="$BIN" sh "$ROOT/install.sh" >/dev/null || fail "install failed"
CHIEF="$BIN/chief"

# ── fake `claude`: one behaviour per recorded case ────────────────────────────
# Every arm commits real work, so the EMPTY-NO-WORK guard is never what stops a
# branch here — what stops it is the criteria, which is the whole point.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/claude" <<FAKE
#!/usr/bin/env bash
set -eu
cat >/dev/null                                   # drain the prompt
PRD=".chief/state/prd.json"                      # cwd = the worktree
name="\$(jq -r '.branchName' "\$PRD" | sed 's#^chief/##')"
echo "\$name" >> "$WORK/agent-turns.txt"         # the ledger the scope gate must keep empty
mkdir -p out; printf 'impl %s\n' "\$name" > "out/\$name.txt"
case "\$name" in
  # The two bar cases: the agent says what it DID, and records no value. This is the
  # exact shape of 347/US-1 (a long declaration note, no render compared) and 348/US-2.
  fc-347-us1) note="Added the extension seam and re-rendered the fixture export." ;;
  fc-348-us2) note="Bound the export-owned skill and re-ran the product acceptance." ;;
  # insimul:164: work committed, stories left false, nothing said. Chief's COMPLETE
  # path is what would promote them — the evidence gate is what must not.
  fc-164)     note="" ;;
  gr-344)     note="AC-4 — the vendored fixture is byte-identical to its source: sha256 8cccab72 on both sides, cmp exit 0; 1401 lines each. Re-vendor restamps and a bare run verifies." ;;
  gr-349)     note="" ;;                          # as recorded: empty on all three stories
  gr-104)     note="" ;;                          # as recorded: empty on both stories
  gr-104-fix) note="bun run check: 0 errors (was 34). check:scripts clean. bun run test green, 412 passed 0 failed." ;;
  *)          note="did the work" ;;
esac
t="\$(mktemp)"
if [ "\$name" = "fc-164" ]; then
  # Leaves every story passes:false with empty notes — the 164 shape exactly.
  cp "\$PRD" "\$t"
else
  jq --arg n "\$note" '.userStories |= map(.passes=true | .notes=\$n)' "\$PRD" > "\$t"
fi
mv "\$t" "\$PRD"
cp "\$PRD" "tasks/chief/\$name.json" 2>/dev/null || true
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
# The verify hook would ALLOW every one of these merges. Nothing below is stopped by a
# test failing — they are stopped by what their criteria claim, which is the distinction
# tasklist 98 exists to draw ("verify is the real merge bar" was never the whole bar).
printf '#!/usr/bin/env bash\nset -eu\necho "verify: (would pass)"\nexit 0\n' > .chief/verify.sh
chmod +x .chief/verify.sh

tasklist() {  # tasklist NAME STORIES-JSON
  jq -n --arg n "$1" --argjson s "$2" \
    '{project:"fc",branchName:("chief/"+$n),description:("replay of "+$n),iters:2,
      dependsOn:[],touches:[$n],warmup:[],userStories:$s}' > "tasks/chief/$1.json"
}

# ── the five, criteria verbatim from the filed tasklists ─────────────────────
tasklist fc-346-us3 '[
  {"id":"US-1","title":"The generated console consumes @cuneiform/network-graph","description":"",
   "acceptanceCriteria":["The package is consumed at a pinned version, and the vendoring/refresh path is written down: `argos:82`/US-NA1 and US-NA3 both called for a step-by-step tarball-refresh protocol, and that need survives the fold."],"passes":false,"notes":""},
  {"id":"US-3","title":"Prove it survives a re-export, and retire the downstream tasklist","description":"",
   "acceptanceCriteria":["`argos/tasks/chief/82-network-ui-adoption.json` is moved to `completed/` with `supersededBy: cuneiform:346-console-network-graph-adoption` and NO `mergedToMain`, matching how the other 26 argos folds are filed."],"passes":false,"notes":""}]'

tasklist fc-347-us4 '[
  {"id":"US-4","title":"Unpark what this earns, and say what it does not","description":"",
   "acceptanceCriteria":["`argos:90` is unparked, with a note recording that its gate was this tasklist and that `cuneiform:345` was its predecessor.","State plainly what remains unearned: the UI extension surface is still last per ADR-0015."],"passes":false,"notes":""}]'

tasklist fc-347-us1 '[
  {"id":"US-1","title":"A spec declares MCP tools and A2A skills; an export declaring none is byte-identical to today","description":"",
   "acceptanceCriteria":["A spec can declare extension MCP tools and A2A skills, and they are rendered into `_mcp/` and `_a2a/` alongside the generated ones.","An export that declares no extensions renders **byte-identically** to the current output. This is the regression that matters: a seam that perturbs the baseline is a seam that breaks every product to serve one."],"passes":false,"notes":""}]'

tasklist fc-348-us2 '[
  {"id":"US-2","title":"Proven on argos, the export that exposed it","description":"",
   "acceptanceCriteria":["`scripts/reexport-product.sh argos` reaches GREEN acceptance: argos own `uv run --extra dev pytest -q` and `.chief/verify.sh` both pass on a freshly rendered tree. The current baseline to beat is **77 failed, 860 passed, 39 errors**.","The specific fixture that exposed it passes, and the trace ops match the values the product declares."],"passes":false,"notes":""}]'

tasklist fc-164 '[
  {"id":"US-1","title":"Move suggestion ranking into core and de-duplicate the three engines","description":"",
   "acceptanceCriteria":["Candidate ranking lives in core over an engine-neutral candidate shape; the engines supply candidates and render results.","A conformance corpus pins ranking for fixed inputs so three engines cannot re-diverge."],"passes":false,"notes":""},
  {"id":"US-2","title":"Declared asset libraries: say where your assets live","description":"",
   "acceptanceCriteria":["A creator can declare one or more asset library roots, scoped so they can be reused across projects, with the declaration serializable and shareable."],"passes":false,"notes":""},
  {"id":"US-3","title":"Portable binding intent across engines","description":"",
   "acceptanceCriteria":["A binding pack separates ENGINE-NEUTRAL intent from the ENGINE-SPECIFIC handle, so the same intent can carry a Unity prefab and a Godot PackedScene."],"passes":false,"notes":""}]'

# ── the three that were genuinely green ──────────────────────────────────────
tasklist gr-344 '[
  {"id":"US-2","title":"Vendor the product spec the way the sibling product is vendored","description":"",
   "acceptanceCriteria":["`--update` re-vendors and restamps; a bare run verifies. The sha256 pin holds UNCONDITIONALLY.","The fixture is BYTE-IDENTICAL to its declared source, including the `package:` line, so the fixture must not be pre-edited to disguise a difference."],"passes":false,"notes":""}]'

green_349='[
  {"id":"US-1","title":"The stdlib-only sentence renders only when it is true","description":"",
   "acceptanceCriteria":["The stdlib-only sentence renders only for an export that genuinely declares no runtime dependencies, derived from the same source `pyproject.toml` is rendered from — not from a hand-maintained second list, which would be a new place to drift.","Every occurrence is covered. The claim is restated further down the same template, and fixing only the opener leaves the falsehood in the body."],"passes":false,"notes":""},
  {"id":"US-2","title":"Proven on both products","description":"",
   "acceptanceCriteria":["A test asserts the property from the SPEC side — an export declaring dependencies must not render the stdlib-only claim — so the sentence cannot return the next time this template is edited.","NOTHING is written into either product repo. The fix is in the generator and arrives by re-export."],"passes":false,"notes":""},
  {"id":"US-3","title":"Record it where each products owner will read it","description":"",
   "acceptanceCriteria":["`docs/reference/product-reexport-acceptance.md` records that the stdlib-only falsehood is fixed upstream and names the release from which a re-render is safe."],"passes":false,"notes":""}]'
tasklist gr-349 "$green_349"

green_104='[
  {"id":"US-1","title":"Drive `bun run check` to zero errors","description":"",
   "acceptanceCriteria":["`bun run check` (tsc -p web/tsconfig.json) reports zero errors; the fixes are type-only (no behavior change) and do not weaken config by disabling strictness wholesale or blanket `// @ts-ignore`.","`bun run check:scripts` (scripts/ has its own tsconfig) is also clean.","`bun run test` (vitest) stays green — no test was broken to satisfy the typechecker."],"passes":false,"notes":""},
  {"id":"US-2","title":"Retire the legacy baseline shim","description":"",
   "acceptanceCriteria":["The .chief/verify.sh TS check needs no baseline-diff shim (it can stay the hard gate its header describes); a note records that the legacy baseline is retired."],"passes":false,"notes":""}]'
tasklist gr-104     "$green_104"
tasklist gr-104-fix "$green_104"

git add -A && git commit -q -m "fc setup"

# ── authoring time: `chief lint` catches the two scope cases before a run at all ──
for n in fc-346-us3 fc-347-us4; do
  if "$CHIEF" lint "$n" >"$WORK/lint-$n.log" 2>&1; then
    cat "$WORK/lint-$n.log"; fail "chief lint passed $n — a criterion naming another repo"
  fi
done
for n in gr-344 gr-349 gr-104; do
  "$CHIEF" lint "$n" >>"$WORK/lint-green.log" 2>&1 \
    || { cat "$WORK/lint-green.log"; fail "chief lint rejected $n, a tasklist that was genuinely green"; }
done

# ── the run ──────────────────────────────────────────────────────────────────
S=$(date +%s)
PATH="$WORK/fakebin:$PATH" "$CHIEF" run >"$WORK/run.log" 2>&1 || { cat "$WORK/run.log"; fail "run exited non-zero"; }
E=$(date +%s)
status() { cat "$REPO/.chief/state/parallel/$1.status" 2>/dev/null || echo MISSING; }
git checkout -q main

# ── 1. each of the five FAILS, and nothing of it lands ───────────────────────
for n in fc-346-us3 fc-347-us4; do
  case "$(status $n)" in UNSATISFIABLE*) ;; *) fail "$n: expected UNSATISFIABLE, got '$(status $n)'" ;; esac
done
for n in fc-347-us1 fc-348-us2 fc-164; do
  case "$(status $n)" in UNVERIFIED*) ;; *) fail "$n: expected UNVERIFIED, got '$(status $n)'" ;; esac
done
for n in fc-346-us3 fc-347-us4 fc-347-us1 fc-348-us2 fc-164; do
  [ ! -f "out/$n.txt" ]                   || fail "$n merged to main — a replayed failure passed"
  [ ! -f "tasks/chief/completed/$n.json" ] || fail "$n was retired — a replayed failure was recorded as done"
done

# ── 2. the two structurally unsatisfiable ones cost ZERO agent turns ─────────
for n in fc-346-us3 fc-347-us4; do
  grep -qx "$n" "$WORK/agent-turns.txt" && fail "$n spent an agent turn on a criterion its worktree cannot satisfy"
done
grep -q 'argos:82' "$(logof fc-346-us3)"  || fail "fc-346-us3 never names the reference it cannot reach"
grep -q 'argos:90' "$(logof fc-347-us4)"  || fail "fc-347-us4 never names the reference it cannot reach"
grep -q 'crossRepo' "$(logof fc-346-us3)" || fail "the stop never names the escape hatch a real cross-repo tasklist would use"

# ── 3. each failure says WHAT was claimed, not that a count did not match ────
grep -q 'byte-identically' "$(logof fc-347-us1)" || fail "fc-347-us1 never quotes the byte-identical claim"
grep -q '77 failed'        "$(logof fc-348-us2)" || fail "fc-348-us2 never quotes the 77-failed baseline"
grep -q 'states a bar'     "$(logof fc-348-us2)" || fail "fc-348-us2 never names the bar that fired"
grep -q 'conformance corpus' "$(logof fc-164)"   || fail "fc-164 never quotes the criterion it claimed"
for id in US-1 US-2 US-3; do
  grep -q "✗ $id" "$(logof fc-164)" || fail "fc-164 reported fewer than all three unevidenced stories ($id missing)"
done

# ── 4. REGRESSION: work that genuinely met its criteria still merges ─────────
for n in gr-344 gr-349 gr-104-fix; do
  case "$(status $n)" in MERGED*) ;; *) fail "$n did not merge, got '$(status $n)' — the gate fails honest work"; esac
  [ -f "out/$n.txt" ]                     || fail "$n's work is not on main"
  [ -f "tasks/chief/completed/$n.json" ]  || fail "$n was not retired"
done
# gr-349 is the strongest of the three: three stories, EMPTY notes as recorded, all
# self-marked, and it merges untouched. Self-reported honest work pays no ceremony.
[ "$(jq '[.userStories[]|select(.notes=="")]|length' tasks/chief/completed/gr-349.json)" = 3 ] \
  || fail "gr-349 did not merge with the empty notes its record actually carries"
grep -q 'unverified' tasks/chief/completed/gr-344.json && fail "gr-344's measured record was marked unverified"

# ── 5. the one measured cost, stated rather than hidden ──────────────────────
# pinakes:104 claims "zero errors" and "stays green" and its filed record says nothing
# about either. The work was done; the record cannot show it, and from the record chief
# cannot tell it apart from cuneiform:348, which claimed GREEN and delivered 25 failed.
case "$(status gr-104)" in UNVERIFIED*) ;; *) fail "gr-104: expected UNVERIFIED on empty notes, got '$(status gr-104)'" ;; esac
grep -q 'zero errors' "$(logof gr-104)" || fail "gr-104's stop never quotes the bar it is held to"
# …and the remedy is one line of notes, on identical criteria: gr-104-fix merged above.
echo "five-cases: 9 replayed tasklists in $((E-S))s wall-clock (the gates' own share is milliseconds — see below)"

# ── 6. the added cost, measured ──────────────────────────────────────────────
# Both gates are pure jq over the tasklist, run once per tasklist per run and never
# during the agent loop. Timed here so a future change that makes them expensive fails
# the test rather than being discovered as a disabled gate.
. "$ROOT/engine/measure.sh"; . "$ROOT/engine/criteria.sh"
_int() { printf '%s' "${1:-0}" | tr -cd '0-9' | sed 's/^$/0/'; }
BIG="$ROOT/tasks/chief/98-unverified-criteria-must-not-pass.json"   # this repo's largest
[ -f "$BIG" ] || BIG="$REPO/tasks/chief/gr-104.json"
cp "$BIG" "$WORK/cost.json"
GS=$(date +%s)
for _ in 1 2 3 4 5; do
  measure_gate "$WORK/cost.json" >/dev/null
  criteria_scope_report "$WORK/cost.json" "$REPO" >/dev/null
done
GE=$(date +%s)
[ $((GE-GS)) -le 5 ] || fail "5 passes of both gates over one tasklist took $((GE-GS))s — too slow to survive on every run"
echo "five-cases: 5 passes of measure_gate + criteria_scope_report over $(basename "$BIG"): $((GE-GS))s"

echo "FIVE-CASES PASS — all five recorded failures now fail (2 before any agent turn); 344/349 and a measured 104 still merge; 104-as-recorded is the one stated cost"
