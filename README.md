# EDC — Your Every Day Carry Skills

Deep codebase understanding and context-aware code review for AI coding agents. Inspired by [Trail of Bits](https://github.com/trailofbits/skills)' audit methodology, generalized for any language and any codebase.

Works with **Claude Code**, **Cursor**, **Codex**, and **Gemini CLI**.

## What it does

**EDC builds deep architectural context, then uses it to catch things a blind diff review would miss.**

### Build pipeline

Run these entrypoints in order on any codebase:
- Claude Code: `/edc:...`
- Codex: `$edc-...`
- Cursor: installed `edc-run-*` commands

1. `/edc:edc-build` — analyzes every function line-by-line using First Principles, 5 Whys, and 5 Hows. Produces:
   - `.context/context.md` — brief architecture map (actors, flows, invariants, trust boundaries)
   - `.context/{module}.md` — deep per-module analysis
   - `.context/issues.md` — actionable list of all problems found
   - `.context/complexity.md` — bloat, duplication, overengineering audit
   - `.context/full-context.md` — complete monolithic analysis (input to edc-split)

2. `/edc:edc-split` — splits `full-context.md` into per-module files (use after `edc-build` if it produced a monolithic file)

3. `/edc:edc-update` — incremental update from branch diff, so you don't rebuild from scratch on every PR

4. `/edc:edc-audit` — identifies overengineering, code bloat, and duplication by comparing context expectations to actual code

5. `/edc:edc-run-review` — context-aware differential review: blast radius, adversarial modeling, invariant checking, structured report

### Hooks (Claude Code only)

The plugin installs two hooks that run automatically, designed to keep context overhead minimal:

- **SessionStart** — loads `.context/context.md` (the lightweight architecture overview) at the start of every session. The deep per-module files are intentionally not loaded here — the overview is enough to orient the agent without burning tokens on context it may never need.

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

This installs the user-facing Codex skills:
- `$edc-build`
- `$edc-update`
- `$edc-split`
- `$edc-audit`
- `$edc-run-review`

It also installs the shared orchestrator at `~/.edc/scripts/edc-review.sh`.

#### Codex auth with the orchestrator

The orchestrator spawns `codex exec` subprocesses under an isolated
`CODEX_HOME` (a fresh temp dir per run) so pipeline state never collides with
your interactive Codex sessions. That isolation also means the subprocesses
don't inherit your Codex login.

If `codex exec` fails with an auth error inside the pipeline, point the
orchestrator at your real Codex home before invoking the skill:

```bash
export EDC_CODEX_HOME="$HOME/.codex"
```

When `EDC_CODEX_HOME` is set, the orchestrator uses it verbatim (and does not
clean it up).

### Gemini CLI

```bash
curl -fsSL https://raw.githubusercontent.com/almogdepaz/edc/main/install.sh | bash -s gemini
```

## Terminal CLI

Cursor and Codex installs also place a shared terminal wrapper at `~/.edc/scripts/edc`.

```bash
# build or update context in the current repo
~/.edc/scripts/edc build --agent claude
~/.edc/scripts/edc build --agent cursor --force
~/.edc/scripts/edc build --agent codex --focus orchestrator

# run the review pipeline in the current repo
~/.edc/scripts/edc review --agent claude --base main
~/.edc/scripts/edc review --agent cursor HEAD --base main
~/.edc/scripts/edc review --agent codex https://github.com/owner/repo/pull/42
```

Notes:
- `--agent` is mandatory.
- `build` defaults to the current directory if no path is passed.
- `review` delegates to `edc-review.sh`, so it automatically builds or updates `.context/` first when context is missing or stale.
- Claude build requires the EDC Claude plugin/commands to already be installed because it invokes `/edc:edc-build`.

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
| `/edc:edc-run-review` | Differential review using context (PR URL, commit SHA, or diff path) |

### Codex skill equivalents

| Skill | Description |
|-------|-------------|
| `$edc-build` | Full context build (or `--force` to rebuild, `--focus <module>` for one module) |
| `$edc-split` | Split `full-context.md` into per-module `.context/*.md` files |
| `$edc-update` | Incremental update from branch diff (`--base <ref>` to set comparison ref) |
| `$edc-audit` | Bloat, duplication, and overengineering detection |
| `$edc-run-review` | Differential review using context (PR URL, commit SHA, or diff path) |

### `/edc:edc-run-review` invocation examples

```bash
# review a GitHub PR by URL
/edc:edc-run-review https://github.com/owner/repo/pull/42

# review current branch against main (shorthand: implies HEAD)
/edc:edc-run-review --base main

# review current branch against main (explicit form)
/edc:edc-run-review HEAD --base main

# review a specific branch against main
/edc:edc-run-review feature/auth --base main

# review a single commit (defaults to its parent as base)
/edc:edc-run-review abc1234

# review a range of commits
/edc:edc-run-review HEAD --base HEAD~5

# review a pre-generated diff file
/edc:edc-run-review path/to/changes.patch
```

Without `--base`, the target's parent (`<target>^`) is used — this means you review only that commit, not the whole branch. To review a branch against main, always pass `--base main`.

## Repo Structure

```
edc/
  install.sh                         # one-line installer for all agents
  plugins/edc/                       # Claude Code plugin (single source of truth)
    .claude-plugin/plugin.json
    commands/                        # claude slash commands (5 user-facing + 1 internal)
      edc-build.md
      edc-split.md
      edc-update.md
      edc-audit.md
      edc-run-review.md             # user-facing: runs orchestrator
      edc-review.md                  # internal: invoked by orchestrator subprocess
    skills/                          # canonical skill content
      edc-context/                   # generalized from TOB audit-context-building
      edc-review/                    # generalized from TOB differential-review
    hooks/                           # automatic context injection
      hooks.json
      session-start.mjs              # surfaces context on session start
      pretooluse-context-inject.mjs  # injects module context before edits
  agents/                            # agent-specific wrappers
    cursor/                          # Cursor commands + install script
    codex/                           # Codex wrapper skills + AGENTS.md + install script
    gemini/                          # Gemini GEMINI.md + install script
```
