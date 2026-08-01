# Tasklist schema

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
  "parked": false,                       // true = skipped by auto-discovery

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
      "notes": ""                        // agent scratch space
    }
  ]
}
```

Notes:
- **Stories run sequentially within a tasklist**, in array order — later stories may
  build on earlier ones. Parallelism is *across* tasklists, never within one.
- **Acceptance criteria are the contract.** Write them concrete and checkable; the
  agent implements a story until they hold and won't mark it done otherwise.
- When a tasklist completes and merges, chief writes
  `tasks/chief/completed/<name>.json` (all `passes:true` + `mergedToMain: <sha>`)
  and retires the source file — so a re-run skips it.
- Deps may reference a tasklist that's already in `completed/`; it counts satisfied.
- A dep name is the **filename minus `.json`**, not a branch name — `some-tasklist`,
  never `chief/some-tasklist`. Qualify it as `<repo>:<tasklist>` to wait on work in
  another repo; see [cross-repo-dependencies.md](cross-repo-dependencies.md).
- **`repo` targets a nested repo (e.g. a submodule).** The agent runs in a worktree of
  that repo, so its checks/deps must resolve there (use `warmup` to provision them, and a
  verify hook that dispatches off its cwd). All merges are serialized, so two tasklists
  on the same submodule never bump the pointer concurrently — but give same-repo
  tasklists distinct `touches` (or `dependsOn`) if their edits would otherwise collide.
