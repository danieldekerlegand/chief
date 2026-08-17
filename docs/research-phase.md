# The research phase — buying the map once

> **Status:** Current · **Updated:** 2026-08-17 · **Owner:** chief

Chief's agent starts every story cold. It gets the tasklist's acceptance criteria, the
project's context file, `progress.txt` — and whatever it greps during that iteration.
So a five-story tasklist derives the same mental model of the codebase five times, and
can mis-derive it five different ways.

That is the most expensive error an agent makes, because it is made **before a line is
written** and every line after it inherits the mistake. A wrong understanding of the
code does not produce one bad line; it produces a thousand plausible ones.

**The research phase** is the opt-in fix. When a tasklist sets `"research": true`, chief
spends **one turn, once, before the first story** mapping the code the tasklist is about
to change into a **structured document** — target files, data flow, point of insertion,
conventions. Every story is then handed that map instead of rediscovering it, and a
human can read and correct it between stories.

```
tasklist ──► RESEARCH turn ──► [document] ──► story 1 ──► story 2 ──► story 3
              (sub-agents)          │           (map)      (map)      (map)
                                    │             ▲          ▲          ▲
                                    └─────────────┴──────────┴──────────┘
                                         persisted · reused · human-editable
```

Two independent benefits, and it is worth being clear that they are separate:

- **Correctness.** Each story works from one validated map rather than a fresh guess.
  Whatever the map gets wrong, it gets wrong *once*, in a place a person can fix.
- **Context economy.** Rediscovery is what fills an iteration's window with greps and
  file dumps. The document is a **compaction artifact**: a story that opens with a map
  spends its window on the change.

See also [plan-review.md](plan-review.md) — the same leverage argument, one rung lower.

## The required sections

The document is **a map, not prose**, and that is enforced. `engine/research.sh` defines
four required H2 sections (`research_sections`) and machine-validates the document
against them. An essay that answers none of them is a *failed research phase*, not a
research phase with a weak document.

| section | what it must answer |
|---|---|
| `## Target files` | every file the implementation will touch or must understand, **with why each one is relevant**. A bare file list is not enough. |
| `## Data flow` | how control and data actually move through those files — entry points, the ordered call path, what state is read and written, where the seams are. |
| `## Point of insertion` | for a fix, the **root-cause hypothesis**, stated as a claim that could be wrong; for a feature, exactly where the new code attaches and what it must not disturb. |
| `## Conventions` | the existing idioms the implementation **must** follow — naming, error handling, logging, the shape of nearby tests, portability constraints — citing the file each was learned from. |

Two rules the validator applies, both deliberate:

- **A present-but-empty section counts as missing.** A skeleton of four headings is the
  exact failure mode a presence check invites, and it is worse than no document at all:
  it passes validation while telling a story nothing.
- **Headings match by case-insensitive prefix.** `## Target files (engine/)` satisfies
  `## Target files`. Burning a whole research turn on a parenthetical is a worse trade
  than accepting the prefix.

The document carries a schema stamp (`<!-- chief.research/1 -->`) so a consumer — or a
person re-reading a stale document — knows which version of this contract it was written
against. The stamp moves only when the required sections change.

## The sub-agent contract: structured summaries, never raw tool output

The searching happens in **sub-agent contexts**; what returns to the parent is a summary
in a fixed shape. The greps and file dumps that produced it stay in the sub-agent's
window — that isolation *is* the point, because letting raw tool output into the parent
would spend exactly the context the phase exists to save.

Getting a sub-agent to honour that is the part that needs saying explicitly, so the
prompt (`research_prompt`) says it explicitly. It instructs the agent to split the
question into a few independent angles — where the change lands · how the surrounding
flow works · what conventions and tests already exist — dispatch one sub-agent per
angle, and require each to return **only**:

```
FILES:       path — one line on why it matters (repeat)
FLOW:        the call/data path it observed, as ordered steps
CONVENTIONS: the local idioms it saw (naming, error handling, test shape)
UNKNOWNS:    what it could not determine, stated plainly
```

No pasted grep results, no file dumps, no directory listings. If a sub-agent returns raw
output anyway, the parent summarizes it before it enters the document. The parent then
**synthesizes** the summaries into the four sections above — the document is a map a
future reader can act on, not a transcript of how the search went.

`UNKNOWNS` is not decoration. The prompt tells the agent to write a gap down as a gap
rather than guess: a named unknown is useful to the story that hits it, and an invented
answer is the failure this whole phase exists to prevent.

## Where it lives

```
.chief/state/research/<tasklist-name>.md          the durable document
.chief/state/research/<tasklist-name>.review.json a human verdict on it (only with review)
```

`.chief/state/` is the same gitignored, filesystem-resumable state the runtime PRD and
the progress log live in, so the path honours `$CHIEF_STATE_DIR` when a project
relocates it.

**Outside the worktree, on purpose.** The driver does `rm -rf` on a tasklist's worktree
at the top of every run, so a document that only ever existed there would be regenerated
by each resumed run — precisely the cost this phase exists to pay once. The driver owns
the durable path and hands it down as `$CHIEF_RESEARCH_FILE`; the agent writes its copy
inside the worktree (the model is only ever told the **worktree-relative** path, because
it is instructed to stay inside its worktree) and **promotes it to the durable store the
moment it validates** — not at the end of the loop, so a run killed mid-story still
leaves the research banked.

## Produced once, reused thereafter

A valid document at the durable path is **never regenerated**. Before spending a turn,
the phase checks the store; a document that validates short-circuits the whole thing:

```
Research: reusing the persisted document (.chief/state/research/42-storage.md) — not re-running research.
```

That covers every way a tasklist comes back: the next story in the same run, a resumed
run after a usage-limit sleep or an operator pause, a re-run after a process death, and
a re-run after a rebuilt worktree. A resumed tasklist does not pay for research twice.

An **incomplete** persisted document is the one exception — if it no longer satisfies the
required sections (a truncated write, a bad hand-edit), the phase says which sections are
missing and regenerates rather than briefing every story with half a map.

## Correcting it by hand

**The durable document is the human-edit surface, and editing it is the cheapest
correction chief offers.** Open `.chief/state/research/<name>.md` between iterations, fix
what is wrong, save. The agent re-seeds the worktree copy from the store and rebuilds the
prompt **at the top of every iteration**, so the next story reads the corrected map — no
re-run, no research turn, no argument with the model.

This is the entire leverage claim made operational: correcting research must be cheaper
than correcting the code that research would otherwise produce. A hand-edited document
validates like any other, so it is reused verbatim and never regenerated.

Two corollaries worth knowing:

- **An agent's edit to the map does not persist.** Stories write inside the worktree,
  which is rebuilt; only the durable store is read. Story prompts say so, and ask the
  agent to report a map it found wrong in its progress note rather than rewriting it.
- **The map is a starting point, not scripture.** Story prompts say that too. A story
  that discovers the map is wrong should say so — a wrong map costs every remaining
  story, which is exactly why it is worth a human's minute.

## Turning it on (and when not to)

```jsonc
{
  "branchName": "chief/42-storage-rewrite",
  "research": true,          // default false
  "userStories": [ … ]
}
```

Precedence, most specific first:

| | |
|---|---|
| `$CHIEF_RESEARCH=1` / `=0` | the operator's override for one run, **both** directions — the seam a host embedding chief uses |
| `"research": true` / `false` | the tasklist author's choice |
| neither | **off** |

**Opt-in is the rule, and it is not shyness.** Roughly **40% of agent tasks are
one-shots** — a doc fix, a version bump, a one-line guard — whose entire cost is smaller
than the research turn that would precede them. Making the phase universal would tax
exactly the tasklists with nothing to learn.

**Turn it on for:**

- **Multi-story tasklists over unfamiliar code.** The map is amortized across every
  story, so the more stories share one area, the better the trade.
- **Bug tasklists whose root cause is not yet known.** `## Point of insertion` is a
  hypothesis a person can disagree with before it becomes a fix.
- **Work in a subsystem with strong local idioms.** `## Conventions` is what keeps five
  fresh-context iterations from inventing five different styles.

**Leave it off for:**

- **One-shots and doc/config edits.** The tasklist is smaller than its own map.
- **Mechanical refactors** — a rename, a move, a lint fix. There is nothing to
  understand that the criteria do not already say.
- **Code the agent just wrote.** A tasklist following straight on from another in the
  same area is re-buying a map it effectively has.

## The budget, and what failure looks like

The phase is **bounded**, and its failure is a **distinct, actionable state** — never a
silent fall-through into implementation on a map that is not there.

| knob | default | what it bounds |
|---|---|---|
| `CHIEF_RESEARCH_MAX_ATTEMPTS` | `2` | provider turns spent getting a **machine-valid** document. Two is deliberate: one honest attempt, plus one retry that is **told which sections came back empty**. |
| `CHIEF_REVIEW_MAX_ROUNDS` | `3` | how many times a **human** may send a valid map back (only when review is on, below) |

The two budgets are separate on purpose: they answer different questions ("can the model
produce the shape?" and "is this map right?"), and sharing one counter would let a
reviewer's first rejection eat the retry that exists for a truncated document. The
attempts budget resets per review round, so the phase costs at most
`attempts × rounds` turns — both documented knobs. A turn blocked by a usage limit is
**not** charged against the budget: it never reached the model.

When the attempts run out:

| surface | value |
|---|---|
| `agent.sh` exit code | `6` |
| `<name>.status` | `RESEARCH-FAILED <passing>/<total>` |
| scheduler state | `failed` (branch **and** worktree kept for re-engagement) |
| `chief ps` / `monitor` phase | `research-failed` |
| events | `tasklist.research-failed` |

**Nothing was implemented** — the phase runs before the first story, so a research
failure is the one stop that is guaranteed to have written no code. The log names the
missing sections and the three ways out: write or repair
`.chief/state/research/<name>.md` by hand (it is reused as-is), raise
`CHIEF_RESEARCH_MAX_ATTEMPTS`, or set `CHIEF_RESEARCH=0` to skip the phase.

A successful phase emits `tasklist.research` (`state=running`), with the document's path
in `detail`, both when it is produced and when it is reused. See
[reference/events.md](reference/events.md).

## Composing with plan review

A tasklist that also sets `"review": "plan"` gets its **map** reviewed too — on the same
[plannotator](plan-review.md) surface, and **first**:

```
RESEARCH ──► human verdict ──► story ──► PLAN ──► human verdict ──► IMPLEMENT
```

That order is the leverage hierarchy itself: research, then plan, then code. It is
structural, not conventional — the gate runs before the story loop, so it is impossible
for a plan to be reviewed before the map it was reasoned from.

**Neither feature is a hard dependency of the other.** Research with review off never
opens a reviewer; plan review with research off is exactly what it was. The reviewer
contract, the five ways to have no reviewer, and the `AWAITING-REVIEW` park are all the
plan checkpoint's, unchanged — see [plan-review.md](plan-review.md). Two differences
only: the map's park happens before the first story (so it names no story, and nothing
at all was implemented), and its verdict lives beside the durable document
(`<name>.review.json`) rather than beside a plan. The verdict is bound to the map's bytes
by checksum, so a re-researched map cannot inherit the approval of the one it replaced,
and an approval given once is never asked for again.

When a reviewer sends the map back, their annotations brief the next research turn
verbatim — a re-research told only that it was rejected produces the same map with
different adjectives.

## Related

- `engine/research.sh` — the contract in code: the required sections, the validator, the
  sub-agent prompt, and the review gate
- `test/research.sh` — the hermetic proof: produced once with its four sections, carried
  into every story, reused on resume with zero second turn, and a hand-edited document is
  what the next story reads. In the merge gate for any branch that touches the engine.
- [plan-review.md](plan-review.md) — the checkpoint one rung down, and the reviewer
  contract this phase reuses
- [reference/tasklist-schema.md](reference/tasklist-schema.md) — `research` alongside the
  rest of the tasklist fields
- [reference/events.md](reference/events.md) — the `tasklist.research*` contract
- [guides/monitoring.md](guides/monitoring.md) — the phase vocabulary `chief ps` renders
