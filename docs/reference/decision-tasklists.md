# Decision tasklists

> **Status:** Current · **Updated:** 2026-08-21 · **Owner:** chief

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
  --note 'Keeps transactional queries local; rules out the SQLite-only deployment.'
```

The note is durable context, not decoration. A verdict without its reasoning is not a
useful record six months later. The command may either release a parked decision:

```sh
chief decide storage-postgres postgres --note '...' --unpark
```

or retire it:

```sh
chief decide storage-postgres postgres --note '...' --retire 117-storage-postgres
```

`--unpark` clears `parked` and `parkedReason` while retaining the verdict in the live
tasklist, so the answer that released the work remains visible. `--retire` refuses to
act while a live tasklist depends on the decision and names those dependents. Once safe,
Chief sets `supersededBy`, deliberately does **not** add `mergedToMain`, and moves the
record to `tasks/chief/completed/`. This is a retirement filing, not a code merge.

The transition is also emitted as `tasklist.decision` in the append-only event stream,
so embedding hosts and `chief events` observe the same state change as the operator.

## ADR outcomes

A decision whose chosen outcome is an ADR can have the agent draft the ADR. The draft
must describe the alternatives and carry the operator's recorded verdict; it must never
claim that the agent selected or approved the option. The operator records that verdict
through `chief decide` after reviewing the brief and draft. If the decision is later
retired, the completed record remains the authoritative retirement pointer and carries
no merge stamp.
