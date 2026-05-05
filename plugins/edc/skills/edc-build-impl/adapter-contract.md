# Adapter Contract

This document defines the runtime contract every EDC adapter must implement against the v2 context layout.

## Shared Inputs

- `AGENTS.md`: short startup orientation for humans and runtimes.
- `.context/index.md`: lightweight architecture overview loaded at session start or on demand.
- `.context/manifest.json`: authoritative routing and policy contract.
- `.context/modules/<name>.md`: deep per-module context selected by manifest routing.

## Advisory Mode

- The adapter MAY surface `AGENTS.md` and `.context/index.md`, but MUST NOT auto-inject module docs on tool use.
- Review/build entrypoints still use `.context/manifest.json` as the source of truth for report paths and freshness checks.
- Missing hook support is acceptable because advisory mode is documentation-only.
- Failure mode: if advisory is requested but the adapter cannot even expose the docs, it must fail loudly.

## Inject Mode

- The adapter MUST discover `.context/manifest.json` before guarded operations.
- Session-start behavior loads `.context/index.md`.
- Pre-tool behavior resolves the target file through the shared router and injects `.context/modules/<name>.md`.
- If manifest routing is missing, stale, ambiguous, or points to a missing module doc, the adapter must fail loudly or surface a warning instead of silently injecting the wrong file.

## Routing Rules

- Adapters MUST treat `.context/manifest.json` as the only routing contract.
- Target file resolution uses `plugins/edc/scripts/edc-route.sh`.
- Ambiguous matches are hard failures.
- Unmatched files follow `policy.unmatchedPathPolicy`.

## Mode-Specific Failure Surface

- `advisory`: best-effort docs only, no hook registration.
- `inject`: hook/runtime registration required; missing hook plumbing is an implementation bug.
- Unimplemented agent/mode pairs MUST exit with `edc: <agent>/<mode> not yet implemented`.
