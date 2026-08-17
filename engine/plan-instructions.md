# Chief agent — the PLAN turn (no edits)

This tasklist has **plan review** enabled (`"review": "plan"`), so the story you are
about to work on gets a **plan** before it gets code. This turn is that plan, and
**only** that plan.

The reason is leverage: reviewing a plan catches the misunderstandings that would
otherwise generate hundreds of lines of wrong code, at a fraction of the cost of
reviewing the code itself. A plan a human can steer in thirty seconds is worth more
than a diff they have to unpick.

## What you must do this turn

1. **Read the runtime PRD** at `.chief/state/prd.json` and skim
   `.chief/state/progress.txt` (the `## Codebase Patterns` section first, if present).
2. **Pick the highest-priority story** with `"passes": false` (first-in-array order) —
   the one named in **This turn** at the bottom of these instructions.
3. **Read enough of the codebase to plan honestly.** Open the files you intend to
   change. A plan built from guesses is the failure mode this whole phase exists to
   catch, and a reviewer cannot tell a guessed path from a real one.
4. **Write the plan artifact** to the exact path given in **This turn**, as JSON in
   the schema below.

## What you must NOT do this turn

- **Do not edit, create, or delete any file** other than the plan artifact itself.
- **Do not commit anything.** There is nothing to commit.
- **Do not flip any `passes` flag.**
- **Do not emit the completion token.** A plan turn never completes a tasklist; if you
  write it here it is ignored, and it will cost the run an iteration.

## The plan artifact

Program design, not prose: which files move, what each change *is*, and how you will
know it worked. Every field is required and every string must be non-empty.

```json
{
  "story": "US-1",
  "summary": "One sentence: what this story changes and why that is the right seam.",
  "changes": [
    {
      "path": "engine/agent.sh",
      "action": "modify",
      "change": "Add a PLAN turn ahead of the implement turn: pick the prompt by mode, validate the artifact, exit 4 when it is malformed."
    },
    {
      "path": "docs/plan-review.md",
      "action": "create",
      "change": "Document the artifact path, its schema, and the exit-code contract."
    }
  ],
  "verification": [
    { "phase": "syntax",  "command": "bash -n engine/agent.sh" },
    { "phase": "lint",    "command": "shellcheck -S error engine/agent.sh" },
    { "phase": "behavior","command": "bash test/smoke.sh" }
  ]
}
```

Field rules — the engine checks these, and a plan that fails them stops the run:

- `story` — must equal the story id in **This turn**, exactly.
- `summary` — a non-empty string.
- `changes` — a non-empty array. Each entry needs `path` (repo-relative), `action`
  (exactly one of `create`, `modify`, `delete`), and `change` (what the edit *does*,
  specific enough that a reviewer can disagree with it).
- `verification` — a non-empty array. Each entry needs `phase` (a short label such as
  `syntax`, `lint`, `test`, `docs`) and `command` (the command you will actually run).

Anything else you add (`risks`, `openQuestions`, `alternatives`) is preserved and shown
to the reviewer, so use them when a decision is genuinely contested.

The artifact must be **valid JSON** — write it with a heredoc or a tool, then read it
back and confirm it parses. A malformed plan is not a smaller plan; it stops the
tasklist with a `PLAN-INVALID` status rather than falling through to code.

After you write the file, say in one line what you planned and stop. The next
iteration implements it.
