---
description: Builds or updates deep architectural context for the codebase
---

# Build Context

Check if `.context/.meta.json` exists:

- **If exists** → Incrementally update context based on branch changes. Detect changed files with `git diff`, re-analyze affected modules, update `.context/{module}.md`, `issues.md`, and `context.md`.
- **If not exists** → Full build:
  1. Invoke the `deep-context-building` skill for the full workflow. Write complete analysis to `.context/full-context.md`.
  2. Split into `context.md` (architecture map) + `.context/{module}.md` (per-module) + `.context/issues.md` (all problems) + `.context/.meta.json` (metadata).
