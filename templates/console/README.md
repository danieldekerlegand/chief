# Console run prompt templates

> **Status:** Draft · **Updated:** 2026-10-23 · **Owner:** chief

The prompts a console run's native runner sends through the Claude Agent SDK, one per phase (design:
`docs/explanation/console-runs.md`). The runner is an Agent SDK program that Chief observes, not a Chief
scheduler; `~/insimul-loops/briefs/console_plan_run.py` is the first. The runner fills every `{{NAME}}`
before sending; a prompt with a `{{` left in it is not sent.

**Agents return; the runner writes.** Read-only phases have no write tool, so each template asks the agent
to *return* its document (or verdict) as its final answer. The runner writes it to the path the template
names and records the call in `cost.jsonl` and the run's `chief.loop-run/v1` manifest. Only the execute-mode
builder edits files itself, in its own worktree.

| Placeholder | Value |
|---|---|
| `{{REPOS}}` | the repos the run covers (absolute paths), first one holds the run record |
| `{{RUN_DIR}}` | the run directory the runner chose (e.g. `<first repo>/.chief/console/<run-id>`, or `~/insimul-loops/briefs/runs/<run-id>` for the first runner) |
| `{{BRIEF}}` | the brief file's path |
| `{{SUBSYSTEM}}`, `{{PATHS}}` | the mapper's subsystem name and the paths it covers |
| `{{ROUND}}`, `{{LENS}}`, `{{LENS_FILE}}` | the gauntlet round, the critic's lens and its template |
| `{{TASKLIST}}`, `{{WORKTREE}}`, `{{BRANCH}}` | execute mode: the tasklist, the worktree (the builder's, or the critic's detached one) and the branch |
| `{{LOCK}}` | the repo's machine-lock wrapper for heavy commands, or empty |
| `{{RULES}}` | the target repo's standing rules the brief names (e.g. a decisions file), or `none` |

Every template ends with the same rules: return only the documents named, cite paths for every claim,
say what you could not check, and never print a secret.
