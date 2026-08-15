# Account credentials — running under a designated provider account

> **Status:** Current · **Updated:** 2026-08-14 · **Owner:** chief

By default a chief run spends **whatever account the invoking shell already carries**:
`engine/agent.sh` execs the provider CLI (`claude`, `devin`, `opencode`, `amp`) and it
inherits the environment, so it authenticates the same way it would if you had typed
the command yourself.

That is the right default for a human at a terminal and the wrong one for anything that
runs chief *on behalf of someone else* — a daemon with several accounts to spend, a CI
job, a container. Those callers need to say **which account this run uses**, without
the credential ending up in a log, a registry entry, or an `argv` some other user can
read out of `ps`.

The **account credential seam** is that designation. One knob, applied at exactly one
place:

```bash
chief run --account-env ~/.chief/accounts/pool-a.env --account-label pool-a
```

Chief designates **one account per run** and does nothing else with it — no pooling, no
balancing, no rotation, no credential storage. Those belong to the caller (see
[Who drives this](#who-drives-this)).

## The knob

| Form | Where it comes from |
| --- | --- |
| `chief run --account-env <file>` | the command line (wins over everything below) |
| `CHIEF_ACCOUNT_ENV_FILE=<file>` | the environment — how a headless/parent process sets it |
| `CHIEF_ACCOUNT_ENV_FILE=<file>` in `.chief/config` | a per-project default |
| `chief run --account-label <name>` / `CHIEF_ACCOUNT_LABEL` | the name the account is **reported** under (defaults to the env file's basename minus `.env`) |

A **file**, never a value on the command line: `chief run --api-key sk-…` would put the
secret in `argv`, where every user on the box can read it with `ps`. A path is not a
secret; the file it names is, and its permissions are yours to set (`chmod 600`).

A relative path is resolved against the cwd you launched from — the driver and its
workers run inside worktrees elsewhere, so a path that stayed relative would mean
something different by the time it was read.

## The file format

`KEY=VALUE`, one per line. Blank lines and `#` comments are skipped, a leading
`export ` is tolerated, and one layer of surrounding `"` or `'` quotes is stripped.
There is no expansion and no line continuation: a value is the rest of the line,
verbatim.

```sh
# ~/.chief/accounts/pool-a.env      chmod 600
ANTHROPIC_API_KEY=sk-ant-…
CLAUDE_CONFIG_DIR=/var/lib/chief/accounts/pool-a
```

The file is **parsed, never sourced**. `.`-ing it would execute whatever it contains
under the agent's privileges, and an env file is *data* handed to chief by an operator
or a parent process. Lines that are not assignments — and keys that are not legal
environment names — are ignored rather than run. Values are exported with the `export`
builtin, so they are never spliced into a command line.

A file that parses to **zero** pairs is an error, not a silent no-op: a typo'd file
must not read as "designated, but nothing applied".

## Where it applies — and where it deliberately doesn't

The credential env is applied **inside the subshell that execs the provider**
(`_run_provider` in [`engine/agent.sh`](../engine/agent.sh)) and nowhere else:

| Phase | Environment |
| --- | --- |
| the agent turn (the provider CLI) | inherited **+ the designated file** |
| git — checkout, commit, rebase, merge | chief's own, unchanged |
| `.chief/verify.sh` (and a tasklist's own `verify` commands) | chief's own, unchanged |
| the iteration hook, warmups | chief's own, unchanged |
| the driver, the scheduler, `chief ps`/`monitor`/`events` | chief's own, unchanged |

That boundary is the point. A credential that reached the verify hook or the iteration
hook would be one arbitrary project script away from a commit, a build log, or an
upload — and none of those phases need an account to do their job. `engine/driver.sh`
`export -n`s the designation so only the explicit hand-off to `agent.sh` carries it.

**With no designation, nothing changes.** The provider inherits the environment exactly
as it did before the seam existed.

## Loud failure, never a silent fallback

A designated file that is missing or unreadable **fails the launch**, before any
worktree, any agent turn, any commit:

```
--account-env: no readable credential env file at /etc/chief/pool-a.env
```

Both `bin/chief` (at launch) and `engine/driver.sh` (so a direct driver invocation
behaves identically) check it; `engine/agent.sh` re-checks before each turn, in case the
file went away mid-run.

The alternative — quietly falling back to the inherited account — is the failure worth
being loud about: it spends *someone else's* quota, and you would only find out from a
bill or an exhausted account.

## What is reported, and what never is

The **designation** is public; the **values** are not. Chief publishes which account a
run spends so an operator can see it, and never publishes what that account is:

| Surface | Carries |
| --- | --- |
| run registry (`$CHIEF_RUNS/<pid>.run`) | `account=<env-file path>` · `accountlabel=<label>` |
| `chief ps` / `chief monitor` | an `acct:<label>` segment on the run header |
| the event stream (`run.started` detail) | `account=<label>` |
| `chief run --headless` summary JSON | `account:{label,envFile}` (both `null` when undesignated) |
| `CHIEF_VERBOSE` / `chief run -V` trace | `account=<label> env=<path>`, plus the **count** of variables applied |
| per-iteration logs (`chief logs`), `*.live.json`, `.chief/state/`, commits | nothing about the account's values |

The one place a credential value exists in a chief variable is `_apply_account_env`,
which suppresses `xtrace` around its body — otherwise `bash -x` (or an inherited
`SHELLOPTS`) would echo every `export KEY=VALUE` into the per-iteration log that
`chief logs` serves.

[`test/account-env.sh`](../test/account-env.sh) pins all of this: a scripted fake
provider reports the variables it actually received, the verify hook reports what *it*
saw, and a single token planted in both credential values is then grepped for across
the run registry, the live records, the logs, the worktrees and `.chief/state`.

## Per-provider credentials

Chief exports the names your file gives it, verbatim — it does not know or validate
what any provider CLI reads. The authoritative list is always that CLI's own
documentation. The common shapes:

| Provider | What a designated account usually means |
| --- | --- |
| `claude` | `CLAUDE_CONFIG_DIR` — point Claude Code at a **separate config/OAuth home**, which is how you switch between subscription logins; or `ANTHROPIC_API_KEY` for API-key billing |
| `opencode` | the provider credential its configured backend reads (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, an OpenAI-compatible `OPENAI_BASE_URL` + key — see [`docs/guides/local-inference-preset.md`](local-inference-preset.md)), and/or `XDG_CONFIG_HOME` to swap its `opencode/` auth store |
| `devin` | its API/session credential, and/or the config home its `devin` CLI login is stored under |
| `amp` | its API key (`AMP_API_KEY`) and/or its config home |

Two rules make the "and/or config home" case work: put **every** variable that account
needs in one file (there is no merging of designations), and remember the seam only
sets environment — a CLI that stores auth in a fixed, unconfigurable path cannot be
switched this way, and needs one container or one user per account instead.

## Who drives this

This is the **runner-side account designation**, and it is deliberately the whole of
chief's involvement. A multi-account operator wants pooling: pick the account with
headroom, hand this run to it, react when it hits a usage limit, rebalance. That policy
needs state chief does not have — every account's quota, every concurrent run across
every repo — so it lives in the caller.

chief-cloud's account pooling and capacity balancing is that caller: its daemon keeps
the pool, chooses an account per run, writes (or points at) the env file, and shells out
to `chief run --account-env … --account-label …`. It then reads back which account the
run used from the registry, the event stream, or the headless summary. Chief's job is
the seam and the non-leakage guarantee; the balancing is not chief's to make.

## See also

- [`docs/guides/providers.md`](providers.md) — the provider seam this hangs off.
- [`docs/guides/headless-invocation.md`](headless-invocation.md) — the summary JSON that
  reports the account back.
- [`docs/reference/events.md`](events.md) — `run.started` and the rest of the stream.
- [`docs/guides/monitoring.md`](monitoring.md) — the run registry `chief ps` reads.
