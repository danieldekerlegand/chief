#!/usr/bin/env bash
# engine/reap.sh — find and reap ORPHANED chief processes: agent work that is still
# running (and still spending account quota) with no live, registered run behind it.
#
# WHY THIS EXISTS. The driver's startup sweep used to be one line:
#
#     orphans="$(pgrep -f "$WT_ROOT" | grep -vx "$$")"; echo "$orphans" | xargs kill -9
#
# and it reaped exactly the wrong layer. `engine/driver.sh`, `engine/agent.sh` and
# `claude --dangerously-skip-permissions --print` carry NO worktree path in their
# command line — only their transient children do (pytest, a build, a game engine).
# So the pattern matched the leaves, killed them, and left the engine above them
# alive to spawn more. It was also silent (`kill -9` with output suppressed) and it
# only ever ran when somebody started a NEW run on that same repo, so an orphan
# could spend for hours unwatched.
#
# THE DURABLE MARKERS this uses instead — neither of which can be argued away by a
# process that chose a boring argv:
#
#   1. CWD. Every process in an agent's tree runs with its cwd inside the run's
#      git worktree (`$WT_ROOT/<tasklist>`), because that is where the driver puts
#      the agent. The path is not in argv, but it IS in the process table — via
#      /proc/<pid>/cwd on Linux, `lsof -d cwd` on macOS. And the worktree root is
#      chief's own directory (under $CHIEF_PREFIX), so a match there is chief's
#      work by construction and names the repo + tasklist it belonged to.
#   2. A SPAWN MARKER on argv, `--chief-run=<run-id>`, stamped by driver.sh on
#      itself (it re-execs once to place it) and on every `agent.sh` frame it
#      starts, and exported as $CHIEF_RUN_ID to the whole tree. The run id encodes
#      the repo (`<repo>-<cksum>-<epoch>-<pid>`), so a sweep can scope itself to
#      ONE repo's runs. This is what catches the driver, whose own cwd is wherever
#      the operator happened to be standing.
#   3. THE INHERITED MARKER, that same $CHIEF_RUN_ID read back out of a candidate's
#      ENVIRONMENT. Keys 1 and 2 are both escapable in principle — chdir out of the
#      worktree, exec with a boring argv — but an exported variable is inherited by
#      every descendant through both. It is the residual case, and it is cheap: the
#      export already exists, this only reads it. Same run id, so the same repo
#      scoping applies. Union, not replacement: matching ANY of the three keys makes
#      a process a candidate, so neither of the other two can regress.
#      Where a host will not show another process's environment (macOS since SIP
#      accepts `ps -E` and silently prints none), this key degrades to nothing and
#      keys 1 and 2 carry the sweep — the availability is PROBED, never assumed, so
#      an empty read is reported as "the key is inactive" and never as "no orphans".
#
# SCOPING — what this must never kill:
#   · another repo's run, or another driver's tree (scope by worktree root / run-id
#     prefix; every candidate is checked against the live registry),
#   · a REGISTERED live run (its driver pid + every descendant is protected),
#   · a live driver that merely lost its run file (it still holds its repo's
#     driver.lock — that is a bookkeeping bug, not an orphan; `chief ps` reports it),
#   · this process, its ancestors, or any process belonging to another user,
#   · a developer's own `claude`/engine processes running anywhere else on the box.
# The protected set is computed BEFORE and AGAIN AFTER the candidate scan, and a pid
# must be absent from both to be reaped — otherwise a live run that spawns a fresh
# agent turn mid-scan could be mistaken for an orphan.
#
# Usable two ways:
#   ·  sourced by engine/driver.sh (the startup sweep, scoped to that repo), and
#   ·  run directly — `chief reap [-n] [--grace N]` — which is the path that does
#      NOT require starting a new run on the repo that stranded the orphan.
#
# Bash 3.2 compatible (no arrays, no process substitution, no GNU-only ps flags).
set -uo pipefail

_REAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# chief_scan_descendants lives in lib.sh; driver.sh has already sourced it when this
# file is sourced from there, so only pay for it when running standalone.
if ! command -v chief_scan_descendants >/dev/null 2>&1; then
  # shellcheck source=engine/lib.sh
  . "$_REAP_DIR/lib.sh"
fi

CHIEF_PREFIX_DEFAULT="${CHIEF_PREFIX:-$HOME/.chief}"
CHIEF_WT_ROOT_ALL="$CHIEF_PREFIX_DEFAULT/worktrees"    # every repo's worktrees live here
CHIEF_RUN_MARKER="--chief-run="                        # the argv spawn marker

# ── primitives ───────────────────────────────────────────────────────────────

chief_reap_canon() {   # $1 = dir -> its canonical path ('' when it doesn't exist)
  [ -d "${1:-}" ] || return 0
  ( cd "$1" 2>/dev/null && pwd -P ) 2>/dev/null
}

# Liveness that is NOT fooled by a zombie. `kill -0` succeeds on a zombie, so a
# reaped-but-unwaited child would look alive forever and every escalation below it
# would spin out its full grace period for nothing.
chief_pid_alive() {    # $1 = pid
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  ps -o pid=,stat= -p "$1" 2>/dev/null | awk '$2 !~ /^Z/ {f=1} END{exit !f}'
}

chief_pid_cmd() {      # $1 = pid -> its command line, trimmed for a report line
  ps -o command= -p "$1" 2>/dev/null | head -1 | cut -c1-88
}

chief_pid_tag() {      # $1 = pid -> the run id from its argv marker ('' if unmarked)
  ps -o command= -p "$1" 2>/dev/null | head -1 | tr ' ' '\n' \
    | sed -n "s/^${CHIEF_RUN_MARKER}//p" | head -1
}

# Every process of THIS user whose cwd is DIR or below it, as "<pid> <cwd>" lines.
# /proc first (Linux, exact and cheap), `lsof -d cwd` second (macOS, ~0.2s for the
# whole process table). With neither, the cwd marker degrades to nothing and the
# argv marker still carries the sweep — never a false positive.
chief_pids_cwd_under() {   # $1 = dir
  local dir d p n
  dir="$(chief_reap_canon "${1:-}")"
  [ -n "$dir" ] || return 0
  if [ -d /proc/self ] && [ -e /proc/self/cwd ]; then
    for d in /proc/[0-9]*; do
      [ -e "$d/cwd" ] || continue
      p="${d#/proc/}"
      n="$(readlink "$d/cwd" 2>/dev/null)" || continue
      [ -n "$n" ] || continue
      case "$n" in "$dir"|"$dir"/*) printf '%s %s\n' "$p" "$n" ;; esac
    done
    return 0
  fi
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -u "$(id -u)" -a -d cwd -F pn 2>/dev/null | awk -v dir="$dir" '
    /^p/ { p = substr($0, 2); next }
    /^n/ { n = substr($0, 2); if (n == dir || index(n, dir "/") == 1) print p, n }'
}

# Can this host show us ANOTHER process's environment at all? PROBED, not assumed,
# because the two ways it can be answered differ in kind:
#   · Linux: /proc/<pid>/environ, readable for this user's own processes, exact.
#   · macOS: nothing. `ps -E` is accepted and simply prints no environment (SIP),
#     for another process AND for this one — which is what the probe below detects.
# Echoes the mechanism to use — "proc" | "ps" | "" when unavailable. Cached per
# shell; the internal "-" is "probed and unavailable", distinct from "not yet
# probed", and is stripped on the way out.
CHIEF_ENV_KEY_MODE=""
chief_env_key_mode() {
  local plain full kv
  if [ -z "$CHIEF_ENV_KEY_MODE" ]; then
    CHIEF_ENV_KEY_MODE="-"
    kv=""
    if [ -r /proc/self/environ ]; then
      IFS= read -r -d '' kv < /proc/self/environ 2>/dev/null || true
    fi
    if [ -n "$kv" ]; then
      CHIEF_ENV_KEY_MODE="proc"
    else
      # `-E` appends the environment to the command column where it works at all.
      # Compare against the same read without it: identical output means it added
      # nothing, and an env-keyed sweep here would find nothing however many
      # orphans there are.
      plain="$(ps -o command= -p "$$" 2>/dev/null | head -1)"
      full="$(ps -E -o command= -p "$$" 2>/dev/null | head -1)"
      [ -n "$full" ] && [ "$full" != "$plain" ] && CHIEF_ENV_KEY_MODE="ps"
    fi
  fi
  printf '%s' "${CHIEF_ENV_KEY_MODE#-}"
  return 0
}

# Every process of THIS user whose ENVIRONMENT carries a CHIEF_RUN_ID with the given
# prefix, as "<pid> <runid>" lines. The prefix is the run-id scope key 2 uses
# (`<repo>-<cksum>-`), so this sweep is scoped to one repo's runs exactly as the argv
# sweep is. Silent — and empty — where chief_env_key_mode reports no mechanism.
#
# OUR OWN run id is never emitted. A host-wide sweep (`chief reap`, prefix '') would
# otherwise match every process of the run this very sweep is running inside — and
# inheritance means that is the whole tree, not just the engine frames key 2 sees. If
# we carry the id, that run is live by construction; the registry check below is the
# wrong place to learn it, because a sweep run with a hermetic $CHIEF_RUNS (the test
# suite does exactly this) cannot see the real run's file.
chief_pids_env_marked() {  # $1 = run id prefix ('' = any chief run)
  local want="${1:-}" self="${CHIEF_RUN_ID:-}" d p v kv
  case "$(chief_env_key_mode)" in
    proc)
      for d in /proc/[0-9]*; do
        [ -r "$d/environ" ] || continue      # another user's, or already gone
        p="${d#/proc/}"; v=""
        while IFS= read -r -d '' kv; do
          case "$kv" in CHIEF_RUN_ID=*) v="${kv#CHIEF_RUN_ID=}"; break ;; esac
        done < "$d/environ" 2>/dev/null
        [ -n "$v" ] || continue
        [ -n "$self" ] && [ "$v" = "$self" ] && continue
        case "$v" in "$want"*) printf '%s %s\n' "$p" "$v" ;; esac
      done
      ;;
    ps)
      ps -E -o pid=,command= -U "$(id -u)" 2>/dev/null | awk -v want="$want" -v self="$self" '
        { for (i = 2; i <= NF; i++) if (index($i, "CHIEF_RUN_ID=") == 1) {
            v = substr($i, 14)
            if (v != self && (want == "" || index(v, want) == 1)) print $1, v
            break } }'
      ;;
  esac
  return 0
}

chief_pids_tagged() {  # $1 = argv substring -> pids of THIS user carrying it
  local p
  [ -n "${1:-}" ] || return 0
  # `--` is load-bearing: the marker STARTS with `--`, and without the separator
  # pgrep parses the pattern as its own option and matches nothing (silently).
  for p in $(pgrep -u "$(id -u)" -f -- "$1" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    printf '%s\n' "$p"
  done
  return 0
}

chief_ancestors() {    # $1 = pid -> that pid and every ancestor of it, up to init
  local p="${1:-}" n=0
  while [ -n "$p" ] && [ "$n" -lt 64 ]; do
    case "$p" in ''|*[!0-9]*) break ;; esac
    [ "$p" -le 1 ] && break
    printf '%s\n' "$p"
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    n=$(( n + 1 ))
  done
  return 0
}

# A repo's state dir, as its .chief/config declares it (default .chief/state) — the
# same cheap config read driver.sh uses for CHIEF_TASKS_DIR.
chief_state_rel() {    # $1 = repo root
  local v
  v="$(sed -n 's/^[[:space:]]*CHIEF_STATE_DIR=\([^ #]*\).*/\1/p' "$1/.chief/config" 2>/dev/null | tail -1)"
  v="$(printf '%s' "$v" | tr -d "\"'")"
  printf '%s' "${v:-.chief/state}"
}

# ── the protected set ────────────────────────────────────────────────────────

CHIEF_PROTECTED=" "
chief_protected_reset() { CHIEF_PROTECTED=" "; }

_chief_protect() {     # $1 = pid — add it to the protected set
  case "${1:-}" in ''|*[!0-9]*) return 0 ;; esac
  case "$CHIEF_PROTECTED" in *" $1 "*) return 0 ;; esac
  CHIEF_PROTECTED="$CHIEF_PROTECTED$1 "
}

_chief_protect_tree() {   # $1 = pid — protect it AND everything below it, if alive
  local pid="${1:-}" p
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  chief_pid_alive "$pid" || return 0
  _chief_protect "$pid"
  chief_scan_descendants "$pid"
  for p in $CHIEF_DESCENDANTS; do _chief_protect "$p"; done
  return 0
}

# Accumulates (never resets) so it can be called twice around the candidate scan.
chief_protected_pids() {
  local runs f pid repos repo lockpid p
  for p in $(chief_ancestors "$$"); do _chief_protect "$p"; done
  runs="${CHIEF_RUNS:-$CHIEF_PREFIX_DEFAULT/runs}"
  for f in "$runs"/*.run; do
    [ -e "$f" ] || continue
    pid="$(sed -n 's/^pid=//p' "$f" 2>/dev/null | head -1)"
    _chief_protect_tree "$pid"
  done
  # A driver holding its repo's driver.lock is RUNNING, whatever the registry says.
  # Losing the run file is a bookkeeping failure; killing it blind would turn that
  # into lost work.
  repos="${CHIEF_REPOS:-$CHIEF_PREFIX_DEFAULT/repos}"
  if [ -f "$repos" ]; then
    while IFS= read -r repo; do
      [ -n "$repo" ] || continue
      lockpid="$(cat "$repo/$(chief_state_rel "$repo")/driver.lock/pid" 2>/dev/null || echo)"
      _chief_protect_tree "$lockpid"
    done < "$repos"
  fi
  return 0
}

# ── identification ───────────────────────────────────────────────────────────

# "<repo> · <tasklist>" for a path inside the worktree root, so a reap can name the
# run it belonged to instead of printing a bare pid.
chief_run_label() {    # $1 = a path under .../worktrees/
  local p="${1:-}" rel repo task
  case "$p" in
    */worktrees/*) rel="${p#*/worktrees/}" ;;
    *) printf '%s' "$p"; return 0 ;;
  esac
  repo="${rel%%/*}"; repo="${repo%-*}"          # <repo>-<cksum> -> <repo>
  task=""
  case "$rel" in */*) task="${rel#*/}"; task="${task%%/*}" ;; esac
  if [ -n "$task" ]; then printf '%s · %s' "${repo:-?}" "$task"; else printf '%s' "${repo:-?}"; fi
}

CHIEF_ORPHANS=""        # space-separated pids to reap
CHIEF_ORPHAN_INFO=""    # one "<pid><TAB><why>" line per pid, for the report

_chief_cand=" "
_chief_cand_add() {     # $1 = pid, $2 = why — record a candidate (no filtering yet)
  local p="${1:-}"
  case "$p" in ''|*[!0-9]*) return 0 ;; esac
  [ "$p" = "$$" ] && return 0
  [ "$p" -le 1 ] && return 0
  case "$_chief_cand" in *" $p "*) return 0 ;; esac
  _chief_cand="$_chief_cand$p "
  CHIEF_ORPHAN_INFO="$CHIEF_ORPHAN_INFO$p	$2
"
}

# chief_find_orphans SCOPE_DIR [MARKER] — sets CHIEF_ORPHANS + CHIEF_ORPHAN_INFO.
#   SCOPE_DIR  a worktree root: one repo's ($WT_ROOT) or the host's (all repos).
#   MARKER     the argv marker to match, e.g. "--chief-run=chief-1234-" for one
#              repo's runs, or "--chief-run=" for every chief run on the host.
chief_find_orphans() {
  local scope="${1:-}" marker="${2:-}" line pid rest p q keep="" info=""
  CHIEF_ORPHANS=""; CHIEF_ORPHAN_INFO=""; _chief_cand=" "

  chief_protected_pids                     # snapshot 1 — before the scan

  if [ -n "$scope" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      pid="${line%% *}"; rest="${line#* }"
      _chief_cand_add "$pid" "working in $(chief_run_label "$rest")"
    done <<EOF
$(chief_pids_cwd_under "$scope")
EOF
  fi
  if [ -n "$marker" ]; then
    for p in $(chief_pids_tagged "$marker"); do
      _chief_cand_add "$p" "chief engine process · run $(chief_pid_tag "$p")"
    done
    # Key 3 — the same run id, inherited through the environment. Reaches the process
    # that escaped BOTH of the others: chdir'd out of the worktree AND wearing a
    # boring argv (a server in a temp dir, a bare `yes`). A union with the two above:
    # _chief_cand_add keeps the first reason recorded, so a process the cwd or argv
    # key already found is unaffected.
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      pid="${line%% *}"; rest="${line#* }"
      _chief_cand_add "$pid" "inherited run marker · run $rest"
    done <<EOF
$(chief_pids_env_marked "${marker#"$CHIEF_RUN_MARKER"}")
EOF
  fi
  # Whatever the agent spawned that then wandered off the worktree (a build in a
  # temp dir, a server in /). Parentage is the only relation that reaches those.
  for p in $_chief_cand; do
    chief_scan_descendants "$p"
    for q in $CHIEF_DESCENDANTS; do _chief_cand_add "$q" "child of pid $p"; done
  done

  chief_protected_pids                     # snapshot 2 — after the scan

  # A candidate must be unprotected in BOTH snapshots and still alive to be reaped.
  for p in $_chief_cand; do
    case "$CHIEF_PROTECTED" in *" $p "*) continue ;; esac
    chief_pid_alive "$p" || continue
    keep="$keep $p"
    info="$info$(printf '%s\n' "$CHIEF_ORPHAN_INFO" | awk -F'\t' -v q="$p" '$1==q {print; exit}')
"
  done
  # shellcheck disable=SC2086
  set -- $keep
  CHIEF_ORPHANS="$*"
  CHIEF_ORPHAN_INFO="$info"
  return 0
}

# ── the reap itself ──────────────────────────────────────────────────────────

# Escalating, bounded and LOUD: a silent `kill -9` sweep is indistinguishable from
# a crash to whoever is watching, so every pid is named with what it was and why it
# was reaped before a signal is sent.  Returns 1 if anything outlived KILL.
chief_reap_pids() {    # $1 = pids  $2 = label  [$3 = grace seconds]
  local pids="${1:-}" label="${2:-orphaned chief processes}" grace="${3:-${CHIEF_REAP_GRACE:-5}}"
  local p left waited=0
  [ -n "$pids" ] || return 0
  case "$grace" in ''|*[!0-9]*) grace=5 ;; esac
  echo "  ⏹ reaping $label (TERM):$pids" >&2
  for p in $pids; do kill -TERM "$p" 2>/dev/null || true; done
  while :; do
    left=""
    for p in $pids; do chief_pid_alive "$p" && left="$left $p"; done
    [ -n "$left" ] || { echo "  ⏹ reaped $label — every process exited on TERM" >&2; return 0; }
    [ "$waited" -ge "$grace" ] && break
    sleep 1; waited=$(( waited + 1 ))
  done
  echo "  ⏹ hard-killing survivors after the ${grace}s grace (KILL):$left" >&2
  for p in $left; do kill -9 "$p" 2>/dev/null || true; done
  sleep 1
  left=""
  for p in $pids; do chief_pid_alive "$p" && left="$left $p"; done
  if [ -n "$left" ]; then
    echo "  !! these survived TERM and KILL:$left — reap by hand (kill -9$left)" >&2
    return 1
  fi
  echo "  ⏹ reaped $label — every process is gone" >&2
  return 0
}

# The shared report: what was found, and which run each pid belonged to.
chief_report_orphans() {   # $1 = headline
  local line pid why
  echo "$1" >&2
  printf '%s\n' "$CHIEF_ORPHAN_INFO" | while IFS=$'\t' read -r pid why; do
    [ -n "$pid" ] || continue
    printf '       · pid %-7s %s\n' "$pid" "$why" >&2
    printf '         %s\n' "$(chief_pid_cmd "$pid")" >&2
  done
  return 0
}

# chief_reap_orphans SCOPE MARKER LABEL [GRACE] — find, report, reap. The one call
# driver.sh makes at startup; also the body of `chief reap`.
chief_reap_orphans() {
  local scope="${1:-}" marker="${2:-}" label="${3:-a previous run}" grace="${4:-${CHIEF_REAP_GRACE:-5}}"
  chief_find_orphans "$scope" "$marker"
  [ -n "$CHIEF_ORPHANS" ] || return 0
  chief_report_orphans "  ⚠ orphaned chief processes from $label — still running with no live registered run:"
  chief_reap_pids "$CHIEF_ORPHANS" "$label" "$grace"
}

# ── the registry's INVERSE: live drivers that no run file knows about ────────
#
# monitor.sh has always pruned a run file whose pid is dead. The opposite failure —
# a LIVE driver with NO run file — had no check at all, and it is the one that
# actually hurt: `chief ps` reported "no active runs" while an agent was mid-turn,
# spending quota nothing was watching. It happens whenever the record is removed
# before the tree is (the teardown inversion US-1 fixed), whenever a run file is
# deleted by hand, and whenever the registry dir is lost under a driver.
#
# The same two markers that find an orphan identify a driver, plus one more fact:
# the run id ENDS in the pid of the driver that minted it. That is what separates
# the driver from the processes sharing its marker — its own `run_worker` subshells
# are forks, so they carry the driver's argv verbatim, and every `agent.sh` frame is
# stamped with the same id. Only one marked process has a pid equal to the id's last
# field, and that one IS the driver.

chief_driver_pids() {   # [MARKER] -> "<pid> <runid>" per LIVE driver of this user
  local marker="${1:-$CHIEF_RUN_MARKER}" p tag
  for p in $(chief_pids_tagged "$marker"); do
    tag="$(chief_pid_tag "$p")"
    [ -n "$tag" ] || continue
    [ "${tag##*-}" = "$p" ] || continue      # a worker subshell / agent frame, not the driver
    chief_pid_alive "$p" || continue
    printf '%s %s\n' "$p" "$tag"
  done
  return 0
}

# <repo>-<cksum>-<epoch>-<pid>: the cksum is of the repo's ABSOLUTE path — the same
# key $WT_ROOT is built from — so a known repo path that hashes to it IS that repo.
chief_run_id_cksum() { # $1 = run id -> the repo-path checksum ('' if malformed)
  local k="${1:-}"
  k="${k%-*}"                                # strip <pid>
  k="${k%-*}"                                # strip <epoch>
  printf '%s' "${k##*-}"
}

# Resolve a run id back to the repo it is driving, through THIS prefix's known-repos
# registry (bin/chief appends to it on every init/run). Going through the registry is
# also what keeps the report scoped to this install: a driver belonging to another
# $CHIEF_PREFIX — a hermetic test's, or a test's view of the developer's own real run
# — hashes to a repo this registry has never heard of, and is left alone.
chief_repo_for_run() { # $1 = run id -> repo root ('' when not a repo of this prefix)
  local want line repos
  want="$(chief_run_id_cksum "${1:-}")"
  case "$want" in ''|*[!0-9]*) return 0 ;; esac
  repos="${CHIEF_REPOS:-$CHIEF_PREFIX_DEFAULT/repos}"
  [ -f "$repos" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$(printf '%s' "$line" | cksum | cut -d' ' -f1)" = "$want" ]; then
      printf '%s' "$line"; return 0
    fi
  done < "$repos"
  return 0
}

# The run file naming this pid, if the registry has one. Matched on the pid= FIELD
# rather than the filename, so a registry entry copied/renamed still counts as
# registration — under-reporting a live driver is the bug being fixed here.
chief_run_file_for_pid() { # $1 = pid -> the <pid>.run path ('' when unregistered)
  local pid="${1:-}" runs f
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  runs="${CHIEF_RUNS:-$CHIEF_PREFIX_DEFAULT/runs}"
  for f in "$runs"/*.run; do
    [ -e "$f" ] || continue
    [ "$(sed -n 's/^pid=//p' "$f" 2>/dev/null | head -1)" = "$pid" ] && { printf '%s' "$f"; return 0; }
  done
  return 0
}

# What a driver is actually working on, straight from its repo's scheduler state —
# the answer to "what do I lose if I kill this pid", which is the whole reason an
# operator needs more than a bare "something is wrong".
chief_driver_inflight() {  # $1 = repo root -> "<name> <state>" pairs, space-joined
  local repo="${1:-}" sd f n st out=""
  [ -n "$repo" ] || return 0
  sd="$repo/$(chief_state_rel "$repo")/parallel"
  for f in "$sd"/*.state; do
    [ -e "$f" ] || continue
    n="$(basename "$f" .state)"
    st="$(head -1 "$f" 2>/dev/null)"
    out="$out $n ${st:-unknown}"
  done
  printf '%s' "${out# }"
}

# How this repo's driver.lock relates to a pid — the single-driver invariant as the
# FILESYSTEM sees it, next to what the process table says.
chief_driver_lock_state() { # $1 = repo root  $2 = pid -> held|stale|other:<pid>|missing
  local repo="${1:-}" pid="${2:-}" lp
  [ -n "$repo" ] || { printf 'missing'; return 0; }
  lp="$(cat "$repo/$(chief_state_rel "$repo")/driver.lock/pid" 2>/dev/null || echo)"
  if   [ -z "$lp" ];        then printf 'missing'
  elif [ "$lp" = "$pid" ];  then printf 'held'
  elif chief_pid_alive "$lp"; then printf 'other:%s' "$lp"
  else printf 'stale:%s' "$lp"; fi
  return 0
}

# chief_find_unregistered_drivers [MARKER] — every LIVE driver with no run file.
#   CHIEF_UNREG       space-separated pids
#   CHIEF_UNREG_INFO  one TAB-separated record per pid:
#                     pid \t runid \t repo \t lockstate \t "<name> <state> …"
CHIEF_UNREG=""
CHIEF_UNREG_INFO=""
chief_find_unregistered_drivers() {
  local marker="${1:-$CHIEF_RUN_MARKER}" pid tag repo lock work pids=""
  CHIEF_UNREG=""; CHIEF_UNREG_INFO=""
  while read -r pid tag; do
    [ -n "$pid" ] || continue
    [ -n "$(chief_run_file_for_pid "$pid")" ] && continue      # registered — nothing to report
    repo="$(chief_repo_for_run "$tag")"
    [ -n "$repo" ] || continue                                 # not a repo of this prefix
    lock="$(chief_driver_lock_state "$repo" "$pid")"
    work="$(chief_driver_inflight "$repo")"
    pids="$pids $pid"
    CHIEF_UNREG_INFO="$CHIEF_UNREG_INFO$pid	$tag	$repo	$lock	$work
"
  done <<EOF
$(chief_driver_pids "$marker")
EOF
  # shellcheck disable=SC2086
  set -- $pids
  CHIEF_UNREG="$*"
  return 0
}

# ── CLI: `chief reap` ────────────────────────────────────────────────────────

chief_reap_usage() {
  cat <<EOF
chief reap [-n|--dry-run] [--grace N]

Sweep the host for ORPHANED chief work: driver/agent/tool processes still running
with no live, registered run behind them (a run killed with SIGKILL, a terminal
closed on an older engine, a crash). Reports what it found — repo, tasklist and
command — then stops it: TERM, then KILL after a grace period.

  -n, --dry-run   report what WOULD be reaped; signal nothing
      --grace N   seconds between TERM and KILL (default ${CHIEF_REAP_GRACE:-5})

Never touches a registered live run, a driver holding its repo's driver.lock,
another user's processes, or anything outside $CHIEF_WT_ROOT_ALL.
EOF
}

chief_reap_main() {
  local dry=0 grace="${CHIEF_REAP_GRACE:-5}" n
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -n|--dry-run) dry=1; shift ;;
      --grace)      grace="${2:-5}"; shift 2 ;;
      --grace=*)    grace="${1#*=}"; shift ;;
      -h|--help)    chief_reap_usage; return 0 ;;
      *)            echo "chief reap: unknown argument '$1' (see 'chief reap --help')" >&2; return 2 ;;
    esac
  done
  chief_find_orphans "$CHIEF_WT_ROOT_ALL" "$CHIEF_RUN_MARKER"
  if [ -z "$CHIEF_ORPHANS" ]; then
    echo "chief reap: no orphaned chief processes (worktrees: $CHIEF_WT_ROOT_ALL)"
    # An empty env read is not evidence of an empty host — say which keys actually ran.
    [ -n "$(chief_env_key_mode)" ] || echo "  (this platform will not show another" \
      "process's environment, so the inherited-\$CHIEF_RUN_ID key was inactive —" \
      "cwd + argv carried this sweep)"
    return 0
  fi
  # shellcheck disable=SC2086
  set -- $CHIEF_ORPHANS; n="$#"
  chief_report_orphans "chief reap: $n orphaned process(es) — chief work with no live, registered run:"
  if [ "$dry" = 1 ]; then
    echo "  (dry run — nothing was signalled; drop -n to reap)" >&2
    return 0
  fi
  chief_reap_pids "$CHIEF_ORPHANS" "orphaned chief work" "$grace"
}

# Run only when executed, not when sourced by driver.sh.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  chief_reap_main "$@"
  exit $?
fi
