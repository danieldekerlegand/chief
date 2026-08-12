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
#      Be honest about how much this is actually carrying: a field census of 176
#      orphans across three repos found key 1 covering MORE than expected — the bare
#      `yes` load-generators (whose cwd `lsof` still reported after the worktree was
#      deleted) and a whole server + npm/tsx tree both sat squarely inside it. The
#      167 leaked integration-test servers that ran out of a temp dir were the
#      suspected escapees, but their cwd was never recorded before they were killed,
#      so whether they beat key 1 is UNVERIFIED. This key is therefore belt-and-
#      braces, not a proven hole: it exists for the process that escapes BOTH of the
#      others — chdir'd out of the worktree AND wearing an argv that says nothing —
#      which is the one shape inheritance can still see. test/teardown.sh part 4
#      builds exactly that process (detached from the tree, `sleep` for a command
#      line, in a temp dir) and pins that this key finds it and stops it.
#      Where a host will not show another process's environment (macOS since SIP
#      accepts `ps -E` and silently prints none), this key degrades to nothing and
#      keys 1 and 2 carry the sweep — the availability is PROBED, never assumed, so
#      an empty read is reported as "the key is inactive" and never as "no orphans".
#      Inheritance is also what makes key 3 the DANGEROUS one, so it alone is gated —
#      see "the inherited marker's blast radius" below.
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

if ! command -v chief_prefix >/dev/null 2>&1; then
  # shellcheck source=engine/paths.sh
  . "$_REAP_DIR/paths.sh"
fi

CHIEF_PREFIX_DEFAULT="$(chief_prefix)"
CHIEF_WT_ROOT_ALL="$(chief_worktree_root)"             # every repo's worktrees live here
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

# ── WHOSE PID NUMBERS ARE THESE? ─────────────────────────────────────────────
#
# Every key below — the <pid>.run registry, driver.lock, the run id's trailing pid —
# is a PID, and a pid means nothing without the namespace it was numbered in. On a
# laptop there is only one and this is invisible. A container has its own, and the
# state prefix may be SHARED with the namespace that wrote it (a bind-mounted
# ~/.chief, a volume mounted into two containers, `docker run -v` against the host's
# prefix). Then pid 42 in the registry is a live driver over there and, here, either
# nothing or somebody else's process entirely — and every pid-keyed decision reads
# backwards:
#
#   · `chief ps` DELETES the run file of a live foreign run ("its pid is dead").
#   · the driver declares a foreign driver.lock stale and STEALS it — two drivers on
#     one repo, which is the single thing that lock exists to prevent.
#   · a foreign run file's pid collides with a local pid and a running driver is
#     mistaken for registered (or a candidate is spared for the wrong reason).
#
# So every record that carries a pid also carries the namespace token it was numbered
# in, and a reader that sees a FOREIGN token declines to interpret the pid at all —
# it neither reaps nor deletes nor steals on the strength of it. Degrading to nothing
# is the whole point: the alternative is acting confidently on a number that means
# something else.
#
# The token, in order:
#   1. $CHIEF_PID_NS               — explicit, for a host that knows better.
#   2. ns:<inode> from /proc/self/ns/pid — Linux, exact, and identical across two
#      containers that genuinely SHARE a namespace (`--pid=host`), which is right.
#   3. proc:<hostname>             — /proc but no ns link (old/restricted kernel).
#      A proxy: containers get their own UTS namespace by default.
#   4. host                        — no /proc at all (macOS/BSD): ONE machine-wide pid
#      space. Deliberately a constant, not the hostname — a laptop's hostname changes
#      with the network, and that must not turn yesterday's records foreign.
CHIEF_NS_TOKEN=""
chief_ns_token() {
  local ns h
  if [ -z "$CHIEF_NS_TOKEN" ]; then
    if [ -n "${CHIEF_PID_NS:-}" ]; then
      CHIEF_NS_TOKEN="${CHIEF_PID_NS}"
    else
      ns="$(readlink /proc/self/ns/pid 2>/dev/null || echo)"
      case "$ns" in
        *'['*']') ns="${ns#*[}"; CHIEF_NS_TOKEN="ns:${ns%]}" ;;
        *) if [ -d /proc/self ]; then h="$(hostname 2>/dev/null || echo)"; CHIEF_NS_TOKEN="proc:${h:-unknown}"
           else CHIEF_NS_TOKEN="host"; fi ;;
      esac
    fi
  fi
  printf '%s' "$CHIEF_NS_TOKEN"
}

# Does $1 name a DIFFERENT pid namespace than this process runs in? An EMPTY token is
# not foreign: it is a record written by an engine older than this field, or by a host
# that could not tell, and treating those as foreign would silently retire the stale
# -lock and stale-run-file cleanup that every ordinary run depends on. Unknown means
# "assume local, behave exactly as before"; only an explicit mismatch changes anything.
chief_ns_foreign() {   # $1 = recorded token
  [ -n "${1:-}" ] || return 1
  [ "$1" = "$(chief_ns_token)" ] && return 1
  return 0
}

# The namespace token recorded in a <pid>.run file ('' for a pre-0.8.14 file).
chief_run_file_ns() {  # $1 = run file
  sed -n 's/^ns=//p' "${1:-}" 2>/dev/null | head -1
}

# The namespace token recorded alongside a driver.lock's pid ('' when absent).
chief_lock_ns() {      # $1 = lock dir
  cat "${1:-}/ns" 2>/dev/null | head -1
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
  # Deliberately NOT namespace-filtered, unlike every other registry read. A foreign
  # run file's pid can only ever ADD to the protected set, and this set only ever
  # SPARES: the worst a numeric coincidence buys is one orphan surviving a sweep. The
  # namespace checks exist to stop confident destruction, so on the one path where
  # ambiguity is safe, ambiguity wins.
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

# ── the inherited marker's blast radius ──────────────────────────────────────
#
# Keys 1 and 2 are EARNED: a cwd inside chief's own directory, or an argv the engine
# stamped on itself. Key 3 is INHERITED, and inheritance is indiscriminate — every
# descendant carries $CHIEF_RUN_ID through chdir, exec and argv, forever, including a
# terminal an operator opened out of an agent's environment. That reach is the whole
# point of the key and also the whole risk of it, so key 3 — and ONLY key 3 — passes
# three gates before a pid becomes a candidate:
#
#   a. the id must NAME A RUN. `<repo>-<cksum>-<epoch>-<pid>`: an id whose cksum,
#      epoch or driver-pid field is missing or non-numeric is not something this
#      engine minted, so it is not evidence of anything.
#   b. the run it names must be DEAD. A marker on a live run's process is stale
#      bookkeeping at worst, never a licence to kill.
#   c. the carrier must not be somebody's SHELL.
#
# All three only ever REMOVE an env-keyed candidate — none of them can subtract from
# what the cwd or argv key found, so 75's coverage cannot regress.

# The two fields that make an id name a RUN rather than just a string: which driver
# minted it, and when. (`chief_run_id_cksum`, which names the repo, is defined with
# the registry helpers below.)
chief_run_id_pid()   { local k="${1:-}"; printf '%s' "${k##*-}"; }
chief_run_id_epoch() { local k="${1:-}"; k="${k%-*}"; printf '%s' "${k##*-}"; }

# Gate (a). A CHIEF_RUN_ID an operator exported by hand, or a value some other tool
# happens to use, must not be a licence to kill — it has to parse as one of ours.
chief_run_id_wellformed() {   # $1 = run id
  local id="${1:-}" f
  case "$id" in *-*-*-*) ;; *) return 1 ;; esac      # <repo>-<cksum>-<epoch>-<pid>
  for f in "$(chief_run_id_cksum "$id")" "$(chief_run_id_epoch "$id")" "$(chief_run_id_pid "$id")"; do
    case "$f" in ''|*[!0-9]*) return 1 ;; esac
  done
  [ "$(chief_run_id_pid "$id")" -gt 1 ] || return 1
  return 0
}

# Gate (b). Both answers compare the WHOLE id, epoch included — that is what tells two
# runs of the same repo apart, and what makes pid reuse unable to fake a live run: a
# recycled pid would have to be wearing the same marker to pass.
chief_run_id_live() {         # $1 = run id -> 0 when the run it names is still running
  local id="${1:-}" pid runs f rp
  pid="$(chief_run_id_pid "$id")"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  runs="${CHIEF_RUNS:-$CHIEF_PREFIX_DEFAULT/runs}"
  for f in "$runs"/*.run; do                # registered: a run file claiming this id
    [ -e "$f" ] || continue
    [ "$(sed -n 's/^runid=//p' "$f" 2>/dev/null | head -1)" = "$id" ] || continue
    # Written in another PID namespace: its pid is not a question this process can
    # answer, so it is not evidence either way. Fall through to the argv check, which
    # reads THIS namespace's process table and is always answerable.
    chief_ns_foreign "$(chief_run_file_ns "$f")" && continue
    rp="$(sed -n 's/^pid=//p' "$f" 2>/dev/null | head -1)"
    chief_pid_alive "$rp" && return 0
  done
  # Unregistered but alive — the run file is a bookkeeping artefact, the process table
  # is the fact. This is the same "lost its run file" case the protected set spares.
  chief_pid_alive "$pid" && [ "$(chief_pid_tag "$pid")" = "$id" ] && return 0
  return 1
}

# Gate (c). Does this pid look like a person's own interactive shell? Inheritance
# reaches one the moment somebody opens a terminal out of an agent's environment, and
# reaping it takes their session and — through the descendant walk — their editor.
#
# The test is on SHAPE, not on a tty (a driver started under nohup has none either):
# a shell invoked with no SCRIPT OPERAND — `-zsh`, `bash`, `bash --norc -i` — is a
# shell somebody is typing into. Every shell the engine runs carries an operand and
# cannot be spelled without one: driver.sh and agent.sh are `bash <path> --chief-run=…`
# and a tool step is `bash -c <command>`. So the gate costs the sweep nothing real.
#
# Deliberately one-way and deliberately generous. It narrows what INHERITANCE alone
# may claim, not what chief's own directory may: a terminal opened INSIDE the worktree
# is still key 1's, exactly as it was before this key existed.
chief_is_interactive_shell() {   # $1 = pid
  local pid="${1:-}" cmd
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  cmd="$(ps -o command= -p "$pid" 2>/dev/null | head -1)"
  [ -n "$cmd" ] || return 1
  # A subshell so `set -f` (a command line may contain a glob) stays local.
  ( set -f
    # shellcheck disable=SC2086
    set -- $cmd
    b="${1#-}"; b="${b##*/}"                # a login shell wears a leading '-'
    case "$b" in sh|bash|zsh|ksh|ksh93|dash|ash|fish|csh|tcsh) ;; *) exit 1 ;; esac
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in -*) ;; *) exit 1 ;; esac  # an operand — a script, not a prompt
      shift
    done
    exit 0 )
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
      _chief_cand_add "$pid" "[cwd]  working in $(chief_run_label "$rest")"
    done <<EOF
$(chief_pids_cwd_under "$scope")
EOF
  fi
  if [ -n "$marker" ]; then
    for p in $(chief_pids_tagged "$marker"); do
      _chief_cand_add "$p" "[argv] chief engine process · run $(chief_pid_tag "$p")"
    done
    # Key 3 — the same run id, inherited through the environment. Reaches the process
    # that escaped BOTH of the others: chdir'd out of the worktree AND wearing a
    # boring argv (a server in a temp dir, a bare `yes`). A union with the two above:
    # _chief_cand_add keeps the first reason recorded, so a process the cwd or argv
    # key already found is unaffected.
    #
    # The three gates are here and nowhere else — see "the inherited marker's blast
    # radius". A `continue` here removes nothing: a pid the cwd or argv key already
    # recorded keeps its candidacy and its reason.
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      pid="${line%% *}"; rest="${line#* }"
      chief_run_id_wellformed "$rest" || continue      # (a) names no run chief minted
      if chief_run_id_live "$rest"; then               # (b) a stale marker cannot kill
        _chief_protect_tree "$(chief_run_id_pid "$rest")"
        continue
      fi
      chief_is_interactive_shell "$pid" && continue    # (c) somebody's terminal
      _chief_cand_add "$pid" "[env]  inherited run marker · run $rest"
    done <<EOF
$(chief_pids_env_marked "${marker#"$CHIEF_RUN_MARKER"}")
EOF
  fi
  # Whatever the agent spawned that then wandered off the worktree (a build in a
  # temp dir, a server in /). Parentage is the only relation that reaches those.
  for p in $_chief_cand; do
    chief_scan_descendants "$p"
    for q in $CHIEF_DESCENDANTS; do _chief_cand_add "$q" "[tree] child of pid $p"; done
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

# The shared report: what was found, WHICH KEY matched it, and which run each pid
# belonged to. The key tag is not decoration — [env] is the one match that rests on
# inheritance alone rather than on chief's own directory or its own argv, so an
# operator reading a dry run can tell at a glance which findings to look twice at.
chief_report_orphans() {   # $1 = headline
  local line pid why
  echo "$1" >&2
  echo "       keys: [cwd] cwd inside a chief worktree · [argv] --chief-run= marker" \
       "· [env] inherited \$CHIEF_RUN_ID · [tree] descendant of a match" >&2
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
    # A foreign namespace's pid 42 is not our pid 42. Counting it as registration
    # would hide a genuinely unregistered local driver behind a numeric coincidence.
    chief_ns_foreign "$(chief_run_file_ns "$f")" && continue
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
chief_driver_lock_state() { # $1 = repo root  $2 = pid -> held|stale|other|foreign|missing
  local repo="${1:-}" pid="${2:-}" lock lp
  [ -n "$repo" ] || { printf 'missing'; return 0; }
  lock="$repo/$(chief_state_rel "$repo")/driver.lock"
  lp="$(cat "$lock/pid" 2>/dev/null || echo)"
  if   [ -z "$lp" ];        then printf 'missing'
  elif chief_ns_foreign "$(chief_lock_ns "$lock")"; then
    # Taken in another PID namespace (a container sharing this repo). "stale" would be
    # a guess, and the one that ends with two drivers on one repo.
    printf 'foreign:%s' "$lp"
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
