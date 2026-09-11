#!/usr/bin/env bash
# engine/ledger.sh — THE DESCENDANT LEDGER, key 4 of the orphan sweep.
#
# WHY A FOURTH KEY. engine/reap.sh finds orphaned work on three keys — a cwd inside
# the run's worktree, a `--chief-run=` marker on argv, and that same run id read back
# out of a candidate's ENVIRONMENT. The third exists for exactly one shape: a
# descendant that chdir'd OUT of the worktree AND exec'd an argv that says nothing.
# Inheritance is the only thing that still reaches such a process… on a host that
# will show you another process's environment. macOS will not: `ps -E` is accepted
# under SIP and prints none, so key 3 degrades to zero and that shape has NO key at
# all on the platform this fleet actually runs on.
#
# It is not a hypothetical shape. 2026-09-11, macOS 26.5: four runs were cut off
# around 00:58 with every driver pid dead and every state file still saying
# `running`, and a manual sweep found `UnrealEditor-Cmd -unattended` on a temporary
# `engine-version-probe-<uuid>.uproject` spawned by a downstream tasklist's run — PPID
# 1, cwd in `/Users/Shared/Epic Games/UE_5.8/…`, no marker on argv, 78 minutes old,
# 199% CPU, and ignoring SIGTERM. test/reap-escaped.sh is that process, reproduced.
#
# WHY THE PPID WALK CANNOT FIND IT EITHER. `stop_reap_tree` and
# `chief_scan_descendants` walk PPID edges DOWN from a live driver. Once the driver
# dies, its descendants are re-parented to PID 1 and there is no edge back to
# anything chief could start a walk from. The tree has to be RECORDED while it is
# still connected — which is what this file does.
#
# THE MECHANISM. While a run is live the driver snapshots its own process tree into
# the run registry beside its `<pid>.run` file: one `<driver pid>.ledger` holding the
# run id, the PID namespace those pids are numbered in, and a record per live
# descendant — pid, START TIME, command. `chief reap` then treats a still-live pid
# found in a DEAD run's ledger as a candidate, and the ledger is a RECORD rather than
# a search: it needs no cwd, no argv and no environment, so nothing a process does
# after it was recorded can hide it.
#
# PID REUSE IS THE FAILURE TO REFUSE. A ledger is a list of numbers, and a number
# outlives the process that wore it. So every entry carries the start time its pid
# had when it was recorded, and a live pid whose start time does NOT match is
# reported LEFT ALONE and never signalled. That check is the whole safety argument
# for the key, which is why the two sides of it — recording and verifying — go
# through ONE function (chief_ledger_starttime); a second reader spelling the token
# differently would turn every entry into a refusal, or worse, every refusal into a
# match. Where a host cannot report a start time at all, the key is inactive rather
# than unchecked (chief_ledger_available), exactly as key 3 is under SIP.
#
# THE BOUND. A snapshot is taken once per scheduler poll (POLL_SECONDS, default 5s),
# so the window is: a process that is spawned, leaves the tree AND loses its driver
# inside one poll interval is not in any ledger. That is the honest limit of the key
# — it bounds what can escape, it does not eliminate it. Keys 1-3 still run, and the
# sweep is a UNION: this key can only ever ADD a candidate.
#
# EARNED, NOT INHERITED. Key 3 is gated three ways (well-formed id · dead run · not
# somebody's shell) because inheritance reaches a terminal an operator opened out of
# an agent's environment. The ledger reaches nothing of the sort: it contains what
# the driver's own tree contained at a moment when the driver was alive to see it,
# which is chief's work by construction — the same standing as a cwd inside chief's
# own worktree root. Its entries are scoped by run id like every other key, and the
# run must be dead before any of them is a candidate.
#
# Sourced by engine/reap.sh (which owns chief_ns_token and chief_runs_dir, both
# called here at run time, after that file has finished sourcing this one).
# Bash 3.2 compatible: no arrays, no process substitution, no GNU-only ps flags.

# The registry file a run's ledger lives in, named for the DRIVER's pid exactly as
# its `<pid>.run` sibling is — so a new run on a recycled pid overwrites the old
# ledger instead of accumulating one per run.
chief_ledger_file() {    # $1 = runs dir, $2 = driver pid
  printf '%s/%s.ledger' "${1%/}" "${2:-}"
}

# WHEN did this pid start? The token both halves of the key are written against:
# recorded once by the snapshot, re-read by the sweep, and compared as strings. Its
# exact spelling is irrelevant as long as it is STABLE for a process and DIFFERENT
# across a pid's reuse — which `ps -o lstart=` (a wall-clock timestamp, present on
# both BSD/macOS and procps) gives to the second.
#
# One mechanism deliberately, on both platforms. A /proc fast path would be exact
# where it exists, but the recording side and the checking side would then be two
# readers that can disagree — and a disagreement here does not degrade, it inverts:
# every honest entry becomes a refusal, or every reused pid becomes a match.
chief_ledger_starttime() {   # $1 = pid -> a stable start-time token ('' when unknown)
  local st
  case "${1:-}" in ''|*[!0-9]*) return 0 ;; esac
  st="$(ps -o lstart= -p "$1" 2>/dev/null | head -1 | tr -s ' ' '_')"
  st="${st#_}"; st="${st%_}"
  printf '%s' "$st"
}

# Can this host report a start time at all? PROBED against our OWN pid, never
# assumed — the same discipline chief_env_key_mode applies to the environment read,
# and for the same reason: a key that silently answers "nothing" is indistinguishable
# from a clean host. Cached per shell; "-" is "probed and unavailable".
CHIEF_LEDGER_MODE=""
chief_ledger_available() {
  if [ -z "$CHIEF_LEDGER_MODE" ]; then
    CHIEF_LEDGER_MODE="-"
    [ -n "$(chief_ledger_starttime "$$")" ] && CHIEF_LEDGER_MODE="lstart"
  fi
  [ "$CHIEF_LEDGER_MODE" = "-" ] && return 1
  return 0
}

# Every LIVE descendant of a pid as "<pid><TAB><start><TAB><command>".
#
# ONE `ps` and one `awk`, with the parent walk done inside awk: this runs on every
# scheduler poll of every live run, and chief_scan_descendants' shape (a fork per
# frontier layer) is the wrong cost at that cadence. `lstart` is five whitespace-
# separated fields ("Thu Sep 11 10:23:45 2026"), joined here with the same `_` that
# chief_ledger_starttime's `tr -s ' ' '_'` produces — a padded day-of-month collapses
# identically on both sides.
#
# THE SNAPSHOT MUST NOT RECORD ITSELF, which is why the `ps` is captured into a
# variable (chief_scan_descendants' idiom) rather than piped straight into the awk.
# `$(ps …)` and the subshell around it are children of the driver and appear in their
# own output; the `kill -0` filter then drops them, because a command substitution is
# reaped before it returns and they are gone by the time this loop reads a row. Piping
# instead would leave the awk ALIVE while the loop runs, and every snapshot would
# record the two processes that took it. Dead entries cost nothing to a reader that
# checks liveness, but a ledger that always names two processes cannot be read as a
# record of what the run was actually doing. `kill -0` is a builtin: no forks here.
chief_ledger_tree() {    # $1 = root pid
  local root="${1:-}" snap pid st cmd
  case "$root" in ''|*[!0-9]*) return 0 ;; esac
  snap="$(ps -eo pid=,ppid=,lstart=,command= 2>/dev/null)"
  [ -n "$snap" ] || return 0
  printf '%s\n' "$snap" | awk -v root="$root" '
    {
      st = $3 "_" $4 "_" $5 "_" $6 "_" $7
      cmd = ""
      for (i = 8; i <= NF; i++) cmd = cmd (i > 8 ? " " : "") $i
      P[$1] = $2; S[$1] = st; C[$1] = cmd; n++; O[n] = $1
    }
    END {
      for (i = 1; i <= n; i++) {
        p = O[i]; q = P[p]; d = 0; ok = 0
        # Up the parent chain, bounded: pid reuse between two lines of one ps
        # snapshot must never turn a cycle into an infinite loop.
        while (d < 64 && q != "" && q != "0" && q != "1") {
          if (q == root) { ok = 1; break }
          q = P[q]; d++
        }
        if (ok) printf "%s\t%s\t%s\n", p, S[p], (C[p] == "" ? "-" : substr(C[p], 1, 200))
      }
    }' | while IFS=$'\t' read -r pid st cmd; do
    kill -0 "$pid" 2>/dev/null || continue
    printf '%s\t%s\t%s\n' "$pid" "$st" "$cmd"
  done
}

# Record this run's tree. Called by driver.sh once per scheduler poll, and by nothing
# else — a snapshot taken by a process that is not the run's driver would name a tree
# that is not the run's.
#
# Written to a temp file and mv'd into place, because `chief reap` may be reading the
# ledger of a run that is dying at that moment and a half-written record would be
# read as a pid-reuse refusal. Every failure here is silent and non-fatal: the ledger
# is an ADDITIONAL key, and a run must not die because its bookkeeping could not be
# written.
chief_ledger_snapshot() {   # [$1 = runs dir] [$2 = driver pid] [$3 = run id]
  local runs="${1:-$(chief_runs_dir)}" pid="${2:-$$}" rid="${3:-${CHIEF_RUN_ID:-}}" f tmp
  chief_ledger_available || return 0
  [ -n "$rid" ] || return 0
  [ -d "$runs" ] || return 0
  f="$(chief_ledger_file "$runs" "$pid")"
  tmp="$f.$$.tmp"
  {
    printf 'runid=%s\n' "$rid"
    printf 'ns=%s\n' "$(chief_ns_token)"      # whose pid numbers these are
    printf 'recorded=%s\n' "$(date +%s)"
    chief_ledger_tree "$pid"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
  mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  return 0
}

# A header field of a ledger file ('' when absent) — runid · ns · recorded.
chief_ledger_field() {   # $1 = ledger file, $2 = field
  sed -n "s/^$2=//p" "${1:-}" 2>/dev/null | head -1
}
