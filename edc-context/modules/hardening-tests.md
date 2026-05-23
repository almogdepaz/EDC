# hardening-tests

Shell-based smoke-test suite that pins the behavioral contracts of every edc orchestrator, helper, and integration point. All tests live under `tests/hardening/` and are run from the repo root via `bash tests/hardening/<test>.sh`. Each test is hermetic: it creates its own `mktemp -d` workspace, isolates git config via `GIT_CONFIG_GLOBAL=/dev/null`, and traps cleanup on exit.

## Test inventory

### t1 — tool lockdown
**File:** `tests/hardening/t1-tool-lockdown.sh`  
**Guards against:** `claude -p` subprocesses spawned without `--allowed-tools` (capability creep).

Statically checks the array-based `claude -p` spawn in `plugins/edc/scripts/edc-lib.sh` and asserts both prompt modes have explicit lockdowns: legacy inline prompts get `--allowed-tools "Skill,Bash,Read,Write,Edit,Grep,Glob"`; prompt-file mode gets the tighter `--allowed-tools "Read,Write,Bash,Grep,Glob"`.

---

### t2 — stream filter
**File:** `tests/hardening/t2-stream-filter.sh`  
**Guards against:** NDJSON stream parsing regressions; silent jq failures; missing `--output-format stream-json --verbose` flag.

Three sub-checks:
1. `scripts/edc-review.sh` has the `command -v jq` fail-fast guard that exits `2`.
2. Sources `stream_filter()` from `plugins/edc/scripts/edc-runtime.sh` via `awk`-extraction and feeds it synthetic NDJSON payloads — verifies assistant text renders, tool_use events render with `→ Read(` prefix, and `is_error` result events go to stderr as `ERROR (subprocess)`.
3. The array-based `claude -p` spawn in `edc-lib.sh` has `--output-format stream-json --verbose`.

---

### t3 — content validation (stub-fraud defense)
**File:** `tests/hardening/t3-content-validation.sh`  
**Guards against:** agent producing structureless (heading-free) output that passes as a valid context or report.

Four sub-checks in a hermetic git repo:
- `3a`: `--check-context` rejects `edc-context/index.md` with no `## ` headings, with a descriptive error.
- `3b`: `--consolidate` rejects a per-module report with no `## ` headings.
- `3c`: a valid report (has `## Summary`) passes `--consolidate` cleanly (exit 0).
- `3d`: `edc-context/manifest.json` declares `schemaVersion == 2`.

---

### t4 — timeouts + pipe guards
**File:** `tests/hardening/t4-timeouts-pipe-guards.sh`  
**Guards against:** hung subprocesses, silent empty-string comparison on malformed manifest.

Six sub-checks:
- `4a/4b`: `TIMEOUT_BIN` detection and `run_with_timeout` present; `edc-spawn.sh` wraps ≥3 per-CLI branches.
- `4c`: `EDC_BUILD_TIMEOUT`, `EDC_UPDATE_TIMEOUT` (in `edc-recover-context.sh`) and `EDC_REVIEW_TIMEOUT` (in `edc-review.sh`) all have env-override defaults.
- `4d`: sources `run_with_timeout()` from `edc-runtime.sh` via awk extraction; fast command succeeds.
- `4e`: slow command (`sleep 5` under 1s budget) fires the timeout and prints `timed out` to stderr.
- `4f`: `--check-context` on a manifest missing `sourceCommit` exits non-zero with a clear error (not silent empty-string comparison).

---

### t5 — portability / plugin install
**File:** `tests/hardening/t5-portability-install.sh`  
**Guards against:** running under bash < 4; unsafe `$ARGUMENTS` quoting; stale or missing plugin install.

Sub-checks:
- `5a/5b`: bash version gate (`BASH_VERSINFO[0]` check + `brew install bash` hint) present and exits `2`.
- `5c`: `$ARGUMENTS` in the Claude command file (`plugins/edc/commands/edc-run-review.md`) is word-split via `set -- $ARGUMENTS` and forwarded as `"$@"`, never used bare.
- `5d`: public command surface exposes only build/update/run-review/doctor; public skills expose only `edc-review` and `edc-audit`; hidden prompt bundles live under `plugins/edc/prompt-bundles/`.
- `5e`: `plugins/edc/scripts/edc-review.sh` exists in the plugin bundle.
- `5f`: `installOrchestratorScript` present in `plugins/edc/hooks/session-start.mjs`.
- `5g`: pi install path copies `~/.edc/skills` for spawned subprocesses.
- `5h`: Node.js install logic copies the plugin script to `<project>/.edc/scripts/edc-review.sh` with mode `0755`.
- `5i`: stale-detection fires when plugin script mtime > project copy mtime.

---

### t6 — auto-mode pipeline (claude)
**File:** `tests/hardening/t6-auto-mode.sh`  
**Guards against:** `run_with_timeout`-cannot-exec-shell-functions regression; stale-context recovery dropping `--base`; missing final review file.

End-to-end pipeline with a hermetic mock `claude` binary that dispatches on prompt content:
- `edc-update-impl` / `# Update Context (v2)` → refreshes `manifest.json:sourceCommit` to HEAD.
- `edc-build` → writes valid `edc-context/{index.md,manifest.json,modules/root.md}`.
- `TASK FILE: <path>` → writes `review-tasks/report-<module>.md` with `## Summary`.

Assertions:
- Orchestrator exits 0.
- Stale-context recovery passed `--base HEAD~1` to the update skill (captured in `.mock-update-prompt`).
- Final `review-*.md` file produced with `## ` headings.
- Per-module `review-tasks/report-*.md` files present.

---

### t7-cli-entrypoint — CLI wrapper routing
**File:** `tests/hardening/t7-cli-entrypoint.sh`  
**Guards against:** `scripts/edc` routing to wrong orchestrator; missing `--agent` enforcement; stale project-local script preference.

Uses fake `bash`, `claude`, `cursor`, `codex` binaries that record invocation args. Checks:
- `7a/7b`: `build` and `review` both reject missing `--agent` with a clear error.
- `7c`: `build` for claude/cursor/codex exports `EDC_AGENT_CLI` and invokes `edc-build.sh` with forwarded `--force`/`--ignore` args.
- `7f`: `find_review_script()` prefers the repo's `edc-review.sh` over a stale `.edc/scripts/` copy; review exports `EDC_AGENT_CLI` and forwards `HEAD --base main --ignore` args.
- `7g`: `install.sh` contains `install_terminal_cli`, `write_cursor_commands`, and `write_codex_skills`.

---

### t7-codex-auto-mode — auto-mode pipeline (codex)
**File:** `tests/hardening/t7-codex-auto-mode.sh`  
**Guards against:** codex-specific flag contract regressions; prompt routing via private project-local `.edc/skills/` before public codex skills.

Mirror of t6 for `EDC_AGENT_CLI=codex`. Mock `codex exec` validates required flags (`--json`, `--color never`, `--sandbox workspace-write`) and stdin sentinel `-` before dispatching on prompt content. Same four assertions as t6 (exit 0, `--base` preserved, final file present with headings, per-module reports present).

---

### t8 — ignore rules
**File:** `tests/hardening/t8-ignore-rules.sh`  
**Guards against:** `.edcignore` not filtering; `--ignore` flag not overriding `.edcignore`.

Two sub-checks in a hermetic repo with `src/keep.txt` and `generated/skip.txt`:
- `8a`: `.edcignore` with `generated/**` causes `--build` to include `src/keep.txt` and exclude `generated/skip.txt` in `review-tasks/manifest.json`.
- `8b`: `--ignore src/**` overrides `.edcignore`, including `generated/skip.txt` and excluding `src/keep.txt`.

---

### t9 — routing contract
**File:** `tests/hardening/t9-routing.sh`  
**Guards against:** routing tier-order or tie-break regressions in `plugins/edc/scripts/edc-route.sh`.

Seven parameterized cases using a synthetic `manifest.json`:
1. `exactFiles` beats `prefixes` regardless of priority.
2. Longest prefix wins over shorter prefix.
3. Priority breaks tie when prefix lengths are equal.
4. Glob matches extensionless paths.
5. No match → exit 1, empty stdout.
6. Tied top-priority candidates (same tier + priority, same file, different modules) → exit 2, empty stdout (ambiguity).
7. Prefix tier wins over glob tier even with lower priority number.

---

### t10 — pi extension
**File:** `tests/hardening/t10-pi-extension.sh`  
**Guards against:** broken pi extension wiring; missing exports from shared lib; factory not registering expected commands/events; context injection not firing.

Four sub-checks:
1. `package.json` declares `pi.extensions` pointing at `./agents/pi/index.mjs`.
2. `agents/pi/index.mjs` parses (`node --check`).
3. `plugins/edc/hooks/lib/route.mjs` exports all 14 expected helper functions (`loadManifest`, `manifestPath`, `checkStaleness`, `extractFilePaths`, `extractFilePathsFromBash`, `normalizePath`, `routeFile`, `moduleDocPath`, `dedupPath`, `isDuplicate`, `isEdcProject`, `installOrchestratorScript`, `resolvePluginRoot`, `buildSessionStartContent`, `buildToolCallInjection`).
4. Extension factory wiring via fake `ExtensionAPI`: registers only user-facing commands (`edc-build`, `edc-update`, `edc-run-review`, `edc-doctor`), command handlers send the rendered command prompt back into pi, `resources_discover` returns only `edc-review` and `edc-audit`, `session_start` installs runtime scripts plus private prompt bundles, and `tool_call` on `src/foo.ts` injects module doc content containing `src-mod`.

---

### t11 — audit orchestrator
**File:** `tests/hardening/t11-audit-orchestrator.sh`  
**Guards against:** audit orchestrator failing to recover from missing/stale context; accepting structureless or incomplete audit reports.

Uses a scenario-file-controlled mock `claude`. Four scenarios:
- `11a`: missing `edc-context/` → build recovery fires → audit produces both `complexity.md` and `issues.md`.
- `11b`: stale context (`sourceCommit=deadbeef`) → update recovery fires → both reports produced.
- `11c`: fresh context, audit mock skips `issues.md` → orchestrator exits non-zero with `audit report missing`.
- `11d`: audit mock writes structureless `complexity.md` (no headings) → orchestrator exits non-zero with `no '## ' headings`.

---

### t12 — build orchestrator
**File:** `tests/hardening/t12-build-orchestrator.sh`  
**Guards against:** wrong routing decision in `edc-build.sh` (build vs update vs refuse); v1 layout not being blocked.

Mock `claude` logs `build` or `update` to a shared log file. Five scenarios:
- `12a`: no `edc-context/` → `build` logged.
- `12b`: healthy v2 + new commit, no `--force` → `update` logged.
- `12c`: healthy v2 + `--force` → `build` logged (wipe first).
- `12d`: partial v2 (no `manifest.json`) → `build` logged.
- `12e`: v1 layout (`edc-context/.meta.json` present) → exit non-zero with `legacy v1` + `rm -rf edc-context` hint; agent NOT spawned.

---

### t13 — update orchestrator
**File:** `tests/hardening/t13-update-orchestrator.sh`  
**Guards against:** update orchestrator acting on invalid state; `--base` not being passed or auto-detected.

Five scenarios with mock `claude`:
- `13a`: no `edc-context/` → refuse with `no edc-context/` + `edc-build` hint; no spawn.
- `13b`: partial v2 (no manifest) → refuse with `partial or malformed` + `force` hint; no spawn.
- `13c`: v1 layout → refuse with `legacy v1` + `rm -rf edc-context` hint; no spawn.
- `13d`: healthy v2 → spawn update; `--base` auto-detected from `main` branch and present in prompt.
- `13e`: explicit `--base main` → forwarded verbatim as `--base main` in the skill prompt.

---

### t14 — resolve-prompt decoupling
**File:** `tests/hardening/t14-resolve-prompt-decoupled.sh`  
**Guards against:** `resolve_prompt` emitting slash commands (which require plugin install); missing skill content; incomplete review bundle; missing `Do not improvise` directive.

Uses a hermetic `$HOME` with symlinked skills tree. Covers claude, cursor, codex:
- No slash commands (no `/edc:` prefix) for any agent on any action.
- `build`, `update`, `audit` each emit their SKILL.md content inline.
- Args string (`--force --focus broker`) prefixed correctly when provided; absent when no args.
- Review prompt embeds full 6-file bundle: task content + SKILL.md + methodology + adversarial + reporting + patterns.
- Review prompt contains `Do not improvise` directive.
- Missing SKILL.md → clear `skill 'edc-build-impl' not found` error.
- Missing supporting file (`methodology.md`) → clear `review skill bundle incomplete` error.

---

### t15 — review routing
**File:** `tests/hardening/t15-review-routing.sh`  
**Guards against:** naive top-level-dir grouping instead of manifest-driven routing; silent unmapped file handling; wrong exit codes for policy violations.

Seven sub-cases:
- `15.1`: `src/broker/*` → `broker-client` module; `src/server/*` → `server` module (NOT synthetic `src` bucket).
- `15.2`: `exactFiles` match routes to declared module.
- `15.3a/b`: `warn-allow` policy groups unexpected unmapped file into `review-tasks/unmapped.md` and logs `WARNING:` with filename.
- `15.4a/b`: expected unmapped file matching `allowedGlobs` still groups under `unmapped` but suppresses the `WARNING:` line.
- `15.5a/b`: `fail` policy exits `2` on unexpected unmapped file and lists offending file in error.
- `15.6a/b`: ambiguous routing (two modules, same prefix, same priority) exits `2` with `match multiple modules` message.
- `15.7`: every name in `review-tasks/manifest.json` is either declared in `edc-context/manifest.json` or the literal `"unmapped"` — no synthetic invented buckets.

---

### t16 — context-dir source-of-truth
**File:** `tests/hardening/t16-context-dir-source-of-truth.sh`  
**Guards against:** stray hardcoded `.context/` literals replacing canonical `edc-context/` path; scripts bypassing the central path constants.

Seven sub-checks:
- `16.1a/b`: `plugins/edc/scripts/edc-paths.sh` exists and exports `EDC_CONTEXT_DIR=edc-context`, `EDC_MANIFEST`, `EDC_INDEX`, `EDC_MODULES_DIR`, `EDC_REPORTS_DIR` with correct defaults.
- `16.2a/b`: `plugins/edc/hooks/lib/paths.mjs` exists and declares `EDC_CONTEXT_DIR = "edc-context"`.
- `16.3`: no production shell script under `plugins/edc/scripts/` contains literal `.context/`.
- `16.4`: no hook `.mjs` uses literal `".context"` for path joining.
- `16.5`: all 9 orchestrator scripts (`edc-review.sh`, `edc-clean-slate.sh`, `edc-audit.sh`, `edc-build.sh`, `edc-update.sh`, `edc-assert-fresh.sh`, `edc-recover-context.sh`, `edc-doctor.sh`, `edc-build-plan.sh`) reference `edc-paths.sh`.
- `16.6`: `plugins/edc/hooks/lib/route.mjs` imports from `./paths.mjs`.
- `16.7`: no skill markdown contains the old `.context/` literal.

---

## Test harness conventions

**Hermetic git repos.** Every test that exercises file-system or git behavior creates a `mktemp -d` workspace, sets `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_SYSTEM=/dev/null`, configures `commit.gpgsign=false`, and traps `rm -rf` on exit. This prevents host git config (GPG signing, hooks) from breaking tests.

**Mock binaries.** End-to-end tests (t6, t7-codex, t11, t12, t13) inject a mock `claude` (or `codex`) as a shell script at the front of `$PATH`. Mocks dispatch on prompt content via pattern matching (`[[ "$prompt" == *"marker"* ]]`). The ordering of pattern checks is documented in comments (e.g., check `edc-update-impl` before `edc-build` because update skill content references build strings).

**Awk-extracted functions.** t2 and t4 source individual functions (`stream_filter`, `run_with_timeout`) from runtime helpers using `awk` range patterns. This avoids sourcing the entire script and side effects.

**Counter pattern.** t9, t10, t14, t15, and t16 use `PASS/FAIL` counters with a `check()` helper. The test exits non-zero if `$FAIL -gt 0`. Counters in t15 live in temp files (not shell variables) to survive subshell-scoped checks in parallel subgroups.

**Scenario files.** t11 uses a `$TMPDIR_T11/scenario` file read by the mock at runtime to switch between `valid`, `missing-issues`, and `stub-complexity` behaviors without rewriting the mock binary.

**Static + runtime checks.** Most tests combine static grep/awk checks (contract is wired in source) with live runtime execution (contract holds at runtime). Static checks alone are insufficient because code paths may be dead; runtime alone is insufficient because structure violations may not crash.

---

## Regression catalog

| Regression | Guarded by |
|---|---|
| `claude -p` without `--allowed-tools` capability leak | t1 |
| jq not installed → silent parse failure | t2 |
| `--output-format stream-json --verbose` missing → no stream output | t2 |
| Agent writes structureless report that passes as context | t3 |
| Subprocess hangs with no timeout | t4 |
| `run_with_timeout` cannot exec shell functions | t6 |
| Stale-context recovery drops `--base` when spawning edc-update | t6, t7-codex |
| `$ARGUMENTS` bare-expansion word-splitting in Claude command file | t5 |
| Plugin script not installed or not executable | t5 |
| bash < 4 silently misbehaves | t5 |
| `scripts/edc` routing to wrong orchestrator | t7-cli |
| Missing `--agent` flag accepted silently | t7-cli |
| Stale `.edc/scripts/edc-review.sh` preferred over repo copy | t7-cli |
| `.edcignore` or `--ignore` flag not filtering files | t8 |
| exactFiles not winning over prefixes/globs | t9 |
| Longest-prefix tie-break broken | t9 |
| Ambiguity not producing exit 2 | t9 |
| pi extension not registering commands or subscribing to events | t10 |
| `buildToolCallInjection` not injecting module docs | t10 |
| Audit orchestrator not recovering missing/stale context | t11 |
| Audit accepting incomplete or structureless reports | t11 |
| `edc-build.sh` routing UPDATE when it should BUILD (or vice versa) | t12 |
| v1 layout not blocked with migration hint | t12, t13 |
| `edc-update.sh` spawning build instead of update | t13 |
| `--base` not auto-detected or not forwarded | t13 |
| `resolve_prompt` emitting slash commands → requires plugin install | t14 |
| Review prompt missing supporting files (methodology etc.) | t14 |
| `Do not improvise` guard missing from review prompt | t14 |
| Naive top-level-dir grouping instead of manifest-driven routing | t15 |
| Unmapped file silently dropped (no warn/fail) | t15 |
| Ambiguous module match not exiting 2 | t15 |
| Synthetic invented module names in review-tasks | t15 |
| Stray `.context/` literals bypassing edc-paths.sh | t16 |
| Orchestrator not sourcing edc-paths.sh | t16 |
