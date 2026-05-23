# Module: plugin-surface

**Scope:** `plugins/edc/.claude-plugin/`, `plugins/edc/commands/`, `plugins/edc/hooks/`, `plugins/edc/scripts/`, `plugins/edc/README.md`

---

## Overview

`plugin-surface` is the EDC plugin's entire public and internal API surface: it defines what users invoke, how Claude Code's hook lifecycle loads context into the session, and the complete orchestration shell-script layer that drives all LLM subprocesses. Everything a user can trigger and everything the runtime does automatically is defined here.

The central design principle is **script-as-orchestrator**: every decision about routing, scheduling, subprocess invocation, freshness gating, and output validation happens in deterministic bash. LLM subprocesses are narrowly scoped to one action each (build, update, audit, review one module) and cannot deviate from their task.

---

## Command Surface (`commands/`)

Four user-facing slash commands are defined as markdown files with YAML frontmatter. All share the pattern: `allowed-tools: [Bash]` only — the host session can do nothing except exec an orchestrator script and surface its output.

| Command | File | Script invoked |
|---|---|---|
| `/edc:edc-build` | `edc-build.md` | `.edc/scripts/edc-build.sh` or `~/.edc/scripts/edc-build.sh` |
| `/edc:edc-update` | `edc-update.md` | `.edc/scripts/edc-update.sh` |
| `/edc:edc-run-review` | `edc-run-review.md` | `.edc/scripts/edc-review.sh` |
| `/edc:edc-doctor` | `edc-doctor.md` | `.edc/scripts/edc-doctor.sh` |

Audit/review methodology is exposed as skills (`edc-audit`, `edc-review`), not command shims. The terminal CLI still exposes `edc audit`, but agent autocomplete stays limited to product-level actions.

Script lookup order: `.edc/scripts/` (project-local, installed by session-start hook) → `~/.edc/scripts/` (user-global install). If neither exists, the command emits `SCRIPT_MISSING` and stops. Commands never retry on failure and never attempt the work inline.

---

## Hook Lifecycle (`hooks/`)

### `hooks.json` — Registration

```json
{
  "hooks": {
    "SessionStart": [{ "matcher": "startup|resume|clear|compact",
                       "command": "node hooks/session-start.mjs" }],
    "PreToolUse":   [{ "matcher": "Edit|Write|Bash",
                       "command": "node hooks/pretooluse-context-inject.mjs",
                       "timeout": 5 }]
  }
}
```

Two hooks: one fires at session boundaries, one fires before every guarded tool call.

### `session-start.mjs` — Session Boundary Hook

Runs on `startup|resume|clear|compact`. Responsibilities:

1. **Platform detection** — heuristically distinguishes Claude Code (plain string output) from Cursor (`{ additional_context: ... }` JSON output) based on input keys.
2. **Project root resolution** — from `input.cwd`, `CLAUDE_PROJECT_ROOT`, `CURSOR_PROJECT_DIR`, or `process.cwd()`.
3. **Orchestrator install** — calls `installOrchestratorScript(projectRoot, pluginRoot)` to copy `edc-review.sh` into `<projectRoot>/.edc/scripts/` if missing or stale (mtime comparison). Idempotent, best-effort.
4. **Context injection** — calls `buildSessionStartContent(projectRoot)`:
   - No manifest: emits a "run `/edc-build`" advisory.
   - `policy.defaultMode === "advisory"`: no-op (returns empty string).
   - Fresh manifest with inject mode: injects `edc-context/index.md` content, prepending a staleness warning if `manifest.sourceCommit !== HEAD`.

Errors are caught and written to stderr; stdout always gets valid output (empty string on error = no injection, never crashes Claude Code).

### `pretooluse-context-inject.mjs` — Per-Tool Context Hook

Fires before every `Edit`, `Write`, or `Bash` tool call. Responsibilities:

1. **Parse tool input** — extracts `tool_name`, `tool_input`, `session_id`, `cwd`.
2. **Path extraction** — calls `extractFilePaths(toolName, toolInput)`:
   - `Edit`/`Write`: reads `tool_input.file_path` directly.
   - `Bash`: regex-scans the command string for path-shaped tokens (`extractFilePathsFromBash`).
3. **Manifest routing** — for each candidate path, calls `routeFile(manifestPath, normalizedPath, pluginRoot)` which execs `edc-route.sh`. Exit 0 = module name on stdout; exit 1 = no match; exit 2 = ambiguous (both treated as no-inject).
4. **Session-level dedup** — `isDuplicate(sessionId, moduleName)` uses a tmpfile at `$TMPDIR/edc-injected-modules-<session-hash>.json` to ensure each module doc is injected at most once per session.
5. **Injection** — reads `edc-context/modules/<name>.md` and returns it as `additionalContext` in the hook output format appropriate to the platform.

Output format:
- Claude Code: `{ hookSpecificOutput: { hookEventName, additionalContext } }`
- Cursor: `{ additional_context: ... }`
- On error or no match: `{}`

### `hooks/lib/paths.mjs` — Path Constants

Single source of truth for JS side of directory layout, mirroring `edc-paths.sh`:

```js
EDC_CONTEXT_DIR = "edc-context"
EDC_MANIFEST_REL = "edc-context/manifest.json"
EDC_INDEX_REL    = "edc-context/index.md"
EDC_MODULES_DIR_REL = "edc-context/modules"
EDC_REPORTS_DIR_REL = "edc-context/reports"
```

### `hooks/lib/route.mjs` — Shared Routing Library

Pure functions shared by both hooks AND the Pi extension (`agents/pi/index.mjs`). Key exports:

| Function | Purpose |
|---|---|
| `resolvePluginRoot(metaUrl)` | Walk up from caller's URL to find dir containing `scripts/` + `skills/`; env override `EDC_PLUGIN_ROOT` wins |
| `loadManifest(projectRoot)` | Read and parse `manifest.json`, return null on missing/invalid |
| `checkStaleness(projectRoot, manifest)` | Compare `manifest.sourceCommit` to `git rev-parse HEAD` |
| `extractFilePaths(toolName, toolInput)` | Accept both Claude-style (`Edit`) and Pi-style (`edit`) tool names |
| `extractFilePathsFromBash(command)` | Regex scan for path-shaped tokens |
| `normalizePath(p, projectRoot)` | Strip `./` prefix and projectRoot prefix |
| `routeFile(manifestPath, filePath, pluginRoot)` | Exec `edc-route.sh`, return module name or null |
| `moduleDocPath(manifest, moduleName)` | Look up `module.doc` field in manifest |
| `isDuplicate(sessionId, moduleName)` | Tmpfile-based dedup with SHA-256 session ID sanitization |
| `installOrchestratorScript(projectRoot, pluginRoot)` | Copy `edc-review.sh` to `.edc/scripts/` if needed |
| `buildSessionStartContent(projectRoot)` | Composite: load manifest, check staleness, build injection text |
| `buildToolCallInjection({...})` | Composite: route file, dedup, read module doc, return injection payload |

---

## Script Layer (`scripts/`)

All scripts require bash ≥ 4. Every orchestrator sources `edc-paths.sh` first.

### `edc-paths.sh` — Directory Layout Constants (Shell)

Defines all path variables as exported shell strings, repo-relative. Every other script sources this. `EDC_CONTEXT_DIR` is overrideable via env.

```bash
EDC_CONTEXT_DIR="edc-context"
EDC_MANIFEST="$EDC_CONTEXT_DIR/manifest.json"
EDC_INDEX="$EDC_CONTEXT_DIR/index.md"
EDC_MODULES_DIR="$EDC_CONTEXT_DIR/modules"
EDC_REPORTS_DIR="$EDC_CONTEXT_DIR/reports"
EDC_BUILD_DIR="$EDC_CONTEXT_DIR/build"
EDC_ISSUES="$EDC_REPORTS_DIR/issues.md"
EDC_COMPLEXITY="$EDC_REPORTS_DIR/complexity.md"
EDC_BUILD_INFO="$EDC_BUILD_DIR/build.json"
```

### `edc-route.sh` — Path-to-Module Router

**Contract:** `edc-route.sh <manifest-path> <file-path>`

Exit codes:
- `0` — single module wins; module name on stdout
- `1` — no match
- `2` — ambiguous (two modules at same tier, same priority); stderr: `"ambiguous: <m1> <m2>"`
- `64` — usage/setup error

Algorithm (three tiers, priority breaks ties within a tier):

1. **T1 `exactFiles`** — exact string equality. First tier to match wins outright.
2. **T2 `prefixes`** — longest matching prefix wins. Among equal-length prefixes, higher `priority` wins.
3. **T3 `globs`** — bash `[[ $file == $pattern ]]`. Among all matching globs, higher `priority` wins.

Implementation: one `jq` pass dumps all rules as TSV `tier<TAB>name<TAB>priority<TAB>pattern` into a variable; bash then walks in memory — avoids O(modules × tiers) jq subprocess forks. `pick_winner` resolves ties; returns ambiguous if multiple modules share max priority at the winning tier.

This is the **single source of truth for routing** — used by hooks (via `route.mjs`), by `edc-review.sh`'s build-mode grouping, by `edc-manifest.sh`'s coverage walk, and by `edc-doctor.sh`'s full-repo validation.

### `edc-manifest.sh` — Deterministic Post-Step

**Contract:** reads partial LLM-authored manifest from stdin, validates, fills deterministic fields, writes complete manifest to stdout.

Enforces the LLM/post-step ownership boundary:
- **Rejects** input that already contains `generatedAt`, `sourceCommit`, or non-empty `coverage` — these must not be LLM-authored.
- **Requires** all structural fields: `schemaVersion`, `edcVersion`, `repoContextFile`, `reports`, `build`, `policy`, `modules`.
- **Requires** every module to declare `priority`.
- **Fills** `generatedAt` (UTC ISO8601), `sourceCommit` (`git rev-parse HEAD`), and coverage counts by walking `git ls-files` and routing each path via `edc-route.sh`.

Exit codes: 0 = success, 1 = validation failure, 64 = setup error (missing jq/git/route.sh).

### `edc-clean-slate.sh` — Build-State Classifier and Wiper

Modes:
- `--check`: classify on-disk state. Exit 0 = no context dir; exit 10 = partial/malformed v2; exit 11 = healthy v2; exit 12 = v1 layout detected (refuses to act, prints migration hint).
- `--force`: unconditionally wipe `edc-context/` and `AGENTS.md`. Refuses if v1 markers present.
- `(default)`: wipe only if partial v2 detected.

**V1 markers** (any of): `.meta.json`, `context.md`, `full-context.md`, `issues.md`, `complexity.md` at the top of `edc-context/`. These are legacy layout indicators; v2 puts reports under `reports/`.

**Healthy v2**: `manifest.json` exists and `jq -e '.schemaVersion == 2'` passes.

### `edc-assert-fresh.sh` — Freshness Gate

Dual-use: exec'd directly (exit 0/1/2) or sourced to define `assert_context_fresh` and `read_manifest_source_commit`.

`assert_context_fresh` checks:
1. `manifest.json` exists
2. `git rev-parse HEAD` matches `manifest.sourceCommit`
3. `edc-context/index.md` exists AND has at least one `## ` heading (stub detection)

`read_manifest_source_commit` uses grep+sed (no jq dependency) to extract `sourceCommit` for performance in the hot path.

### `edc-runtime.sh` — Subprocess Runtime Helpers

Sourced by every orchestrator. Provides:

- **`TIMEOUT_BIN`**: detected `timeout` (Linux) or `gtimeout` (macOS/coreutils). Falls back to background watchdog if neither is available.
- **`run_with_timeout <secs> <label> <cmd...>`**: wraps command with timeout. On watchdog path, preserves stdin via fd 3 to allow here-string passthrough; kills both watchdog and cmd on completion.
- **`ensure_codex_exec_home` / `cleanup_codex_exec_home`**: manages an isolated `CODEX_HOME` temp dir for codex subprocess isolation. Auto-installs EXIT trap.
- **`stream_filter`**: reads NDJSON from agent CLI stdout, translates to human-readable progress. Handles Claude (`type=assistant`, `type=tool_use`), Cursor (`type=tool_call` with `subtype=started`), Codex (`msg.type=agent_message/agent_reasoning/exec_command_begin`), and error events (`type=result is_error=true`, `type=error`, `msg.type=error`).

### `edc-spawn.sh` — Per-CLI Subprocess Dispatcher

Sourced by orchestrators. Defines single function:

```bash
edc_spawn <phase-label> <timeout-secs> <prompt-string>
```

Dispatch by `$EDC_AGENT_CLI`:
- `claude`: `claude -p --output-format stream-json --verbose --allowed-tools "Skill,Bash,Read,Write,Edit,Grep,Glob" <<< "$prompt"`
- `cursor`: `cursor agent -p --output-format stream-json --force --trust <<< "$prompt"`
- `codex`: `env CODEX_HOME="$CODEX_EXEC_HOME" codex exec --json --color never --sandbox workspace-write - <<< "$prompt"`

All three pipe through `stream_filter` and are wrapped with `run_with_timeout`. Prompt is passed via here-string on stdin. The `--allowed-tools` lockdown on claude is intentional — review subprocesses must not use arbitrary tools.

### `edc-resolve-prompt.sh` — Prompt Builder

Sourced by orchestrators. Defines `resolve_prompt <action> [args...]`:

| Action | Skill | Notes |
|---|---|---|
| `build` | `edc-build-impl` | Args prepended as "CLI arguments" context |
| `update` | `edc-update-impl` | Args prepended |
| `audit` | `edc-audit` | No args |
| `review` | `edc-review` | Full bundle embed (see below) |

Skill discovery by agent:
- `claude`: `.edc/skills/<name>/SKILL.md` → `~/.edc/skills/<name>/SKILL.md` → `~/.claude/plugins/marketplaces/edc/plugins/edc/skills/<name>/SKILL.md`
- `cursor`: `.cursor/skills/<name>/` → `~/.cursor/skills/<name>/`
- `codex`: `.codex/skills/<name>/` → `~/.codex/skills/<name>/`

**Review prompt embedding**: `_emit_review_prompt` embeds the full `edc-review` bundle inline (SKILL.md + methodology.md + adversarial.md + reporting.md + patterns.md). This prevents subagents from improvising methodology when only a file path was given. Each section is delimited by `=====` banners. The task file content is also embedded inline (not just a path).

### `edc-recover-context.sh` — Context Recovery State Machine

Sourced by `edc-review.sh` and `edc-audit.sh`. Defines `recover_context_if_needed [build_args... -- update_args...]`.

State machine:
1. `assert_context_fresh` → return 0 immediately if already fresh.
2. Classify: `MISSING` (no manifest, or index.md missing/structureless, or git failed) vs `STALE` (sourceCommit ≠ HEAD).
3. Wipe v1/partial-v2 leftovers via `edc-clean-slate.sh`.
4. Spawn build (MISSING) or update (STALE) via `edc_spawn`.
5. Re-check freshness. If still not fresh: wipe with `--force` and retry build once.
6. Final check. On failure: emit copy-pasteable manual-repair hint and return 1.

Arg splitting: `--` separator divides build-only args from update-only args. Without separator, all args go to both.

### `edc-build.sh` — Build Orchestrator

Full pipeline for `/edc:edc-build`:
1. Dep check (jq, git).
2. Parse args (`--force`, `--focus <module>`, `--ignore <glob>`).
3. **Routing decision in shell** (`decide_route`): call `edc-clean-slate.sh --check`:
   - Exit 0 → `"build"` (no context dir)
   - Exit 11 + no `--force` → `"update"` (healthy v2, incremental)
   - Exit 11 + `--force` → `"wipe-and-build"`
   - Exit 10 → `"wipe-and-build"` (partial v2, always wipe)
   - Exit 12 → `FAIL` (v1 layout, print migration hint)
4. Wipe if route demands it.
5. Spawn `edc-build-impl` or `edc-update-impl` skill via `edc_spawn`.
6. Run `edc-doctor.sh` as final validation gate. Non-zero doctor = build failed.

Timeouts: `EDC_BUILD_TIMEOUT` (default 3600s) for build; `EDC_UPDATE_TIMEOUT` (default 1800s) for update.

### `edc-update.sh` — Incremental Update Orchestrator

Pipeline for `/edc:edc-update`:
1. Preflight: `edc-clean-slate.sh --check` — must return exit 11 (healthy v2). Refuses with actionable hint for missing (rc 0), partial (rc 10), or v1 (rc 12).
2. Auto-detect base ref (`git merge-base HEAD main || git merge-base HEAD master`) if `--base` not given.
3. Spawn `edc-update-impl` skill.
4. Validate with `edc-doctor.sh`.

### `edc-audit.sh` — Audit Orchestrator

Pipeline for terminal/orchestrated `edc audit` runs:
1. Context freshness gate via `recover_context_if_needed` (auto-builds/updates if needed).
2. Spawn `edc-audit` skill.
3. Validate: `edc-context/reports/complexity.md` and `edc-context/reports/issues.md` must exist AND contain at least one `## ` heading (stub detection).

### `edc-review.sh` — Review Orchestrator (Most Complex)

Pipeline for `/edc:edc-run-review`. Modes dispatched by first arg:

| Mode | Trigger | Purpose |
|---|---|---|
| `auto` (default) | any non-flag first arg | Full pipeline: freshness gate → build tasks → per-module agents → consolidate → verify |
| `--build` | `--build <target>` | Task generation only: context gate + diff + routing → write `review-tasks/` + emit TASK lines |
| `--base <ref>` | shorthand | `HEAD --base <ref>` → auto_mode |
| `--check-context` | flag | Assert fresh, print OK or exit 1 |
| `--consolidate` | flag | Merge per-module reports into final `review-<target>.md` |
| `--verify` | flag | Assert fresh + all reports exist + final file exists |

**auto_mode pipeline:**
1. Dep check for chosen agent CLI.
2. `recover_context_if_needed` — blocks until context is fresh or exits non-zero.
3. Self-invoke with `--build <target>` to generate `review-tasks/`.
4. Parse `TASK <path>` lines from `--build` output.
5. For each TASK: resolve full review prompt (embedded bundle), call `edc_spawn "edc-review/<module>"`, call `assert_report_valid` immediately.
6. Self-invoke `--consolidate`.
7. Self-invoke `--verify`.

**build_mode steps:**
1. Context gate: manifest must exist, index.md must have `## ` headings, `sourceCommit == HEAD`.
2. Diff source by target type: GitHub PR URL (`gh pr diff`), local diff file (scan `+++ b/` lines), or git ref (`git diff base..target --name-only`).
3. Filter `edc-context/`, `review-tasks/`, and prior `review-*.md` files from diff output. Apply `.edcignore` (or `--ignore` patterns).
4. Route each file via `edc-route.sh`. Group into `MODULE_FILES` associative array. Unmatched → `"unmapped"` bucket. Ambiguous → fatal (exit 2).
5. Apply `policy.unmatchedPathPolicy` (`fail` / `warn-allow` / `allow`) from manifest.
6. Write `review-tasks/manifest.json` and `review-tasks/<module>.md` per module.
7. Emit `TASK review-tasks/<module>.md` lines.

**assert_report_valid**: report must exist AND contain at least one `## ` heading. Empty or stub reports fail immediately.

**consolidate_mode**: reads `review-tasks/manifest.json`, verifies all reports, writes final `review-<target-slug>.md` with date/HEAD/modules header and per-module sections.

**Ignore support**: `--ignore <glob>` args or `.edcignore` file (comments `#`, blank lines stripped). Pattern matching: exact path, `path/*` prefix, or bash glob.

### `edc-doctor.sh` — Layout and Routing Validator

Deterministic validator run after every build/update. Checks:
1. `AGENTS.md`, `edc-context/index.md`, `edc-context/manifest.json` all exist.
2. `index.md` has `## ` headings.
3. Manifest is valid JSON, `schemaVersion == 2`, `policy.defaultMode` is advisory/inject, `unmatchedPathPolicy == "warn-allow"`.
4. Every `module.doc` path exists on disk.
5. Full repo walk: `git ls-files | edc-route.sh` — orphan tracked paths (exit 1, not in `allowedGlobs`) and ambiguous routings (exit 2) both fail.

Exit 0 = "edc-doctor: ok". Exit 1 = one or more failures listed on stderr.

### `edc-build-plan.sh` — Deterministic Task Planner

**Contract:** reads JSON (`{ modules: [{ name, paths, approxLoc }] }`) from stdin, outputs JSON task list to stdout.

Used by `edc-build-impl` skill to plan parallel per-module context builds. Validates uniqueness of module names, validates `--changed <name1,name2>` filter against actual module names, then emits:

```json
{ "tasks": [{ "kind": "module-context", "module": "...", "paths": [...], "out": "edc-context/modules/<kebab-name>.md", "prompt": "..." }] }
```

Prompt template is a standardized instruction to invoke the `edc-module-context-impl` skill and write directly to the output path. Module names are kebab-cased (lowercase, spaces/underscores → hyphens).

---

## Route/Runtime Data Flow

```
manifest.json
    │
    ├─ edc-route.sh ◄──── file path (from hooks or review build-mode)
    │       │
    │       └─ module name (exit 0) / no-match (exit 1) / ambiguous (exit 2)
    │
    ├─ hooks/lib/route.mjs (JS wrapper)
    │       ├─ session-start: index.md injection, staleness warning
    │       └─ pretooluse: module doc injection, per-session dedup
    │
    └─ edc-review.sh --build
            ├─ routes each changed file → MODULE_FILES map
            ├─ writes review-tasks/<module>.md
            └─ emits TASK lines → auto_mode iterates
                    │
                    └─ edc_spawn "edc-review/<module>"
                            └─ claude/cursor/codex subprocess
                                    │
                                    └─ writes review-tasks/report-<module>.md
                                            │
                                            └─ edc-review.sh --consolidate
                                                    └─ review-<target>.md
```

---

## Deterministic vs LLM Split

| Layer | Owner | What it does |
|---|---|---|
| Shell orchestrators | Deterministic | Routing decisions, freshness gating, wipe/rebuild routing, file I/O, subprocess spawning, output validation, consolidation |
| `edc-route.sh` | Deterministic | Path-to-module routing (3-tier algorithm + priority) |
| `edc-manifest.sh` | Deterministic | Post-step fill: timestamps, sourceCommit, coverage counts |
| `edc-clean-slate.sh` | Deterministic | Build state classification and wipe |
| `edc-doctor.sh` | Deterministic | Full layout and routing validation |
| `edc-build-plan.sh` | Deterministic | Task list generation from module spec |
| LLM subprocesses | LLM | Authoring module docs, index.md, manifest structural fields, audit reports, per-module review reports |

The LLM cannot author `generatedAt`, `sourceCommit`, `coverage.*` — `edc-manifest.sh` actively rejects manifests that contain these fields. The LLM cannot decide "build vs update" — that's `edc-clean-slate.sh`. The LLM cannot decide when a build is valid — that's `edc-doctor.sh`.

---

## Error / Exit Code Conventions

| Script | Exit 0 | Exit 1 | Exit 2 | Other |
|---|---|---|---|---|
| `edc-route.sh` | module matched | no match | ambiguous | 64: usage/setup |
| `edc-manifest.sh` | success | validation failure | bash version | 64: setup |
| `edc-clean-slate.sh` | no-op / wiped | — | bash version | 10: partial v2; 11: healthy v2; 12: v1 layout |
| `edc-assert-fresh.sh` | fresh | not fresh | not a git repo | — |
| `edc-doctor.sh` | all ok | validation failures | dep/setup error | — |
| `edc-review.sh --build` | tasks written | context not ready | bad args/env | — |
| `edc-review.sh --consolidate/--verify` | all pass | assertion failed | bad args | — |
| `edc-build.sh` / `edc-update.sh` / `edc-audit.sh` | success | pipeline failure | dep/arg error | — |

All scripts use `set -euo pipefail` (orchestrators) or `set -uo pipefail` (helpers). Symlink resolution (`_edc_resolve_script_dir`) is done at startup in every orchestrator that sources sibling scripts — without it, symlinked installs in `.edc/scripts/` would fail to find siblings.

---

## Trust Boundaries

- **Host session** (the user's Claude session): `Bash` only. Cannot read, write, or reason about code. It is a pass-through launcher.
- **LLM subprocesses** (`claude -p --allowed-tools "Skill,Bash,Read,Write,Edit,Grep,Glob"`): can touch the filesystem but cannot escape the project directory (codex uses `--sandbox workspace-write`). Their task is narrowly specified via embedded prompts; they cannot improvise methodology.
- **Hooks** (Node.js, 5-second timeout on PreToolUse): execute in the Claude Code harness, read-only file access (manifest, module docs, index). Never write to user files. Best-effort — errors write to stderr but never crash the session.
- **`edc-route.sh`**: exec'd by both hooks (via `execFileSync`) and orchestrators. Treated as a pure function — no side effects.
- **`edc-manifest.sh`**: post-step only. Runs after LLM finishes, before output is used. The validation boundary between LLM-authored and computed fields.

---

## Key Invariants

1. **Routing is always `edc-route.sh`**: hooks, review build-mode, manifest post-step, and doctor all use the same binary. No parallel routing logic.
2. **Context freshness = `sourceCommit == git rev-parse HEAD`**: any staleness is surfaced at session start (hook), gated at review/audit pipeline entry, and auto-recovered via `recover_context_if_needed`.
3. **One subprocess per action**: build, update, audit, and each per-module review each spawn exactly one agent process. No parallelism within a pipeline phase.
4. **Report validation before consolidation**: `assert_report_valid` is called immediately after each module subprocess returns — a missing or stub report fails fast, before consolidation.
5. **Policy mode is manifest-driven**: `policy.defaultMode` controls whether hooks inject context. `advisory` = hooks are silent. `inject` = active injection. The shell never overrides this.
6. **V1 is refused, not auto-migrated**: `edc-clean-slate.sh` prints a copy-pasteable `rm` + rebuild command and exits 12. It never auto-wipes a v1 layout.
