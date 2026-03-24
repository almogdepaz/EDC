# EDC — Your Every Day Carry Skills

Deep codebase understanding and context-aware code review for AI coding agents. Inspired by [Trail of Bits](https://github.com/trailofbits/skills)' audit methodology, generalized for any language and any codebase.

Works with **Claude Code**, **Cursor**, **Codex**, and **Gemini CLI**.

## What it does

**Build context** analyzes every function in your codebase — line-by-line, block-by-block, with First Principles, 5 Whys, and 5 Hows. Produces:

- `context.md` — brief architecture map (actors, flows, invariants, trust boundaries)
- `.context/{module}.md` — deep per-module analysis
- `.context/issues.md` — actionable list of all problems found
- `.context/full-context.md` — complete monolithic analysis
- `.context/.meta.json` — metadata for incremental updates

**Review** uses the context files to catch things a blind diff review would miss: invariant violations, cross-module breakage, regression of known issues.

## Install

### Claude Code

```bash
claude plugins marketplace add almogdepaz/edc
claude plugins install edc@edc
```

Commands: `/edc:build-context`, `/edc:review <pr>`

### Cursor

```bash
git clone https://github.com/almogdepaz/edc.git
cd edc && bash agents/cursor/install.sh /path/to/your/project
```

Copies skills to `.cursor/skills/` and commands to `.cursor/commands/`.

### Codex

```bash
git clone https://github.com/almogdepaz/edc.git
cd edc && bash agents/codex/install.sh /path/to/your/project
```

Copies skills to `.codex/skills/`. Use `$deep-context-building` and `$differential-review`.

For global install: `bash agents/codex/install.sh --global`

### Gemini CLI

```bash
git clone https://github.com/almogdepaz/edc.git
cd edc && bash agents/gemini/install.sh /path/to/your/project
```

Copies skills to `.gemini/skills/`.

For global install: `bash agents/gemini/install.sh --global`

## Skills

Two generalized skills from Trail of Bits:

- **deep-context-building** — ultra-granular code analysis (from `audit-context-building`)
- **differential-review** — structured code review with blast radius, adversarial modeling, and reporting (from `differential-review`)

## Repo Structure

```
edc/
  skills/                          # shared skill content (source of truth)
    deep-context-building/
    differential-review/
  agents/
    claude/                        # Claude Code plugin
    cursor/                        # Cursor skills + commands
    codex/                         # Codex skills + AGENTS.md
    gemini/                        # Gemini CLI skills + GEMINI.md
```
