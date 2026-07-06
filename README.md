# EDC — Every Day Carry Skills

Repo maps for coding agents.

EDC gives coding agents a local generated repo map before they touch code: module-level paths, boundaries, invariants, assumptions, review notes, trust boundaries, and routing metadata. It builds a persistent `edc-context/` tree, then uses that map for focused reviews, quality review, debugging, and context loading.

Works with **Claude Code**, **Cursor**, **Codex**, and **pi**.

## 30-second start

```bash
pi install npm:@sgtbeatdown/edc
cd your-repo
pi
# run /edc, choose build context, then review all changes
```

First run may write `edc-context/`, `AGENTS.md` or `EDC_AGENTS.md`, local runtime cache `.edc/`, pi job state under `.git/edc/`, and `review-*.md` reports. Generated context is disposable; source remains authoritative. See [Generated Files and Local State](#generated-files-and-local-state) for details and `.gitignore` guidance.

## Why EDC?

| Tool style | Strength | Gap | EDC angle |
|---|---|---|---|
| Cursor rules / Claude memory / `AGENTS.md` | Simple local guidance | Manual and drifts | Generated, updated, validated context tree |
| Claude/Cursor/Codex agents | Good at code changes | Start each repo/session mostly blind | Shared repo map before work starts |
| PR bots | Convenient diff review | Remote, black-box, PR-only | Local inspectable context-aware review |
| Semantic search / code search | Finds relevant code | Does not encode authority or invariants | Authored module docs with routing and guardrails |

## What EDC Does

EDC separates deterministic orchestration from LLM analysis:

- Shell scripts own routing, freshness checks, manifest updates, subprocess spawning, and validation.
- Subagents write per-module architecture context and review reports.
- Agent integrations expose the same workflows through native commands, skills, hooks, or pi's interactive menu.

The generated context lives in the target repository under `edc-context/`: an overview, module docs, routing manifest, build metadata, and audit/review reports. Build it once per repo, then update it from diffs as code moves. Security reviews are routed through the generated manifest so each changed path gets the relevant module context instead of a giant undifferentiated context dump.

### Commands

| Command | When to run it |
|---------|----------------|
| **build** | Once per repo, and after big refactors. Discovers modules and writes `edc-context/{index.md, manifest.json, modules/*.md, reports/*, build/build.json}` plus a short agent orientation (`AGENTS.md`, or `EDC_AGENTS.md` when preserving an existing `AGENTS.md`). |
| **update** | Before review/delivery-review/audit if HEAD has moved. Incremental refresh from a branch diff so you do not rebuild from scratch on every PR. |
| **review** | On a branch diff. Runs all lenses: security, delivery/architecture, and quality review. |
| **security-review** | On a PR, branch, commit, or diff file. Runs context-aware security/adversarial review and writes a consolidated `review-*.md` report. |
| **delivery-review** | On a branch or commit diff. Checks goal/spec delivery and architecture fit, writing `delivery-review-*.md`. |
| **quality-review** | Anytime. Compares context expectations against actual code to flag code-quality and maintainability risks. |
| **audit** | Deprecated alias for `quality-review`. |
| **doctor** | When something feels off. Validates the `edc-context/` tree and routing contract. |
| **mode** | Shows or toggles runtime context loading mode (`advisory` or `inject`). |

### Terminal CLI

The unified installer (`bash install.sh --agent <agent>`) places a shared terminal wrapper at `~/.edc/scripts/edc` alongside the orchestrator scripts and adds `~/.edc/scripts` to your shell `PATH` when it can detect a zsh/bash rc file. Restart your shell after install, or run `export PATH="$HOME/.edc/scripts:$PATH"` for the current shell. Pass `--no-path` to skip rc-file edits.

From any terminal, in the target repo:

```bash
# build or update context in the current repo
edc build  --agent claude
edc build  --agent cursor --force
edc build  --agent codex --focus orchestrator
edc build  --agent codex --ignore 'vendor/**' --ignore 'dist/**'
edc update --agent claude              # incremental refresh after HEAD moves

# run all review lenses in the current repo: security, delivery, then quality
edc review --agent claude --diff main...HEAD
edc review --agent pi --diff main...HEAD
# legacy alias during transition
edc review-all --agent pi --diff main...HEAD

# run the security-only review pipeline in the current repo
edc security-review --agent claude --base main
edc security-review --agent cursor HEAD --base main
edc security-review --agent codex --pr 42
edc security-review --agent pi HEAD --base main
edc security-review --agent codex https://github.com/owner/repo/pull/42
edc security-review --agent codex HEAD --base main --ignore 'generated/**'

# goal/spec delivery + architecture-fit review
edc delivery-review --agent claude HEAD --base main
edc delivery-review --agent pi HEAD --base main

# code quality / maintainability review
edc quality-review --agent claude
edc quality-review --agent pi
# deprecated alias
edc audit --agent pi

# runtime-mode toggle (used by Claude Code and pi inject/advisory hooks)
edc mode                # show current mode
edc mode advisory       # docs only, hooks no-op
edc mode inject         # auto-load context through supported hooks

# validate the edc-context/ layout
edc doctor
```

`--agent` selects which CLI (`claude` / `cursor` / `codex` / `pi`) drives subprocess fanout, and is mandatory for `build`, `update`, `review`, `security-review`, `delivery-review`, and `quality-review` (not for `mode` or `doctor`). Review commands auto-build or auto-update `edc-context/` first if it is missing or stale. Differential scope can be written as `--diff <base>...<target>` or legacy `target --base <ref>`. Security review routes changed files through `edc-context/manifest.json`: module-mapped files get module context, unexpected unmapped files are reviewed with repo-level context only, and paths matching `unmapped.allowedGlobs` are intentionally skipped but listed in the final review. `--ignore` may be repeated; passing any `--ignore` flag overrides `.edcignore` for that run, otherwise `.edcignore` is read from the repo root.

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

Both paths install the plugin surface (slash commands + hooks + skills) and the terminal CLI (`~/.edc/scripts/edc`). The direct installer also adds a zsh/bash `PATH` entry when possible; use `--no-path` to skip shell rc edits.

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
# npm package
pi install npm:@sgtbeatdown/edc

# project-local install for a team repo
pi install npm:@sgtbeatdown/edc -l

# or from a local checkout
bash install.sh --agent pi
```

For pi commands, menu behavior, background jobs, modes, requirements, and troubleshooting, see [`pi/README.md`](pi/README.md).

#### Codex auth with the orchestrator

The orchestrator spawns `codex exec` using your normal Codex configuration by default, so ChatGPT OAuth/API-key login state under `~/.codex` is inherited. If you need an isolated Codex home for tests or benchmarks, set:

```bash
export EDC_CODEX_HOME=/path/to/isolated/codex-home
```

When `EDC_CODEX_HOME` is set, the orchestrator uses it verbatim and does not clean it up.

## Agent Commands and Menus

Claude, Cursor, and Codex expose thin wrappers for the same deterministic orchestrators. Pi exposes the workflows through one interactive `/edc` menu instead of separate slash commands.

| Agent | User-facing actions |
|-------|---------------------|
| Claude Code | `/edc:edc-build`, `/edc:edc-update`, `/edc:edc-run-review`, `/edc:edc-doctor`; methodology skills `edc-review`, `edc-audit`, `edc-delivery-review` |
| Cursor | `/edc-build`, `/edc-update`, `/edc-run-review`, `/edc-doctor`; public methodology skills |
| Codex | `$edc-build`, `$edc-update`, `$edc-run-review`, `$edc-doctor`; public methodology skills |
| pi | `/edc` interactive menu: review all changes/security review/delivery review/quality review/status/build/update/doctor; methodology skills `edc-review`, `edc-audit`, `edc-delivery-review` |

### Review invocation examples

```bash
# terminal CLI
edc security-review --agent claude --pr 42
edc security-review --agent codex https://github.com/owner/repo/pull/42
edc security-review --agent pi HEAD --base main
edc security-review --agent claude abc1234                 # single commit; base defaults to abc1234^
edc security-review --agent claude HEAD --base HEAD~5      # commit range
edc security-review --agent claude path/to/changes.patch   # pre-generated diff file
edc security-review --agent claude --pr 42 --base main --ignore-context

# Claude slash command equivalent
/edc:edc-run-review --pr 42
/edc:edc-run-review HEAD --base main
/edc:edc-run-review path/to/changes.patch
```

Without `--base`, a git ref target uses its parent (`<target>^`) as the base, which reviews only that commit. To review a branch against `main`, pass `--base main`. For PR targets, EDC uses `gh pr diff <number-or-url> --name-only`, so `gh` must be installed and authenticated. Use `--ignore-context` for a pure direct review with no context build/update and no reads from existing `edc-context/`; use `--no-context-refresh` to skip creation/update while still allowing existing context if present.

## Runtime Modes

EDC stores runtime mode in `edc-context/manifest.json` as `policy.defaultMode`.

- **`advisory`** (default) — pure docs. Hooks no-op. Agents read `edc-context/index.md` and relevant `edc-context/modules/<name>.md` when prompted by a command/menu or by the user. Zero token overhead per tool call.
- **`inject`** — auto-loaded context for supported integrations. Session start surfaces `edc-context/index.md`; before `Edit`/`Write`/`Bash`/tool-call paths, EDC resolves the file through `manifest.json` and injects the matching module doc once per session.

Toggle from a target repo after context exists:

```bash
edc mode
edc mode advisory
edc mode inject
```

Cursor and Codex are docs-only regardless of the mode flag. Claude Code and pi support injection.

## Generated Files and Local State

EDC writes generated context and local runtime state in a few places:

- `edc-context/` — generated per-module deep context written by build/update; review task IPC lives under `edc-context/review-tasks/`. This directory is disposable: recovery may wipe and rebuild it.
- `AGENTS.md` / `EDC_AGENTS.md` — short generated orientation pointing agents at `edc-context/`. If a repo already has a non-EDC `AGENTS.md`, non-pi builds preserve it, write `EDC_AGENTS.md`, and explain how to replace, append, or reference it. Set `EDC_AGENTS_MODE=overwrite` to replace `AGENTS.md`.
- `review-*.md` — consolidated review output.
- `.edc/` — project-local runtime copy used by hooks/extensions when they need deterministic access to orchestrator scripts and private prompt bundles. Global installs also live under `~/.edc/`.
- `.git/edc/status` and `.git/edc/<kind>.log` — pi's current background job status/logs. These are git metadata files, not worktree files, and need no `.gitignore` entry.

For repos where you do not want generated EDC artifacts tracked, add:

```gitignore
AGENTS.md
EDC_AGENTS.md
edc-context/
review-*.md
.edc/
```

If generated context or review outputs get committed, `edc review` filters them out of diffs automatically so the tool does not review its own output, but you will still usually want them ignored to keep history clean.

## Repo Structure

```
edc/
  install.sh                           # one-line installer for all agents
  AGENTS.md / EDC_AGENTS.md            # generated agent entrypoint/orientation
  .claude-plugin/marketplace.json      # Claude plugin marketplace manifest
  plugins/edc/                         # plugin, skills, hooks, and shared orchestrators
    commands/                          # user-facing Claude slash commands
    skills/                            # user-facing methodology skills
    prompt-bundles/                    # hidden prompt bundles for orchestrator subprocesses
    scripts/                           # everything that ships to ~/.edc/scripts/
    hooks/                             # Claude hook surface + shared JS runtime helpers
  pi/                                  # pi package surface, docs, extension, and installer
  tests/hardening/                     # shell/Node regression tests
  benchmark/                           # CVE recall and review benchmark harnesses
```

Cursor and Codex have no in-repo runtime source beyond installer templates. Their wrappers are emitted by `install.sh` into `~/.cursor/commands/` and `~/.codex/skills/`, and delegate to the orchestrators under `~/.edc/scripts/`.

For implementation details, see [`plugins/edc/README.md`](plugins/edc/README.md). For generated architecture context, see [`edc-context/index.md`](edc-context/index.md) after running `edc build`.
