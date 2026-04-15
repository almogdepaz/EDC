# EDC — Your Every Day Carry Skills

Deep codebase understanding and context-aware code review for AI coding agents. Inspired by [Trail of Bits](https://github.com/trailofbits/skills)' audit methodology, generalized for any language and any codebase.

Works with **Claude Code**, **Cursor**, **Codex**, and **Gemini CLI**.

## What it does

**EDC builds deep architectural context, then uses it to catch things a blind diff review would miss.**

### Build pipeline

Run these in order on any codebase:

1. `/edc:edc-build` — analyzes every function line-by-line using First Principles, 5 Whys, and 5 Hows. Produces:
   - `context.md` — brief architecture map (actors, flows, invariants, trust boundaries)
   - `.context/{module}.md` — deep per-module analysis
   - `.context/issues.md` — actionable list of all problems found
   - `.context/complexity.md` — bloat, duplication, overengineering audit
   - `.context/full-context.md` — complete monolithic analysis (input to edc-split)

2. `/edc:edc-split` — splits `full-context.md` into per-module files (use after `edc-build` if it produced a monolithic file)

3. `/edc:edc-update` — incremental update from branch diff, so you don't rebuild from scratch on every PR

4. `/edc:edc-audit` — identifies overengineering, code bloat, and duplication by comparing context expectations to actual code

5. `/edc:edc-review` — context-aware differential review: blast radius, adversarial modeling, invariant checking, structured report

### Hooks (Claude Code only)

The plugin installs two hooks that run automatically:

- **SessionStart** — on every new session, surfaces any existing `.context/` files so the agent starts context-aware
- **PreToolUse** — before every `Edit`, `Write`, or `Bash` call, injects relevant module context so the agent never edits blind

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

## Commands

| Command | Description |
|---------|-------------|
| `/edc:edc-build` | Full context build (or `--force` to rebuild, `--focus <module>` for one module) |
| `/edc:edc-split` | Split `full-context.md` into per-module `.context/*.md` files |
| `/edc:edc-update` | Incremental update from branch diff (`--base <ref>` to set comparison ref) |
| `/edc:edc-audit` | Bloat, duplication, and overengineering detection |
| `/edc:edc-review` | Differential review using context (PR URL, commit SHA, or diff path) |

## Repo Structure

```
edc/
  install.sh                         # one-line installer for all agents
  plugins/edc/                       # Claude Code plugin (single source of truth)
    .claude-plugin/plugin.json
    commands/                        # claude slash commands (5 total)
      edc-build.md
      edc-split.md
      edc-update.md
      edc-audit.md
      edc-review.md
    skills/                          # canonical skill content
      edc-context/                   # generalized from TOB audit-context-building
      edc-review/                    # generalized from TOB differential-review
    hooks/                           # automatic context injection
      hooks.json
      session-start.mjs              # surfaces context on session start
      pretooluse-context-inject.mjs  # injects module context before edits
  agents/                            # agent-specific wrappers
    cursor/                          # Cursor commands + install script
    codex/                           # Codex AGENTS.md + install script
    gemini/                          # Gemini GEMINI.md + install script
```
