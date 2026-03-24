# EDC — Every Day Carry Skills

This project uses EDC for deep codebase context and code review.

## Available Skills

- **$edc-context** — Ultra-granular line-by-line code analysis. Builds architectural context with invariants, trust boundaries, data flows, and fragility clusters.
- **$edc-review** — Structured code review with blast radius analysis, adversarial modeling, and comprehensive reporting.

## Workflow

### Build context (first time)
Run `$edc-context` on the codebase. Write output to `.context/full-context.md`. Then split into `context.md` (overview) + `.context/{module}.md` (per-module) + `.context/issues.md` (problems).

### Update context (on changes)
If `.context/.meta.json` exists, only re-analyze modules with changed files (based on `git diff`).

### Review a PR
Always refresh context first, then run `$edc-review` on the diff:

1. Read `git rev-parse HEAD` and `.context/.meta.json`.
2. If `.meta.json` is missing, build full context.
3. If `.meta.json` exists but `lastCommit != HEAD`, run incremental context update.
4. Load `.context/context.md`, `.context/issues.md`, and relevant `.context/{module}.md` before broad searching.
5. Use grep/search only to validate targeted hypotheses, scoped to changed files + direct dependencies where possible.
