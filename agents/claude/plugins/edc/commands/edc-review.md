---
name: edc:edc-review
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

## Step 1 — Ensure context is fresh (mandatory)

Always run `/edc:edc-build` before any review analysis. This must:
- Build if `.context/.meta.json` is missing.
- Incrementally update if context exists but is stale.
- No-op only when context is already current and complete.

After running `/edc:edc-build`, validate freshness:
1. Read `git rev-parse HEAD`
2. Read `.context/.meta.json` and compare `lastCommit`
3. If mismatch or required context files are missing, run `/edc:edc-build` again (or `--force`) and do not continue until aligned.

## Step 2 — Load known issues

Load context files before broad search:
1. `.context/context.md`
2. `.context/issues.md`
3. relevant `.context/{module}.md` files
4. `.context/complexity.md`

During the review, cross-reference changed files against these:
- If a change touches code with a known issue → mention the issue and whether the change fixes, worsens, or ignores it
- If a change introduces a pattern flagged in complexity.md (new wrapper, new dead export, deeper call chain) → flag it
- Use grep/search only to validate specific hypotheses, scoped to changed files + direct dependencies where possible.

## Step 3 — Review

Invoke the `edc-review` skill with the target and baseline arguments for the full workflow. The skill already integrates with `.context/` files for invariant checking and blast radius — the issues.md and complexity.md cross-references from step 2 are additional context for the review.
