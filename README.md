# EDC — Your Every Day Carry Skills

Deep codebase understanding and context-aware code review for AI coding agents. Inspired by [Trail of Bits](https://github.com/trailofbits/skills)' audit methodology, generalized for any language and any codebase.

Works with **Claude Code**, **Cursor**, **Codex**, and **Gemini CLI**.

## What it does

**Build context** analyzes every function in your codebase — line-by-line, block-by-block, with First Principles, 5 Whys, and 5 Hows. Produces:

- `context.md` — brief architecture map (actors, flows, invariants, trust boundaries)
- `.context/{module}.md` — deep per-module analysis
- `.context/issues.md` — actionable list of all problems found
- `.context/complexity.md` — bloat, duplication, overengineering audit
- `.context/full-context.md` — complete monolithic analysis

**Review** uses the context files to catch things a blind diff review would miss: invariant violations, cross-module breakage, regression of known issues.

## Install

### Claude Code

```bash
claude plugins marketplace add almogdepaz/edc
claude plugins install edc@edc
```

### Cursor

```bash
curl -fsSL https://raw.githubusercontent.com/almogdepaz/edc/main/install.sh | bash -s cursor
```

### Codex

```bash
curl -fsSL https://raw.githubusercontent.com/almogdepaz/edc/main/install.sh | bash -s codex
```

### Gemini CLI

```bash
curl -fsSL https://raw.githubusercontent.com/almogdepaz/edc/main/install.sh | bash -s gemini
```

## Skills

Two generalized skills from Trail of Bits:

- **deep-context-building** — ultra-granular code analysis (from `audit-context-building`)
- **differential-review** — structured code review with blast radius, adversarial modeling, and reporting (from `differential-review`)

## Repo Structure

```
edc/
  install.sh                         # one-line installer for all agents
  skills/                            # shared skill content (source of truth)
    deep-context-building/
    differential-review/
  agents/
    claude/                          # Claude Code plugin (marketplace)
    cursor/                          # Cursor skills + commands
    codex/                           # Codex skills + AGENTS.md
    gemini/                          # Gemini CLI skills + GEMINI.md
```
