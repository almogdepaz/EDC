---
description: Builds or updates deep architectural context for the codebase
---

# Build Context

1. Read current commit: `git rev-parse HEAD`.
2. Check for `.context/.meta.json` and parse `lastCommit`.

Routing:

- **If `.context/.meta.json` is missing** -> Full build:
  1. Invoke `edc-context` skill for full workflow -> `.context/full-context.md`
  2. Split into `context.md` + `.context/{module}.md` + `.context/issues.md` + `.context/.meta.json`
  3. Run complexity audit -> `.context/complexity.md`
- **If `.meta.json` exists and `lastCommit` != `HEAD`** -> Incremental update:
  1. Detect changed files with `git diff` from base.
  2. Re-analyze affected modules only.
  3. Update `.context/{module}.md`, `.context/issues.md`, `context.md`, and `.context/.meta.json`.
- **If `.meta.json` exists and `lastCommit` == `HEAD`** -> Verify context completeness only:
  - Ensure `context.md`, `.context/issues.md`, and module files referenced by `.meta.json` exist.
  - If missing/incomplete, run full build.

Always finish with `.context/.meta.json` updated to current `HEAD`.
