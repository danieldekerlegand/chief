# Providers — the onboarding recipe

Chief drives an agent CLI, it doesn't embed one. The whole seam is a single `case`
in [`engine/agent.sh`](../engine/agent.sh)'s `_run_provider()`: chief composes the
prompt, pipes it in, reads stdout, and preserves the CLI's exit status. Everything
else about a provider — auth, sessions, tools, model catalogue — belongs to that
CLI.

So **adding an agent CLI is one dispatch case plus one test fixture.** What makes
it feel bigger is the *roster surfaces*: two independent validator lists, the CLI
shorthands, `chief models`, the config template, and the README all name providers
separately and drift apart if you only edit the ones you happen to grep. This doc
is the checklist that closes that gap — work it top to bottom and nothing is left
half-wired.

> Why it exists: an audit (2026-08-11) found `amp` accepted by **both** validators
> with a **first-class** dispatch case (`amp --dangerously-allow-all`), while
> `driver.sh`'s header called it "a legacy alias", both invalid-provider error
> strings named only three providers, and it appeared in no template, README row,
> `chief models` case, or test. Every one of those is a line on the checklist
> below that nobody knew to tick.

## Invariants a provider case must satisfy

A provider is eligible for the seam if its CLI can do these three things. If it
can't, no amount of chief-side wiring will make it work.

1. **It runs non-interactively from a piped prompt.** One shot, prompt on stdin
   (or written to `$PROMPT_FILE` — see [prompt delivery](#2-prompt-delivery)), agent
   output on stdout/stderr, then exit. Chief's loop *is* the session: a fresh
   invocation per iteration, all continuity carried by the repo, the runtime PRD,
   and `progress.txt`. A CLI that needs a TTY, prompts for permission, or expects
   to be resumed by session id does not fit.
2. **It preserves its own exit status.** The invocation is
   `_run_provider < "$PROMPT_FILE" 2>&1 | tee /dev/stderr; exit "${PIPESTATUS[0]}"` —
   `PIPESTATUS[0]`, deliberately, so the *provider's* status survives the pipe. That
   status is half of usage-limit classification (`_is_rate_limit`); a wrapper that
   swallows it into a constant `0`/`1` breaks [limit detection](#usage-limit-detection).
3. **It needs no chief-side state.** No per-provider config file, no session
   registry, no cleanup hook. The dispatch case is the entire integration. If a
   provider needs env (a base URL, a credential), that belongs in a *preset*
   (`engine/preset.sh`, see [`local-inference-preset.md`](local-inference-preset.md)),
   which resolves to an existing provider·model pair — not in a new dispatch case.

Also required in practice: **permission bypass**. Chief runs unattended, so the
case must pass whatever flag makes the CLI stop asking (`--dangerously-skip-permissions`,
`--permission-mode bypass`, `--dangerously-allow-all`). A provider that blocks on a
confirmation prompt reads to the engine as a hung iteration, not as a refusal.

## The checklist

Ten items. The first two are the integration; the rest are the roster surfaces
that keep it honest.

### 1. The dispatch case — `_run_provider()` in `engine/agent.sh`

The only code that has to exist. Add one branch to the `case "$PROVIDER" in`:

```bash
    newcli)
      if [ -n "$MODEL" ]; then newcli --print --yes --model "$MODEL"
      else newcli --print --yes
      fi
      ;;
```

Decide three things, and record each in the [roster table](#current-roster):

- **Non-interactive / print mode** — the flag that makes one shot and exits
  (`--print`, `run`, …).
- **Permission bypass** — the flag that suppresses confirmations.
- **Model wiring** — see [model overrides](#model-overrides). Wire `$MODEL` to the
  CLI's model flag, or *record the decision* that the CLI has none. Silently
  ignoring `--model` is the one outcome that isn't allowed: the user sees their
  model echoed by `chief ps`, the driver, and the verbose trace while the provider
  runs on its default.

### 2. Prompt delivery

Chief always pipes the composed prompt on **stdin** and always writes it to
`$PROMPT_FILE` first, so a case may use either channel:

| Channel | Providers | Shape |
|---|---|---|
| stdin | `claude`, `opencode`, `amp` | nothing extra — the case just reads what's piped |
| prompt file | `devin` | `--prompt-file "$PROMPT_FILE"` |

`devin`'s `--print` mode does **not** read stdin; without `--prompt-file` it panics
`print mode requires a prompt` on every iteration, which the engine can only see as
a stall. If a new CLI behaves the same way, pass `"$PROMPT_FILE"` the same way —
it's the identical bytes the caller is piping, so the two channels never disagree.

### 3. Both validator lists

There are **two**, in different files, and they must accept the same set:

- [`engine/agent.sh`](../engine/agent.sh) — the `if [[ "$PROVIDER" != … ]]` guard
  just above the state-dir setup (`Error: Invalid provider '…'`, exit 1).
- [`bin/chief`](../bin/chief) — the `case "$provider" in claude|devin|opencode|amp)`
  in `cmd_run` (`invalid provider '…'`, exit 2).

Add the name to both, **and update both error strings to name the full roster.**
The strings are hand-maintained prose, not generated from the list, so they are the
first thing to rot: today both say "claude, devin, or opencode" while both lists
accept `amp` as well — a user who typed a real provider is told it isn't one.
`test/provider-conformance.sh`'s drift guard (item 10) fails if the two lists
diverge; the error strings are on you.

### 4. The `--<provider>` shorthand (optional but expected)

In `cmd_run`'s argument loop, next to `--claude` / `--devin` / `--opencode`:

```bash
    --newcli)      provider=newcli; shift ;;
```

Optional in the sense that `--provider newcli` already works. Expected in the sense
that every other first-class provider has one, and its absence is how `amp` came to
read as second-class.

### 5. `chief models`

Add a case to `cmd_models` in [`bin/chief`](../bin/chief). Delegate to the CLI's own
enumeration if it has one (`devin models list`, `opencode models`) — never hardcode a
model list, they're account-specific and change often. If the CLI has no listing
command, print its stable aliases the way `_models_claude` does, or say plainly that
it has none. Also extend the no-arg summary and the `unknown provider '…'` message.

### 6. `chief run --help`

The `--provider claude|devin|opencode` line and the shortcuts line in `bin/chief`'s
usage block.

### 7. `templates/config`

The roster comment on `CHIEF_PROVIDER` (`# AI provider: claude | devin | opencode`).
This is what every new project scaffolded by `chief init` reads as the supported set.

### 8. README

Two places: the provider prose under the quickstart (`Use --provider …` + the
shortcut list) and the `chief run --provider P --model M` row of the command table.

### 9. ROADMAP

The **Current State** multi-provider line and the provider-breadth row in the
capability table. These are the two statements a reader trusts about what's
supported; keep them agreeing with each other and with the code.

### 10. The conformance fixture

Register the provider in the hermetic conformance harness
[`test/provider-conformance.sh`](../test/provider-conformance.sh) (wired into
`test/all.sh`, CI, and `.chief/verify.sh`). **The registration point is the `ROSTER`
array near the top of that file — add one line, and you are done:**

```
name|prompt-channel|model-stance|argv-WITH-model|argv-WITHOUT-model
```

- `prompt-channel` — `stdin` or `prompt-file`, matching item 2.
- `model-stance` — `wired` (the argv interpolates `%MODEL%`) or `unwired` (it must
  not); the harness rejects an entry whose stance and argv disagree, so the
  [model-override decision](#model-overrides) can't be left implicit.
- `argv-*` — the **exact, complete** argument vector, space-separated, with the
  placeholders `%MODEL%` and `%PROMPT_FILE%` substituted at assert time.

The scripted fake CLI is generated from a shared double, so no new test scaffolding
is written per provider. From that one line the harness drives the real
`engine/agent.sh` twice (with and without `--model`) and asserts the exact argv the
engine composes, prompt delivery on the documented channel, that an `unwired`
provider never leaks the model value into its argv, and that a fake emitting
`<promise>COMPLETE</promise>` after a commit ends the loop with exit 0.

The same file carries the **roster-drift guard** from item 3: it parses the provider
list out of *both* validators and fails if they disagree with each other or with the
`ROSTER` — so a provider that is accepted but untested (or tested but unaccepted) is
a red build, not a discovery two audits later.

## Model overrides

`$MODEL` comes from `--model` / `CHIEF_MODEL` and is surfaced to the user in the
driver's banner, `chief ps`/`chief monitor`, and the `CHIEF_VERBOSE` trace *before*
the provider runs. Exactly one of these stances is acceptable, and it must be
written down in the [roster table](#current-roster):

- **Supported** — wire `$MODEL` to the CLI's model flag in the dispatch case, and
  add the `chief models` case so a user can discover valid values.
- **Unsupported** — the CLI has no model flag. Say so in the roster table and in
  `chief models`, and make an explicit `--model` either refuse or warn. Never
  accept-and-ignore.

## Usage-limit detection

Chief distinguishes "the account hit a usage limit" from "the agent made no
progress" by **reading the provider's own output**, because that is the only signal
a CLI reliably gives:

```
_is_rate_limit(out, status):
  out matches $RATE_LIMIT_PATTERN                              -> limit
  status != 0 AND out matches $RATE_LIMIT_STATUS_PATTERN       -> limit
  otherwise                                                    -> not a limit
```

Both patterns live at the top of [`engine/agent.sh`](../engine/agent.sh) and are
overridable from the environment. `RATE_LIMIT_PATTERN` covers prose phrasings
("usage limit reached", "your limit will reset at", "5-hour limit reached ∙ resets
3pm"); `RATE_LIMIT_STATUS_PATTERN` is deliberately weaker (`429`, `rate_limit_error`,
`overloaded_error`) and only counts when the CLI **also exited non-zero** — which is
why invariant 2 above matters.

**The defaults were written against the Claude Code CLI's phrasings.** A new
provider that says it differently ("quota exhausted", "plan limit hit — try again
in 2h") matches nothing, and its limit stop is demoted to a no-progress iteration:
the loop burns its budget and exits 1 as a stall, indistinguishable to the driver
from a genuinely failed tasklist. So when onboarding:

1. Find out how the CLI announces a limit (and what it exits with).
2. Extend `RATE_LIMIT_PATTERN` / `RATE_LIMIT_STATUS_PATTERN` to cover it — they are
   shared, provider-agnostic regexes, so widen carefully; a pattern that matches
   ordinary agent prose turns every iteration into a sleep.
3. Add a case to [`test/ratelimit.sh`](../test/ratelimit.sh) (or `test/limitstate.sh`)
   with a fake emitting that phrasing, asserting the pause+resume path is taken.
4. If the phrasing includes a reset time, check `_seconds_until_reset` parses it;
   otherwise chief falls back to its default wait.

Until step 2 is done, document the gap — an undetected limit is a *silent* failure
mode, and the operator's only clue is a tasklist that stalls at the same hour every
day.

## Current roster

| Provider | Non-interactive | Bypass flag | Prompt via | `--model` | `chief models` |
|---|---|---|---|---|---|
| `claude` (default) | `--print` | `--dangerously-skip-permissions` | stdin | supported | family aliases (no live list) |
| `devin` | `--print` | `--permission-mode bypass` (+ `--respect-workspace-trust false`) | `--prompt-file` | supported | `devin models list` |
| `opencode` | `run` | *(none needed)* | stdin | supported | `opencode models [provider]` |
| `amp` | *(default)* | `--dangerously-allow-all` | stdin | **not wired** — see below | none |

`amp` is a genuine dispatch case, not an alias of anything: `CHIEF_PROVIDER=amp`
runs `amp --dangerously-allow-all` with the prompt on stdin, and both validators
accept it. Its remaining gaps are exactly the checklist items nobody ticked —
the error strings, the `--amp` shorthand, the `chief models` case, the template and
README mentions, the `--model` stance, and a conformance fixture. Tasklist
`85-provider-onboarding-harness` settles them (promote or retire — no third state);
this table is updated there.

## Related

- [`README.md`](../README.md) — provider selection in the quickstart + command table.
- [`ROADMAP.md`](../ROADMAP.md) — provider breadth as a tracked capability.
- [`docs/local-inference-preset.md`](local-inference-preset.md) — presets: a named
  bundle that resolves to an existing provider·model, the right home for
  endpoint/credential wiring.
- [`docs/verify-hook.md`](verify-hook.md) — the merge gate every provider's work
  passes through, whichever CLI produced it.
