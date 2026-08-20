# Tasklist schema

> **Status:** Current · **Updated:** 2026-08-20 · **Owner:** chief

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

  // --- the marker link (optional) ---
  "downstreamCounterpart":               // this tasklist is a MARKER for work that is
    ["agora:75-encode-scenarios"],       //   owned and built ELSEWHERE; these are the
                                         //   tasklist(s) that actually complete it, in
                                         //   the same "<repo>:<stem>" notation dependsOn
                                         //   uses (a bare stem is this repo). A single
                                         //   string is accepted too. The FORWARD half of
                                         //   supersededBy — see the note below.
  "supersededBy":                        // the BACKWARD half, written when the marker is
    "agora:75-encode-scenarios",         //   RETIRED: what replaced it. Metadata for a
                                         //   human reader; chief does not read it.

  "parked": false,                       // true = skipped by auto-discovery. Naming one in
                                         //   `chief run` prints its reason and stops
                                         //   (`--parked` runs it anyway).
  "parkedReason": "",                    // WHY it is parked, in a field rather than in
                                         //   prose. Optional and additive: `parked` alone
                                         //   still parks and reads as a park that does
                                         //   not say why. An OPAQUE STRING — chief holds
                                         //   no vocabulary; a project declares its own
                                         //   with CHIEF_PARK_REASONS in .chief/config, and
                                         //   `chief status` breaks the parked total down
                                         //   by it. See status.md.
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
  Neither field requires the other. The required sections, the sub-agent contract, the
  reuse-on-resume guarantee and the bounded-failure state:
  [../research-phase.md](../research-phase.md).
- **`downstreamCounterpart` is what makes a marker followable.** A tasklist can be a
  placeholder for work that belongs in another repo — the spec repo holds the spec,
  the implementation lands downstream — and the failure mode is silent: when the
  downstream tasklist merges, the marker upstream keeps sitting in the backlog,
  indistinguishable from work that still needs doing. (Measured across this host on
  2026-08-18/19: five of koine's ten markers had already shipped and every one was
  still counted as pending by `chief list`.) Declaring the counterpart in a field
  makes the link **checkable**: `chief lint` resolves each reference with the same
  lookup a cross-repo `dependsOn` uses, and a reference naming a repo or stem that
  does not exist fails the lint with the same message a bad dep edge gets — a pointer
  to nothing is worse than no pointer, because it reads as checked.
  **Prose is not the mechanism.** A counterpart mentioned only in `description` (the
  `DOWNSTREAM COUNTERPART: agora:75-…` convention) is readable but not checkable, and
  chief does not detect it or claim to — the lint reports how many declarations it
  actually saw. `supersededBy` is the same link pointing backwards, recorded when the
  marker is finally retired; chief reads it for exactly one purpose — a marker that
  already carries it has been retired and is never reported again.
  **The link is then followed forward.** `chief lint` resolves every declared
  counterpart and reports each one that carries `mergedToMain` while its marker is
  still live, naming the marker, the counterpart and the merge sha, so retiring it
  needs no second investigation:

  ```
  downstream work has landed — these markers are still live in tasks/chief/:
    ⚑ 57-general-finetune-provider — its downstream counterpart has MERGED: agora:50-finetune-live-endpoints @ea9d6c7
  ```

  Only that state is a finding. A counterpart still in flight is the normal state of
  a marker and is silent; so is a counterpart *filed* to `completed/` without
  `mergedToMain`, which has merged nowhere and can satisfy no dependency edge either.
  And the check **degrades rather than aborts** — a counterpart in a repo that is not
  checked out on this host is reported as unresolvable and every other marker is
  still checked, because a partial checkout is the common case.

  **The same report runs in `chief list`,** because that is where the backlog is
  actually read and a check nobody remembers to run catches nothing — the flagged row
  is marked inline and the block follows the listing:

  ```
     0/4   57-general-finetune-provider  ⚑ counterpart merged
  downstream work has landed — these markers are still live in tasks/chief/:
    ⚑ 57-general-finetune-provider — its downstream counterpart has MERGED: agora:50-finetune-live-endpoints @ea9d6c7
      ↳ retire by hand, in this order: repoint anything whose dependsOn names the
        marker at its counterpart FIRST, then stamp "supersededBy" and file the marker
        to completed/. A completed record with no "mergedToMain" satisfies no
        dependency edge, so a dependent still pointing at a filed marker is blocked
        forever, on a record that can never be stamped.
  ```

  It **reports and never fails**: `chief list` and `chief lint` both exit 0 on a
  finding and a run schedules the marker exactly as before. Retiring a marker is a
  judgement — it wants a `supersededBy` value, and sometimes dependents repointed —
  and refusing to launch on somebody else's merge would block work that is fine.
  That ordering is the part that silently breaks a queue, which is why it is printed
  next to the finding rather than left in this document: a marker never merges, so
  the record it leaves in `completed/` carries no `mergedToMain`, and `mergedToMain`
  is the entire test a cross-repo `dependsOn` applies. File the marker with a
  dependent still pointing at it and that dependent is blocked forever, on a record
  that can never be stamped.
- **`repo` targets a nested repo (e.g. a submodule).** The agent runs in a worktree of
  that repo, so its checks/deps must resolve there (use `warmup` to provision them, and a
  verify hook that dispatches off its cwd). All merges are serialized, so two tasklists
  on the same submodule never bump the pointer concurrently — but give same-repo
  tasklists distinct `touches` (or `dependsOn`) if their edits would otherwise collide.
