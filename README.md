# EDC — Context-Aware Code Review for Pi and AI Agents

EDC builds a local repository architecture map so coding agents stop reviewing blind.

Use it when you want a Pi/Claude/Cursor/Codex agent to understand module ownership, path routing, trust boundaries, invariants, and review scope before it comments on code.

What you get:

- **repo map / agent context** — generated `edc-context/` docs with module boundaries and routing metadata
- **context-aware code review** — security, delivery/architecture, and quality lenses routed to the right module docs
- **local-first workflow** — runs from your repo through Pi's `/edc` menu or the terminal CLI; no remote PR bot required

Works with **Pi**, **Claude Code**, **Cursor**, and **Codex**.

## 30-second start

```bash
pi install npm:@sgtbeatdown/edc
cd your-repo
pi
# run /edc, choose build context, then choose scope + review lens
```

First run may write `edc-context/`, `AGENTS.md` or `EDC_AGENTS.md`, pi job state under `.git/edc/`, and `review-*.md` reports. Runtime code comes only from the installed package or `~/.edc`; old repo-local `.edc/` caches are ignored and can be removed manually. Generated context is disposable; source remains authoritative. See [Generated Files and Local State](#generated-files-and-local-state) for details and `.gitignore` guidance.

## Why EDC?

| Tool style | Strength | Gap | EDC angle |
|---|---|---|---|
| Cursor rules / Claude memory / `AGENTS.md` | Simple local guidance | Manual and drifts | Generated, updated, validated context tree |
| Claude/Cursor/Codex agents | Good at code changes | Start each repo/session mostly blind | Shared repo map before work starts |
| PR bots | Convenient diff review | Remote, black-box, PR-only | Local inspectable context-aware review |
| Semantic search / code search | Finds relevant code | Does not encode authority or invariants | Authored module docs with routing and guardrails |

Before source-research workers run, EDC checks whether an already-installed Octocode CLI responds successfully and gives workers explicit available/unavailable guidance. Octocode remains optional: EDC never installs or requires it, and workers fall back immediately to their existing tools when it is absent or fails.

## What EDC Does

EDC separates deterministic orchestration from LLM analysis:

- Shell/Node coordinators own routing, freshness checks, task graphs, bounded subprocess pools, staging, promotion, and validation.
- Clean workers write one staged module context or review report each; models never choose process commands or launch nested agents.
- Agent integrations expose the same workflows through native commands, skills, hooks, or pi's interactive menu.

The generated context lives in the target repository under `edc-context/`: an overview, module docs, routing manifest, build metadata, and audit/review reports. Build it once per repo, then update it from diffs as code moves. Security reviews are routed through the generated manifest so each changed path gets the relevant module context instead of a giant undifferentiated context dump.

### Commands

| Command | When to run it |
|---------|----------------|
| **build** | Once per repo, and after big refactors. Discovers modules and writes `edc-context/{index.md, manifest.json, modules/*.md, reports/*, build/build.json}` plus a short agent orientation (`AGENTS.md`, or `EDC_AGENTS.md` when preserving an existing `AGENTS.md`). |
| **update** | Before review if HEAD has moved. Incremental refresh from a branch diff so you do not rebuild from scratch on every PR. |
| **review full\|diff [base]** | Runs all lenses: security, delivery/architecture, and quality review. |
| **security full\|diff [base]** | Runs context-aware security/adversarial review and writes a consolidated `review-*.md` report. |
| **delivery full\|diff [base]** | Checks goal/spec delivery and architecture fit, writing `delivery-review-*.md`. |
| **quality full\|diff [base]** | Code-quality and maintainability review. Full audits all modules; diff audits modules owning changed files. |
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

# run all review lenses (serial by default): security, delivery, and quality
edc review full --agent claude
edc review diff --agent pi          # diff vs detected default branch
edc review diff main --agent pi     # diff vs explicit base
# if the working tree is dirty, choose exactly one policy:
edc review diff main --agent pi --include-working-tree
edc review diff main --agent pi --committed-only

# run the security-only review pipeline in the current repo
edc security full --agent claude
edc security diff main --agent cursor
edc security diff origin/main --agent codex --ignore 'generated/**'

# goal/spec delivery + architecture-fit review
edc delivery full --agent claude
edc delivery diff main --agent pi

# code quality / maintainability review
edc quality full --agent claude
edc quality diff main --agent pi

# runtime-mode toggle (used by Claude Code and pi inject/advisory hooks)
edc mode                # show current mode
edc mode advisory       # docs only, hooks no-op
edc mode inject         # auto-load context through supported hooks

# validate the edc-context/ layout
edc doctor
```

`--agent` selects which CLI (`claude` / `cursor` / `codex` / `pi`) drives subprocess fanout, and is mandatory for `build`, `update`, `review`, `security`, `delivery`, and `quality` (not for `mode` or `doctor`). Review commands auto-build or auto-update `edc-context/` first if it is missing or stale. Use `full` for the current tracked repo and `diff [base]` for `HEAD` versus a base branch; omitted diff base uses the detected default branch. Dirty differential review fails before context recovery or workers unless you pass `--include-working-tree` or `--committed-only`. Include mode creates one immutable synthetic commit containing staged, unstaged, deleted, and non-ignored untracked files, recursively snapshotting dirty initialized submodules, without moving HEAD/refs or changing any real index; combined security, delivery, and quality lenses all review that same commit in order by default, or concurrently after explicit opt-in. Committed-only mode excludes every working-tree change. Security review routes files through `edc-context/manifest.json`: module-mapped files get module context, unexpected unmapped files are reviewed with repo-level context only, and paths matching `unmapped.allowedGlobs` are intentionally skipped but listed in the final review. Quality diff audits only modules owning changed files; quality full audits all modules. Structured result files include scope/base/target, candidate kind/commit, and evidence-derived dirty/untracked inclusion. `success-with-warning` means one or more review calls failed or omitted output; EDC preserves substantive prose and inserts explicit unavailable-coverage markers instead of discarding the rest of the review. `--ignore` may be repeated; passing any `--ignore` flag overrides `.edcignore` for that run, otherwise `.edcignore` is read from the repo root.

### Worker concurrency and pi observability

All EDC orchestration is serial by default: combined review runs security, delivery, then quality, and worker manifests use `maxConcurrency: 1`. Set exact `EDC_PARALLEL=1` to enable concurrent review lenses and module-worker pools. Only after that opt-in does `EDC_MAX_CONCURRENCY` apply; it accepts an integer from 1–64 and defaults to `4`. Prompts, transcripts, task results, stderr, and staged outputs live under `.git/edc/runs/<run-id>/`. Canonical reports/context are written only after staged outputs validate as contained single-link regular files.

Pi workers always use `--no-extensions`, so arbitrary global/project extension discovery remains disabled. To observe EDC workers, explicitly allow one prompt-neutral extension entrypoint:

```text
# ~/.edc/config (environment variables override this file)
EDC_PARALLEL=0
# Used only when EDC_PARALLEL=1:
EDC_MAX_CONCURRENCY=4
EDC_PI_EXTENSION_PATH=/absolute/path/to/agent_observer/src/extension.ts
```

`EDC_PI_EXTENSION_PATH` must name an absolute readable file. EDC passes exactly `-e <path>` in addition to `--no-extensions`; no other extension is enabled. Worker processes also receive `EDC_RUN_ID`, `EDC_TASK_ID`, `EDC_TASK_PHASE`, and optional `EDC_TASK_MODULE` provenance.

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

Marketplace installation provides the package-backed Claude commands, hooks, and skills; it does not provision `~/.edc` or a standalone `edc` command. The standalone terminal CLI requires the direct installer, which installs `~/.edc/scripts/edc` and adds a zsh/bash `PATH` entry when possible; use `--no-path` to skip shell rc edits.

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
# npm package (global)
pi install npm:@sgtbeatdown/edc

# or from a local checkout (also global)
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
| pi | `/edc` interactive menu: choose scope first (full repo, changes vs default branch, changes vs custom base), then lens (combined/security/delivery/quality); methodology skills `edc-review`, `edc-audit`, `edc-delivery-review` |

### Review invocation examples

```bash
# terminal CLI
edc review full --agent pi
edc review diff main --agent pi --include-working-tree  # complete dirty candidate
edc review diff main --agent pi --committed-only        # committed target only
edc security full --agent claude
edc security diff HEAD~5 --agent claude
# advanced legacy security forms still support PRs, single commits, and patch files:
edc security-review --agent claude --pr 42
edc security-review --agent claude path/to/changes.patch

# Claude slash command equivalent for combined review
/edc:edc-run-review --full
/edc:edc-run-review HEAD --base main
```

Without `--base`, a git ref target uses its parent (`<target>^`) as the base, which reviews only that commit. To review a branch against `main`, pass `--base main`. For PR numbers, PR URLs, or patch files, use the explicit security-only command (`edc security-review --agent <agent> ...`) because delivery and quality phases require a git diff scope. Use `--ignore-context` for a pure direct security review with no context build/update and no reads from existing `edc-context/`; use `--no-context-refresh` to skip creation/update while still allowing existing context if present.

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

EDC writes generated context and operational state in a few places:

- `edc-context/` — generated per-module deep context written by build/update; review task IPC lives under `edc-context/review-tasks/`. This directory is disposable: recovery may wipe and rebuild it.
- `AGENTS.md` / `EDC_AGENTS.md` — short generated orientation pointing agents at `edc-context/`. If a repo already has a non-EDC `AGENTS.md`, non-pi builds preserve it, write `EDC_AGENTS.md`, and explain how to replace, append, or reference it. Set `EDC_AGENTS_MODE=overwrite` to replace `AGENTS.md`.
- `review-*.md` — consolidated review output.
- `~/.edc/` — managed global terminal runtime and private prompt bundles. Package integrations may execute their own installed package source directly. Repo-local `.edc/` is never read, repaired, created, or executed; remove legacy caches manually if desired.
- `.git/edc/status` and `.git/edc/<kind>.log` — pi's current background job status/logs. These are git metadata files, not worktree files, and need no `.gitignore` entry.

For repos where you do not want generated EDC artifacts tracked, add:

```gitignore
AGENTS.md
EDC_AGENTS.md
edc-context/
review-*.md
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
