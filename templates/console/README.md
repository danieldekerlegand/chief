# Console run prompt templates

> **Status:** Proposed · **Updated:** 2026-10-23 · **Owner:** chief

The prompts `chief console` sends to `claude -p`, one per phase (design: `docs/explanation/console-runs.md`).
Chief fills every `{{NAME}}` before sending; a prompt with a `{{` left in it is not sent.

| Placeholder | Value |
|---|---|
| `{{REPOS}}` | the repos the run covers (absolute paths), first one holds the run record |
| `{{RUN_DIR}}` | `<first repo>/.chief/console/<run-id>` |
| `{{BRIEF}}` | the brief file's path |
| `{{SUBSYSTEM}}`, `{{PATHS}}` | the mapper's subsystem name and the paths it covers |
| `{{ROUND}}`, `{{LENS}}`, `{{LENS_FILE}}` | the gauntlet round, the critic's lens and its template |
| `{{TASKLIST}}`, `{{WORKTREE}}`, `{{BRANCH}}` | execute mode: the tasklist, the builder's worktree and branch |
| `{{LOCK}}` | the repo's machine-lock wrapper for heavy commands, or empty |
| `{{RULES}}` | the target repo's standing rules the brief names (e.g. a decisions file), or `none` |

Every template ends with the same block: write only the files named, cite paths for every claim, say
what you could not check, and never print a secret.
