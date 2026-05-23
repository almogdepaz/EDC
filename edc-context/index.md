# EDC — Repo Overview

EDC ("external deep context") is a multi-agent harness that builds, refreshes, and consumes per-module architectural context for a target codebase. The same plugin powers Claude Code, Cursor, Codex, and (via an adapter) Pi. EDC's value proposition: deterministic shell orchestrators own routing, freshness, and validation; LLM subagents own analysis. The two never overlap.

This file is the session-start orientation. For machine-readable routing/policy, see `manifest.json`. For deep per-module detail, see the linked module docs.

## Repo Purpose

- **Tool:** EDC plugin + CLI for "deep context" generation/use across agents.
- **Output it produces:** `edc-context/` directory (this directory) consumed by hooks at session start and pre-tool-use to inject relevant module context into the agent's prompt.
- **Companion benchmark:** CVE-recall benchmark harness measures how much external context improves vulnerability discovery on real repos (curl, redis).

## Actor Map

| Actor                | Surface                                                                                                                           | Where                  |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------- | ---------------------- |
| End user             | `edc <build|update|review|audit|mode|doctor> --agent <claude|cursor|codex|pi>`                                                    | `scripts/edc`          |
| Claude Code / Cursor | User-facing slash commands `/edc-build`, `/edc-update`, `/edc-run-review`, `/edc-doctor`; review/audit methodology exposed as skills | `plugins/edc/`         |
| Codex                | Same slash commands; spawn pipeline isolates `$CODEX_HOME` per subprocess                                                         | `plugins/edc/scripts/` |
| Pi                   | Adapter at `agents/pi/index.mjs` that maps Pi's event API onto the same shared `route.mjs` lib used by Claude/Cursor hooks        | `agents/pi/`           |
| Subagents            | Stateless `claude -p` / `cursor` / `codex` invocations spawned by orchestrator scripts; receive a self-contained prompt + tool allowlist | `edc-spawn.sh`         |

## Module Map

| Module             | Doc                                                  | Role                                                                                |
| ------------------ | ---------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `runtime-cli`      | [modules/runtime-cli.md](modules/runtime-cli.md)         | Repo-root entrypoints: `scripts/edc` dispatch shim, `scripts/edc-review.sh` re-entrant orchestrator, `install.sh`, ignore files. |
| `plugin-surface`   | [modules/plugin-surface.md](modules/plugin-surface.md)   | Slash-command definitions, hooks, and the deterministic shell orchestrators that own all routing/freshness/validation. |
| `canonical-skills` | [modules/canonical-skills.md](modules/canonical-skills.md) | LLM-facing prompt material: public skills (`edc-review`, `edc-audit`) plus private prompt bundles (`edc-module-context-impl`, `edc-build-impl`, `edc-update-impl`). No code; pure prompts. |
| `agent-wrappers`   | [modules/agent-wrappers.md](modules/agent-wrappers.md)   | Adapters that port the EDC plugin surface to non-Claude agents (currently Pi).      |
| `benchmarking`     | [modules/benchmarking.md](modules/benchmarking.md)       | CVE-recall benchmark harness, scoring, autoresearch loop, GEPA optimizer, regression checks. |
| `hardening-tests`  | [modules/hardening-tests.md](modules/hardening-tests.md) | t1–t16 shell hardening suite covering tool lockdown, routing, orchestrator behavior, and regressions. |

Curl/redis benchmark fixtures (`benchmark/curl/**`, `benchmark/redis/**`) are intentionally excluded via `.edcignore`.

## Key Flows

### 1. Build (`edc build`)

```
user
  → scripts/edc                         (dispatch shim, picks edc-build.sh)
  → plugins/edc/scripts/edc-build.sh    (orchestrator: clean-slate gate, route-decision)
  → claude -p (skill: edc-build-impl)   (LLM orchestrator subprocess)
       │
       ├─ discovers modules
       ├─ pipes module list → edc-build-plan.sh    (deterministic task list)
       ├─ spawns 1 subagent per module             (skill: edc-context, clean slate)
       │     each writes edc-context/modules/<name>.md and returns ≤500-tok summary
       ├─ stitches summaries → edc-context/index.md
       ├─ invokes edc-audit skill             (writes reports/issues.md, complexity.md)
       ├─ writes partial manifest → pipes through edc-manifest.sh (deterministic post-step)
       └─ writes AGENTS.md
  → edc-doctor.sh                       (post-skill backstop validation)
```

### 2. Update (`edc update`)

`edc-update.sh` → `edc-update-impl` prompt bundle: detects changed files via `git diff`, routes them via `edc-route.sh` to determine touched modules, re-spawns `edc-module-context-impl` only for those modules, refreshes `index.md` + reports + manifest. Preserves `policy.defaultMode`. No-op when no source changes.

### 3. Review (`edc review`)

`scripts/edc-review.sh` is both the public entrypoint and a self-re-entrant orchestrator. `auto_mode`:

1. `recover_context_if_needed` — gates on freshness; rebuilds context if stale/missing.
2. `bash "$0" --build` — emits one `review-tasks/<module>.md` per touched module by routing changed files through the manifest.
3. Spawns one `edc-spawn` subprocess per module (skill: `edc-review` Mode A) → each writes `review-tasks/report-{module}.md`.
4. `bash "$0" --consolidate` + `--verify` — assembles the final review report, validates structure (heading-free reports are rejected).

### 4. Hooks (continuous)

`session-start.mjs` runs at session boundary: detects platform, installs `.edc/scripts/edc-review.sh`, injects `edc-context/index.md` into the conversation (or surfaces a staleness warning derived from `manifest.sourceCommit` vs HEAD).

`pretooluse-context-inject.mjs` runs before every `Edit`/`Write`/`Bash`: extracts paths from the tool input, routes them through `edc-route.sh`, dedups per-session, and injects the matching `modules/<name>.md` into the agent's context. Pi's adapter wires Pi's lifecycle events onto the same shared `route.mjs` lib.

## Global Invariants

- **Manifest is the single routing/policy source of truth.** Every router (shell, JS, Pi adapter) reads `edc-context/manifest.json` and only that. No hard-coded module lists.
- **Deterministic vs LLM split.** Shell scripts own routing, freshness gating, manifest provenance fields, validation, and exit codes. LLM subagents only author markdown summaries and the LLM-owned subset of `manifest.json`. `edc-manifest.sh` actively rejects LLM attempts to author `generatedAt`, `sourceCommit`, or coverage counts.
- **Clean-slate subagents.** Every analysis subagent (`edc-module-context-impl`, `edc-audit`, `edc-review`) runs without inheriting parent conversation. Findings are based on code, not on what someone said earlier.
- **Freshness is a hard gate.** `edc-assert-fresh.sh` requires `manifest.sourceCommit == HEAD` AND `index.md` contains at least one `##` heading. Stale context blocks `edc review`/`audit` until rebuilt.
- **Schema version: 2.** v1 markers (top-level `edc-context/.meta.json` or `edc-context/context.md`) cause hard refusal — no silent migration.
- **Path source-of-truth: `edc-paths.sh` (shell) and `hooks/lib/paths.mjs` (JS).** No `.context/` literals are allowed in production code (enforced by t16).

## Trust Boundaries

- **`curl|bash` install** (`install.sh`, remote agents): no integrity check on fetched scripts. Acceptable for a developer tool, but worth noting.
- **`scripts/edc-review.sh`**: `target` argument is interpolated into `git diff "${base}..${target}"` — caller-controlled string flows into shell. Mitigated by the fact that `target` originates from user CLI input, not untrusted sources.
- **`.edcignore`**: write access to this file allows suppressing review of arbitrary paths. Not a vulnerability; an intentional knob that escalates with repo write access.
- **Inject mode** (auto-context injection): enforced Claude-only at the CLI layer. Other agents stay in advisory mode by default.
- **Spawned subprocesses**: tool allowlist is locked per spawn (t1 verifies the exact `--allowed-tools` string in `edc-spawn.sh`). Codex spawns isolate `$CODEX_HOME` to avoid cross-run contamination.

## Blast-Radius Summary

Most-impactful files (any change here affects every agent and every command):

- `plugins/edc/scripts/edc-paths.sh` + `plugins/edc/hooks/lib/paths.mjs` — change a path constant, every orchestrator follows.
- `plugins/edc/scripts/edc-route.sh` — single routing implementation; changes affect hooks, review, audit, build coverage.
- `plugins/edc/scripts/edc-manifest.sh` — gates manifest authorship; relaxing its rejections reopens cross-cutting bugs.
- `plugins/edc/prompt-bundles/edc-module-context-impl/SKILL.md` — every per-module doc in this directory was produced by following its instructions.
- `edc-context/manifest.json` — runtime routing depends on its `modules[].match` patterns being accurate.

Lower blast radius: per-module docs (`edc-context/modules/*.md`), benchmark target configs (curl/redis), individual hardening tests.

## Reports

- [reports/issues.md](reports/issues.md) — known problems and risks.
- [reports/complexity.md](reports/complexity.md) — overengineering / bloat / duplication signals.

## Untested Areas

- Pi adapter event wiring (`agents/pi/index.mjs`) — manual verification only; Pi's runtime is not in CI.
- Remote install fetch (`install.sh` from GitHub raw) — no integrity check; not exercised by hardening tests.
- GEPA optimizer (`benchmark/gepa/`) — long-running; covered by smoke checks but not full convergence.
