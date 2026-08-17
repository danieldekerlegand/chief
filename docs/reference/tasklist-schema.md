# Tasklist schema

> **Status:** Current · **Updated:** 2026-08-14 · **Owner:** chief

A tasklist is one JSON file in `tasks/chief/<name>.json`. `<name>` is its id
(used for the branch, deps, and the completed record). It's a coherent unit of
work run to completion by a chain of agent iterations.

```jsonc
{
  "project": "my-project",
  "branchName": "chief/my-feature",     // branch the tasklist runs on
  "description": "One paragraph: what this tasklist delivers and why.",

  // --- where the work happens (optional) ---
  "repo": ".",                           // "." = the project (default). A path (e.g.
                                         //   "packages/engine" or a submodule "sub")
                                         //   targets a nested git repo: the branch,
                                         //   worktree, commits, and merge all happen
                                         //   THERE; on success chief merges into that
                                         //   repo's base, bumps the project's pointer to
                                         //   it, and retires the tasklist in the project.
  "baseBranch": "main",                  // integration branch to branch from / merge into
                                         //   (default: the project's base, usually main)

  // --- scheduler fields (all optional) ---
  "iters": 5,                            // soft per-story iteration budget (default 5)
  "dependsOn": ["other-tasklist",        // hard: won't start until these are merged
                "pinakes:their-work"],   //   "<repo>:<tasklist>" waits on ANOTHER repo
                                         //   (see cross-repo-dependencies.md)
  "touches": ["frontend", "db-schema"],  // conflict domains; two tasklists sharing one
                                         //   are never co-scheduled (see drivers-and-safety.md)
  "warmup": ["npm ci"],                  // shell run in the worktree before the agent
                                         //   loop (provision gitignored deps)
  "verify": ["cargo test"],              // merge gate for THIS tasklist, run with
                                         //   cwd = the work repo. Overrides the
                                         //   project-wide .chief/verify.sh hook —
                                         //   so a multi-repo project doesn't need one
                                         //   hook dispatching off cwd. Omit to use
                                         //   the project hook.
  "crossRepo": ["argos"],                // repos this tasklist's ACCEPTANCE CRITERIA may
                                         //   name. Omit it and a criterion referencing
                                         //   another repo (`argos:82`, `argos/tasks/…`,
                                         //   `../argos/…`) fails the tasklist as
                                         //   UNSATISFIABLE before the first agent turn —
                                         //   a worktree cannot do work that lives
                                         //   elsewhere. Declaring it is the explicit,
                                         //   reviewable hatch for real coordination.
  "parked": false,                       // true = skipped by auto-discovery
  "review": "none",                      // "plan" = a HUMAN approves the agent's plan
                                         //   before it writes any code (one extra turn
                                         //   per story). "none" (default) is the
                                         //   straight-to-code loop. See plan-review.md.
  "research": false,                     // true = spend ONE up-front turn mapping the
                                         //   code (target files · data flow · point of
                                         //   insertion · conventions) into
                                         //   .chief/state/research/<name>.md, which
                                         //   every story then reads instead of
                                         //   re-deriving it. Produced once, reused on
                                         //   resume, human-editable between iterations.
                                         //   false (default) — see the note below.

  "userStories": [
    {
      "id": "US-1",                      // stable, unique within the tasklist
      "title": "Short imperative title",
      "description": "What to build and any important context.",
      "acceptanceCriteria": [            // the bar for 'done' — the agent verifies these
        "A concrete, checkable statement.",
        "Another one."
      ],
      "passes": false,                   // flipped true when the story is done
      "notes": ""                        // agent scratch space — AND the story's
                                         //   evidence: a story chief passes on the
                                         //   agent's behalf must say HOW here, and one
                                         //   whose criteria state a measurable bar
                                         //   ("green", "exit 0", "77 failed") must
                                         //   record the value it OBSERVED. Neither and
                                         //   the run stops UNVERIFIED
      // "unverified": true              // written BY chief, never by hand: the story
                                         //   claimed a bar chief cannot evaluate and
                                         //   recorded no observation, so it is neither
                                         //   passing nor silently ignored
    }
  ]
}
```

Notes:
- **Stories run sequentially within a tasklist**, in array order — later stories may
  build on earlier ones. Parallelism is *across* tasklists, never within one.
- **Acceptance criteria are the contract.** Write them concrete and checkable; the
  agent implements a story until they hold and won't mark it done otherwise.
- **A criterion that states a bar must be measured.** One containing a checkable
  numeric or state bar makes the story owe an observed value in its `notes`; without
  it the story is marked `unverified` rather than `passes` and the branch stops. Chief
  does not judge whether the observation MEETS the bar — see
  [verify-hook.md](verify-hook.md) for which layer checks what.
- **A criterion must be satisfiable from this tasklist's worktree.** One that names
  another repo is stopped before the run starts (`UNSATISFIABLE`) unless the tasklist
  declares `crossRepo`; `chief lint` reports the same finding while it is still a text
  edit, and `chief gen` warns. See
  [drivers-and-safety.md](../explanation/drivers-and-safety.md).
- When a tasklist completes and merges, chief writes
  `tasks/chief/completed/<name>.json` (all `passes:true` + `mergedToMain: <sha>`)
  and retires the source file — so a re-run skips it.
- Deps may reference a tasklist that's already in `completed/`; it counts satisfied.
- A dep name is the **filename minus `.json`**, not a branch name — `some-tasklist`,
  never `chief/some-tasklist`. Qualify it as `<repo>:<tasklist>` to wait on work in
  another repo; see [cross-repo-dependencies.md](cross-repo-dependencies.md).
- **`review` is the only field that puts a human in the loop.** `"plan"` makes each
  story spend one turn writing a plan artifact that a person approves (or annotates)
  before any edit; anything else — and the default — is off, and the loop is exactly
  what it was. Enable it on the tasklists where a misread requirement is expensive
  (architectural, wide-blast-radius, "I'm not sure this is the right seam") and leave
  it off for the one-shots, refactors and doc fixes that are most of a roadmap. It is
  a one-word, reviewable diff either way. The rationale, the artifact schema, the
  reviewer contract and what happens when nobody is there:
  [plan-review.md](plan-review.md).
- **`research` buys the map once instead of once per story.** With it on, chief spends
  one turn before the first story writing a structured map of the code to
  `.chief/state/research/<name>.md`, and appends that map to every story's (and every
  plan's) prompt. Two things follow. Correctness: the stories work from one validated
  model of the code instead of each re-deriving its own, badly. Context economy: an
  iteration that opens with the map spends its window on the change rather than on
  greps and file dumps. **Off by default, and the rule is a cost one** — roughly two in
  five tasklists are one-shots (a doc fix, a version bump, a one-line guard) whose whole
  cost is smaller than the research turn that would precede them, so turn it on where
  several stories share one body of code, where the change lands somewhere unfamiliar,
  or where a wrong mental model is expensive, and leave it off otherwise.
  `$CHIEF_RESEARCH=1|0` overrides the tasklist for one run in both directions. The
  document is **reviewable and editable**: a human can correct it between iterations and
  the next story reads the correction, and on a tasklist that also sets `"review":
  "plan"` the map goes to the same reviewer first — research, then plan, then code.
  Neither field requires the other.
- **`repo` targets a nested repo (e.g. a submodule).** The agent runs in a worktree of
  that repo, so its checks/deps must resolve there (use `warmup` to provision them, and a
  verify hook that dispatches off its cwd). All merges are serialized, so two tasklists
  on the same submodule never bump the pointer concurrently — but give same-repo
  tasklists distinct `touches` (or `dependsOn`) if their edits would otherwise collide.
