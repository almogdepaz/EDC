# EDC Plugin — Architecture

This directory is the canonical source for everything EDC ships: claude
slash commands, shared orchestrator scripts (installed for every agent),
canonical skill content, and claude-only hooks.

See the top-level [`README.md`](../../README.md) for install instructions and
the user-facing tour.

## User-facing commands (claude)

| Command | What it does |
|---------|--------------|
| `/edc:edc-build` | Build the v2 context tree (`AGENTS.md`, `edc-context/index.md`, `edc-context/manifest.json`, `edc-context/modules/*`) |
| `/edc:edc-update` | Incrementally refresh the v2 context tree from branch diff |
| `/edc:edc-run-review` | Run differential review on the current branch / commit / PR number or URL |
| `/edc:edc-doctor` | Validate the v2 context tree and manifest routing contract |

Audit and review methodology are exposed as skills (`edc-audit`, `edc-review`), not as user-facing commands. Internal worker command shims were removed so autocomplete only shows real user actions.

Cursor (`/edc-*`), Codex (`$edc-*`), and Pi expose the same user-facing command set through wrappers emitted by `install.sh` / `agents/pi/`: build, update, run-review, and doctor.

## Internal structure

```
plugins/edc/
  commands/                            # user-facing slash commands
    edc-build.md
    edc-update.md
    edc-run-review.md                  # user-facing review launcher
    edc-doctor.md

  scripts/                             # everything that ships to ~/.edc/scripts/
    edc                                # terminal CLI (build / update / review / audit / mode / doctor)
    edc-build.sh                       # full-build orchestrator
    edc-update.sh                      # incremental-update orchestrator
    edc-audit.sh                       # complexity / bloat audit orchestrator
    edc-review.sh                      # differential review orchestrator
    edc-doctor.sh                      # context-tree validator

    edc-lib.sh                         # sourced helpers: PATHS, RUNTIME, SPAWN, PROMPT sections
    edc-assert-fresh.sh                # freshness gate (sourceCommit vs HEAD)
    edc-clean-slate.sh                 # v1 leftover detection + wipe
    edc-recover-context.sh             # auto-rebuild/update when context is stale

    edc-route.sh                       # path -> module router (exec'd, stable CLI contract)
    edc-manifest.sh                    # manifest stdin/stdout filter
    edc-build-plan.sh                  # deterministic per-module task planner (jq)

  skills/                              # user-facing methodology skills
    edc-review/                        # differential review methodology + patterns
    edc-audit/                         # bloat / duplication / overengineering methodology

  prompt-bundles/                      # hidden prompt bundles for orchestrators
    edc-module-context-impl/           # per-module context methodology
    edc-build-impl/                    # full-build prompt bundle
    edc-update-impl/                   # incremental update prompt bundle

  hooks/                               # claude-only: automatic context injection
    hooks.json
    session-start.mjs                  # surfaces edc-context/index.md on session start
    pretooluse-context-inject.mjs      # injects module context before Edit/Write/Bash
    lib/                               # shared mjs helpers (paths, platform, route)
```

## Design: script-as-orchestrator

The user's agent session uses thin command wrappers that call deterministic orchestrators (`edc-build.sh`, `edc-update.sh`, `edc-review.sh`, `edc-doctor.sh`; terminal CLI also exposes `edc-audit.sh`), which:

1. Validates context freshness (`edc-context/manifest.json.sourceCommit` vs HEAD)
2. Auto-rebuilds or auto-updates context if stale (via `edc-recover-context.sh`)
3. Spawns one fresh `<agent> -p` subprocess per module with the skill content
   piped as the prompt (`edc-resolve-prompt`)
4. For review: consolidates per-module reports into a single review file

Each subprocess is a fresh context with a single instruction. The driving
session does not perform analysis itself — it spawns workers and verifies
their outputs.

## Skill files as prompt templates

`skills/edc-review/` contains:

- `SKILL.md` — main review workflow definition
- `methodology.md` — phase-by-phase review process
- `patterns.md` — vulnerability pattern catalog (tunable via autoresearch / GEPA)
- `adversarial.md` — attacker modeling methodology
- `reporting.md` — output format contract

These are **prompt material**. The orchestrator concatenates them into the
subprocess prompt; they exist as separate files so each one can be tuned
independently.

`prompt-bundles/edc-build-impl/`, `prompt-bundles/edc-update-impl/`, and `prompt-bundles/edc-module-context-impl/` are hidden prompt bundles for orchestrator subprocesses. `skills/edc-audit/` is both a user-facing methodology skill and the audit prompt used by terminal/orchestrated audit flows.

## Multi-agent support

The orchestrators are agent-agnostic. `EDC_AGENT_CLI` selects which CLI
spawns subprocesses:

- `claude` → `claude -p`
- `cursor` → `cursor agent -p`
- `codex`  → `codex exec`

`scripts/edc-lib.sh` centralizes the per-agent subprocess dispatch, prompt
resolution, and codex-home isolation.

## Context lifecycle

- **build**: full context build; writes `AGENTS.md` plus the v2 `edc-context/` tree
- **update**: incremental refresh when HEAD advances
- **stale** when `edc-context/manifest.json.sourceCommit != HEAD`
- review / audit / update require fresh context — orchestrators auto-recover
  via `edc-recover-context.sh`, and `edc-doctor.sh` validates the result

## Default invocation

```bash
edc-review.sh --base main              # review current branch vs main
edc-review.sh feat-branch --base main  # review branch vs main
edc-review.sh --pr 42 --base main      # review PR by number (uses gh)
edc-review.sh https://github.com/...   # review PR by URL (uses gh)
edc-review.sh path/to/diff.patch       # review diff file
```

For PR targets, the orchestrator shells out to `gh pr diff <number-or-url> --name-only`.
Use `--ignore-context` for a pure direct review with no context build/update and
no reads from existing `edc-context/`; use `--no-context-refresh` to skip
creation/update while still allowing existing context.
