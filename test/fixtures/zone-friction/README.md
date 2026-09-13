# zone-friction corpora — the registries the recorded measurement used

These four files are inputs to `scripts/zone-friction.sh`, checked in so the numbers in
`tasks/chief/completed/910-*.json` and `docs/reference/overlap-zones.md` can be
re-derived rather than believed. They are **not** this repo's registry — chief's own
`.chief/zones.conf` does not exist, and a zone here would hold chief's own merges.

Two pairs, each `<pair>.before.conf` (the rule as a `path:` glob fires today) and
`<pair>.after.conf` (the same glob narrowed with `surface:<glob>:<ere>`):

- **broad** — "every function declaration under `engine/`". The zone an operator writes
  first, and the one the measurement says does *not* earn its friction here: in a repo
  whose every tasklist authors engine functions, almost every merge rewrites a
  declaration, so the narrowing releases almost nothing.
- **namespace** — the agent exit-code namespace in `engine/driver.sh`, which
  `CLAUDE.md` calls "a contended namespace across parallel tasklists" — i.e. a real
  design-overlap surface, named as one before this tasklist existed. This is the shape
  the narrowing is for.

Re-run either with:

    bash scripts/zone-friction.sh test/fixtures/zone-friction/namespace.before.conf \
                                  test/fixtures/zone-friction/namespace.after.conf
