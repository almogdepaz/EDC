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

Check if `.context/.meta.json` exists AND `--force` was NOT passed:

- **If `.meta.json` exists** → run `/edc:edc-update` (incremental update based on branch changes)
- **If `.meta.json` does NOT exist** (or `--force`) → run full build + split + audit:
  1. Spawn a **clean subagent** (using the Agent tool) to invoke the `edc:edc-context` skill (NOT `audit-context-building` — that is a different plugin). The subagent MUST be a fresh agent with NO access to the current conversation context — this prevents bias from the user's discussion influencing the analysis. Pass the subagent a prompt that says which files/modules to analyze and where to write the output (`.context/full-context.md`). The subagent should have access to: Read, Grep, Glob, Write, Bash, Skill tools.
  2. Then run `/edc:edc-split` to produce `context.md` + `.context/{module}.md` + `issues.md` + `.meta.json`.
  3. Then run `/edc:edc-audit` to produce `.context/complexity.md`.

**CRITICAL — Clean Slate Rule:** All analysis (edc-context, edc-review, edc-audit) MUST run in subagents that do NOT inherit the parent conversation. This ensures findings are based purely on code analysis, not influenced by what the user said or what files were previously discussed. The subagent sees only: the code, the skill instructions, and the task prompt. Nothing else.

## Post-Build: Agent Snippets

After all context files are generated, update agent instruction files for non-Claude agents:

1. If `.cursorrules` exists AND does not already contain `## Codebase Context (EDC)`, append:

```
## Codebase Context (EDC)

This project has deep architectural context in `.context/`.

Before modifying code:
1. Read `context.md` for architecture overview and module map
2. Find the relevant module in `.context/.meta.json` (modules → files mapping)
3. Read `.context/{module}.md` for function-level analysis, invariants, and assumptions
4. Check `.context/issues.md` for known problems in the area you're touching

Before code review:
1. Read `.context/issues.md` and `.context/complexity.md`
2. Cross-reference changes against documented invariants in the relevant module context
```

2. If `AGENTS.md` exists AND does not already contain `## Codebase Context (EDC)`, append:

```
## Codebase Context (EDC)

Deep architectural context is available in `.context/`. Read `context.md` first for the module map, then `.context/{module}.md` for the module you're working in. Check `.context/issues.md` before making changes.
```

3. Do NOT create these files if they don't already exist — only append to existing ones.
