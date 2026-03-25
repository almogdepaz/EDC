---
name: edc:edc-build
description: Builds or updates deep architectural context for any codebase
argument-hint: "[--force] [--focus <module>]"
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash(git *)
  - Task
  - Write
---

# Build Context

**Arguments:** $ARGUMENTS

Parse arguments:
1. **Force** (optional): `--force` to rebuild from scratch even if context exists
2. **Focus** (optional): `--focus <module>` for specific module analysis

## Routing

Check if `.context/.meta.json` exists AND `--force` was NOT passed:

- **If `.meta.json` exists** → run `/edc:edc-update` (incremental update based on branch changes)
- **If `.meta.json` does NOT exist** (or `--force`) → run full build + split + audit:
  1. Invoke the `edc-context` skill for the full workflow. Write the complete analysis to `.context/full-context.md`.
  2. Then run `/edc:edc-split` to produce `context.md` + `.context/{module}.md` + `issues.md` + `.meta.json`.
  3. Then run `/edc:edc-audit` to produce `.context/complexity.md`.
