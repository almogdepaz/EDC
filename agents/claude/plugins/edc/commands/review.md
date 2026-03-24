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
- If no `.context/.meta.json` → full build + split + audit-complexity (new repo)
- If `.meta.json` exists → incremental update (existing repo)

## Step 2 — Load known issues

Read `.context/issues.md` and `.context/complexity.md`. During the review, cross-reference changed files against these:
- If a change touches code with a known issue → mention the issue and whether the change fixes, worsens, or ignores it
- If a change introduces a pattern flagged in complexity.md (new wrapper, new dead export, deeper call chain) → flag it

## Step 3 — Review

Invoke the `differential-review` skill with the target and baseline arguments for the full workflow. The skill already integrates with `.context/` files for invariant checking and blast radius — the issues.md and complexity.md cross-references from step 2 are additional context for the review.
