#!/usr/bin/env bash
# engine/gitenv.sh — the two git assumptions a HOST run gets for free and a
# CONTAINER run does not: that git will operate on the repo at all, and that a
# commit has an author.
#
# WHY THIS FILE EXISTS. Chief's whole loop is git — branch, worktree, commit,
# rebase, merge. On a laptop both of these are already true and nothing here does
# anything. Inside a container they are routinely false, and they fail LATE and
# unrecognisably: the driver gets several minutes into an agent iteration and then
#
#   1. OWNERSHIP. A bind-mounted repo is owned by the HOST uid; the container runs
#      as another (`--user 1000`, or root against a rootless mount). Git refuses to
#      even parse such a repo's config — "detected dubious ownership in repository"
#      — so every `git -C "$REPO" …` fails identically to "not a repository". The
#      documented fix is `safe.directory`, and it is only honoured in PROTECTED
#      configuration (system, global, command scope — see git-config(1) SCOPES), so
#      it cannot be set from the repo. `git config --global` needs a writable HOME,
#      which is exactly what a container may not have; the COMMAND scope, via
#      $GIT_CONFIG_COUNT/$GIT_CONFIG_KEY_<n>/$GIT_CONFIG_VALUE_<n>, needs no files
#      and is inherited by every git the run spawns — the agent's and the verify
#      hook's included. That is what this uses.
#
#   2. IDENTITY. `git commit` needs a name and an email. Git guesses them from the
#      passwd entry and the hostname, and a minimal image has neither a passwd entry
#      for the uid nor a hostname with a domain, so the guess is rejected as bogus
#      and the FIRST commit of the run dies with "Please tell me who you are".
#
# DEFAULTS, and why they differ between the two:
#
#   · Ownership is OPT-IN ($CHIEF_GIT_SAFE_DIRECTORY). Trusting a repo this uid does
#     not own is a security decision about a repo chief did not choose — the host
#     makes it, not us. Unset, chief still DIAGNOSES the refusal up front and names
#     the knob, instead of dying at the first git call an hour in.
#   · Identity is AUTOMATIC. A missing committer has no security dimension; it is
#     pure friction, and a run that cannot commit cannot do anything at all. Only
#     ever applied when git itself says it cannot resolve one, so a host run keeps
#     the operator's real identity untouched.
#
# Bash 3.2 compatible. Sourced by engine/driver.sh (whose exports every child git
# inherits) and by bin/chief for the same diagnosis at init time. What an embedding
# host sets, and what each knob below degrades to, is docs/containers.md.

# Why git will not operate on $1 — 'ok' | 'ownership' | 'norepo' | 'nogit'.
# The message is git's own; we only classify it, so a rewording upstream degrades to
# 'norepo' (still an error, just a less specific one) rather than to a false 'ok'.
chief_git_probe() {   # $1 = repo dir
  local dir="${1:-.}" err
  command -v git >/dev/null 2>&1 || { printf 'nogit'; return 0; }
  err="$(git -C "$dir" rev-parse --git-dir 2>&1 >/dev/null)" && { printf 'ok'; return 0; }
  case "$err" in
    *ownership*|*safe.directory*) printf 'ownership' ;;
    *)                            printf 'norepo' ;;
  esac
}

# Append `safe.directory=<path>` to the COMMAND-scope config every child git reads.
# Additive: an existing $GIT_CONFIG_COUNT (a host that injected its own config) is
# extended, never overwritten.
chief_git_trust_dir() {   # $1 = path, or '*' for every repo
  local path="${1:-}" n
  [ -n "$path" ] || return 0
  n="${GIT_CONFIG_COUNT:-0}"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  eval "GIT_CONFIG_KEY_$n=safe.directory; export GIT_CONFIG_KEY_$n"
  eval "GIT_CONFIG_VALUE_$n=\$path;       export GIT_CONFIG_VALUE_$n"
  GIT_CONFIG_COUNT=$(( n + 1 )); export GIT_CONFIG_COUNT
}

# $CHIEF_GIT_SAFE_DIRECTORY as a list of paths to trust, or '' when it is unset/off.
#   1 | true | yes | auto   the repo itself, plus chief's worktree root (worktrees
#                           live outside the repo and are their own git dirs)
#   *                       every repo — the blanket opt-out, for a throwaway container
#   <path>[:<path>…]        exactly these
chief_git_safe_dirs() {   # $1 = repo dir  [$2 = worktree root]
  local v="${CHIEF_GIT_SAFE_DIRECTORY:-}" repo="${1:-}" wt="${2:-}"
  case "$v" in
    ''|0|false|no|off) return 0 ;;
    1|true|yes|auto)   printf '%s\n' "$repo"; [ -n "$wt" ] && printf '%s\n' "$wt"; return 0 ;;
    '*')               printf '%s\n' '*'; return 0 ;;
  esac
  printf '%s\n' "$v" | tr ':' '\n' | while IFS= read -r p; do [ -n "$p" ] && printf '%s\n' "$p"; done
}

# Make git operate on $1, or explain why it will not. Echoes one note per action
# taken; returns non-zero (with the diagnosis on stdout) when git still refuses.
# Idempotent — a second call on a working repo is a probe and nothing else.
chief_git_ensure_ownership() {   # $1 = repo dir  [$2 = worktree root]
  local repo="${1:-.}" wt="${2:-}" state p noglob
  state="$(chief_git_probe "$repo")"
  case "$state" in
    ok)    return 0 ;;
    nogit) echo "ERROR: git is not installed — chief cannot run without it."; return 1 ;;
    norepo) echo "ERROR: git will not operate on $repo (not a repository, or permissions)."
            echo "       Run \`git status\` in it to see git's own message."; return 1 ;;
  esac
  # ownership: the container case this file exists for.
  #
  # `set -f` around the loop is load-bearing, not tidiness. chief_git_safe_dirs
  # legitimately prints `*` (the blanket mode), and an UNQUOTED expansion of that
  # word is pathname expansion: the trust list silently became the file names in the
  # cwd — `tasks`, `bin`, `README.md` — none of which is a repo, so `*` trusted
  # nothing and the blanket opt-out did not work at all. The word-splitting the loop
  # relies on (one path per line) is kept; only globbing is turned off, and only if
  # it was on, so a caller that had already disabled it is left as it was.
  noglob=0
  case $- in *f*) ;; *) set -f; noglob=1 ;; esac
  for p in $(chief_git_safe_dirs "$repo" "$wt"); do chief_git_trust_dir "$p"; done
  if [ "$noglob" = 1 ]; then set +f; fi
  if [ "$(chief_git_probe "$repo")" = ok ]; then
    echo "  (git: trusting $repo via safe.directory — CHIEF_GIT_SAFE_DIRECTORY is set)"
    return 0
  fi
  echo "ERROR: git refuses this repo — 'detected dubious ownership in repository at $repo'."
  echo "       The checkout is owned by a different uid than this process (uid $(id -u)),"
  echo "       which is the normal shape of a bind-mounted repo inside a container."
  if [ -z "${CHIEF_GIT_SAFE_DIRECTORY:-}" ]; then
    echo "       Fix it for THIS run only (no files written, inherited by every child git):"
    echo "           CHIEF_GIT_SAFE_DIRECTORY=1     # trust the repo + chief's worktree root"
    echo "           CHIEF_GIT_SAFE_DIRECTORY='*'   # trust every repo (throwaway container)"
    echo "       Or persist it in git itself:  git config --global --add safe.directory $repo"
  else
    echo "       CHIEF_GIT_SAFE_DIRECTORY is set and git STILL refuses — this git may be too"
    echo "       old to honour command-scope safe.directory (needs 2.31+). Set it in a global"
    echo "       config instead:  git config --global --add safe.directory $repo"
  fi
  return 1
}

# Give the run a committer when git cannot resolve one. `git var GIT_COMMITTER_IDENT`
# applies exactly the strictness `git commit` does — it fails both when nothing is
# configured AND when the auto-detected value is bogus (no passwd entry, or a
# domain-less hostname), which is the container case and is why this is not a plain
# `git config user.email` read. Echoes one note when it acts, nothing when it does not.
chief_git_ensure_identity() {   # $1 = repo dir
  local repo="${1:-.}" name email
  git -C "$repo" var GIT_COMMITTER_IDENT >/dev/null 2>&1 && return 0
  name="${CHIEF_GIT_IDENTITY_NAME:-chief}"
  email="${CHIEF_GIT_IDENTITY_EMAIL:-chief@localhost}"
  GIT_AUTHOR_NAME="$name";     GIT_COMMITTER_NAME="$name"
  GIT_AUTHOR_EMAIL="$email";   GIT_COMMITTER_EMAIL="$email"
  export GIT_AUTHOR_NAME GIT_COMMITTER_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_EMAIL
  echo "  (git: no committer identity on this host — commits will be authored as $name <$email>;"
  echo "   set CHIEF_GIT_IDENTITY_NAME / CHIEF_GIT_IDENTITY_EMAIL to change it)"
  return 0
}

# Both, in the only order that works: identity is probed THROUGH the repo's config,
# so ownership has to be settled first or the identity probe fails for the wrong
# reason. Non-zero = git cannot operate here; the caller prints and exits.
chief_git_env_setup() {   # $1 = repo dir  [$2 = worktree root]
  chief_git_ensure_ownership "$1" "${2:-}" || return 1
  chief_git_ensure_identity "$1"
  return 0
}
