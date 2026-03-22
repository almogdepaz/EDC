---
description: Context-aware code review of a pull request
argument-hint: "[PR number or URL]"
allowed-tools: [Read, Grep, Glob, Bash(gh *), Agent, Write]
---

# Review

**Arguments:** $ARGUMENTS

Perform a context-aware code review of a pull request, using the codebase's `context.md` for deep architectural understanding.

## Step 1 — Ensure context exists

Check if `context.md` AND `.context/` directory exist in the repository root.

If either does NOT exist:
- Inform the user: "No context found. Running /build-context first..."
- Run the full /build-context flow (see build-context command) to generate context.md + .context/*.md
- Then continue with step 2

If both exist:
- Continue to step 2

## Step 2 — Load architecture context

Read `context.md` to understand the codebase architecture, module map, key flows, and trust boundaries. Do NOT load any `.context/*.md` files yet — those are loaded selectively in Step 3.

## Step 3 — Identify PR scope and load relevant deep context

Use `gh pr view` and `gh pr diff` to:
1. Get the PR description and changed files
2. Identify which modules are affected by mapping changed file paths to the Module Map in context.md
3. Load ONLY the `.context/{module}.md` files for affected modules — do not load unrelated modules

## Step 4 — Context-informed review

Launch parallel Sonnet agents to independently review the change. Each agent receives: the PR diff, the architecture overview from context.md, AND the relevant `.context/*.md` files for affected modules.

**Critical: how agents use context files vs code**

Context files contain ONLY hard-to-discover insights (invariants, coupling, implicit contracts, gotchas). They do NOT contain function signatures, type definitions, or surface-level descriptions — agents must READ THE ACTUAL CODE for that. The context files tell agents what to WATCH FOR, not what the code DOES.

- To understand what a function does → `Read` the source file
- To understand what invariants it must maintain → check `.context/*.md`
- To understand what other modules it's coupled to → check `.context/*.md`
- To understand its signature and types → `Read` / `Grep` the code
- To understand what breaks if you change it → check `.context/*.md`

a. **Agent #1 — Invariant compliance**: Read the changed code directly. Then check `.context/*.md` for invariants and implicit contracts affecting those functions. Does the change violate any documented invariant? Does it break an assumption that downstream code relies on?

b. **Agent #2 — Bug scan**: Read the changed files directly. Do a scan for bugs, using context files for what a surface read would miss: non-obvious data flows, trust boundary assumptions, stateful gotchas documented in fragility notes.

c. **Agent #3 — Historical context**: Read the git blame and history of the modified code. Identify any bugs in light of that historical context.

d. **Agent #4 — Cross-module impact**: Using the cross-module coupling sections from context.md and `.context/*.md`, identify modules that could be affected by this change even though they aren't directly modified. READ THE ACTUAL CODE of those coupled modules to verify — don't just report what the context file says might break.

## Step 5 — Confidence scoring

For each issue found in Step 4, launch a parallel Haiku agent to score confidence 0-100:

- **0**: False positive, doesn't stand up to scrutiny, or pre-existing issue.
- **25**: Might be real, but could be false positive. Agent couldn't verify.
- **50**: Verified real issue, but nitpick or unlikely in practice.
- **75**: Verified, very likely real, will impact functionality. Existing approach is insufficient.
- **100**: Absolutely certain, will happen frequently. Evidence directly confirms.

For invariant-related issues, the agent must verify the invariant is actually documented in the relevant `.context/*.md` file.

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
