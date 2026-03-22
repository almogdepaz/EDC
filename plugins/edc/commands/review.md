---
description: Context-aware code review of a pull request
argument-hint: "[PR number or URL]"
allowed-tools: [Read, Grep, Glob, Bash(gh *), Agent, Write]
---

# Review

**Arguments:** $ARGUMENTS

Perform a context-aware code review of a pull request, using the codebase's `context.md` for deep architectural understanding.

## Step 1 — Ensure context exists

Check if `context.md` exists in the repository root.

If it does NOT exist:
- Inform the user: "No context.md found. Running /build-context first..."
- Run the full /build-context flow (see build-context command) to generate it
- Then continue with step 2

If it DOES exist:
- Continue to step 2

## Step 2 — Load context

Read `context.md` to understand the codebase architecture, invariants, trust boundaries, and key flows.

## Step 3 — Identify PR scope

Use `gh pr view` and `gh pr diff` to:
1. Get the PR description and changed files
2. Identify which modules/areas are affected

## Step 4 — Context-informed review

Launch parallel Sonnet agents to independently review the change, each with the relevant context from context.md:

a. **Agent #1 — Invariant compliance**: Check if the changes violate any invariants documented in context.md. Do the changes maintain the assumptions and postconditions documented for the affected functions?

b. **Agent #2 — Bug scan**: Read the file changes and do a shallow scan for obvious bugs. Focus on large bugs, avoid nitpicks. Use the context.md understanding of data flows and trust boundaries to spot issues a context-free review would miss.

c. **Agent #3 — Historical context**: Read the git blame and history of the modified code. Identify any bugs in light of that historical context.

d. **Agent #4 — Cross-module impact**: Using the cross-function dependencies and workflow reconstructions from context.md, check if the changes could break flows or assumptions in OTHER parts of the codebase that aren't directly modified.

## Step 5 — Confidence scoring

For each issue found in Step 4, launch a parallel Haiku agent to score confidence 0-100:

- **0**: False positive, doesn't stand up to scrutiny, or pre-existing issue.
- **25**: Might be real, but could be false positive. Agent couldn't verify.
- **50**: Verified real issue, but nitpick or unlikely in practice.
- **75**: Verified, very likely real, will impact functionality. Existing approach is insufficient.
- **100**: Absolutely certain, will happen frequently. Evidence directly confirms.

For invariant-related issues, the agent must verify the invariant is actually documented in context.md.

## Step 6 — Filter

Filter out issues with score < 80. If no issues meet this threshold, skip to Step 8 with "no issues found."

## Step 7 — Eligibility re-check

Use a Haiku agent to verify the PR is still open and hasn't been updated since review started.

## Step 8 — Post results

Use `gh pr comment` to post the review. Format:

---

### Code review

Found N issues:

1. <brief description> (context.md invariant: "<quoted invariant>")

<link to file and line with full SHA + line range>

2. <brief description> (bug due to <file and code snippet>)

<link to file and line with full SHA + line range>

Generated with [Claude Code](https://claude.ai/code)

<sub>- If this code review was useful, react with thumbs up. Otherwise, thumbs down.</sub>

---

Or if no issues:

---

### Code review

No issues found. Checked for bugs, invariant compliance, and cross-module impact using context.md.

Generated with [Claude Code](https://claude.ai/code)

---

## False positives to filter

- Pre-existing issues not introduced in this PR
- Something that looks like a bug but is not
- Pedantic nitpicks a senior engineer wouldn't call out
- Issues a linter/typechecker/compiler would catch
- General code quality issues unless documented as invariants in context.md
- Issues on lines the user did not modify
- Changes in functionality that are likely intentional

## Link format

Links MUST use full git SHA + line ranges:
```
https://github.com/owner/repo/blob/[full-sha]/path/file.ext#L[start]-L[end]
```
- Full SHA required (not abbreviated)
- Include at least 1 line of context before and after
- Do NOT use bash interpolation in links — resolve SHA before writing the comment

## Notes

- Do not attempt to build, typecheck, or run tests. These run separately in CI.
- Use `gh` for all GitHub interactions.
- Make a todo list first.
