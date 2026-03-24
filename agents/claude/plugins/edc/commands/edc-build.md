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

Check `HEAD` and context freshness first:
1. Read `git rev-parse HEAD`
2. If `.context/.meta.json` exists, read `lastCommit`
3. If `lastCommit == HEAD`, verify required context files exist (`context.md`, `.context/issues.md`, module files from `.meta.json`)

Routing:

- **If `--force` is passed** → run full build + split + audit
- **If `.meta.json` missing** → run full build + split + audit
- **If `.meta.json` exists and `lastCommit != HEAD`** → run `/edc:edc-update` (incremental update)
- **If `.meta.json` exists and `lastCommit == HEAD` but context files are missing/incomplete** → run full build + split + audit
- **If `.meta.json` exists and `lastCommit == HEAD` and files are complete** → no-op (context already fresh)

Full build + split + audit:
  1. Invoke the `edc-context` skill for the full workflow. Write the complete analysis to `.context/full-context.md`.
  2. Then run `/edc:edc-split` to produce `context.md` + `.context/{module}.md` + `issues.md` + `.meta.json`.
  3. Then run `/edc:edc-audit` to produce `.context/complexity.md`.

Always end with `.context/.meta.json` reflecting current `HEAD`.
