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

## Step 1 — Ensure context exists

Run `/edc:build-context` first. This will:
- If no `.context/.meta.json` → full build + split (new repo)
- If `.meta.json` exists → incremental update (existing repo)

## Step 2 — Review

Invoke the `differential-review` skill with the target and baseline arguments for the full workflow.
