#!/usr/bin/env bash
# engine/lib.sh — shared helpers sourced by the driver.
#
# Expects these globals (set by driver.sh from bin/chief + the project config):
#   CHIEF_PROJECT   project root (the base working tree; verify + merge run here)
#   TASKS_REL       tasklists dir, RELATIVE to the project (e.g. tasks/chief)
#   TASKS_DIR       tasklists dir, ABSOLUTE
#   COMPLETED       $TASKS_DIR/completed (absolute)
#   STATE           runtime state dir (absolute; holds snapshots/)
#   VERIFY_HOOK     absolute path to the project verify hook (or empty to skip)
#   BASE_BRANCH     integration branch (e.g. main)

# WHICH GATES ACTUALLY EXECUTED is written into the completed record here, so
# engine/cigate.sh comes with it. Sourcing costs nothing (assignments and function
# definitions only) and keeps the three-state vocabulary — RAN AND PASSED · RAN
# AND FAILED · DID NOT RUN — stated in exactly one file.
# shellcheck source=engine/cigate.sh
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cigate.sh"

# chief_scan_descendants PID [EXTRA_PIDS] — collect every LIVE process descended
# from PID (plus any still-live pid named in EXTRA_PIDS) into the global
# CHIEF_DESCENDANTS, space-separated, DEEPEST layer first.
#
# This is the reap primitive teardown is built on, and it deliberately walks the
# ps parent/child tree instead of matching argv: the processes that matter —
# driver.sh's worker subshells, engine/agent.sh, and `claude --print` — carry no
# distinguishing string on their command line at all, so any `pgrep -f` pattern
# matches only their transient grandchildren and leaves the engine itself running.
# Parentage is the one relation that holds for the whole chain.
#
# EXTRA_PIDS exists because parentage alone is not quite enough DURING a reap: when
# an agent.sh frame dies first, its `claude` child is reparented to init and stops
# being a descendant of anything. Carrying the originally-collected set forward is
# what keeps an escapee visible instead of silently "gone".
#
# ZOMBIES are excluded via ps's stat column, and that is load-bearing: a worker
# subshell the driver has TERMed but not yet `wait`ed is a zombie, and `kill -0`
# SUCCEEDS on a zombie. A liveness test built on kill alone would therefore report
# the tree as still running forever, and teardown would refuse to release records
# it is supposed to release.
#
# Sets a GLOBAL rather than printing, on purpose: called as `$(...)` it would run in
# a subshell that is itself a live descendant of PID, and would report itself. As a
# plain call the only transient children are this function's own `ps`/`awk`, which
# are dead by the time the liveness filter runs and are dropped there.
#
# bash 3.2: no arrays, no process substitution, no `pgrep -P` (Linux-only flags).
CHIEF_DESCENDANTS=""
chief_scan_descendants() {
  local root="$1" extra="${2:-}" snap frontier next out="" depth=0 p kids live=""
  CHIEF_DESCENDANTS=""
  case "$root" in ''|*[!0-9]*) return 0 ;; esac
  snap="$(ps -eo pid=,ppid=,stat= 2>/dev/null | awk '$3 !~ /^Z/ {print $1, $2}')"
  [ -n "$snap" ] || return 0
  frontier="$root"
  # Breadth-first, depth-bounded: a ps snapshot is a forest, but pid reuse between
  # the snapshot and the walk must never turn a cycle into an infinite loop.
  while [ -n "$frontier" ] && [ "$depth" -lt 32 ]; do
    next=""
    for p in $frontier; do
      kids="$(printf '%s\n' "$snap" | awk -v pp="$p" '$2==pp && $1!=pp {print $1}')"
      [ -n "$kids" ] && next="$next $kids"
    done
    [ -n "$next" ] && out="$next $out"     # prepend: deepest layer ends up first
    frontier="$next"
    depth=$(( depth + 1 ))
  done
  for p in $extra; do
    case " $out " in *" $p "*) continue ;; esac
    printf '%s\n' "$snap" | awk -v q="$p" '$1==q {f=1} END{exit !f}' && out="$out $p"
  done
  for p in $out; do
    case " $live " in *" $p "*) continue ;; esac
    kill -0 "$p" 2>/dev/null && live="$live $p"
  done
  # shellcheck disable=SC2086
  set -- $live
  CHIEF_DESCENDANTS="$*"
  return 0
}

# WHAT IS SITTING IN THE WORKTREE, UNCOMMITTED — the other half of the question
# branch_has_real_work() answers. That one asks about COMMITS, and a run that stops
# without committing answers it `no` while its whole output sits on disk: talos,
# 2026-08-24, tasklist 71 rendered `✗ failed · no progress last iter` with 2,029
# correctly-placed files staged and untracked in its worktree, and an operator reading
# that row would reasonably conclude the tasklist was broken and re-scope it. "No work
# produced" and "work produced but never committed" are a real signal and a
# RECOVERABLE state, and until now they printed the same.
#
# BEST-EFFORT BY CONSTRUCTION, and that is a requirement rather than a nicety: this is
# a reporting improvement and must never become a new way for a run to die. A missing
# worktree, a broken gitdir link, an unreadable index, an awk that chokes — every one
# of them resolves to an empty string, which reads as "nothing to add" at both call
# sites. One `git status` and one awk pass, run once per stop, never in a loop.
#
# `-uall` on purpose: git's default collapses an untracked directory into ONE porcelain
# line, so tasklist 71 would have reported "1 uncommitted file" for its 2,029. Git does
# not descend into IGNORED directories either way, so the expensive trees (target/,
# node_modules/ — engine/sweep.sh's whole table) are skipped, not walked.
#
# LC_ALL=C because agent-authored paths are UTF-8 and this awk uses substr() — see
# CLAUDE.md; BSD awk aborts on a multi-byte character in a UTF-8 locale.
#
# $1 = the worktree. Prints ONE human phrase, or '' when the tree is clean or unreadable.
worktree_pending() {
  [ -d "${1:-}" ] || return 0
  LC_ALL=C git -C "$1" status --porcelain -uall 2>/dev/null | LC_ALL=C awk '
    {
      n++
      x = substr($0, 1, 1); y = substr($0, 2, 1)
      if (x == "?") untracked++
      else { if (x != " ") staged++; if (y != " ") unstaged++ }
      # The TOP-LEVEL prefix, in first-seen order. "2,029 files" is a number;
      # "dogfood/open-rts/" is where to look — the criterion is that the report NAMES
      # what is there. A rename prints `old -> new`; the destination is what is on disk.
      p = substr($0, 4)
      i = index(p, " -> "); if (i > 0) p = substr(p, i + 4)
      sub(/^"/, "", p)
      j = index(p, "/"); top = (j > 0) ? substr(p, 1, j) : p
      if (!(top in seen)) {
        seen[top] = 1; ntop++
        if (ntop <= 3) tops = tops (tops == "" ? "" : ", ") top
      }
    }
    END {
      if (n == 0) exit 0
      if (untracked) parts = untracked " untracked"
      if (unstaged)  parts = parts (parts == "" ? "" : ", ") unstaged " modified"
      if (staged)    parts = parts (parts == "" ? "" : ", ") staged " staged"
      printf "%d uncommitted file(s)", n
      if (parts != "") printf " (%s)", parts
      if (tops  != "") { printf " · %s", tops; if (ntop > 3) printf " +%d more", ntop - 3 }
      printf "\n"
    }' 2>/dev/null
  return 0
}

# verify_branch [cwd] — run the project's verify hook for the CURRENTLY checked-out
# branch. Contract: exit 0 = pass, non-zero = fail. Runs with cwd = $1 (default
# $CHIEF_PROJECT; the driver passes the submodule work-repo for `repo:<sub>`
# tasklists) and the branch checked out. CHIEF_PROJECT + CHIEF_BASE_BRANCH are
# exported pointing at that repo/base so the hook can baseline failures and, for a
# submodule, dispatch its checks off the cwd. No hook configured => skipped (pass).
verify_branch() {
  local cwd="${1:-$CHIEF_PROJECT}"
  if [ -z "${VERIFY_HOOK:-}" ]; then echo "  verify: (no hook configured — skipped)"; return 0; fi
  if [ ! -x "$VERIFY_HOOK" ]; then echo "  ✗ verify hook not executable: $VERIFY_HOOK"; return 1; fi
  # Export STRICT_VERIFY/NO_VERIFY too, so a hook can baseline NEW failures vs the
  # base branch rather than failing on debt that pre-exists on it (see docs/reference/verify-hook.md).
  ( cd "$cwd" && CHIEF_BASE_BRANCH="${work_base:-$BASE_BRANCH}" CHIEF_PROJECT="$cwd" \
      STRICT_VERIFY="${STRICT_VERIFY:-0}" NO_VERIFY="${NO_VERIFY:-0}" "$VERIFY_HOOK" )
}

# finalize_merged NAME BRANCH SHA [WORK_REPO] [SUB] — after a clean merge of the
# branch into its base: write the merged record (all stories passed + mergedToMain
# sha) into completed/, retire the source tasklist, and delete the branch.
#
# The record + retire always live in the PROJECT (tasklists are a project concern).
# For a submodule tasklist (SUB non-empty) the branch was merged inside the
# submodule (WORK_REPO); its new base sha is now the submodule's checked-out HEAD, so
# we stage the submodule pointer in the project and fold that bump into the same
# retire commit. The branch is deleted in WORK_REPO (where it lives).
# PARENT-INDEX LOCK. Workers run concurrently but share ONE project index, so any git
# op that mutates it (the driver's isolation guard, the retire below) must be serialized
# — otherwise a loser of the index.lock race fails, and because these calls are
# error-suppressed it fails SILENTLY: the tasklist merges but is never retired, then
# shows up as "pending" forever. Short-held mkdir lock, same pattern as WT_LOCK.
idx_lock()   { local w=0; while ! mkdir "${IDX_LOCK:-/tmp/.chief-idx.lock}" 2>/dev/null; do sleep 1; w=$(( w + 1 )); [ "$w" -gt 120 ] && break; done; }
idx_unlock() { rmdir "${IDX_LOCK:-/tmp/.chief-idx.lock}" 2>/dev/null || true; }

# run_verify CWD NAME — the merge gate for ONE tasklist.
#
# A per-tasklist `"verify": ["cmd", ...]` array takes precedence over the project-wide
# hook: each command runs with cwd = the WORK repo (the submodule for a repo:<sub>
# tasklist), so a multi-repo project doesn't need one hook script dispatching off cwd.
# With no per-tasklist commands this falls through to the project hook (verify_branch),
# and with neither, verification is skipped (treated as a pass) exactly as before.
run_verify() {
  local cwd="$1" name="$2" cmds rc=0
  cmds="$(jq -r '(.verify // [])[]' "$TASKS_DIR/$name.json" 2>/dev/null || true)"
  if [ -n "$cmds" ]; then
    echo "  verify: per-tasklist commands (cwd=$(basename "$cwd"))"
    while IFS= read -r c; do
      [ -z "$c" ] && continue
      echo "    \$ $c"
      ( cd "$cwd" && CHIEF_BASE_BRANCH="${work_base:-$BASE_BRANCH}" CHIEF_PROJECT="$cwd" \
          STRICT_VERIFY="${STRICT_VERIFY:-0}" NO_VERIFY="${NO_VERIFY:-0}" eval "$c" ) \
        || { echo "    ✗ failed: $c"; rc=1; break; }
    done <<< "$cmds"
    return $rc
  fi
  verify_branch "$cwd"
}

# The merge gate's verdict cache. A rebase can rewrite commit ids without changing
# the tree, so the tree is the correctness key. The base commit and verify-hook
# blob are part of it too. Records are per repository and bounded.
verify_cache_dir() {
  local cwd="$1" root cache_repo="${VERIFY_CACHE_REPO:-$cwd}"
  root="$(git -C "$cache_repo" rev-parse --show-toplevel 2>/dev/null || echo "$cache_repo")"
  printf '%s/verify-cache/%s' "$STATE" "$(printf '%s' "$root" | cksum | awk '{print $1}')"
}

# verify_cache_subs CWD — the SUBMODULE CHECKOUT the gate will see, digested.
#
# The fourth component of the key, and it is in there because CHIEF ITSELF moves it.
# A project worktree never initializes its submodules, so the agent boundary runs the
# hook with `dep/` an EMPTY DIRECTORY; the merge phase runs `submodules_sync` first
# (93) and runs the same hook, over the same tree, against a submodule checked out to
# match the gitlink. Same tree sha, same base, same hook, DIFFERENT FILESYSTEM — and
# a hook that looks inside a submodule answers differently in the two places.
# test/submodule-gitlink.sh is exactly that gate, and with a three-part key it read
# the boundary's legitimate red ("submodule working tree is STALE") back at the merge
# and never re-ran the check `93` exists to guarantee.
#
# `-` vs ` ` in `git submodule status` is the whole distinction (uninitialized vs
# checked out), but the sha is digested with it so a gitlink that moved without the
# tree moving misses too. A repo with no submodules digests to a constant and the key
# behaves exactly as it did before.
verify_cache_subs() {
  local st
  st="$(git -C "$1" submodule status --recursive 2>/dev/null || true)"
  [ -n "$st" ] || { printf 'nosub'; return 0; }
  printf '%s' "$st" | cksum | awk '{print $1}'
}

# verify_cache_try CWD NAME BASE — is this exact gate run already answered?
#
# THE KEY IS THE WHOLE ARGUMENT. `tree.base.hook.subs` names the four inputs the gate
# is a function of: HEAD's tree, the base commit it is measured against, the blob of
# the hook doing the measuring, and the submodule checkout it will see. If none of
# them has moved, a second run is not a second sample — it is the SAME COMPUTATION,
# and its answer cannot have changed. That reasoning says nothing about the verdict's
# VALUE, so a RED record is reused on exactly the same terms a green one is.
#
# It did not used to be. Until 120 only `status=0` was honoured and every other
# status fell through to a full re-run, so an agent that could not fix a gate paid
# the whole gate again each iteration to be told the same thing. Measured on
# cuneiform 2026-09-03: `388-the-panel-emission-contract` ran 01:55→07:52, merged
# nothing, and spent FIVE full gate runs (~11.6 min each) reporting the SAME single
# assertion failure six times — over a tree the agent had, in its own words, nothing
# left to change in, and therefore never changed.
#
# THIS IS NOT THE FLAKY-TEST CASE. The argument for re-running a red gate is that the
# red may be noise. That argument is about re-running after SOMETHING CHANGED — a
# different tree, a moved base, an edited hook — and in every one of those cases the
# key has already moved and this function has already missed. Here nothing changed.
#
# WHY THE DEFAULT IS SAFE, AND WHERE THE HATCH IS. The default rests on one claim:
# for a FIXED tree, base, hook and submodule checkout the gate is a deterministic
# function of its inputs, so a second run is not a second sample — it is the same
# computation, and re-running it can only reproduce the answer already on disk. A
# gate for which that claim is false (a real clock, a real network, a race, an
# order-dependent suite) is a gate whose verdict was never a property of the tree in
# the first place, and chief cannot detect that from the outside: both runs are just
# a status. So it is the OPERATOR who says so — `CHIEF_VERIFY_CACHE=0` makes every
# lookup here decline, the gate runs, and its fresh verdict OVERWRITES the record
# (every caller of this function records after running, so nothing extra is needed
# to make the stale answer go away). It is the same shape as the engine's other
# opt-outs — CHIEF_VERIFY_TESTS=0, CHIEF_SWEEP=0, CHIEF_MERGE_BATCH_BISECT=0 — and
# it is exported through the driver to the agent boundary and the merge phase alike,
# so one variable clears both reads of a run. Documented in
# docs/reference/verify-hook.md beside `chief verify`.
#
# RETURNS THE RECORDED EXIT STATUS on a hit, and 1 on a miss — deliberately in that
# direction, because the two are not distinguishable from the return alone and one of
# the two confusions is much worse than the other. A caller that checks only the
# return treats a red hit as a miss and re-runs the gate: wasteful, never wrong. The
# inverse convention (0 = hit) would make the same oversight skip the gate and accept
# a failing tree. $VERIFY_CACHE_HIT is how a caller tells a red hit from a miss;
# $VERIFY_CACHE_RECORD names the record and $VERIFY_CACHE_STATUS its verdict.
verify_cache_try() {
  local cwd="$1" name="$2" base="$3" dir key rec tree st
  VERIFY_CACHE_HIT=0; VERIFY_CACHE_STATUS=""; VERIFY_CACHE_RECORD=""
  [ -n "${VERIFY_HOOK:-}" ] && [ -x "$VERIFY_HOOK" ] || return 1
  [ -z "$(jq -r '(.verify // [])[]' "$TASKS_DIR/$name.json" 2>/dev/null || true)" ] || return 1
  dir="$(verify_cache_dir "$cwd")"
  tree="$(git -C "$cwd" rev-parse HEAD^{tree} 2>/dev/null || echo)"
  key="$tree.$(git -C "$cwd" rev-parse "$base" 2>/dev/null || echo).$(git hash-object "$VERIFY_HOOK" 2>/dev/null || echo no-hook).$(verify_cache_subs "$cwd")"
  rec="$dir/$key"; [ -f "$rec" ] || return 1
  # THE ESCAPE HATCH, checked here rather than at the top so it can name the record it
  # is deliberately ignoring: "the gate ran" and "the gate ran because you asked it to"
  # are different log lines, and an operator chasing a flaky gate needs the second.
  if [ "${CHIEF_VERIFY_CACHE:-1}" = 0 ]; then
    echo ">> verify cache DISABLED (CHIEF_VERIFY_CACHE=0): a matching verdict exists ($rec) and is being IGNORED — the gate runs, and its result replaces that record"
    return 1
  fi
  st="$(sed -n 's/^status=//p' "$rec" | head -1)"
  case "$st" in ''|*[!0-9]*) return 1 ;; esac          # unreadable record = no record
  [ "$(sed -n 's/^tree=//p' "$rec" | head -1)" = "$tree" ] || return 1
  VERIFY_CACHE_HIT=1; VERIFY_CACHE_STATUS="$st"; VERIFY_CACHE_RECORD="$rec"
  if [ "$st" = 0 ]; then
    echo ">> verify SKIPPED: tree $tree (GREEN verdict from $rec; same base and verify hook)"
  else
    # Named in its own words: an operator reading a log must never have to work out
    # whether the gate ran, and "SKIPPED" alone beside a refused completion reads as
    # a contradiction unless the verdict it was skipped ON is on the same line.
    echo ">> verify SKIPPED: tree $tree (RED verdict, exit $st, from $rec; same base and verify hook) — the gate was NOT re-run; its recorded output follows"
  fi
  return "$st"
}

# verify_cache_output — replay the failing gate's own output for the record
# `verify_cache_try` just hit, on stdout, for the caller to log or persist.
#
# The status alone is not enough. A reused red that names no failing test leaves the
# agent with a blocked completion and nothing to act on — the invisibility 119 fixed,
# arriving through a different door — so the output is retained with the record and
# replayed with it. Prints nothing for a green hit or a miss.
verify_cache_output() {
  local rec="${VERIFY_CACHE_RECORD:-}"
  [ "${VERIFY_CACHE_HIT:-0}" = 1 ] || return 0
  [ -n "$rec" ] && [ "${VERIFY_CACHE_STATUS:-0}" != 0 ] || return 0
  if [ -s "$rec.out" ]; then
    cat "$rec.out"
  else
    echo "   (this verdict was recorded without its output — the gate's own report is not available for replay)"
  fi
  return 0
}

# verify_cache_record CWD BASE STATUS [OUTPUT_FILE] — write the verdict for HEAD's
# tree. OUTPUT_FILE, when given and the verdict is RED, is retained beside the record
# as `<key>.out` so `verify_cache_output` can replay WHY it failed. Tail-bounded:
# these accumulate per tree and a gate's own report of what broke is at the end of
# its output, not the start.
verify_cache_record() {
  local cwd="$1" base="$2" status="$3" out="${4:-}" dir key rec tmp tree hook base_sha subs cap lines
  [ -n "${VERIFY_HOOK:-}" ] && [ -x "$VERIFY_HOOK" ] || return 0
  dir="$(verify_cache_dir "$cwd")"; mkdir -p "$dir" || return 0
  tree="$(git -C "$cwd" rev-parse HEAD^{tree} 2>/dev/null || echo)"
  base_sha="$(git -C "$cwd" rev-parse "$base" 2>/dev/null || echo)"
  hook="$(git hash-object "$VERIFY_HOOK" 2>/dev/null || echo no-hook)"
  subs="$(verify_cache_subs "$cwd")"
  key="$tree.$base_sha.$hook.$subs"; rec="$dir/$key"; tmp="$rec.tmp.$$"
  { echo "status=$status"; echo "tree=$tree"; echo "base=$base_sha"; echo "hook=$hook"; echo "subs=$subs"; } > "$tmp" && mv "$tmp" "$rec"
  rm -f "$rec.out"          # a green re-record must not leave the old red's report behind
  if [ "$status" != 0 ] && [ -n "$out" ]; then
    # OUTPUT_FILE of `-` reads the output from STDIN, so a caller that already has it
    # in a variable needs no scratch file of its own. It is read TWICE (line count,
    # then tail) — which is also why a process substitution would not do here.
    if [ "$out" = - ]; then cat > "$tmp.in"; out="$tmp.in"; fi
    cap="${VERIFY_CACHE_OUTPUT_LINES:-500}"
    lines="$(wc -l < "$out" 2>/dev/null | tr -d ' ')"; lines="${lines:-0}"
    if [ -s "$out" ]; then
      {
        if [ "$lines" -gt "$cap" ] 2>/dev/null; then
          echo "   … ($(( lines - cap )) earlier lines elided from the recorded gate output)"
        fi
        tail -n "$cap" "$out"
      } > "$tmp" 2>/dev/null && mv "$tmp" "$rec.out" || rm -f "$tmp"
    fi
    rm -f "$tmp.in"
  fi
  # Enumerate RECORDS only — never the `.out` companions or a raced `.tmp.` — and
  # drop each with its own, or a pruned pair could leave a record whose report is gone.
  find "$dir" -type f -name '*.*.*' ! -name '*.out' ! -name '*.tmp.*' -print 2>/dev/null \
    | sort -r | sed -n '33,$p' | while IFS= read -r old; do rm -f "$old" "$old.out"; done
}

# bump_submodule_chain PROJECT SUB NAME SHA — stage the submodule-pointer bump for SUB,
# which may be NESTED (e.g. `babylon/packages/core`, a submodule OF a submodule).
#
# WHY THIS IS NOT `git -C PROJECT add SUB`. That is what it used to be, and for a nested
# submodule it does not work:
#
#     $ git -C <project> add babylon/packages/core
#     fatal: Pathspec 'babylon/packages/core' is in submodule 'babylon'
#
# The project tracks `babylon` as a gitlink; the inner pointer belongs to babylon's index,
# not the project's. Because the call was error-suppressed the failure was INVISIBLE: the
# branch merged into the submodule's base, the pointer never moved at any level, and the
# run still reported MERGED. A whole class of silent-failure bugs in this file has the same
# shape (see the retire-verification below), so this one fails LOUDLY instead.
#
# Walks real repo boundaries with `rev-parse --show-superproject-working-tree` rather than
# splitting the path on `/` — path segments are not repo boundaries (`packages` above is a
# plain directory), so a string split would stage the wrong thing.
#
# Each intermediate hop is committed in the repo that owns it, pathspec-scoped so a
# concurrent worker's unrelated staged work is never swept into it. The TOP-LEVEL segment
# is left STAGED in the project for the caller's retire commit to fold in — preserving the
# existing one-commit-per-tasklist shape. Returns non-zero with a reason on any failure.
bump_submodule_chain() {
  local project="$1" sub="$2" name="$3" sha="$4"
  local cur super rel
  project="$(cd "$project" 2>/dev/null && pwd -P)" || { echo "  !! bump: project path unreadable"; return 1; }
  cur="$(cd "$project/$sub" 2>/dev/null && pwd -P)" || { echo "  !! bump: '$sub' unreadable under $project"; return 1; }
  while :; do
    super="$(git -C "$cur" rev-parse --show-superproject-working-tree 2>/dev/null || true)"
    [ -z "$super" ] && break                       # no superproject: we are at the top
    super="$(cd "$super" 2>/dev/null && pwd -P)" || { echo "  !! bump: superproject of '$cur' unreadable"; return 1; }
    rel="${cur#"$super"/}"
    git -C "$super" add -- "$rel" 2>/dev/null || { echo "  !! bump: could not stage '$rel' in $super"; return 1; }
    # The project's stage is the caller's to commit.
    [ "$super" = "$project" ] && return 0
    # Nothing staged means the pointer was already current — not an error, just nothing to do.
    if ! git -C "$super" diff --cached --quiet -- "$rel" 2>/dev/null; then
      git -C "$super" commit -q -m "chore(chief): $name — bump $rel to the merged sha" -- "$rel" 2>/dev/null \
        || { echo "  !! bump: could not commit '$rel' in $super"; return 1; }
    fi
    cur="$super"
  done
  echo "  !! bump: '$sub' has no superproject — not a submodule of $project"
  return 1
}

finalize_merged() {
  local name="$1" branch="$2" sha="$3" work_repo="${4:-$CHIEF_PROJECT}" sub="${5:-}"
  local bump_failed=0
  # Prefer the run's snapshot (carries the agent's passes/notes); fall back to the
  # pristine template. NOTE: snapshots live in $SNAP (.chief/state/snapshots), NOT
  # under $STATE (.chief/state/parallel) — using $STATE here silently always fell
  # through to the template and dropped the agent's notes.
  local src="${SNAP:-$STATE/snapshots}/$name.json"; [ -f "$src" ] || src="$TASKS_DIR/$name.json"
  local rec="$COMPLETED/$name.json"
  # The record force-passes every story, because a merged tasklist is done by
  # definition and the record is what `is_recorded_done` reads. THE ONE EXCEPTION is a
  # story that declared `terminalFalse` (engine/terminal.sh): its answer really is NO,
  # that answer IS the deliverable, and rewriting it to true would leave the completed/
  # record asserting the opposite of what the tasklist found. So it is left alone —
  # false, declared, with its finding in `notes` — and a successor tasklist can cite it.
  if command -v node >/dev/null 2>&1; then
    node -e "const fs=require('fs');const j=JSON.parse(fs.readFileSync('$src','utf8'));(j.userStories||[]).forEach(s=>{if(s.terminalFalse!==true)s.passes=true;});j.mergedToMain='$sha';fs.writeFileSync('$rec',JSON.stringify(j,null,2)+'\n');" 2>/dev/null \
      || cp "$src" "$rec"
  else
    jq --arg sha "$sha" '(.userStories |= map(if .terminalFalse == true then . else .passes=true end)) | .mergedToMain=$sha' "$src" > "$rec" 2>/dev/null || cp "$src" "$rec"
  fi
  # WHICH GATES ACTUALLY EXECUTED, recorded while the answer is still knowable.
  # Not on the merge path in any sense that can hurt: the merge commit already
  # exists, nothing here touches the network, and every failure mode ends with the
  # record exactly as it was. What it catches is the merge that had no gate at all
  # — three tasklists in `amphora` merged against a verify hook that ran one
  # unrelated check and then `exit 0`, and `vita`'s `72` against a workflow no
  # event chief produces could start. Both were found by hand; neither had to be.
  cigate_stamp_merge_record "$rec" "$work_repo" "$sha" "${VERIFY_HOOK:-}" "${NO_VERIFY:-0}" 2>/dev/null || true
  # THE OPERATOR'S VERDICT, on the record that outlives the run. For a DECISION
  # tasklist the live JSON is deliberately not where the verdict lives (engine/
  # decision.sh's header says why: uncommitted, the isolation guard discards it;
  # committed, it collides with the branch's own pass-flag edit at rebase) — and the
  # durable record it lives in instead is gitignored. completed/ is the one file that
  # is written ONCE, here, after the last rebase this tasklist will ever see, so it is
  # where "who approved this, and why" can be kept for a reader six months out. Purely
  # additive and never fatal: no verdict, no jq, or a bad read all leave $rec as it was.
  local _fm_vf
  if command -v decision_verdict_file >/dev/null 2>&1; then
    _fm_vf="$(decision_verdict_file "$CHIEF_PROJECT" "$name")"
    if [ -s "$_fm_vf" ] && [ -s "$rec" ]; then
      if jq --slurpfile v "$_fm_vf" '.verdict=$v[0]' "$rec" > "$rec.verdict" 2>/dev/null; then
        mv "$rec.verdict" "$rec"
      else rm -f "$rec.verdict"; fi
    fi
  fi
  # Retire the source tasklist. MUST be -f: `git rm` REFUSES to remove a file with
  # local modifications (--ignore-unmatch only suppresses "no match"), and an agent
  # that reached out of its worktree to flip pass-flags in the PROJECT's copy leaves
  # exactly that. Without -f this failed silently (2>/dev/null || true), so the record
  # + pointer-bump committed but the tasklist was never retired — it stayed "pending"
  # forever while is_recorded_done skipped it. The completed record is authoritative,
  # so discarding those stray edits is correct.
  idx_lock
  git -C "$CHIEF_PROJECT" rm -q -f --ignore-unmatch "$TASKS_REL/$name.json" 2>/dev/null || true
  git -C "$CHIEF_PROJECT" add "$TASKS_REL/completed/$name.json" 2>/dev/null || true
  if [ -n "$sub" ]; then
    # NOT error-suppressed, deliberately: a pointer bump that silently no-ops leaves the
    # submodule's base advanced and every enclosing pointer stale, while the run still
    # says MERGED. That is the exact failure this function's other guards exist to prevent.
    if ! bump_submodule_chain "$CHIEF_PROJECT" "$sub" "$name" "$sha"; then
      echo "  !! $name: SUBMODULE POINTER NOT BUMPED for '$sub' — the merge landed in the"
      echo "     submodule but the project still points at the old sha. Fix by hand:"
      echo "       git -C $CHIEF_PROJECT/$sub log --oneline -1     # the merged sha"
      echo "       then stage the pointer in each enclosing repo and commit."
      bump_failed=1
    fi
    git -C "$CHIEF_PROJECT" commit -q -m "chore(chief): $name complete @$sha — bump $sub + record + retire" 2>/dev/null || true
  else
    git -C "$CHIEF_PROJECT" commit -q -m "chore(chief): $name complete @$sha — record + retire" 2>/dev/null || true
  fi
  idx_unlock
  # VERIFY the retire. These git calls are error-suppressed, so a failure (lost
  # index.lock race, unexpected git state) would otherwise be invisible and the tasklist
  # would sit "pending" forever while is_recorded_done skips it. One retry, then say so
  # loudly — a merged-but-unretired tasklist is confusing, and silence is what let this
  # class of bug hide.
  if [ -f "$CHIEF_PROJECT/$TASKS_REL/$name.json" ]; then
    idx_lock
    git -C "$CHIEF_PROJECT" rm -q -f --ignore-unmatch "$TASKS_REL/$name.json" 2>/dev/null || true
    git -C "$CHIEF_PROJECT" commit -q -m "chore(chief): retire $name (retry)" 2>/dev/null || true
    idx_unlock
  fi
  [ -f "$CHIEF_PROJECT/$TASKS_REL/$name.json" ] && \
    echo "  !! RETIRE FAILED for $name — $TASKS_REL/$name.json still present despite a merged record." \
         "It will look 'pending' but be skipped. Remove it by hand: git rm -f $TASKS_REL/$name.json" >&2
  # VERIFY THE BUMP, for the same reason the retire is verified: do not trust the call,
  # check the effect. Walks the chain and asserts every enclosing repo's RECORDED gitlink
  # equals the child's HEAD — which is what "the pointer moved" actually means, at every
  # level. A stale link here means the merged code is unreachable from the project.
  if [ -n "$sub" ] && ! verify_submodule_chain "$CHIEF_PROJECT" "$sub"; then
    bump_failed=1
  fi
  [ "$bump_failed" = "1" ] && \
    echo "  !! POINTER STALE for $name ('$sub') — the merge is in the submodule but the project" \
         "does not reference it. Nothing else will see this work until the pointers are bumped." >&2
  # Never force-delete a branch here. A future caller may reuse this helper after
  # filing a record, and a branch that is not reachable from the integration base is
  # still somebody's work. The normal merge makes this check true; keep the explicit
  # guard so a surprising state is reported and preserved rather than lost.
  if git -C "$work_repo" merge-base --is-ancestor "$branch" "${work_base:-$BASE_BRANCH}" 2>/dev/null; then
    git -C "$work_repo" branch -d "$branch" >/dev/null 2>&1 || \
      echo "  !! branch kept: could not delete genuinely merged $branch"
  else
    echo "  !! branch kept: $branch is not an ancestor of ${work_base:-$BASE_BRANCH} (unmerged work)"
  fi
}

# verify_submodule_chain PROJECT SUB — post-condition for bump_submodule_chain. For every
# hop from SUB up to PROJECT, the enclosing repo's committed gitlink must equal the child's
# HEAD. Prints each mismatch; returns non-zero if any hop is stale.
verify_submodule_chain() {
  local project="$1" sub="$2" cur super rel recorded head rc=0
  project="$(cd "$project" 2>/dev/null && pwd -P)" || return 1
  cur="$(cd "$project/$sub" 2>/dev/null && pwd -P)" || return 1
  while :; do
    super="$(git -C "$cur" rev-parse --show-superproject-working-tree 2>/dev/null || true)"
    [ -z "$super" ] && break
    super="$(cd "$super" 2>/dev/null && pwd -P)" || return 1
    rel="${cur#"$super"/}"
    head="$(git -C "$cur" rev-parse HEAD 2>/dev/null || true)"
    recorded="$(git -C "$super" ls-tree HEAD -- "$rel" 2>/dev/null | awk '{print $3}')"
    if [ -z "$recorded" ] || [ "$recorded" != "$head" ]; then
      echo "  !! stale pointer: $super records '$rel' at ${recorded:-<none>}, but its HEAD is ${head:-<unknown>}" >&2
      rc=1
    fi
    cur="$super"
  done
  return $rc
}
