# Provider unavailability — an iteration that never reached the model

**A request the API refused is not an attempt the agent made.**

Chief's stall counter answers one question: *is the agent getting anywhere?* It is
built from evidence — a turn ran, and the story count did not move. A `529
Overloaded`, a dropped connection or a revoked key produces no such evidence: no turn
was taken, no tool was called, nothing was attempted. Scoring it as a no-progress
iteration conflates *"the agent tried and got nowhere"* with *"the agent was never
given a chance"*, and only the first is evidence about the work.

## What it cost before this existed

Measured on talos, 2026-08-24. `71-real-game-supply-decision` ran three consecutive
iterations whose entire output was:

```
API Error: 529 Overloaded. This is a server-side issue, usually temporary
```

Each was scored `no progress`, the third tripped `stall 3/2`, and the run printed
*"Chief stalled 3 iterations after its 5-iter budget without completing. Stopping."*
and left the branch `INCOMPLETE`. `72-godot-ci-containerized-build-lane` died the
same way two iterations later.

`71` was 1/2 passing with 2,029 correctly-placed files sitting uncommitted in its
worktree. `chief ps` rendered it `✗ failed · no progress last iter`. An operator
reading that would reasonably conclude the tasklist was broken and re-scope it.

## The classification

`engine/agent.sh` classifies an invocation as **no turn taken** when *all three* hold:

1. **The provider process exited non-zero.** A turn that returned 0 was taken,
   whatever its text says. This is what stops an agent *writing about* a 529 from
   being classified as one.
2. **The invocation left no trace.** HEAD did not move and no story flipped — read
   off the branch at the call site, not believed from the output. "The tasklist's
   state is unchanged by it" is checked, not asserted.
3. **The failure names itself as a request-level refusal** — a status code or an
   error type read out of the provider's own structured error envelope.

Condition 3 is the interesting one, and it is deliberately *not* a grep for
`API Error`. In order:

| source | shape | example |
|---|---|---|
| status key | `"status"` / `"status_code"` / `"statusCode"` | `{"status": 529, …}` |
| error type | the inner `"type"` of an error envelope | `{"type":"error","error":{"type":"overloaded_error"}}` |
| CLI error line | `API Error: <code>` | `API Error: 529 Overloaded…` |
| transport | no HTTP at all | `ECONNRESET`, `socket hang up`, `could not resolve host` |

The status codes are split by what they **mean**, not by how they read: `500 502 503
504 529` is the API unable to serve the request, `401 402 403` the API unwilling to.
Both are refusals of the *request*, so both are "no turn was taken". What to **do**
about each differs, and that decision is not made by the classifier.

### The rule for the text arms

A match-on-prose rule whose observations are not written down cannot be audited when
it stops firing, and a silently-stopped classifier reads exactly like the bug it was
added to fix. So the last two rows above are a **documented, dated list**: every entry
is a message someone actually saw, recorded beside the date they saw it, in the
comment block above `PROVIDER_TRANSPORT_PATTERN` in
[`engine/agent.sh`](../../engine/agent.sh). Widening either arm means adding an
observation, not adding a guess.

The structured arms need no such list — a machine-readable status code is the
provider's contract, and it survives any rewording of the sentence beside it.

## What happens then

The iteration is **not charged to anything**: not to the stall counter, not to
`MAX_ITERATIONS`, not to `HARD_MAX`. The same turn is re-run.

Because a stop that costs no budget also ends no run, something has to bound it:
`PROVIDER_NOTURN_LIMIT` (default 3) consecutive refusals stop the agent loop with
**exit 8**. The count is consecutive — an outage that clears mid-run leaves no charge
behind for a later blip to trip over.

`PROVIDER_NOTURN_LIMIT=0` disables the classification entirely and restores the
pre-fix behaviour, where every refusal is scored as a stall.

## What the run reports

Exit 8 is a **block**, not a failure. `engine/driver.sh` records the tasklist as
`PROVIDER-UNAVAILABLE <passing>/<total>` in scheduler state `provider-unavailable`,
keeps its branch **and** its worktree, and reports it in the summary next to the other
holds — never among the failures:

```
   ⏸ PROVIDER UNAVAILABLE — 1 tasklist(s) BLOCKED by the API, not failed and not stalled: 71-real-game-supply-decision
    · 71-real-game-supply-decision   HTTP 529 (overloaded_error) — 2026-08-24 14:02:11
    NO agent turn was taken on these, so the run learned nothing about their work —
    their branches, commits and worktrees are all kept exactly as they were.
```

`chief ps` renders the row `⏸ no-api`, on the same glyph as every other hold. It is
never a failure glyph, because that render *is* the bug.

`dep_broken()` ignores the state, so dependents stay `pending` (schedulable on the
next run) rather than cascading to `blocked`. Under the headless contract the run
exits `7` (`paused` — work withheld, not broken); see
[headless-invocation.md](../guides/headless-invocation.md).

Unlike a usage limit, **no wait window is armed**. An overload publishes no reset
time, and inventing an account-wide ETA to hold the whole run behind would be worse
than ending the run and letting the next one try.

## This is not the usage-limit path

A usage/session limit (`429`, `rate_limit_error`, "your limit will reset at 3pm") is a
different condition with a different remedy: there is a *window*, chief parses its
reset time out of the provider's own message and sleeps until it reopens
(`_rate_limit_wait`, scheduler state `rate-limited`, exit 2). See
[providers.md](../guides/providers.md#usage-limit-detection).

`overloaded_error` used to live in `RATE_LIMIT_STATUS_PATTERN` and is deliberately
gone from it. An overload is not a quota: there is no window to read, so the limit
path's reset parsing found nothing and fell back to sleeping `RATE_LIMIT_WAIT` — an
hour, on a condition the provider itself calls temporary.

Both checks run **before** the progress/stall accounting, for the same reason: that
accounting is a judgement about the work, and neither a blocked request nor a refused
one is evidence about the work.

## Knobs

| variable | default | meaning |
|---|---|---|
| `PROVIDER_NOTURN_LIMIT` | `3` | consecutive refused requests before the loop stops with exit 8. `0` disables the classification |
| `PROVIDER_TRANSPORT_PATTERN` | see `engine/agent.sh` | the text arm for failures that never reached HTTP and so carry no status code |
