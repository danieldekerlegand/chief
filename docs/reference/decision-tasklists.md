# Decision tasklists

> **Status:** Current · **Updated:** 2026-08-26 · **Owner:** chief

A decision tasklist is a tasklist whose deliverable is an operator's judgement rather
than a merged branch. Declare it with `"type": "DECISION"`; `"kind": "DECISION"` and
`"decision": true` are accepted aliases for hand-authored records.

## The interactive loop

A decision tasklist always runs the research phase before its stories. The research
artifact is the decision brief at `.chief/state/research/<tasklist>.md`. It maps the
relevant code and, importantly, names the concrete options and what each option
forecloses, makes more expensive, or rules out later. The agent may improve that brief,
frame the alternatives, and draft an ADR or other deliverable, but it must not choose
an option or record a verdict.

After the stories pass, Chief stops at `AWAITING-DECISION`. This is intentional: the
agent's `passes` state means only that the brief and any draft are prepared. The
scheduler does not treat a model-written `verdict` field or verdict file as consent.
Only the operator-facing `chief decide` command can supply the terminal verdict. This
separation makes an agent-authored approval a rejected counterfactual, rather than a
shortcut around the human gate.

The decision brief and review state are durable. Research is persisted outside the
rebuilt worktree, and the existing `review.sh` contract is used when review is enabled:
its checksum-bound verdict and append-only `rounds` survive process death, usage-limit
sleeps, and worktree reconstruction. A missing or non-interactive reviewer parks the
run; absence is never interpreted as approval.

## Recording a verdict

Record the human choice and its reasoning with:

```sh
chief decide storage-postgres postgres \
  --note 'Keeps transactional queries local; rules out the SQLite-only deployment.' --proceed
```

The note is durable context, not decoration. A verdict without its reasoning is not a
useful record six months later.

Every verdict is recorded with exactly one **action**, and the action — never the
verdict word — is what the branch's fate is read from. The choice is the operator's own
vocabulary ("postgres", "approved", "the MIT row"); Chief holds no dictionary that could
tell a yes from a no in it. The four actions split along one line: whether the
deliverable is the verdict itself, or code that was waiting on it.

| Action | The tasklist | The prepared branch |
|---|---|---|
| `--proceed` | stays live, any park cleared | **merges** — the next run reads the verdict and continues to the ordinary rebase → verify → merge path |
| `--decline` | parks (`parkedReason: declined`), carrying the verdict | **never merges** — kept, with its worktree, at `DECISION-DECLINED` |
| `--retire ID` | filed to `completed/` with the verdict and `supersededBy` | untouched; nothing schedules it again |
| `--unpark` | stays live, park cleared | untouched — the verdict is recorded and authorises no merge |

`--retire` and `--unpark` are the two that assume **the deliverable is the verdict**.
Neither is consent to merge code: a tasklist carrying code that is answered with one of
them records the verdict and halts again, saying which flag would move it. That is the
whole reason `--proceed` and `--decline` exist — the first decision tasklist to run in
anger produced 2,209 insertions across 16 files gated on a licence call, and neither of
the original two flags fit that shape.

Where the human-readable copy of the verdict lands follows one rule: **a verdict is
written into a tasklist file only when that file will never be rebased again.** The two
actions that end the tasklist on the spot (`--retire`, `--decline`) carry it in their own
JSON. The two that leave it live (`--proceed`, `--unpark`) do not — the branch is about
to replay onto this base and its commits edit that same file, so a verdict committed
beside them is the `REBASE-CONFLICT` described below. Those two rely on the durable
record, and `finalize_merged` stamps the verdict onto the `completed/` record at the
merge, which is past every rebase.

Any tasklist edit `chief decide` makes is **committed for you** (`--no-commit` opts out),
for a blunt reason: `chief run` guards what the agent forks from and refuses to start on
an uncommitted tracked change, so a decide that left the tasklist dirty would be a
verdict the operator could not act on. `--proceed` on an unparked tasklist changes
nothing at all and so commits nothing.

`--retire` refuses to act while a live tasklist depends on the decision and names those
dependents. Once safe, Chief sets `supersededBy`, deliberately does **not** add
`mergedToMain`, and moves the record to `tasks/chief/completed/`. This is a retirement
filing, not a code merge.

## Saying no

`--decline` is the half that makes this a decision point rather than an approval queue:

```sh
chief decide licence-anchor 'commercial terms rejected' \
  --note 'The vendor licence forbids redistribution of the weights.' --decline
```

The verdict is recorded exactly as an approval is — durable, bound to the stories,
carrying the note and who recorded it. The branch and its worktree are **kept**:
declining work is not the same as discarding it, and the diff remains readable while
someone decides what to do with it. Nothing merges, in two independent ways — the
tasklist parks so the scheduler never picks it up again, and if it is run anyway
(`chief run --parked <name>`) the driver reads the verdict, refuses the merge and stops
at `DECISION-DECLINED`. That state is terminal and successful: the question was asked
and answered.

**Dependents of a declined decision are cascaded to `blocked`,** deliberately. The work
they were waiting on is not arriving, and leaving them pending against a branch that
will never merge is the failure this whole family of bugs is made of. `chief decide`
names those dependents at the moment you decline — a decline is your answer and Chief
does not veto it the way it vetoes an unsafe retirement, but you find out immediately
rather than at the next run. Repoint or retire them.

## The verdict is read on the next run

Recording a verdict is not a filing exercise: the next `chief run` reads it, and the
tasklist stops halting. With a verdict present the branch continues to the ordinary
rebase → verify → merge path, exactly like any other finished tasklist; without one it
halts at `AWAITING-DECISION` as before. This is what makes a decision that **carries
code** finishable — a licence call gating an implementation is a legitimate and common
shape, and the deliverable is then the merged branch, not the verdict alone.

Three properties make that safe to rely on:

**What it may do is carried by the action, not by the verdict word.** `--proceed`
authorises the merge and `--decline` refuses it; `--unpark` and `--retire` authorise
nothing (`decision_authority` in `engine/decision.sh` is the one place that mapping
exists). A record written before those flags existed, or with either of the other two,
reads as "authorises no merge" and halts — never as a yes.

**The verdict is durable, and it is not something an agent can write.** It is recorded
at `.chief/state/decisions/<tasklist>.json`, beside the driver's other per-tasklist
state — gitignored, outside every worktree, and written only by `chief decide`. The
`.verdict` field in the tasklist is the copy a human reads; the driver reads the record.
It cannot live in the tasklist JSON alone for two reasons that each cost a verdict its
life: the driver's isolation guard runs `git checkout -- tasks/<name>.json` on every
iteration (undoing an agent that reached out of its worktree), which discards an
uncommitted field; and *committing* the field collides at rebase with the branch's own
edits to that same file, ending the decided tasklist in `REBASE-CONFLICT`.

**The verdict is bound to what it approved.** `chief decide` records a checksum of the
stories — their ids, titles and acceptance criteria, not their `passes` flags — the same
way `review.sh` binds a plan approval to the plan it was given for. Re-word the tasklist
or re-plan the branch after the verdict is recorded and the tasklist comes back to
`AWAITING-DECISION` saying the verdict was given for different stories. Consent to one
brief is not consent to its successor.

`test/decision-e2e.sh` drives the whole sequence — halt → a verdict that authorises
nothing → `chief decide --proceed` → resume → verify → merge → retire, plus the
stale-verdict refusal and the declined branch that never merges.

The transition is emitted as `tasklist.decision` in the append-only event stream twice
over, and on purpose: once by `chief decide` when the operator records it (into
`$CHIEF_RUNS/decisions.events.jsonl`, since there may be no run alive at the time), and
once by the driver when it READS the record, into that run's own stream. The second is
what makes a completed run record which human decided what — `state` carries the action
and `detail` carries the verdict, the note and the identity it was stamped with. The
park or merge that follows is the transition; the decision event is the authority for
it.

## ADR outcomes

A decision whose chosen outcome is an ADR can have the agent draft the ADR. The draft
must describe the alternatives and carry the operator's recorded verdict; it must never
claim that the agent selected or approved the option. The operator records that verdict
through `chief decide` after reviewing the brief and draft. If the decision is later
retired, the completed record remains the authoritative retirement pointer and carries
no merge stamp.
