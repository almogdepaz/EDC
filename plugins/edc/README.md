# EDC Plugin — Architecture

## User-facing commands

| Command | What it does |
|---------|--------------|
| `/edc:edc-build` | Build or update the v2 context tree (`AGENTS.md`, `.context/index.md`, `.context/manifest.json`, `.context/modules/*`) |
| `/edc:edc-update` | Incrementally refresh the v2 context tree from branch diff |
| `/edc:edc-audit` | Write `.context/reports/issues.md` and `.context/reports/complexity.md` from existing module docs |
| `/edc:edc-run-review` | Run differential security review on the current branch or target |
| `/edc:edc-doctor` | Validate the v2 context tree and manifest routing contract |

These are the ONLY commands users should see and invoke.

## Internal structure

```
plugins/edc/
  commands/
    edc-build.md
    edc-update.md
    edc-audit.md
    edc-review.md       internal review skill entrypoint
    edc-run-review.md   user-facing review launcher
    edc-doctor.md
  scripts/
    edc-review.sh       orchestrator — owns all review routing, spawns agent subprocesses
    edc-route.sh        shared path -> module router
    edc-manifest.sh     deterministic manifest post-step
    edc-doctor.sh       schema + coverage validator
  skills/
    edc-build-impl/     context-building skill (invoked by wrappers)
    edc-update-impl/    incremental context refresh skill
    edc-audit-impl/     report generation skill
    edc-context/        deep per-file context (invoked by edc-build)
    edc-review-impl/    review methodology + patterns (consumed by script as prompt material)
  hooks/
    session-start.mjs
    pretooluse-context-inject.mjs
```

## Design: script-as-orchestrator

The user's Claude session has ONLY `Bash` access. It runs `edc-review.sh` which:

1. Checks context freshness (`.context/manifest.json.sourceCommit` vs HEAD)
2. Spawns `claude -p` for context build/update if needed
3. Generates per-module task files in `review-tasks/`
4. Spawns `claude -p` per module for review
5. Consolidates reports into final review file
6. Verifies all outputs exist

Each spawned subprocess is a fresh context with a single instruction. The user's session
never does analysis itself — it physically cannot (no Read/Write/Grep/Glob).

## Skill files as prompt templates

The `skills/edc-review-impl/` directory contains:

- `SKILL.md` — main review workflow definition
- `methodology.md` — phase-by-phase review process
- `patterns.md` — vulnerability pattern catalog (tuned by autoresearch)
- `adversarial.md` — attacker modeling methodology

These are **prompt material**, not user-invocable skills. The orchestrator script `cat`s
them into the `claude -p` prompt for each review subprocess. They exist as separate files
so the autoresearch benchmark loop can tune them independently.

Users should NEVER invoke `edc-review-impl` directly. It will be removed from the
`skills/` directory and moved to a non-discoverable location (e.g. `scripts/prompts/`)
once the inlining migration is complete.

## Default behavior

```bash
edc-review.sh                          # review current branch vs main
edc-review.sh feat-branch --base main  # review branch vs main
edc-review.sh https://github.com/...   # review PR
edc-review.sh path/to/diff.patch       # review diff file
```

No target = reviews current branch against main. No flags needed for the common case.

## Context lifecycle

- `edc-build`: full context build, writes `AGENTS.md` plus the v2 `.context/` tree
- `edc-update`: incremental update when HEAD advances
- Context is stale when `.context/manifest.json.sourceCommit != HEAD`
- Reviews require fresh context and valid routing — `edc-review.sh` auto-recovers and `edc-doctor.sh` validates the result
