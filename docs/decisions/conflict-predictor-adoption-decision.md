# Decision: chief builds the overlap-zone registry; it does not bind a conflict predictor

> **Status:** Current · **Updated:** 2026-08-17 · **Owner:** chief

**Status:** decided (DECLINE to adopt, for now) · **Scope:** `chief/91-enforceable-overlap-zones`
US-0 · **Assessed:** 2026-08-17

## The question

The 2026-08-13 portfolio scan flagged this tasklist before it was built: the
worktree-orchestration category now contains tools that **predict conflicts between
worktrees before they happen and warn when two agents are about to overlap on the same
function or class**. That is a strictly finer instrument than chief's `touches` tag, and
it is adjacent rather than competing — *a competitor at your layer is a threat; a
competitor at an adjacent layer is a socket*. So: **can a predictor be bound behind
chief's existing `touches` seam — the registry consuming a predictor's verdict instead of
a hand-declared tag — rather than chief building the registry itself?**

## The decision

**No. Chief builds the registry, and binds no predictor.** The decline is on the seam,
not on the tools: what a predictor computes is not what the `touches` seam consumes, at
the moment it consumes it. The registry is built so that a predictor verdict *could* be
an additional input later (see [The seam left open](#the-seam-left-open)); nothing here
forecloses that.

## What was assessed

Two purpose-built cross-worktree conflict predictors, in depth; one orchestrator checked
and excluded. Figures are what the public repositories showed on 2026-08-17.

| | **Clash** ([clash-sh/clash](https://github.com/clash-sh/clash)) | **Grove** ([NathanDrake2406/grove](https://github.com/NathanDrake2406/grove)) |
|---|---|---|
| What it detects | file + hunk conflicts, via `git merge-tree` three-way merge simulation | five layers: file · hunk · **symbol** · dependency (export/import) · schema (migrations, deps, env, routes), scored green/yellow/red/black |
| Interface | `clash status --json`, `clash check <file>`, `clash watch` (TUI) | `grove conflicts <a> <b>`, `--json` on all read commands, `grove check` → exit 0 clean / 1 dirty |
| Process model | CLI, no daemon; file watching only in `watch` mode | **daemon** — actor model, background file watcher, SQLite persistence |
| Scope | live worktrees against their merge bases | each worktree against a shared base |
| Runtime | single Rust binary, MIT | single Rust binary (5-crate workspace), MIT/Apache-2.0 |
| Maturity | 63 stars, 47 commits on main, releases + CI | 13 stars, 195 commits, 93% test coverage claimed |

**ccswarm** ([nwiizo/ccswarm](https://github.com/nwiizo/ccswarm), 149 stars, pre-1.0) was
checked because the scan named it. It is an orchestrator with worktree isolation; its
README documents task prediction and dependency resolution, **not** a cross-worktree
conflict predictor exposed as a library or subcommand. There is nothing to bind. It is
recorded here so the next reader does not re-check it.

### Could either be bound behind `touches`?

**No — the seam reads at a time when neither tool has anything to say.** `touches` is
consumed at **admission**: the scheduler decides whether to launch tasklist B while A is
running ([drivers-and-safety.md](../explanation/drivers-and-safety.md) §Scheduling). At
that instant B has no worktree and no diff — its branch *is* the base. Both tools derive
their verdict from diffs between live worktrees. Neither can answer the scheduler's
question, because the evidence they need does not exist yet. A predictor is not a
finer-grained `touches`; it is a **different question asked at a different time**
(mid-run and at merge, not at admission).

**And at the times they can answer, the marginal value is small:**

- **Clash predicts what chief already determines.** Chief's merge floor performs the real
  rebase and re-verifies before every merge. A `git merge-tree` *prediction* of a textual
  conflict is strictly weaker than the actual three-way merge chief runs anyway. Its real
  value is the *earlier* warning during the run — and chief has no actuator for one: it
  cannot re-serialize a tasklist already in flight, only report. Chief already reports
  exactly this, from the real diff, in the under-tagged-`touches` audit.
- **Grove's extra layers are the interesting part, and cost the most.** Symbol,
  dependency and schema overlap are genuinely beyond anything chief computes. But it wants
  a daemon with a background watcher and a SQLite store, and *daemon-free is a stated
  property of chief*, not an accident — the same property that decided
  [CLI-only](desktop-gui-decision.md). It also puts a Rust toolchain-or-binary between a
  user and a runner whose floor is bash 3.2 + git + jq.
- **Neither detects the risk this tasklist exists for.** The failure the registry
  addresses is cross-branch **design divergence** — parallel agents each holding a
  different slice of context, producing individually correct code that breaks when
  combined. Every layer both tools compute is a *collision* — the same file, hunk, symbol,
  export, schema touched twice. Two branches can agree on every one of those and still
  disagree on the design. A red score is not the signal, and a green one is not
  reassurance. That gap is precisely why the mitigation is a **human** gate.
- **Youth cuts both ways, and the wrong direction is worse.** At 63 and 13 stars these are
  young. A predictor wrong in either direction is worse than a coarse hint an operator
  already distrusts: a false red trains operators to click through the review gate, and a
  false green hands them an authority the tool does not have.

## The acceptance bar this had to clear

The measured failure mode, from the same scan: `280`'s `touches` were **conceptual tags**
— `cuneiform-engine`, `render-goldens` — that lexically match no path, so the scheduler
could not serialize it against anything, while `308`/`311` declared real paths and were
correctly serialized on `ccl.rs`. **Any mechanism adopted or built here must catch the
conceptual-tag case, or it fixes nothing.**

- **A predictor "catches" it only in the weak sense** that it never reads `touches` at all
  — it reads diffs. So it is immune to a bad tag, but it can only speak once both branches
  have written code: after co-scheduling, with no actuator. It converts a silent overlap
  into a mid-run warning, which is what chief's existing audit already produces post-hoc,
  from the real diff, with no new dependency.
- **This is the binding constraint on the build.** A zone whose only key is a `touches`
  domain name inherits `280`'s failure exactly: a tasklist tagged `cuneiform-engine`
  matches no zone and walks through the gate. Therefore the registry's zone matcher **must
  evaluate the branch's real changed-file list** (`git diff --name-only <base>...<branch>`
  — the same scope the verify hook and the touches-audit use) against zone **path
  patterns**, and treat the `touches`-domain key as an additional, optional match, never
  the only one. A conceptual tag then costs nothing: the paths still match. US-1 is built
  to that constraint, and the hermetic test in US-3 pins it.

## Why a DECLINE is a legitimate answer here

Coarse-but-cheap is the position this tasklist's own premise defends: **the merge floor
(rebase → re-verify → `--no-ff`) is the correctness guarantee; `touches` is a scheduling
hint.** Nothing assessed here changes that, and nothing assessed here is on the axis the
registry adds — policy above the floor, asking a human about design divergence that no
automated gate detects. Buying a Rust binary, a daemon, or both to compute a finer version
of the hint would add dependency and a new class of wrong answers without touching the
gap. The honest move is to build the small policy layer, keep the floor exactly as it is,
and leave the socket open.

## The seam left open

If a predictor later earns adoption, the shape is already decided by the constraint above:
the registry evaluates **a set of changed paths plus zone policy**. A predictor is bound by
supplying *additional* zone matches — "these two branches overlap on symbol `run_worker`" —
into the same evaluation, at the same merge-time seam, as an **optional** input whose
absence changes nothing. It is never consulted at admission (it has nothing to read there),
never replaces a declared zone, and never grants approval — only ever *asks* for one. Any
such binding stays behind a config flag and an explicitly installed binary; chief's floor
stays bash + git + jq.

## If this is ever reversed

Re-opening means one of the assessed facts changed: a predictor detects design divergence
rather than collision, or one ships daemon-free with a stable JSON contract and enough
adoption that a wrong verdict is a known quantity. Amend this record with the new evidence
and bind at the merge-time seam described above — not at the scheduler, which is the one
place the analysis says a predictor cannot help. **Until then, chief declares its own
zones.**
