# EDC — Your Every Day Carry Skills

Deep codebase understanding and context-aware code review for AI coding agents. Inspired by [Trail of Bits](https://github.com/trailofbits/skills)' audit methodology, generalized for any language and any codebase.

Works with **Claude Code**, **Cursor**, **Codex**, and **pi**.

## What it does

**EDC builds deep architectural context, then uses it to catch things a blind diff review would miss.**

### Build pipeline

Run these entrypoints in order on any codebase:
- Claude Code: `/edc:edc-build`, `/edc:edc-update`, `/edc:edc-audit`, `/edc:edc-run-review`, `/edc:edc-doctor`
- Cursor: `/edc-build`, `/edc-update`, `/edc-audit`, `/edc-review`
- Codex: `$edc-build`, `$edc-update`, `$edc-audit`, `$edc-review`
- pi: `/edc-build`, `/edc-update`, `/edc-audit`, `/edc-run-review`, `/edc-doctor`, `/edc-review`

All four agents also get a shared terminal CLI at `~/.edc/scripts/edc` (`edc build|update|review|audit|mode|doctor`).

1. **build** — discovers modules, then spawns one subagent per module to deeply analyze its files (function-level: First Principles, 5 Whys, 5 Hows) in parallel. Produces:
   - `AGENTS.md` — short runtime orientation
   - `edc-context/index.md` — brief architecture map (actors, flows, invariants, trust boundaries)
   - `edc-context/manifest.json` — routing and policy contract
   - `edc-context/modules/<name>.md` — deep per-module analysis
   - `edc-context/reports/issues.md` — actionable list of all problems found
   - `edc-context/reports/complexity.md` — bloat, duplication, overengineering audit
   - `edc-context/build/build.json` — build provenance (timestamp, version, source commit, modules emitted)

2. **update** — incremental update from branch diff, so you don't rebuild from scratch on every PR

3. **audit** — identifies overengineering, code bloat, and duplication by comparing context expectations to actual code

4. **review** — context-aware differential review: blast radius, adversarial modeling, invariant checking, structured report

### Two runtime modes (Claude Code)

EDC ships two modes for Claude Code, controlled by `policy.defaultMode` in `edc-context/manifest.json`. See [Install → Claude Code](#claude-code) for how to flip them.

- **`advisory`** (default) — pure docs. The plugin installs hooks but they no-op. The agent reads `edc-context/index.md` and the relevant `edc-context/modules/<name>.md` on its own (slash commands prompt for it; otherwise it's the user's call). Zero token overhead per tool call.
- **`inject`** — auto-loaded context. Two hooks fire:
  - `SessionStart` surfaces `edc-context/index.md` (lightweight architecture map) on session boot
  - `PreToolUse` resolves the file you're about to `Edit`/`Write`/`Bash` to its module via `manifest.json` and injects `edc-context/modules/<name>.md` once per session (deduplicated)

  Net effect in inject: the agent always has the overview, gets deep module context exactly when it touches a file in that module, and never loads the full project context.

Cursor and Codex don't have a hook system, so they're docs-only regardless of the flag. Pi has an event-based extension API and supports both modes (same `edc-context/manifest.json` toggle as Claude Code).

## Install

### Claude Code

Recommended — install via the plugin marketplace:

```bash
claude plugin marketplace add almogdepaz/edc
claude plugin install edc@edc
```

Alternative — install the runtime directly from a clone:

```bash
bash install.sh --agent claude
```

Both paths install the plugin (slash commands + hooks + skills) and the terminal CLI (`~/.edc/scripts/edc`).

#### Picking a mode

After running `/edc:edc-build` once in a target repo, choose how aggressive context loading should be:

```bash
edc mode               # show the current mode
edc mode advisory      # default — docs only, hooks no-op
edc mode inject        # auto-load context via hooks
```

- **`advisory`** if you want minimum token overhead and prefer to drive context loading via slash commands (`/edc:edc-run-review` etc.) or by reading `edc-context/` files yourself.
- **`inject`** if you want the agent to always have the architecture overview at session start and to automatically receive the relevant module doc the first time it touches a file in each module during the session.

The flag is a `jq` write to `edc-context/manifest.json`; flip it as often as you like. Rebuilds preserve the chosen mode.

### Cursor

```bash
# remote one-liner
curl -fsSL https://raw.githubusercontent.com/almogdepaz/edc/main/install.sh | bash -s cursor

# or from a local checkout
bash install.sh --agent cursor
```

### Codex

```bash
# remote one-liner
curl -fsSL https://raw.githubusercontent.com/almogdepaz/edc/main/install.sh | bash -s codex

# or from a local checkout
bash install.sh --agent codex
```

### pi

```bash
# direct (pi clones the repo and registers the extension)
pi install git:github.com/almogdepaz/edc

# or via the unified installer
bash install.sh --agent pi
```

Exposes `/edc-build`, `/edc-update`, `/edc-audit`, `/edc-run-review`, `/edc-doctor`, `/edc-review` inside pi. Honors `policy.defaultMode` in `edc-context/manifest.json` for advisory/inject — see `agents/pi/README.md`.

All installers (claude, cursor, codex, pi) also drop the shared terminal CLI and orchestrator scripts under `~/.edc/scripts/` so `edc build|review|audit|update|mode|doctor` works from any shell.

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

## Terminal CLI

Every installer (claude, cursor, codex, pi) places a shared terminal wrapper at `~/.edc/scripts/edc` alongside the orchestrator scripts.

```bash
# build or update context in the current repo
~/.edc/scripts/edc build --agent claude
~/.edc/scripts/edc build --agent cursor --force
~/.edc/scripts/edc build --agent codex --focus orchestrator
~/.edc/scripts/edc build --agent codex --ignore 'vendor/**' --ignore 'dist/**'

# run the review pipeline in the current repo
~/.edc/scripts/edc review --agent claude --base main
~/.edc/scripts/edc review --agent cursor HEAD --base main
~/.edc/scripts/edc review --agent codex https://github.com/owner/repo/pull/42
~/.edc/scripts/edc review --agent codex HEAD --base main --ignore 'generated/**'

# claude runtime-mode toggle (no-op for cursor/codex)
~/.edc/scripts/edc mode                # show current mode
~/.edc/scripts/edc mode inject         # turn on auto-injection
~/.edc/scripts/edc mode advisory       # turn it off

# validate the edc-context/ layout
~/.edc/scripts/edc doctor
```

Notes:
- `--agent` is mandatory for `build` and `review` (not for `mode` or `doctor`).
- `build` defaults to the current directory if no path is passed.
- `--ignore` may be repeated. If any `--ignore` flags are passed, EDC ignores `.edcignore` for that run.
- Otherwise, if `.edcignore` exists in the repo root, EDC reads non-empty, non-comment lines from it as repo-relative glob patterns.
- `review` delegates to `edc-review.sh`, so it automatically builds or updates `edc-context/` first when context is missing or stale.

## Two Independent Install Paths

The terminal CLI and the claude plugin are independent. You can install
either, both, or neither — they don't depend on each other.

- **CLI only** (`bash install.sh --agent claude`): installs `~/.edc/scripts/`
  + `~/.edc/skills/`. The `edc` command works in any repo. Subprocess agents
  (claude/cursor/codex) are spawned by the orchestrator and given the skill
  content directly via stdin — no slash-command system required.
- **Claude plugin** (`claude plugin marketplace add almogdepaz/edc
  && claude plugin install edc@edc`): adds slash commands
  (`/edc:edc-build`, etc.) and session/pre-edit hooks for use *inside*
  interactive claude. The plugin still calls into `~/.edc/scripts/` for the
  heavy orchestrator logic, so you'll want the CLI installed as well if you
  use the plugin's `/edc:edc-run-review` command.
- **Both**: install both for full coverage. The CLI handles `edc review`
  from the terminal, the plugin handles slash commands inside an interactive
  claude session.

## Gitignore

EDC writes scratch state into your repo. Add these to your target repo's `.gitignore`:

```
edc-context/
review-tasks/
review-*.md
```

- `edc-context/` — per-module deep context written by `edc-build`/`edc-update`
- `review-tasks/` — per-module task files and reports from `edc-review`
- `review-*.md` — consolidated review output

If these get committed, `edc-review` filters them out of diffs automatically so the tool doesn't review its own output, but you'll still want them ignored to keep your git history clean.

## Commands

| Command | Description |
|---------|-------------|
| `/edc:edc-build` | Full context build (or `--force` to rebuild, `--focus <module>` for one module) |
| `/edc:edc-update` | Incremental update from branch diff (`--base <ref>` to set comparison ref) |
| `/edc:edc-audit` | Bloat, duplication, and overengineering detection |
| `/edc:edc-run-review` | Differential review using context (PR URL, commit SHA, or diff path) |
| `/edc:edc-doctor` | Diagnoses `edc-context/` layout, flags v1 leftovers / partial v2 state |

### Cursor / Codex skill equivalents

Cursor and Codex install the same four wrappers (just without the `edc:` prefix and without `doctor`/`review` internals):

| Cursor command | Codex skill | Description |
|----------------|-------------|-------------|
| `/edc-build` | `$edc-build` | Full context build (or `--force` to rebuild, `--focus <module>` for one module) |
| `/edc-update` | `$edc-update` | Incremental update from branch diff (`--base <ref>` to set comparison ref) |
| `/edc-audit` | `$edc-audit` | Bloat, duplication, and overengineering detection |
| `/edc-review` | `$edc-review` | Differential review using context (PR URL, commit SHA, or diff path) |

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
  install.sh                           # one-line installer for all agents
  AGENTS.md                            # universal agent entrypoint (orientation)
  .claude-plugin/marketplace.json      # claude plugin marketplace manifest
  plugins/edc/                         # claude plugin + shared orchestrator (single source of truth)
    .claude-plugin/plugin.json
    commands/                          # claude slash commands
      edc-build.md
      edc-update.md
      edc-audit.md
      edc-run-review.md                # user-facing: spawns orchestrator
      edc-review.md                    # internal: per-module review subprocess
      edc-doctor.md                    # diagnose edc-context/ layout
    skills/                            # canonical skill content (also installed for cursor/codex)
      edc-context/                     # per-module deep analysis (TOB-derived)
      edc-build-impl/                  # full-build orchestrator (v2 module fanout)
      edc-update-impl/                 # incremental update from branch diff
      edc-audit-impl/                  # bloat / duplication / overengineering audit
      edc-review-impl/                 # differential review (TOB-derived)
    scripts/                           # everything that ships to ~/.edc/scripts/
      edc                              # terminal CLI (build / update / review / audit / mode / doctor)
      edc-build.sh, edc-update.sh, edc-audit.sh, edc-review.sh   # action orchestrators
      edc-doctor.sh                    # context-tree validator
      edc-lib.sh                       # sourced helpers (paths, runtime, spawn, prompt resolution)
      edc-route.sh, edc-manifest.sh    # path -> module routing + manifest IO
      edc-assert-fresh.sh              # freshness gate (sourceCommit vs HEAD)
      edc-clean-slate.sh               # detects v1 leftovers, wipes for clean v2 build
      edc-recover-context.sh           # auto-rebuild/update when context is stale
      edc-build-plan.sh                # deterministic per-module task planner (jq)
    hooks/                             # claude-only: automatic context injection (advisory|inject)
      hooks.json
      session-start.mjs                # surfaces edc-context/index.md on session start
      pretooluse-context-inject.mjs    # injects module context before Edit/Write/Bash
      lib/                             # shared mjs helpers (paths, platform, route)
  agents/
    pi/                                # pi extension (index.mjs + install script)
```

Cursor and Codex have no in-repo source files. Their slash-command wrappers are
emitted directly by `install.sh` (see `write_cursor_commands` / `write_codex_skills`)
into `~/.cursor/commands/` and `~/.codex/skills/` respectively, and delegate to
the orchestrators under `~/.edc/scripts/`.
