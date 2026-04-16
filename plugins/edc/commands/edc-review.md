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
  - Agent
---

# Differential Review

**Arguments:** $ARGUMENTS

Parse arguments:
1. **Target** (required): PR URL, commit SHA, or diff path
2. **Baseline** (optional): `--baseline <ref>` for comparison reference

---

## Step 1 — Context gate (hard conditional, no exceptions)

Run: `git rev-parse HEAD` → store as CURRENT_COMMIT.

Read `.context/.meta.json`. Apply exactly one branch:

| Condition | Action | Rule |
|-----------|--------|------|
| `.context/.meta.json` does not exist | Use Skill tool to invoke `edc:edc-build`. Wait for completion. | Do NOT proceed until context is built. |
| `lastCommit` in `.meta.json` != CURRENT_COMMIT | Use Skill tool to invoke `edc:edc-update`. Wait for completion. | Do NOT proceed until update completes. |
| `lastCommit` == CURRENT_COMMIT | Context is fresh. Proceed immediately. | Do NOT run any build or update. |

You MUST use the Skill tool for edc-build and edc-update — do not paraphrase or inline their logic.

---

## Step 2 — Load top-level context

Read these files (they exist after Step 1):
- `.context/context.md` — module map, invariants, coupling, trust boundaries
- `.context/issues.md` — known problems (read if exists)

Extract the **module map** from `context.md`: the table or section that maps directories/files to named modules.

Store the full text of `.context/context.md` — you will pass it verbatim to reviewing subagents.

---

## Step 3 — Identify changed files and group by module

Get the diff for the target:
- PR URL → `gh pr diff <url> --name-only`
- Commit SHA → `git diff <sha>^..<sha> --name-only`
- Diff path → read the file, extract changed file paths

Map each changed file to its module using the module map from Step 2.

Group files by module. Each group becomes one reviewing subagent in Step 4.

If a file does not map to any named module, group it as module `"root"`.

---

## Step 4 — Spawn reviewing subagents (one per module)

For each module group, spawn one subagent using the Agent tool.

Pass the following prompt VERBATIM — fill in the placeholders marked with `{}`, do not paraphrase, summarize, or add your own review logic:

---

```
You are a differential code reviewer. Your ONLY job is to invoke the edc-review skill using the Skill tool.

DO NOT write your own review.
DO NOT summarize what the review would find.
DO NOT reproduce the skill's methodology inline.
USE THE SKILL TOOL to invoke `edc:edc-review`.

Inputs to pass to the skill:
- Target: {TARGET}
- Baseline: {BASELINE}  ← omit this line entirely if no baseline was provided
- Module under review: {MODULE_NAME}
- Files to review: {COMMA_SEPARATED_FILE_LIST}

Context to pass to the skill:

<top-level-context>
{FULL_TEXT_OF_CONTEXT_MD}
</top-level-context>

<issues>
{FULL_TEXT_OF_ISSUES_MD_OR_"No issues.md found"}
</issues>

Before invoking the skill, also read `.context/{MODULE_NAME}.md` yourself and include its full text
as additional context when calling the skill. If that file does not exist, note that and proceed.

After the skill completes, return its full report output — do not truncate or summarize it.
```

---

## Step 5 — Consolidate reports

After all subagents complete, write a single file: `review-{TARGET_SHORT}.md`

Structure:
1. Header: target, baseline, date, modules reviewed
2. One section per module, containing that subagent's full report
3. Summary section: cross-module findings, invariant violations that span modules, overall risk rating

Do not editorialize or re-summarize individual findings — include them in full.
