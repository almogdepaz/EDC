---
name: edc:review
description: Performs differential review of code changes using codebase context
argument-hint: "<pr-url|commit-sha|diff-path> [--baseline <ref>]"
allowed-tools:
  - Read
  - Write
  - Grep
  - Glob
  - Bash
---

# Differential Review

**Arguments:** $ARGUMENTS

Parse arguments:
1. **Target** (required): PR URL, commit SHA, or diff path
2. **Baseline** (optional): `--baseline <ref>` for comparison reference

Invoke the `differential-review` skill with these arguments for the full workflow.
