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

The plugin installs two hooks that run automatically, designed to keep context overhead minimal:

- **SessionStart** — loads `context.md` (the lightweight architecture overview) at the start of every session. The deep per-module files are intentionally not loaded here — the overview is enough to orient the agent without burning tokens on context it may never need.

- **PreToolUse** — before every `Edit`, `Write`, or `Bash` call, resolves the target file to its module via `.context/.meta.json`, then injects only that module's `.context/{module}.md`. Each module is injected at most once per session (deduplicated), so repeated edits to the same module don't re-inject.

The result: the agent always has the architecture overview, gets deep module context exactly when it needs it, and never loads the full project context.

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

## Gitignore

EDC writes scratch state into your repo. Add these to your target repo's `.gitignore`:

```
.context/
review-tasks/
review-*.md
```

- `.context/` — per-module deep context written by `edc-build`/`edc-update`
- `review-tasks/` — per-module task files and reports from `edc-review`
- `review-*.md` — consolidated review output

If these get committed, `edc-review` filters them out of diffs automatically so the tool doesn't review its own output, but you'll still want them ignored to keep your git history clean.

## Commands

| Command | Description |
|---------|-------------|
| `/edc:edc-build` | Full context build (or `--force` to rebuild, `--focus <module>` for one module) |
| `/edc:edc-split` | Split `full-context.md` into per-module `.context/*.md` files |
| `/edc:edc-update` | Incremental update from branch diff (`--base <ref>` to set comparison ref) |
| `/edc:edc-audit` | Bloat, duplication, and overengineering detection |
| `/edc:edc-review` | Differential review using context (PR URL, commit SHA, or diff path) |

### `/edc:edc-review` invocation examples

```bash
# review a GitHub PR by URL
/edc:edc-review https://github.com/owner/repo/pull/42

# review current branch against main (full branch diff)
/edc:edc-review HEAD --baseline main

# review a specific branch against main
/edc:edc-review feature/auth --baseline main

# review a single commit (defaults to its parent as baseline)
/edc:edc-review abc1234

# review a range of commits
/edc:edc-review HEAD --baseline HEAD~5

# review a pre-generated diff file
/edc:edc-review path/to/changes.patch
```

Without `--baseline`, the target's parent (`<target>^`) is used — this means you review only that commit, not the whole branch. To review a branch against main, always pass `--baseline main`.

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
