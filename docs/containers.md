# Running chief in a container / Riju workspace

An embedded chief run inside a container — a Cuneiform **Riju** per-language workspace,
a `docker run` against a bind-mounted checkout, a CI job in an image — must behave
exactly like a host run: same scheduling, same `implement → verify → merge`, same
records. It is the *same engine*; this document is about the **environment** it needs,
because a container removes four things a laptop gives chief for free.

Nothing here is a mode or a code path. There is no `--container` flag: every knob below
is an ordinary environment variable, and a host run that sets none of them behaves as
it always has.

## TL;DR — what an embedding host sets

```sh
docker run --rm \
  -v /srv/checkouts/myrepo:/work/myrepo \      # the repo (must be WRITABLE)
  -v chief-state:/var/lib/chief \              # durable state, optional but recommended
  -e CHIEF_PREFIX=/var/lib/chief \             #   state prefix: registry, repos list
  -e CHIEF_WORKTREE_ROOT=/var/lib/chief/wt \   #   worktrees (a real fs, outside the repo)
  -e CHIEF_GIT_SAFE_DIRECTORY=1 \              #   trust the bind-mounted repo (opt-in)
  -e CHIEF_GIT_IDENTITY_EMAIL=bot@example.com \#   who the commits are from (optional)
  -e CHIEF_PROJECT=/work/myrepo \
  myimage chief run --headless -p 2
```

| variable | what it settles | default without it |
|---|---|---|
| `CHIEF_PREFIX` | all host-wide state: `runs/`, `repos`, `worktrees/` | `$HOME/.chief`, then `$XDG_STATE_HOME/chief`, then `${TMPDIR:-/tmp}/chief-<uid>` |
| `CHIEF_WORKTREE_ROOT` | the worktree tree only, relocatable off the prefix | `<prefix>/worktrees` |
| `CHIEF_RUNS` / `CHIEF_REPOS` | the run registry / known-repos list, each on its own | `<prefix>/runs`, `<prefix>/repos` |
| `CHIEF_GIT_SAFE_DIRECTORY` | **opt-in**: makes git operate on a repo owned by another uid | unset — chief refuses up front with a diagnosis |
| `CHIEF_GIT_IDENTITY_NAME` / `_EMAIL` | the committer used **only** when git cannot resolve one | `chief <chief@localhost>` |
| `CHIEF_PID_NS` | this container's PID-namespace token, if you know better than chief | auto-detected (`/proc/self/ns/pid`, else hostname, else `host`) |
| `CHIEF_HEADLESS=1` | non-interactive shape + machine-readable lines — see [`headless-invocation.md`](headless-invocation.md) | interactive/human output |

Plus the ordinary requirements, which a container makes easy to get wrong: **`git` and
`jq` must be on `PATH`**, the **repo mount must be writable** (chief commits, branches,
merges), and the provider CLI (`claude`, `opencode`, …) must be installed and
authenticated in the image.

## The four assumptions, and how each one holds

### 1. `$HOME` may be unset, minimal, or read-only

Every host-wide path resolves in one place, `engine/paths.sh`, in this order:

1. `$CHIEF_PREFIX` — explicit, always wins.
2. `$HOME/.chief` — when `$HOME` exists **and** either it or an existing
   `$HOME/.chief` is writable. (A bind-mounted `~/.chief` under an immutable home is a
   supported shape: the prefix being writable is enough.)
3. `$XDG_STATE_HOME/chief`.
4. `${TMPDIR:-/tmp}/chief-<uid>` — the container floor.

The floor is keyed by uid, so two users sharing a `/tmp` never collide, and it is
**stable** for a given uid, so `chief ps` in a second container shell resolves the same
registry the driver wrote in the first. It is also **ephemeral**: state does not survive
a container restart. A host that wants durable runs sets `CHIEF_PREFIX` onto a volume.

Chief checks that the state tree is **writable, not merely nameable**, once, at startup,
and names the knob if it is not — a read-only prefix otherwise surfaces much later as a
permission error from deep inside `git worktree add`.

### 2. Worktrees must be relocatable

Worktrees live **outside the repo** on purpose: a worktree nested inside `$REPO` makes a
`--print` agent resolve its project root to the outer working tree, so it edits *that*
and the branch merges empty. `CHIEF_WORKTREE_ROOT` moves the tree all repos share,
independently of the prefix, because the worktree tree has a requirement the rest of the
prefix does not — it must be on a real filesystem (not a tmpfs you sized for a registry,
not an overlay whose upper layer the repo's bind mount is missing from).

The per-repo key is `<basename>-<cksum of the absolute path>`. A container's mount path
differs from the host's, so the same repo keys differently inside — which is exactly what
keeps a container run's worktrees from colliding with the host's.

### 3. git will not touch a repo owned by another uid

A bind-mounted checkout is owned by the **host** uid; the container runs as another
(`--user 1000`, or root against a rootless mount). Git then refuses to parse the repo at
all — `detected dubious ownership in repository at …` — and every `git -C "$REPO"` fails
identically to "not a repository".

`CHIEF_GIT_SAFE_DIRECTORY` is the opt-in:

| value | effect |
|---|---|
| unset / `0` / `false` / `no` / `off` | nothing is trusted. Chief still **diagnoses** the refusal at startup and names this knob. |
| `1` / `true` / `yes` / `auto` | trust this repo **and** chief's worktree root. |
| `*` | trust every repo — the blanket opt-out for a throwaway container. |
| `/a:/b:/c` | trust exactly these paths. |

It is injected through git's **command config scope**
(`GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_<n>`/`GIT_CONFIG_VALUE_<n>`), which git counts as
*protected configuration* — so it is honoured (a repo-scope value would be ignored),
it writes **no files** (no writable `$HOME` needed), and every git the run spawns
inherits it: the agent's and the verify hook's included. An existing `GIT_CONFIG_COUNT`
that the host injected is **extended, never overwritten**. Needs git 2.31+; older gits
need `git config --global --add safe.directory <repo>` instead.

**Why opt-in.** Trusting a repo this uid does not own is a security decision about a repo
chief did not choose. The host makes it; chief will not make it silently.

### 4. There may be no committer identity, and pids may be numbered elsewhere

**Identity is automatic.** Chief probes with `git var GIT_COMMITTER_IDENT`, which applies
exactly `git commit`'s strictness — it fails both when nothing is configured and when
git's guess is bogus (no passwd entry for the uid, or a domain-less hostname, both normal
in a minimal image). Only on failure does the run export
`CHIEF_GIT_IDENTITY_NAME`/`_EMAIL` (default `chief <chief@localhost>`) for every commit
and merge it makes, and it says so in its output. A host with a real identity never
reaches this and keeps the operator's own.

**PID namespaces.** Chief's registry, its per-repo `driver.lock` and its run ids are all
keyed by **pid**, and a pid means nothing without the namespace it was numbered in. Share
a prefix between namespaces — a bind-mounted `~/.chief`, one volume in two containers,
`docker run -v` against the host's prefix — and every pid-keyed decision reads backwards:
`chief ps` would delete the registry entry of a run that is live next door, and a driver
would call a foreign `driver.lock` stale and **steal** it, putting two drivers on one repo.

So every pid-keyed record carries the namespace token its numbers were minted in
(`ns=` in `<pid>.run`, `driver.lock/ns`), and a reader that sees a **foreign** token
declines to interpret the pid at all. Degrading to nothing is the point: the alternative
is acting confidently on a number that means something else. The token is
`$CHIEF_PID_NS` if set, else the `/proc/self/ns/pid` inode (exact, and identical across
containers that genuinely share a namespace via `--pid=host`), else `proc:<hostname>`,
else the constant `host`.

## Guarantees

Inside a container, with the environment above:

- **Identical loop.** Same scheduler, same `dependsOn`/`touches` serialization, same
  worktree isolation, same rebase → verify → `--no-ff` merge, same retire-to-`completed/`.
- **Fail fast, with the knob named.** An unwritable state tree, a repo git refuses, or a
  missing committer are diagnosed **at startup**, in chief's own words, not an hour into
  an agent iteration in git's.
- **No `$HOME` required.** Not for state, not for git config, not for the run registry.
- **Nothing is written outside** `$REPO` and the resolved prefix / worktree root.
- **The records stay honest across namespaces.** `chief ps`, `chief reap` and the driver
  lock never destroy, steal or mis-read a record numbered in another namespace.
- **Backwards compatible.** A record with no namespace token (written before 0.8.14, or
  by a host that could not tell) reads as local, so single-namespace hosts behave exactly
  as they always have.

## What degrades, and into what

| in a container | behaviour |
|---|---|
| ephemeral prefix (the `/tmp` floor, no volume) | runs work; **state does not survive a restart** — an interrupted run's records are gone. Set `CHIEF_PREFIX` onto a volume for durability. |
| a foreign `<pid>.run` in a shared registry | not shown, not counted, **not removed** — reported as a one-line footnote by `chief ps`. |
| a foreign `driver.lock` | the run **stops** rather than guessing. Stop the other container's run, or `rm -rf` the lock if you know it is gone. |
| `chief reap` across namespaces | foreign records are never a licence to kill. Reaping only ever *spares* on ambiguity — see [`drivers-and-safety.md`](drivers-and-safety.md#orphans-how-chief-work-is-identified-and-how-its-stopped). |
| no `/proc` (macOS/BSD) | one machine-wide pid space; the token is the constant `host` and nothing changes. |
| no `lsof` and no `/proc` | the reaper's cwd key is inert; the argv marker still carries the sweep — never a false positive. |
| `CHIEF_GIT_SAFE_DIRECTORY` unset on a foreign-owned repo | the run **refuses to start**, with git's message and the knob. |
| git older than 2.31 | command-scope `safe.directory` is ignored; the error says so and points at `git config --global`. |

## Testing it

`test/container.sh` pins all four conditions **without a container**, so the guarantees
above are asserted on an ordinary laptop and in CI:

| condition | how it is staged |
|---|---|
| no `$HOME` | `env -u HOME`, with `bash -u` so an unbound read is fatal |
| relocated prefix + worktree root | temp `CHIEF_PREFIX` and a `CHIEF_WORKTREE_ROOT` deliberately outside it |
| dubious ownership | `GIT_TEST_ASSUME_DIFFERENT_OWNER=1` — git's own hook; no second uid, no mount |
| no committer identity | `user.useConfigOnly=true` + `GIT_CONFIG_GLOBAL`/`_SYSTEM` at `/dev/null` |
| a foreign PID namespace | `$CHIEF_PID_NS`, written into records the test then requires chief to decline |

It runs a **whole** `implement → verify → merge` in that environment, and asserts the
negative controls too: a run refuses up front without the ownership opt-in, `chief ps`
still prunes dead *local* run files, and a stale *local* lock is still auto-cleared.
It is in `.chief/verify.sh`, `.github/workflows/ci.yml` and `test/all.sh`.

## Related

- [`headless-invocation.md`](headless-invocation.md) — the non-interactive contract a
  container run almost always wants next to this one.
- [`events.md`](events.md) — the NDJSON stream a host subscribes to instead of scraping
  output.
- [`monitoring.md`](monitoring.md) — the run registry and live records, whose pid keys
  section 4 is about.
- [`drivers-and-safety.md`](drivers-and-safety.md) — the scheduler, the safety floor and
  the reaper.
