#!/usr/bin/env bash
# engine/paths.sh — where chief keeps its HOST-WIDE state, resolved in exactly one
# place, for bin/chief, the driver, the monitor and the reaper alike.
#
# WHY THIS FILE EXISTS. The prefix used to be spelled `${CHIEF_PREFIX:-$HOME/.chief}`
# inline in five scripts, and that expression is wrong in a container:
#
#   · Under `set -u` (every one of those scripts) an UNSET $HOME is not a fallback,
#     it is `HOME: unbound variable` — the run dies on line 1 of the driver with a
#     message that names neither chief nor the container. A minimal image (scratch,
#     distroless, a `docker run --user 1000` with no passwd entry) has no HOME.
#   · A READ-ONLY or nonexistent $HOME resolves fine and then fails much later, at
#     `git worktree add`, as a confusing permission error inside git.
#
# So resolution is a function, it never touches an unset variable, and it falls
# through to somewhere writable instead of somewhere merely nameable:
#
#   1. $CHIEF_PREFIX               — explicit; ALWAYS wins. What a host sets.
#   2. $HOME/.chief                — the host default, when $HOME exists and either
#                                    it or an existing $HOME/.chief is writable.
#   3. $XDG_STATE_HOME/chief       — the conventional stateful-data location.
#   4. ${TMPDIR:-/tmp}/chief-<uid> — the container floor. Keyed by uid so two users
#                                    sharing a /tmp never collide, and STABLE for a
#                                    given uid so `chief ps` in one container shell
#                                    resolves the same registry the driver wrote in
#                                    another. Ephemeral by nature: state does not
#                                    survive a container restart, which is why a
#                                    host that wants durable runs sets (1) onto a
#                                    volume. See docs/drivers-and-safety.md.
#
# NOTHING HERE CREATES A DIRECTORY. These are pure path resolvers, called from the
# top of scripts that may only be printing help; the callers that need the tree
# (driver.sh) mkdir it and check writability with a diagnosis attached.
#
# Bash 3.2 compatible (no arrays, no ${var@Q}, no process substitution).

chief_prefix() {
  local uid tmp
  if [ -n "${CHIEF_PREFIX:-}" ]; then printf '%s\n' "${CHIEF_PREFIX%/}"; return 0; fi
  if [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then
    # An existing prefix wins even when $HOME itself is read-only: a bind-mounted
    # ~/.chief under an immutable home is a supported container shape.
    if [ -d "$HOME/.chief" ] && [ -w "$HOME/.chief" ]; then printf '%s\n' "$HOME/.chief"; return 0; fi
    if [ -w "$HOME" ]; then printf '%s\n' "$HOME/.chief"; return 0; fi
  fi
  if [ -n "${XDG_STATE_HOME:-}" ]; then printf '%s\n' "${XDG_STATE_HOME%/}/chief"; return 0; fi
  uid="${UID:-$(id -u 2>/dev/null || echo 0)}"
  tmp="${TMPDIR:-/tmp}"
  printf '%s\n' "${tmp%/}/chief-$uid"
}

# The host-wide run registry (one <pid>.run per live driver) and the known-repos
# list. Both are overridable on their own, INDEPENDENTLY of the prefix, so a host
# can put the volatile registry on a tmpfs and keep worktrees on a volume.
chief_runs_dir()  { printf '%s\n' "${CHIEF_RUNS:-$(chief_prefix)/runs}"; }
chief_repos_dir() { printf '%s\n' "${CHIEF_REPOS:-$(chief_prefix)/repos}"; }

# The root holding EVERY repo's worktrees ($CHIEF_WORKTREE_ROOT/<repo>-<cksum>/…).
# Relocatable on its own because the worktree tree is the one part of the prefix
# with a hard requirement beyond writability: it must be on a filesystem that
# supports git worktrees (a real one — not an overlay whose upper layer the repo's
# bind mount is missing from), and it must NOT be inside the repo, or a `--print`
# agent resolves its project root to the outer tree and the branch merges empty.
chief_worktree_root() {
  if [ -n "${CHIEF_WORKTREE_ROOT:-}" ]; then printf '%s\n' "${CHIEF_WORKTREE_ROOT%/}"; return 0; fi
  printf '%s\n' "$(chief_prefix)/worktrees"
}
