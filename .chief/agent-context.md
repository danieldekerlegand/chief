# Project context for Chief agents

This is appended to Chief's generic loop instructions and given to the agent each
iteration. Put your project's specifics here.

## Quality checks (loop step 5 — how to verify a story)
- Typecheck: `…`
- Tests (scope to what you changed): `…`
- Lint: `…`
Only mark a story done when the relevant checks are green.

## Conventions
- <where things live, naming, commit style, patterns to follow>

## Gotchas
- <non-obvious requirements, flaky tests to ignore, files that must stay in sync>

## The research document (only if this tasklist sets `"research": true`)

When a tasklist opts in, chief runs **one** research turn before the first story and
writes a structured map of the code — target files, data flow, point of insertion,
conventions — to `.chief/state/research/<tasklist>.md`. That document is then appended
to the prompt of **every** story turn (and every plan turn), under the heading
`# Research — the validated map of this codebase for THIS tasklist`.

**As the agent:** start from the map instead of re-deriving it, and spend the context
you saved on the change. Treat it as a strong starting point, not as scripture — if
you find it wrong while implementing, say so in your progress note.

**As a human:** that file is the correction surface, and it is the cheapest one you
have. Open it between iterations, fix what is wrong, save — the next story reads your
edit. Chief re-seeds the map from that file at the top of every iteration and never
regenerates a document that validates, so an edit sticks. Correcting the map costs
minutes; correcting the code it would otherwise have produced costs the rest of the
tasklist.

**When to turn it on.** Off by default, because roughly two in five tasklists are
one-shots — a doc fix, a version bump, a one-line guard — whose whole cost is smaller
than the research turn that would precede them. Turn it on when several stories share
one body of code (the map is paid for once and reused), when the change lands somewhere
unfamiliar, or when a wrong mental model would be expensive. Leave it off for small,
obvious, single-story work. `CHIEF_RESEARCH=1` / `CHIEF_RESEARCH=0` overrides the
tasklist for one run, in both directions.
