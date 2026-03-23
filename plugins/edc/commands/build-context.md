---
name: edc:build-context
description: Builds deep architectural context for any codebase
argument-hint: "[--focus <module>]"
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - Task
  - Write
---

# Build Context

**Arguments:** $ARGUMENTS

Parse arguments:
1. **Focus** (optional): `--focus <module>` for specific module analysis

Invoke the `deep-context-building` skill with these arguments for the full workflow. Write the complete analysis to `.context/full-context.md`.
