# Changelog

**What shipped is recorded in `ROADMAP.md` and in `tasks/chief/completed/*.json`, not
here.** Every merged tasklist appears as a completed record and is named in the
roadmap's band table, and `test/doc-sync.sh` fails CI when one is missing — so that
record cannot silently fall behind the engine. `VERSION` is the version those merges
have reached; `chief update` installs it.

This file is kept because the ecosystem documentation standard names it a root file
where a repo ships, and because a `CHANGELOG.md` that does not exist reads as an
oversight while one that lies reads as current. It carries the pointer above and
nothing else.

A hand-maintained changelog was tried here: three entries on 2026-08-20/21, then
nothing across the next fifteen merged tasklists, while the gated roadmap stayed
correct over the same span. That file is archived verbatim — with the measurement, and
with what reinstating it would cost — at
[`docs/archive/changelog-2026-08-21.md`](docs/archive/changelog-2026-08-21.md).
Its three entries were never wrong, only mis-filed under `## Unreleased`: all three
shipped in **v0.8.82** on 2026-08-21.

- Release history, per band: [`ROADMAP.md`](ROADMAP.md)
- Per-tasklist detail, with acceptance criteria and merge sha: `tasks/chief/completed/`
- The commands themselves: [`README.md`](README.md)'s command table
