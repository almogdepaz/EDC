---
name: edc-build-impl
description: Semantic assembly contract for coordinator-owned v2 context builds
---

# Build Context Assembly (v2)

EDC's shell coordinator owns routing, module discovery, task planning, worker processes, bounded concurrency, timeouts, staging, report synthesis, manifest finalization, promotion, curator passes, and doctor validation. This prompt is semantic guidance only. Never launch an agent, invoke a skill as a process, run an EDC orchestrator, or choose worker flags.

## Coordinator-owned discovery contract

The coordinator inventories `git ls-files -s` without reading source bodies. Discovery uses package/crate/workspace boundaries and top-level directories only as fallback. mode 160000 entries are submodule/gitlink boundaries, not ordinary indexed source. The coordinator validates a structured module plan before any module worker runs.

Each module worker receives one exact scope and writes one staged module doc. Workers do not read sibling source bodies. Cross-module synthesis consumes staged module docs and lightweight metadata only. All outputs remain in git-private run storage until validation succeeds.

## Semantic assembly inputs

Assembly receives:

- a validated discovery plan
- validated staged module docs
- deterministic module metadata
- coordinator-generated cross-module flow notes
- exact staged output paths

Read only those inputs plus lightweight repository metadata. Do not re-read source bodies.

## Single operational context index

Author `index.md` as the repo's single operational context index. It must be routing-first, compact, and contain this top-level section order:

```md
# <repo> context index

## How to use
- read this file first
- choose module docs by changed path/task
- for cross-boundary work, read only the related modules named by routing/coupling guidance
- contextless.entries are machine coverage only and must not appear in the human index read path
- reports are not part of the ordinary index read path

## Route by path/task
| touching / task | read first | also inspect | why |

## Critical global invariants

## Cross-module coupling / blast radius
```

Optional compact sections may appear after `## Route by path/task` only when useful:

- `## Architecture overview` — tiny actor/trust-boundary orientation, not an essay
- `## Module table` — compact discoverability when route rows do not expose every module

Do not include generated file counts, LOC estimates, or manifest priority values in the index. If an agent can discover it with one Read, Grep, or Glob, leave it out.

## Module docs

Persist only decision-useful read boundaries, ownership and authority, implicit contracts, ordering constraints, cross-module cascade risks, trust boundaries, historical footguns, and source-truth pointers. Do not persist inventories, copied schemas/constants, function narration, or empty template sections.

## Partial manifest ownership

Assembly may author only:

- `schemaVersion: 2`
- `edcVersion`
- `repoContextFile: edc-context/index.md`
- canonical `reports` and `build` paths
- `policy.defaultMode` and `policy.unmatchedPathPolicy`
- real `modules[]` entries with name, canonical doc, summary, unique priority, and match rules
- optional `contextless.entries[]`
- `unmapped.allowedGlobs` for legacy compatibility

Do not author `generatedAt`, `sourceCommit`, or `coverage.*`; the coordinator-owned manifest finalizer writes them. Preserve an operator-authored advisory/inject mode when the coordinator supplies one; otherwise default to advisory. Unmatched policy is warn-allow.

Do not create fake `misc`, `other`, or directory-bucket modules whose only guidance is to inspect files. Use contextless coverage when no durable human context exists.

## Build metadata and entrypoint

Build metadata records timestamp/version/module/ignore provenance without becoming ordinary read-path context. The short agent entrypoint points to `edc-context/index.md` for routing/invariants/coupling and `edc-context/manifest.json` as the authoritative routing/policy contract. It states the runtime mode and does not duplicate the index.

## Output discipline

Write only coordinator-declared staged outputs. Do not write canonical `edc-context/`, reports, or root entrypoints directly. Do not finalize the manifest. Do not run doctor or curator. The coordinator validates every staged artifact and promotes only a complete layout.
