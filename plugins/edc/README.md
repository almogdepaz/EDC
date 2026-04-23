# EDC Plugin — Architecture

## User-facing commands

| Command | What it does |
|---------|--------------|
| `/edc:edc-build` | Build deep codebase context (`.context/`) |
| `/edc:edc-review` | Run differential security review on current branch or target |

These are the ONLY commands users should see and invoke.

## Internal structure

```
plugins/edc/
  commands/
    edc-review.md       user-facing command (Bash-only, invokes the script)
  scripts/
    edc-review.sh       orchestrator — owns all routing, spawns claude -p subprocesses
  skills/
    edc-build/          context building skill (invoked by script)
    edc-context/        deep per-file context (invoked by edc-build)
    edc-review-impl/    review methodology + patterns (consumed by script as prompt material)
    edc-update/         incremental context update (invoked by script)
  hooks/
    session-start.sh    injects context summary on session start
```

## Design: script-as-orchestrator

The user's claude session has ONLY `Bash` access. It runs `edc-review.sh` which:

1. Checks context freshness (`.context/.meta.json` vs HEAD)
2. Spawns `claude -p` for context build/update if needed
3. Generates per-module task files in `review/`
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

- `edc-build`: full context build, writes `.context/*.md` + `.meta.json`
- `edc-update`: incremental update when HEAD advances
- Context is stale when `.meta.json` lastCommit != HEAD
- Reviews require fresh context — script auto-triggers build/update if needed
