# Decision: Chief is the development-operations monorepo

**Status:** Accepted · **Date:** 2026-10-21

Chief's runner, the former Chief Cloud control plane, and Rosetta's reusable portfolio
observability solve one operational problem at different timescales. They share a project catalog,
run identity, evidence model, telemetry, and permissions, so their reusable code belongs in one
monorepo.

The package boundary remains explicit:

| Area | Owns |
|---|---|
| Chief engine | local tasklist execution, verification, worktrees, provider invocation |
| Console | live and historical run monitoring and eventual cross-host control |
| Portfolio | project catalog, roadmap projection, competitors, ideas, evidence, programme history |
| Contracts | portable project, run, evidence, and telemetry records |
| Collectors | read-only adapters over Git, Chief, trackers, and private workspace sources |

The engine stays daemon-free and CLI-first. The monorepo can ship applications without making
them prerequisites of `bin/chief`; this preserves the installation and failure boundary recorded
in the earlier desktop-GUI decision.

## Public code and private data

Application code, schemas, and generic collectors may be public. Workspace configuration and
collected records are separate inputs. A private workspace can contain commercial strategy,
competitor judgments, transcripts, private repository paths, screenshots, and object-storage
references without placing any of them in the public source tree.

Small evidence may live in the private data repository. Large images and video live in Git LFS or
object storage; versioned evidence manifests keep their URI, hash, caption, capture time, and
provenance. The UI reads the manifest and does not require media bytes in this repository.

## Koine and Agora

Koine remains the neutral contract repository and Agora remains its shared runtime. Chief may
export OpenTelemetry-compatible signals and expose or consume Koine-shaped capabilities through
adapters. Neither relationship makes the fabric part of the development-operations monorepo.

## Rosetta migration

The existing Rosetta repository first acts as the private workspace source. Reusable watch,
catalog, and projection logic moves here only after its data dependencies are explicit. Its
private strategy and topology remain readable throughout the migration; no source move is allowed
to strand or silently publish them.
