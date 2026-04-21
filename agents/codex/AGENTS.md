# EDC — Every Day Carry Skills

This project uses EDC for deep codebase context and code review.

## Available Skills

- **$edc-build** — Full context build. Routes into the shared EDC build flow and writes `.context/`.
- **$edc-update** — Incremental context refresh from branch diff.
- **$edc-split** — Split `.context/full-context.md` into module files and overview files.
- **$edc-audit** — Overengineering, duplication, and complexity audit.
- **$edc-run-review** — Self-driving differential review. Spawns fresh `codex exec` subprocesses through the shared orchestrator.
- **$edc-context** — Low-level deep architectural analysis skill used by the build/update pipeline.
- **$edc-review-impl** — Low-level differential review methodology used by the orchestrator. Do not use this directly unless you are debugging the pipeline.

## Workflow

### Build context

- First time: run `$edc-build`
- On later changes: run `$edc-update`
- If you need the manual pipeline: `$edc-build` writes `.context/full-context.md`, then splits it into `.context/context.md`, `.context/{module}.md`, `.context/issues.md`, `.context/complexity.md`, and `.context/.meta.json`

### Review changes

Run `$edc-run-review <target> [--base <ref>]`.

Common forms:
- `$edc-run-review --base main`
- `$edc-run-review HEAD --base main`
- `$edc-run-review <commit-sha>`
- `$edc-run-review <pr-url>`

The wrapper invokes the shared orchestrator:

```bash
EDC_AGENT_CLI=codex bash .edc/scripts/edc-review.sh <target> [--base <ref>]
```

The orchestrator owns the flow:
- Detect missing or stale context
- Spawn fresh `codex exec` sessions for `edc-build-impl` or `edc-update-impl` when needed
- Generate per-module review tasks
- Spawn one fresh `codex exec` review session per module
- Consolidate and verify the final `review-*.md`

On success it prints:
- `Consolidated: <path>`
- `Verified: <path>`

Tell the user the final review file path and do not redo the review inline.

### Codex auth for spawned subprocesses

The orchestrator spawns `codex exec` under an isolated `CODEX_HOME` (fresh
temp dir per run) so pipeline state stays separated from the user's
interactive Codex sessions. If `codex exec` fails with an auth error,
export `EDC_CODEX_HOME=$HOME/.codex` before running the skill — the
orchestrator will reuse that path verbatim instead of creating a temp one.
