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
| `/edc:edc-run-review` | Run combined security, delivery, and quality review for `--full` or a git diff target/base |
| `/edc:edc-doctor` | Validate the v2 context tree and manifest routing contract |

Quality review, security review, and delivery/architecture review methodology are exposed as skills (`edc-audit`, `edc-review`, `edc-delivery-review`). Internal worker command shims were removed so autocomplete only shows real user actions.

Cursor (`/edc-*`) and Codex (`$edc-*`) expose the same user-facing command set through wrappers emitted by `install.sh`: build, update, run-review, and doctor. Pi exposes workflows through one interactive `/edc` menu: choose scope first (full repo, changes vs default branch, or custom base), then lens (combined/security/delivery/quality), plus status/build/update/doctor.

## Internal structure

```
plugins/edc/
  commands/                            # user-facing slash commands
    edc-build.md
    edc-update.md
    edc-run-review.md                  # user-facing review launcher
    edc-doctor.md

  scripts/                             # everything that ships to ~/.edc/scripts/
    edc                                # terminal CLI (build / update / review/security/delivery/quality / mode / doctor)
    edc-build.sh                       # full-build orchestrator
    edc-update.sh                      # incremental-update orchestrator
    edc-audit.sh                       # quality review / maintainability orchestrator (full or diff-scoped)
    edc-review.sh                      # security/adversarial review orchestrator
    edc-delivery-review.sh             # goal/spec delivery + architecture-fit review orchestrator
    edc-doctor.sh                      # context-tree validator

    edc-lib.sh                         # sourced helpers: PATHS, RUNTIME, SPAWN, PROMPT sections
    edc-assert-fresh.sh                # freshness gate (sourceCommit vs HEAD)
    edc-clean-slate.sh                 # v1 leftover detection + wipe
    edc-recover-context.sh             # auto-rebuild/update when context is stale

    edc-manifest.sh                    # manifest stdin/stdout filter
    ../hooks/lib/classify-cli.mjs      # batch path classifier used by shell orchestrators
    edc-build-plan.sh                  # deterministic per-module task planner (jq)

  skills/                              # user-facing methodology skills
    edc-review/                        # security/adversarial review methodology + patterns
    edc-audit/                         # code quality / maintainability audit methodology
    edc-delivery-review/               # goal/spec delivery + architecture-fit review methodology

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

The user's agent session uses thin command wrappers that call deterministic orchestrators (`edc-build.sh`, `edc-update.sh`, `edc-review.sh`, `edc-delivery-review.sh`, `edc-doctor.sh`; terminal CLI also exposes `edc-audit.sh`), which:

1. Validates context freshness (`edc-context/manifest.json.sourceCommit` vs HEAD)
2. Auto-rebuilds or auto-updates context if stale (via `edc-recover-context.sh`)
3. Materializes validated task manifests under `.git/edc/runs/<run-id>/` and launches fresh module workers through a bounded coordinator-owned pool
4. Validates staged worker outputs before deterministic synthesis/consolidation and canonical promotion

Review task routing is explicit: mapped files get their module context, unexpected unmapped files are reviewed under the synthetic `unmapped` bucket with repo-level context only, and files matching `unmapped.allowedGlobs` are intentionally skipped but represented by a deterministic `allowed-unmapped` report.

Each subprocess is a fresh context with one declared task and output set. Models do not launch agents or choose process flags; the runtime owns concurrency, timeout/cancellation, provenance, logs, and promotion.

## Skill files as prompt templates

`skills/edc-review/` contains the security/adversarial review bundle:

- `SKILL.md` — main security review workflow definition
- `methodology.md` — security triage/history/blast-radius workflow
- `patterns.md` — vulnerability pattern catalog (tunable via autoresearch / GEPA)
- `adversarial.md` — attacker modeling methodology
- `reporting.md` — security report contract

`skills/edc-audit/` contains the quality-review bundle. Its main `SKILL.md` is intentionally small and points to `references/` for scope, smell baseline, quality checks, and reporting. Runtime result JSON uses `success`, `failed`, or `success-with-warning`; the warning state means durable reports/context validated despite transport/provider oddities.

`skills/edc-delivery-review/` contains the delivery/architecture review bundle. It keeps goal/spec delivery and architecture fit as separate axes.

These are **prompt material**. Runtime prompt resolution embeds the required bundle files for orchestrated subprocesses; they exist as separate files so each one can be tuned independently.

`prompt-bundles/edc-build-impl/`, `prompt-bundles/edc-update-impl/`, and `prompt-bundles/edc-module-context-impl/` are hidden prompt bundles for orchestrator subprocesses.

## Multi-agent support

The orchestrators are agent-agnostic. `EDC_AGENT_CLI` selects which CLI
spawns subprocesses:

- `claude` → `claude -p`
- `cursor` → `cursor agent -p`
- `codex`  → `codex exec`
- `pi`     → `pi --mode json`

`scripts/edc-lib.sh` centralizes per-agent dispatch, prompt resolution, pi JSON supervision, worker task manifests, and codex-home isolation. Orchestration is serial by default. Exact `EDC_PARALLEL=1` enables concurrent review lenses and module workers; only then does `EDC_MAX_CONCURRENCY` apply (integer 1–64, default `4`).

Pi worker discovery is always disabled with `--no-extensions`. Operators may load exactly one approved prompt-neutral extension by setting `EDC_PI_EXTENSION_PATH` to an absolute readable entrypoint. For agent-observer, point it at the installed/built `extension.ts` or JavaScript entrypoint. Workers receive structured run/task/phase/module environment provenance.

## Context lifecycle

- **build**: full context build; writes `AGENTS.md` plus the v2 `edc-context/` tree
- **update**: incremental refresh when HEAD advances
- **stale** when `edc-context/manifest.json.sourceCommit != HEAD`
- review / audit / update require fresh context — orchestrators auto-recover
  via `edc-recover-context.sh`, and `edc-doctor.sh` validates the result
- `edc-context/` is generated and disposable; recovery may wipe and rebuild it
- Pi background review operational state is deliberately outside `edc-context/`: current status lives at `.git/edc/status`, current raw log at `.git/edc/review.log` (resolved via `git rev-parse --git-path`)

## Default invocation

```bash
edc review full --agent pi             # combined full repo review
edc review diff main --agent pi --include-working-tree  # complete dirty candidate vs main
edc review diff main --agent pi --committed-only        # committed HEAD vs main
edc security full --agent pi           # security full repo review
edc security diff main --agent pi      # security current branch vs main
edc delivery full --agent pi           # delivery/architecture full repo review
edc quality diff main --agent pi       # quality review for modules changed vs main

edc-review.sh --full                   # lower-level security full repo review
edc-review.sh --base main              # lower-level security current branch vs main
edc-review.sh --pr 42 --base main      # lower-level security PR by number (uses gh)
edc-review.sh https://github.com/...   # lower-level security PR by URL (uses gh)
edc-review.sh path/to/diff.patch       # lower-level security diff file
```

Dirty differential review requires `--include-working-tree` or `--committed-only`; clean trees need neither. Include mode creates one immutable synthetic commit shared by the security, delivery, and quality lenses. It includes staged, unstaged, deleted, and non-ignored untracked files, recursively snapshots dirty initialized submodules, and does not change HEAD, refs, or any real index. Combined review prepares context once, runs the lenses serially in that order by default, continues after a failed lens, then promotes validated reports. Exact `EDC_PARALLEL=1` retains the concurrent launch/wait behavior.

For PR targets, the orchestrator shells out to `gh pr diff <number-or-url> --name-only`.
Use `--ignore-context` for a pure direct review with no context build/update and
no reads from existing `edc-context/`; use `--no-context-refresh` to skip
creation/update while still allowing existing context.
