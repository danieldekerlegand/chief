#!/usr/bin/env bash
# engine/sweep.sh — the DISK half of reaping: what chief CAUSED TO BE BUILT inside a
# worktree goes when the worktree goes.
#
# WHY THIS EXISTS. `engine/reap.sh` collects orphaned agent PROCESSES; nothing ever
# collected the bytes they left behind. Measured 2026-08-13 in cuneiform: a checkout's
# `core/engine/target` had reached 61 GB across 729,816 files, and a *warm*
# `cargo test --no-run` — compiling nothing — took over two minutes, because cargo
# stats that tree on every invocation. A single parallel worktree adds ~7 GB of its
# own. Chief creates the conditions for all of it and had no matching teardown.
#
# The leak is not that `rm -rf $wt` fails to remove a build directory — it removes
# everything under it. The leak is that worktree removal is BEST-EFFORT at every
# call site (`wt_git remove --force … 2>/dev/null || true`), and a removal that
# fails leaves the whole tree standing, build directory included, behind a run that
# has already finished. Sweeping the heavy directories FIRST means the bytes are
# reclaimed even when the git removal that follows loses, and it makes that removal
# cheap instead of a walk over three-quarters of a million files.
#
# THE RULE — what chief created with the worktree goes with the worktree; what the
# OPERATOR put there does not. Deliberately NOT Rust-specific: the shape is general
# (a per-worktree directory a language toolchain owns), so it is a TABLE and adding
# a toolchain is a row, not a new branch.
#
# THE HAZARD THIS IS DESIGNED AROUND. A shared `CARGO_TARGET_DIR` (which cuneiform
# may adopt) puts the build directory OUTSIDE the worktree, shared by every live
# run on the box. A naive `rm -rf $wt/**/target` then either misses it — harmless —
# or FOLLOWS a symlink into it and deletes a cache four running builds are reading.
# So containment is not assumed anywhere: `chief_sweep_candidate` is a pure function
# of three paths that REFUSES with a stated reason rather than guessing, a symlink
# is never followed (it is refused as itself), and every verdict is asserted over
# adversarial paths in test/sweep.sh rather than argued for in this comment.
#
# Bash 3.2 compatible (no arrays — the find expression is built in "$@" — no process
# substitution, no GNU-only find/du flags).
set -uo pipefail

# ── the table ────────────────────────────────────────────────────────────────
# One row per toolchain: <directory name>|<what owns it>. A directory bearing one of
# these names, inside a chief worktree, was built by the run chief started there.
# Adding a toolchain is adding a row.
chief_sweep_table() {
  cat <<'EOF'
target|cargo
node_modules|npm/pnpm/yarn/bun
.venv|uv/virtualenv
build|cmake/gradle/meson
EOF
}

# $1 = a directory NAME -> what owns it ('' when the name is not in the table)
chief_sweep_toolchain() {
  local n t
  while IFS='|' read -r n t; do
    [ -n "$n" ] || continue
    [ "$n" = "${1:-}" ] && { printf '%s' "$t"; return 0; }
  done <<EOF
$(chief_sweep_table)
EOF
  return 1
}

# ── primitives ───────────────────────────────────────────────────────────────

chief_sweep_canon() {   # $1 = dir -> its canonical path ('' when it is not a dir)
  [ -d "${1:-}" ] || return 0
  ( cd "$1" 2>/dev/null && pwd -P ) 2>/dev/null
}

# Is $1 strictly under $2? Both must already be canonical. The trailing slashes are
# load-bearing: without them "$root/tl-evil" matches the prefix "$root/tl".
chief_sweep_under() {   # $1 = path  $2 = ancestor
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  [ "$1" = "$2" ] && return 1
  case "$1/" in "$2"/*) return 0 ;; *) return 1 ;; esac
}

chief_sweep_bytes() {   # $1 = dir -> its size in bytes (0 when unreadable)
  local k
  k="$(du -sk "$1" 2>/dev/null | awk '{print $1; exit}')"
  case "$k" in ''|*[!0-9]*) k=0 ;; esac
  printf '%s' "$(( k * 1024 ))"
}

chief_sweep_human() {   # $1 = bytes -> "1.4 GB"
  LC_ALL=C awk -v b="${1:-0}" 'BEGIN{
    split("B KB MB GB TB", u, " "); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    if (i == 1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i]
  }'
}

# ── the verdict — a PURE function of three paths ─────────────────────────────
#
# chief_sweep_candidate ROOT WORKTREE PATH
#   prints "sweep <canonical path>"  and returns 0  when PATH is a build directory
#                                    chief caused to exist inside WORKTREE, or
#   prints "refuse <reason>"         and returns 1  otherwise.
#
# Reads the filesystem (a path question cannot be answered without it) but MUTATES
# nothing, which is what makes the adversarial cases cheap to assert. ROOT is passed
# in rather than resolved from the environment so the caller's notion of "chief's
# worktree root" is the one enforced — the driver honours a WT_ROOT override, and a
# function that consulted $CHIEF_WORKTREE_ROOT behind its back would disagree with it.
#
# Reasons, each of which a test pins:
#   empty-argument · relative-path · worktree-missing · not-a-chief-worktree
#   worktree-is-a-symlink · unknown-artifact · symlink · missing · outside-worktree
chief_sweep_candidate() {
  local root="${1:-}" wt="${2:-}" p="${3:-}" rootc wtc pc base

  [ -n "$root" ] && [ -n "$wt" ] && [ -n "$p" ] || { echo "refuse empty-argument"; return 1; }
  case "$root" in /*) ;; *) echo "refuse relative-path"; return 1 ;; esac
  case "$wt"   in /*) ;; *) echo "refuse relative-path"; return 1 ;; esac
  case "$p"    in /*) ;; *) echo "refuse relative-path"; return 1 ;; esac

  # 1. IS THIS CHIEF'S WORKTREE? A directory under the worktree root is chief's work
  #    by construction — that root is chief's own directory and nothing else writes
  #    there (the same argument engine/reap.sh's cwd key rests on). Anything else is
  #    somebody's checkout, and is never touched. A SYMLINKED worktree is refused
  #    outright rather than resolved: containment would then be judged against a
  #    directory the operator, not chief, chose.
  rootc="$(chief_sweep_canon "$root")"
  [ -n "$rootc" ] || { echo "refuse not-a-chief-worktree"; return 1; }
  [ -L "$wt" ] && { echo "refuse worktree-is-a-symlink"; return 1; }
  wtc="$(chief_sweep_canon "$wt")"
  [ -n "$wtc" ] || { echo "refuse worktree-missing"; return 1; }
  chief_sweep_under "$wtc" "$rootc" || { echo "refuse not-a-chief-worktree"; return 1; }

  # 2. IS IT A KNOWN ARTIFACT? Checked on the NAME, before the filesystem is asked
  #    anything about it, so an unknown directory is cheap and can never fall through.
  base="${p##*/}"
  chief_sweep_toolchain "$base" >/dev/null || { echo "refuse unknown-artifact"; return 1; }

  # 3. NEVER FOLLOW A SYMLINK. This is the shared-CARGO_TARGET_DIR shape: a `target`
  #    inside the worktree that is a link to a cache other live runs are building in.
  #    It is refused as ITSELF — not resolved and then judged, which is how a link
  #    pointing back inside the worktree would smuggle the outside case through.
  [ -L "$p" ] && { echo "refuse symlink"; return 1; }
  [ -d "$p" ] || { echo "refuse missing"; return 1; }

  # 4. IS IT INSIDE? The canonical form, so a symlinked ANCESTOR cannot carry the
  #    path out of the worktree between here and the rm. A shared build directory
  #    named directly (an absolute CARGO_TARGET_DIR) dies here.
  pc="$(chief_sweep_canon "$p")"
  [ -n "$pc" ] || { echo "refuse missing"; return 1; }
  chief_sweep_under "$pc" "$wtc" || { echo "refuse outside-worktree"; return 1; }

  echo "sweep $pc"
  return 0
}

# ── the scan ─────────────────────────────────────────────────────────────────
# Candidate directories under a worktree, top-most first: a matched directory is
# PRUNED, so the 200k files inside a node_modules are never walked looking for a
# `target` nested in them. One pass, with the -name expression built from the table
# in "$@" (bash 3.2 has no arrays and this must not be an eval).
#
# SYMLINKS ARE COLLECTED TOO (-type l), and that is the point rather than an
# oversight: `-type d` alone would skip a `target` that links to a shared cache
# SILENTLY, and an operator whose build directory was reclaimed everywhere except
# the one repo that adopted a shared CARGO_TARGET_DIR deserves the refusal line
# saying so. The verdict still refuses every one of them; find never follows one
# (no -L), so nothing on the other side is even walked.
chief_sweep_find() {   # $1 = worktree
  local wt="${1:-}" n t first=1
  [ -d "$wt" ] || return 0
  set -- "$wt" -mindepth 1 -maxdepth "${CHIEF_SWEEP_DEPTH:-6}" \
        \( -name .git -o -name .chief \) -prune -o \( -type d -o -type l \) \(
  while IFS='|' read -r n t; do
    [ -n "$n" ] || continue
    if [ "$first" = 1 ]; then set -- "$@" -name "$n"; first=0
    else set -- "$@" -o -name "$n"; fi
  done <<EOF
$(chief_sweep_table)
EOF
  [ "$first" = 1 ] && return 0
  set -- "$@" \) -prune -print
  find "$@" 2>/dev/null
}

# ── the sweep ────────────────────────────────────────────────────────────────
# chief_sweep_worktree ROOT WORKTREE [LABEL] [-n]
#
# Reclaims every build directory the verdict allows, reports the bytes, and NEVER
# fails the caller: a run that produced good work must not be undone by a disk
# reclaim that could not read a directory. Sets, for a caller that wants to total
# across a run:  CHIEF_SWEEP_BYTES · CHIEF_SWEEP_COUNT · CHIEF_SWEEP_REFUSED.
chief_sweep_worktree() {
  local root="${1:-}" wt="${2:-}" label="${3:-sweep}" dry="${4:-}"
  local p verdict reason detail="" b
  CHIEF_SWEEP_BYTES=0; CHIEF_SWEEP_COUNT=0; CHIEF_SWEEP_REFUSED=0
  [ "${CHIEF_SWEEP:-1}" = 0 ] && return 0
  [ -d "$wt" ] || return 0

  while IFS= read -r p; do
    [ -n "$p" ] || continue
    verdict="$(chief_sweep_candidate "$root" "$wt" "$p")"
    reason="${verdict#* }"
    case "$verdict" in
      sweep\ *)
        b="$(chief_sweep_bytes "$reason")"
        [ "$dry" = "-n" ] || rm -rf -- "$reason" 2>/dev/null || true
        CHIEF_SWEEP_BYTES=$(( CHIEF_SWEEP_BYTES + b ))
        CHIEF_SWEEP_COUNT=$(( CHIEF_SWEEP_COUNT + 1 ))
        detail="$detail, ${p#"$wt"/} ($(chief_sweep_human "$b"))"
        ;;
      *)  # Refusal is never silent — a refused path is the interesting one.
        CHIEF_SWEEP_REFUSED=$(( CHIEF_SWEEP_REFUSED + 1 ))
        echo ">> $label: REFUSED to sweep $p — $reason"
        ;;
    esac
  done <<EOF
$(chief_sweep_find "$wt")
EOF

  if [ "$CHIEF_SWEEP_COUNT" -gt 0 ]; then
    echo ">> $label: $([ "$dry" = "-n" ] && echo 'would reclaim' || echo reclaimed) $(chief_sweep_human "$CHIEF_SWEEP_BYTES") of build artifacts —${detail#,}"
  fi
  return 0
}
