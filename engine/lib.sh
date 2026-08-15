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
  if command -v node >/dev/null 2>&1; then
    node -e "const fs=require('fs');const j=JSON.parse(fs.readFileSync('$src','utf8'));(j.userStories||[]).forEach(s=>s.passes=true);j.mergedToMain='$sha';fs.writeFileSync('$rec',JSON.stringify(j,null,2)+'\n');" 2>/dev/null \
      || cp "$src" "$rec"
  else
    jq --arg sha "$sha" '(.userStories |= map(.passes=true)) | .mergedToMain=$sha' "$src" > "$rec" 2>/dev/null || cp "$src" "$rec"
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
  git -C "$work_repo" branch -d "$branch" >/dev/null 2>&1 || true
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
