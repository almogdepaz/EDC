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

## Step 1 — Ensure context is fresh

Always run `/edc:edc-build` first before any review analysis.
- Missing `.context/.meta.json` → full context build.
- Existing but stale context → incremental update.
- Existing and current context → no-op verification.

After edc-build, validate freshness:
- Read `.context/.meta.json` and compare `lastCommit` with `git rev-parse HEAD`.
- If mismatched, run `/edc:edc-build --force` and do not start review until aligned.

## Step 2 — Load context to reduce unnecessary search

Read context files first so searches are informed, not exploratory:
- `.context/context.md` — module map, invariants, coupling, trust boundaries
- `.context/issues.md` — known problems to cross-reference
- relevant `.context/{module}.md` files for changed modules — function-level detail, assumptions, call graphs
- `.context/complexity.md` — bloat, dead exports, wrappers

Use this context to inform and scope your searches. Grep is expected — grep without context is wasteful.

During the review, cross-reference changed files against these:
- If a change touches code with a known issue → mention the issue and whether the change fixes, worsens, or ignores it
- If a change introduces a pattern flagged in complexity.md (new wrapper, new dead export, deeper call chain) → flag it

## Step 3 — Fix-completeness check

If the PR claims to fix a pattern (e.g., injection, validation, error handling), grep the codebase for ALL instances of that pattern — not just the changed files. A fix that covers 4/7 call sites is worse than no fix (false sense of security).

## Step 4 — Review

Spawn a **clean subagent** (using the Agent tool) to invoke the `edc:edc-review` skill with the target and baseline arguments. The subagent MUST be a fresh agent with NO access to the current conversation context — this prevents bias from the user's discussion influencing the review findings. Pass the subagent:
- The target (PR URL, commit SHA, or diff)
- The baseline reference
- The path to `.context/` files so it can load them independently

The subagent should have access to: Read, Write, Grep, Glob, Bash, Skill tools.

The report MUST include a "Context Inputs & Compliance" section listing context files consulted, invariants checked (with pass/fail), and search scope.

**CRITICAL — Clean Slate Rule:** The review subagent must NOT inherit the parent conversation. If the user said "I think function X has a bug," the reviewer must not know that — it should find (or not find) the bug independently based on code analysis alone. This is essential for unbiased security review.
