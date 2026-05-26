# EDC — Your Every Day Carry Skills

Deep codebase understanding and context-aware code review for AI coding agents. Inspired by [Trail of Bits](https://github.com/trailofbits/skills)' audit methodology, generalized for any language and any codebase.

Works with **Claude Code**, **Cursor**, **Codex**, and **pi**.

## What it does

EDC builds a persistent map of a codebase — module boundaries, per-module deep analysis, invariants, trust boundaries — then uses that map to do context-aware reviews and audits that a blind diff review would miss.

All commands write to / read from `edc-context/` at the repo root. You only need to **build** once; everything else is on-demand.

### Commands

| Command | When to run it |
|---------|----------------|
| **build** | Once per repo (and after big refactors). Discovers modules and spawns one subagent per module to deeply analyze its files in parallel. Writes `edc-context/{index.md, manifest.json, modules/*.md, reports/*, build/build.json}` plus a short `AGENTS.md` orientation. |
| **update** | Before review/audit if HEAD has moved. Incremental refresh from the branch diff so you don't rebuild from scratch on every PR. (review and audit auto-run this if context is stale.) |
| **review** | On a PR / branch / commit / diff file. Context-aware differential review: blast radius, adversarial modeling, invariant checking. Outputs a structured report. |
| **audit** | Anytime. Compares context expectations against actual code to flag overengineering, bloat, and duplication. |
| **doctor** | When something feels off. Validates the `edc-context/` tree and routing contract. |

### Run it

Every installer (claude, cursor, codex, pi) places a shared terminal wrapper at `~/.edc/scripts/edc` alongside the orchestrator scripts. From any terminal, in the target repo:

```bash
# build or update context in the current repo
edc build  --agent claude
edc build  --agent cursor --force
edc build  --agent codex --focus orchestrator
edc build  --agent codex --ignore 'vendor/**' --ignore 'dist/**'
edc update --agent claude              # incremental refresh after HEAD moves

# run the review pipeline in the current repo
edc review --agent claude --base main
edc review --agent cursor HEAD --base main
edc review --agent codex --pr 42
edc review --agent pi HEAD --base main
edc review --agent codex https://github.com/owner/repo/pull/42
edc review --agent codex HEAD --base main --ignore 'generated/**'

# complexity / bloat / duplication audit
edc audit  --agent claude
edc audit  --agent pi

# runtime-mode toggle (used by Claude Code and pi inject/advisory hooks)
edc mode                # show current mode
edc mode inject         # turn on auto-injection
edc mode advisory       # turn it off

# validate the edc-context/ layout
edc doctor
```

`--agent` selects which CLI (`claude` / `cursor` / `codex` / `pi`) drives the per-module subprocess fanout, and is mandatory for `build` / `update` / `review` / `audit` (not for `mode` or `doctor`). `review` and `audit` auto-build or auto-update `edc-context/` first if it's missing or stale. `build` defaults to the current directory if no path is passed. `--ignore` may be repeated; passing any `--ignore` flag overrides `.edcignore` for that run, otherwise `.edcignore` is read from the repo root.

Claude, Cursor, and Codex expose wrapper commands for build/update/run-review/doctor (for example `/edc:edc-run-review` in Claude Code, `/edc-run-review` in Cursor, `$edc-run-review` in Codex). Pi exposes one interactive `/edc` menu with review/status/build/update/audit/doctor actions. Audit/review methodology is exposed as skills (`edc-audit`, `edc-review`) instead of slash commands. All command wrappers shell out to the same orchestrators under `~/.edc/scripts/`.

### Two runtime modes (Claude Code and pi)

EDC ships two modes for Claude Code and pi, controlled by `policy.defaultMode` in `edc-context/manifest.json`. See [Install → Claude Code](#claude-code) for how to flip them.

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

After building context once in a target repo (`/edc:edc-build`, pi's `/edc` → Build context, or `edc build --agent <agent>`), choose how aggressive context loading should be:

```bash
edc mode               # show the current mode
edc mode advisory      # default — docs only, hooks no-op
edc mode inject        # auto-load context via hooks
```

- **`advisory`** if you want minimum token overhead and prefer to drive context loading via commands/menus (`/edc:edc-run-review`, pi's `/edc`, etc.) or by reading `edc-context/` files yourself.
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

Exposes a single interactive `/edc` menu inside pi (review current branch vs `main`, review status, build, update, audit, doctor). The review action runs in the background; current run status is written to `.git/edc/status` and the current raw review log to `.git/edc/review.log` (one slot, overwritten by the next review). Pi also exposes the human-facing `edc-review` and `edc-audit` skills for ad hoc methodology use; internal build/update/context skills stay hidden from pi autocomplete. Honors `policy.defaultMode` in `edc-context/manifest.json` for advisory/inject — see `agents/pi/README.md`.

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

## Generated files and local state

EDC writes generated context and local runtime state in a few places:

- `edc-context/` — generated per-module deep context written by `edc-build`/`edc-update`; review task IPC lives under `edc-context/review-tasks/`. This directory is disposable: recovery may wipe and rebuild it.
- `AGENTS.md` — short generated orientation pointing agents at `edc-context/`.
- `review-*.md` — consolidated review output.
- `.edc/` — project-local runtime copy used by hooks/extensions when they need deterministic access to orchestrator scripts and private prompt bundles. Global installs also live under `~/.edc/`.
- `.git/edc/status` and `.git/edc/review.log` — pi's current background review status/log. These are git metadata files, not worktree files, and need no `.gitignore` entry.

For repos where you don't want generated EDC artifacts tracked, add:

```
AGENTS.md
edc-context/
review-*.md
.edc/
```

If generated context or review outputs get committed, `edc-review` filters them out of diffs automatically so the tool doesn't review its own output, but you'll still usually want them ignored to keep history clean.

## Commands

| Command | Description |
|---------|-------------|
| `/edc:edc-build` | Full context build (or `--force` to rebuild, `--focus <module>` for one module) |
| `/edc:edc-update` | Incremental update from branch diff (`--base <ref>` to set comparison ref) |
| `/edc:edc-run-review` | Differential review using context (PR number/URL, branch, commit SHA, or diff path) |
| `/edc:edc-doctor` | Diagnoses `edc-context/` layout, flags v1 leftovers / partial v2 state |

### Cursor / Codex / pi equivalents

Cursor and Codex install user-facing wrappers (without the `edc:` prefix). Pi exposes the same workflows through one interactive `/edc` menu instead of separate slash commands.

| Cursor command | Codex command skill | Pi menu action | Description |
|----------------|---------------------|----------------|-------------|
| `/edc-build` | `$edc-build` | Build context | Full context build (or `--force` to rebuild, `--focus <module>` for one module via CLI) |
| `/edc-update` | `$edc-update` | Update context from main | Incremental update from branch diff (`--base <ref>` to set comparison ref) |
| `/edc-run-review` | `$edc-run-review` | Review current branch vs main | Differential review using context. Pi starts this in the background and stores current status/log under `.git/edc/`. |
| `/edc-doctor` | `$edc-doctor` | Doctor / validate context | Diagnoses `edc-context/` layout, flags v1 leftovers / partial v2 state |

### `/edc:edc-run-review` invocation examples

```bash
# review a GitHub PR by number (uses `gh pr diff 42 --name-only`)
/edc:edc-run-review --pr 42

# review a GitHub PR by URL
/edc:edc-run-review https://github.com/owner/repo/pull/42

# review a PR without creating/updating/reading EDC context
/edc:edc-run-review --pr 42 --base main --ignore-context

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

Without `--base`, the target's parent (`<target>^`) is used for git refs — this means you review only that commit, not the whole branch. To review a branch against main, always pass `--base main`. For PR targets, EDC uses `gh pr diff <number-or-url> --name-only`, so `gh` must be installed and authenticated. Use `--ignore-context` to skip context creation/update and forbid reading existing EDC context; use `--no-context-refresh` to skip creation/update but allow existing context if present.

## Repo Structure

```
edc/
  install.sh                           # one-line installer for all agents
  AGENTS.md                            # universal agent entrypoint (orientation)
  .claude-plugin/marketplace.json      # claude plugin marketplace manifest
  plugins/edc/                         # claude plugin + shared orchestrator (single source of truth)
    .claude-plugin/plugin.json
    commands/                          # user-facing slash commands
      edc-build.md
      edc-update.md
      edc-run-review.md                # user-facing: spawns orchestrator
      edc-doctor.md                    # diagnose edc-context/ layout
    skills/                            # user-facing methodology skills
      edc-review/                      # differential review methodology
      edc-audit/                       # bloat / duplication / overengineering methodology
    prompt-bundles/                    # hidden prompt bundles for orchestrators
      edc-module-context-impl/         # per-module context methodology
      edc-build-impl/                  # full-build prompt bundle
      edc-update-impl/                 # incremental-update prompt bundle
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
