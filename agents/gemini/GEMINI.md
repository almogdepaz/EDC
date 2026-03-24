# EDC — Every Day Carry Skills

This project uses EDC for deep codebase context and code review.

## Available Skills

- **edc-context** — Ultra-granular line-by-line code analysis. Builds architectural context with invariants, trust boundaries, data flows, and fragility clusters. See `.gemini/skills/edc-context/SKILL.md`.
- **edc-review** — Structured code review with blast radius analysis, adversarial modeling, and comprehensive reporting. See `.gemini/skills/edc-review/SKILL.md`.

## Workflow

### Build context (first time)
Activate the `edc-context` skill. Analyze the full codebase. Write output to `.context/full-context.md`. Then split into `context.md` (overview) + `.context/{module}.md` (per-module) + `.context/issues.md` (problems).

### Update context (on changes)
If `.context/.meta.json` exists, only re-analyze modules with changed files (based on `git diff`).

### Review a PR
Ensure context is fresh (build or update), then activate the `edc-review` skill on the diff.
