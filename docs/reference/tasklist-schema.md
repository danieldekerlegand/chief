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

  "type": "DECISION",                     // optional: the deliverable is a human
                                             // verdict, not a merged branch. `kind:
                                             // "DECISION"` and `decision: true` are
                                             // accepted aliases for hand-authored records.

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
  "parkedReason": "HUMAN_DECISION: choose the storage backend", // WHY it is parked, in a field rather than in
                                         //   prose. Optional and additive: `parked` alone
                                         //   still parks and reads as a park that does
                                         //   not say why. An OPAQUE STRING — chief holds
                                         //   no vocabulary; a project declares its own
                                         //   with CHIEF_PARK_REASONS in .chief/config, and
                                         //   `chief status` breaks the parked total down
                                         //   by it. See status.md. The leading class is one
                                         //   of HUMAN_DECISION, EXTERNAL_DEPENDENCY, TOOLCHAIN,
                                         //   or COUNTERPARTY, followed by a colon and opaque
                                         //   prose. For example, HUMAN_DECISION: choose A
                                         //   means a person must choose; TOOLCHAIN: UE SDK
                                         //   not provisioned is a dependency, not a decision.
                                         //   Unknown classes remain valid prose and render
                                         //   verbatim. `chief status --decision` filters to
                                         //   HUMAN_DECISION parks.
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

  // A DECISION tasklist always pays for research. Its brief names the options and
  // what each forecloses. Passing stories only prepares the brief; it cannot merge
  // or approve the choice. Set review:"decision" to use the existing review gate.

  // A DECISION tasklist always pays for research. Its brief names the options and
  // what each forecloses. Passing stories only prepares the brief; it cannot merge
  // or approve the choice. Use review:"decision" for the existing review gate.

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
      // "terminalFalse": true           // OPT-IN, written BY HAND when the tasklist is
                                         //   authored: a NEGATIVE finding on this story
                                         //   is a deliverable, not a failure to deliver.
                                         //   The story is DONE once it records the
                                         //   measurement behind the answer, and `passes`
                                         //   stays false because the answer is false
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
- **A story may declare that FALSE is its terminal answer** — `"terminalFalse": true`.
  Some stories are verifications: *"check whether the commission→deploy flow completes,
  honestly."* When the honest answer is **no**, that story has delivered its work and
  the finding is the output. Without this field chief has exactly one notion of done —
  every story `passes:true` — so such a tasklist can never complete. (Measured on
  cuneiform `283-nixos-bare-metal-vpn-topology-target`: 63 commits, 59 iterations and
  **42 consecutive identical measurements** before a human read the agent's own note
  saying the tasklist needed manual retirement.)

  A story is **settled** — the tasklist may stop asking about it — when either:

  | state | `passes` | `terminalFalse` | `notes` | settled? |
  |---|---|---|---|---|
  | delivered | `true` | — | — | yes, answer **YES** |
  | terminated negative | `false` | `true` | an observed value | yes, answer **NO** |
  | declared, never measured | `false` | `true` | nothing recorded | **no** — open, and reported as *skipped* |
  | ordinary unfinished | `false` | absent | — | **no** |

  Three consequences, and they are the whole feature:
  - **`passes` is never rewritten.** It stays `false` on a terminal negative, on the
    branch and in the `completed/` record, because that *is* the finding. Completion is
    computed from *settled*; a reader that never heard of the field still reads the
    record correctly.
  - **The declaration is INERT without evidence.** A declared story whose `notes` record
    no observation is *not* done — it is skipped work, it keeps the tasklist open, and
    the run says so in its own words rather than parking as "the iteration budget ran
    out". Otherwise the field would be a way to mark hard stories complete. The
    observation bar is the lenient one the bar rule already uses: any number, or a
    word like *green* / *clean* / *failing*.
  - **Nothing changes for a story without it.** No declaration, no new behaviour: the
    story completes only by passing, exactly as before.

  `chief ps` and `chief list` render a settled negative distinctly — `2+1/4`, never
  folded into the passing count and never left out of it.

  **Retiring one by hand: `chief retire --negative <name>`.** A tasklist that settles
  on a negative and still has a branch to merge is finished by `chief run` like any
  other. The command is for the other case — the one `283` was in, where the branch
  will not (or should not) run again and the operator has to close the tasklist
  themselves. It retires a tasklist whose delivered stories **passed** and whose
  remaining story **terminated false**, and refuses everything else:

  | state | `chief retire --negative` |
  |---|---|
  | every story settled, ≥1 settled **NO** | **retires** — files `completed/`, removes the live tasklist |
  | an ordinary open story (no declaration) | **refuses**, naming the story |
  | declared but nothing measured | **refuses**, naming the story |
  | every story passes, nothing negative | **refuses** — that one retires by *merging* |
  | not in the base branch, and something still `dependsOn` it | **refuses**, naming the dependents |

  The last row is the retirement trap the `downstreamCounterpart` note below describes:
  a `completed/` record satisfies a dependency edge only if it carries `mergedToMain`,
  so filing an unmerged one under a live dependent blocks that dependent forever.
  Chief stamps `mergedToMain` when it can verify the branch is contained in the base,
  and otherwise says so plainly.

  The **declaration and the finding usually live in different files** — the operator
  adds `terminalFalse` to `tasks/chief/<name>.json` after a run has already recorded
  the measurement in `.chief/state/snapshots/<name>.json` — so the command reads the
  **union** of the two per story id and reports which file supplied the measurement.
  The record it writes keeps the negative as `false` with its `notes`, and lifts the
  same finding into a `retiredOnNegative` block so a successor tasklist can cite it
  without knowing the predicate:

  ```jsonc
  "retiredOnNegative": {
    "at": "2026-08-26T18:22:41Z",
    "by": "chief retire --negative",
    "branch": "chief/283-nixos-bare-metal-vpn-topology-target",
    "merged": false,                    // no mergedToMain: satisfies no dependency edge
    "source": "the run's snapshot .chief/state/snapshots/283-….json",
    "stories": [
      { "id": "US-3",
        "title": "VERIFY the MaaS commission→deploy flow, honestly",
        "finding": "verdict maas-client-absent; no file under core/ services/ apps/ … calls a MaaS API. Do this instead: land a MaaS client in services/ first." }
    ]
  }
  ```

  `-n` prints the verdict and writes nothing; `--no-commit` leaves the two file changes
  in the working tree instead of committing them.

- **Progress is judged on the DIFF, and chief's own state directory does not count.**
  An iteration advances the tasklist if a story's `passes` rose, or if its commits
  touched at least one path outside `.chief/state/` (`$CHIEF_STATE_DIR`). A commit whose
  entire diff is `.chief/state/**` is bookkeeping: it scores as **no progress**, the
  stall counter increments exactly as it would for an iteration that committed nothing,
  and the log says `BOOKKEEPING ONLY` so the commit does not look lost. The rule reads
  the diff and never the commit message — the same discipline the no-work guard applies
  to a claim of *completion*, applied to a claim of *progress*. (Measured in `formant`
  on 2026-08-24: a tasklist blocked on a human measurement re-stamped its notes every
  turn and reached iteration 11 of a 5-iteration budget.)
  **Writing notes and progress records stays fully supported** — they are how the next
  iteration and a human reader learn what was tried, and an iteration that does real
  work *and* updates them scores as progress on the strength of the real work. The state
  paths are not subtracted from anything; they simply cannot carry the verdict alone.
  **`touches` cannot exempt a tasklist from this**, and this is the one case chief
  genuinely cannot express: work whose *entire product* is content under
  `.chief/state/` is not a tasklist chief can drive to completion, because every
  iteration of it scores as a stall. `touches` is a conflict domain the scheduler
  serializes on — a conceptual tag, frequently not even a path — not a scope grant, and
  a guard the tasklist under judgement could switch off would not be a guard. It is not
  silent about it: an iteration scored `BOOKKEEPING ONLY` on a tasklist that *did* list
  the state directory in `touches` prints a note saying why the declaration made no
  difference. Do such work by hand outside a run, or give the tasklist a real product
  (the engine, `templates/`, `docs/`) to change.

  **What the operator sees.** The per-iteration line names what advanced rather than
  asserting that something did — `Iteration 3: progress — US-2 passed; 4 paths outside
  .chief/state/ changed (e.g. engine/agent.sh) (2/3 passing)`. (`progress (0/2
  passing). Continuing...` was the sentence formant's run printed eleven times: it
  states progress and zero passing in the same breath and names nothing, so there is
  nothing in it to disbelieve. Note that *zero passing* is an honest state on its own —
  a tasklist mid-story, committing real files, whose single story flips at the end.)
  And a tasklist the stall counter stops gets its own block in the run summary,
  `STOPPED ADVANCING`, kept apart from the two failures it is otherwise indistinguishable
  from: a `VERIFY-FAILED` gate (the work exists, the gate said no) and a
  `PROVIDER UNAVAILABLE` block (no turn was ever taken — see
  [provider-unavailability.md](provider-unavailability.md)). The three need opposite
  responses, and raising `iters` fixes only the case where the budget really was the
  binding constraint. The block quotes the agent's own closing words from its final
  turn underneath the reason.

  **What chief will not do: act on an agent asking to be stopped.** formant's agent
  said, in prose, *"further iterations on this tasklist can only add churn; re-parking
  it would be the honest call"* — and was re-driven five more times. Chief does not
  detect that, deliberately. There is no signal to match on: a phrase list
  (`re-parking`, `blocked on`, `cannot proceed`) fires on an agent *describing* a
  blocker it then clears, misses every rephrasing, and rots silently as models change
  their idiom. The only reliable form is a protocol token the way
  `<promise>COMPLETE</promise>` is one, which is a change to the agent contract rather
  than to the loop — and it would buy little now, because the stall counter reaches the
  same stop within `STALL_LIMIT` iterations of the first churning turn. What was
  actually lost was the reasoning, buried at iteration 10 of a log nobody re-reads, so
  chief **quotes** those closing words in the summary and draws no conclusion from them.
- **A tasklist that keeps re-answering one question is STOPPED and diagnosed.** The
  safety net for the case where nobody declared `terminalFalse` on the story that
  needed it — and the case it is measured on is the same one: cuneiform `283` recorded
  **42 consecutive identical measurements** and ended `INCOMPLETE`, which is a wrong
  verdict on finished work rather than a cheap one.

  When the story chief is driving records the **same outcome** — same measurement, same
  blocker, `passes` unmoved — at `REPEAT_LIMIT` consecutive iteration boundaries
  (**default 3**), the run stops that tasklist with the outcome `CANNOT-COMPLETE`. It
  names the story, quotes the finding verbatim, and names the two actions that resolve
  it: **amend the criterion**, or **declare the negative terminal** (`terminalFalse`
  above). Chief chooses neither — it cannot evaluate the finding, and guessing would be
  a way to bury unfinished work.

  Three properties make it the rule it is:
  - **It is independent of the stall counter, and has to be.** `283` committed real
    files outside `.chief/state/` on every one of those 42 iterations, so progress
    scored every time — with the bookkeeping fix above fully in place. The comparison
    is on the story's **recorded outcome**, never on commits.
  - **An outcome only exists once it is measured.** A story mid-implementation has
    recorded nothing, and quiet iterations of ordinary work never accumulate repeats.
    The observation bar is the same lenient one the bar rule and the inert rule use.
    That also keeps this rule disjoint from `MEASURE_DEMOTE_LIMIT`: a story with no
    observation is that rule's business and never reaches this one.
  - **A reworded finding is not a repeat.** The comparison is conservative on purpose —
    a missed repeat costs iterations, a false one stops a tasklist that was working.

  The branch, its worktree and every commit are kept, and the run summary gives these
  their own block (`CANNOT COMPLETE AS WRITTEN`), apart from `STOPPED ADVANCING`: they
  are the opposite shape, and raising `iters` is the exactly-wrong response to them.
- **A criterion must be satisfiable from this tasklist's worktree.** One that names
  another repo is stopped before the run starts (`UNSATISFIABLE`) unless the tasklist
  declares `crossRepo`; `chief lint` reports the same finding while it is still a text
  edit, and `chief gen` warns. See
  [drivers-and-safety.md](../explanation/drivers-and-safety.md).
- When a tasklist completes and merges, chief writes
  `tasks/chief/completed/<name>.json` (every story `passes:true` — except one that
  declared `terminalFalse`, which keeps its `false` and its finding — plus
  `mergedToMain: <sha>`)
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
  [plan-review.md](../plan-review.md).
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
