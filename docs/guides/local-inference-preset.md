# The local-inference preset — cost avoidance as a supported mode

> **Status:** Current · **Updated:** 2026-08-14 · **Owner:** chief

`chief run --local` (long form `--preset local`, or `CHIEF_PRESET=local`) runs
**every agent turn on a LOCAL / self-hosted inference server**, through the existing
OpenCode provider dispatch. Tokens cost nothing, so a run can be as long and as
wasteful as the experiment needs.

This is a **preset, not a new provider**. It resolves to the plain pair
`provider=opencode` + `model=$CHIEF_LOCAL_MODEL` before anything else runs, so the
scheduler, `chief ps` / `chief monitor`, the event stream and the logs all report the
resolved provider·model exactly as they do for any other run. Nothing downstream
knows a preset was involved.

## The tradeoff, stated plainly

**You are trading coding quality for marginal cost.** A model small enough to serve
from your own machine writes materially worse code than a frontier model: it misreads
multi-file context, invents APIs, satisfies acceptance criteria shallowly, and burns
more iterations on the same story — sometimes without ever converging.

Chief will not choose that for you, and never silently degrades into it. The preset
is opt-in per run, and when it is unconfigured it **errors out rather than falling
back to a paid provider** — the one failure mode an operator asking for zero cost
must be protected from.

Reach for it when the run's value is in the *volume*, not the *diff*:

| Good fit | Bad fit |
| --- | --- |
| Soak-testing the harness itself (scheduler, merge policy, reap, pause/resume) | Anything you intend to ship |
| High-volume agentic testing where you measure throughput, not code | A tasklist whose stories need real design judgement |
| Throwaway branches, fixture generation, load on a host app embedding chief | A run whose `verify.sh` gate is expensive to fail |
| Working offline, or under a hard spend ceiling | A first pass on an unfamiliar codebase |

## The one switch

```sh
chief run --local            # shorthand
chief run --preset local     # long form
CHIEF_PRESET=local chief run # env / .chief/config
```

All three are the same thing, and compose with every other `chief run` flag —
`-p N`, `--no-merge`, `--headless`, trailing tasklist names.

Because the preset *is* the provider choice, pairing it with a conflicting
`--provider` or `--model` is an error rather than a silent override: `--local
--provider claude` is ambiguous about which one is paying, so chief refuses instead
of guessing.

## Configuration

The preset hard-codes **no host**. It needs two values, from the environment or the
project's `.chief/config`:

| Variable | Required | Meaning |
| --- | --- | --- |
| `CHIEF_LOCAL_ENDPOINT` | **yes** | Base URL of your local OpenAI-compatible server, e.g. `http://127.0.0.1:11434/v1` (Ollama) or `http://127.0.0.1:1234/v1` (LM Studio) |
| `CHIEF_LOCAL_MODEL` | **yes** | Model id to ask that server for — the value that reaches `opencode run --model …` |
| `CHIEF_LOCAL_ENDPOINT_ENV` | no | Env var the endpoint is published as (default `OPENAI_BASE_URL`) |
| `CHIEF_LOCAL_API_KEY` | no | Placeholder credential (default `local`) — local servers ignore it, but SDKs reject an empty one |
| `CHIEF_LOCAL_API_KEY_ENV` | no | Env var that credential is published as (default `OPENAI_API_KEY`) |

In `.chief/config` (scaffolded commented-out by `chief init`):

```sh
CHIEF_PRESET=local
CHIEF_LOCAL_ENDPOINT=http://127.0.0.1:11434/v1
CHIEF_LOCAL_MODEL=ollama/qwen2.5-coder:14b
```

The two `_ENV` overrides exist so a local backend that reads *different* variable
names is reachable without patching the engine — chief publishes the endpoint and the
key under whatever names you name.

### Wiring OpenCode to the local server

Chief supplies the endpoint and credential as environment variables; OpenCode still
needs a provider entry that reads them. Any OpenAI-compatible provider block works —
in `~/.config/opencode/opencode.json`:

```json
{
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "options": { "baseURL": "{env:OPENAI_BASE_URL}" },
      "models": { "qwen2.5-coder:14b": {} }
    }
  }
}
```

With that block, `CHIEF_LOCAL_MODEL=ollama/qwen2.5-coder:14b` reaches the dispatch as
`opencode run --model ollama/qwen2.5-coder:14b`, pointed at your machine. If you set
`CHIEF_LOCAL_ENDPOINT_ENV`, use that name in the `baseURL` instead.

Sanity-check the pair outside chief first — `opencode run --model <id>` on a one-line
prompt. A model that cannot complete that will not complete an agent turn.

### Seeing which local models are available

```sh
chief models opencode
```

is the way to list what you can put in `CHIEF_LOCAL_MODEL` — it is a live list from
the OpenCode CLI (`opencode models`), so it reflects the providers you actually
configured, local ones included. Narrow it with a provider argument
(`chief models opencode ollama`). `chief models` with no argument prints every
provider's list.

## When it is not configured

```console
$ chief run --local
chief: preset 'local' is not configured. Set:
  CHIEF_LOCAL_ENDPOINT   base URL of your local OpenAI-compatible inference server
                         (e.g. http://127.0.0.1:11434/v1)
  CHIEF_LOCAL_MODEL      model id to ask that server for
                         (list what it serves with: chief models opencode)
  in the environment or <repo>/.chief/config, then re-run.
  Refusing to fall back to a paid provider — that is what this preset exists to avoid.
```

Exit 2 from `chief run`, exit 1 from a direct `engine/agent.sh` invocation (its
bad-invocation code). An unknown preset name fails the same way, naming the presets
that exist.

## For hosts embedding chief

The preset resolves at **both** entry points — `bin/chief` (before provider
defaulting) and `engine/agent.sh` (before provider validation) — and the resolver is
idempotent, so a host that shells out to either one gets identical behavior. Pass
`CHIEF_PRESET=local` in the child environment alongside the two required variables,
or set them in the target repo's `.chief/config`.

Combined with `--headless` ([`headless-invocation.md`](headless-invocation.md)) this
is the shape a host uses for unattended, zero-cost volume:

```sh
CHIEF_PRESET=local \
CHIEF_LOCAL_ENDPOINT=http://127.0.0.1:11434/v1 \
CHIEF_LOCAL_MODEL=ollama/qwen2.5-coder:14b \
  chief run --headless -p 4
```

The `chief: provider=` / `model=` lines and the event stream report `opencode` and
the local model id — there is no separate "preset" field to special-case.

## See also

- [`headless-invocation.md`](headless-invocation.md) — the non-interactive embedding mode.
- [`events.md`](../reference/events.md) — where the resolved provider·model shows up on the wire.
- `engine/preset.sh` — the resolver, and the place a second preset would be added.
