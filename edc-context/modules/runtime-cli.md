# Module: runtime-cli

**Files:** `scripts/edc`, `scripts/edc-review.sh`, `install.sh`, `README.md`, `.edcignore`, `.gitignore`

**Role:** User-facing entry layer. Every user-initiated action — whether typed at a terminal or piped from `curl` — passes through this module before any plugin logic runs. It owns no business logic; it validates, resolves, and delegates.

---

## 1. Actors and Entry Points

| Actor | Entry point | Path |
|---|---|---|
| End user (terminal) | `scripts/edc` shim | `edc build|update|review|audit|mode|doctor` |
| End user (curl pipe) | `install.sh` | `bash install.sh --agent <agent>` or `curl … \| bash -s <agent>` |
| Orchestrators (internal) | `scripts/edc-review.sh` | `bash edc-review.sh [--build|--consolidate|--verify|--check-context] …` |
| Plugin slash commands | plugin scripts in `plugins/edc/commands/` | delegates → same orchestrators |

`scripts/edc` is the primary public CLI. `scripts/edc-review.sh` is both a user entry point (invoked by `edc review`) and a re-entrant orchestrator (its `auto_mode` calls `bash "$0" --build …` to invoke itself as a sub-phase).

---

## 2. `scripts/edc` — CLI Shim

### 2.1 Invariants and Initialization

```
SCRIPT_DIR = realpath of the directory containing scripts/edc
REPO_ROOT  = SCRIPT_DIR/..   (the edc repo root when running from a clone,
                               or ~/.edc/scripts/.. when installed)
```

`set -euo pipefail` is active for the lifetime of the process. Any unhandled non-zero return aborts immediately — there is no global error trap.

**Key invariant:** `SCRIPT_DIR` and `REPO_ROOT` are computed once at startup via `cd … && pwd`, making them immune to working-directory changes inside subshells.

### 2.2 Command Dispatch (`main`)

```
main() → case $1 in build|review|audit|update|mode|doctor|--help|-h|help
```

`main` requires at least one argument; zero args prints usage and exits 2.

Unknown subcommands hit `die "unknown command: $command"` → exit 2.

There is no `--version` flag.

### 2.3 Agent Validation (`require_command`)

Called after `--agent` is parsed in every data-plane command (build/review/audit/update). Checks `command -v <agent>`. Supported values: `claude`, `cursor`, `codex`. Any other value → `die`. This is the sole allowlist gate; the check is case-sensitive and exact-match only.

**Invariant:** `require_command` is always called before the downstream script is located or invoked. An absent binary can never reach script dispatch.

### 2.4 Script Location (`find_*_script` functions)

Each command resolves its delegate script via a priority-ordered candidate list:

| Priority | Path |
|---|---|
| 1 | `REPO_ROOT/plugins/edc/scripts/edc-<cmd>.sh` (dev/clone path) |
| 2 | `.edc/scripts/edc-<cmd>.sh` (repo-local install) |
| 3 | `$HOME/.edc/scripts/edc-<cmd>.sh` (user-global install) |

**Exception — `find_review_script`:** priority 1 is `SCRIPT_DIR/edc-review.sh` (the symlinked copy in `scripts/`), not the plugin path. This is because `scripts/edc-review.sh` is a symlink → `plugins/edc/scripts/edc-review.sh`; the shim resolves it through the symlink by following `SCRIPT_DIR`.

If no candidate is found, the function returns 1 and `die` fires. There is no silent fallthrough.

**5 Whys on the search order:**
- *Why dev path first?* Running `edc` from a clone should always exercise the local source, not a stale installed copy.
- *Why `.edc/` second?* Supports per-repo overrides (e.g. a fork with patched orchestrators).
- *Why `$HOME/.edc/` last?* Global install is the production path; it loses to more specific overrides.
- *Why is review script special?* `scripts/edc-review.sh` already exists as a symlink; following it avoids duplication and keeps the link as the authoritative pointer.

### 2.5 Per-Command Flow

#### `build_cmd`

1. Parses `--agent`, `--force`, `--focus <module>`, `--ignore <glob>` (repeatable), optional positional `<path>`.
2. Validates `--agent` via `require_command`.
3. Validates positional path exists as a directory.
4. **Resolves build script relative to the target directory** (`cd "$target" && find_build_script`). This means the search for `.edc/scripts/edc-build.sh` and `$HOME/.edc/scripts/edc-build.sh` runs from inside the target, which matters when the target is a different repo.
5. Invokes: `(cd "$target"; EDC_AGENT_CLI="$agent" bash "$build_script" "${passthrough[@]}")` — a subshell so `cd` doesn't affect the parent.
6. `--ignore` is passed through verbatim; `.edcignore` processing happens in the downstream script, not here.

**Invariant:** `build_cmd` never reads or writes `edc-context/`. It is a pure delegator.

#### `review_cmd`

1. Parses `--agent`, `--base <ref>`, `--ignore <glob>`, `--context-mode advisory|inject`.
2. `context_mode` defaults to empty string; if empty, it falls back to `read_manifest_default_mode` (reads `edc-context/manifest.json` via `jq`).
3. Calls `validate_context_mode` on the resolved value; invalid values → exit 2.
4. Calls `enforce_agent_context_mode`: if `context_mode` is non-empty and `agent != "claude"` → exit 2. (Cursor/Codex are docs-only; inject is Claude-only.)
5. Finds `edc-review.sh` via `find_review_script`.
6. Invokes: `EDC_AGENT_CLI="$agent" EDC_CONTEXT_MODE="$context_mode" bash "$review_script" "${passthrough[@]}"`.

**Note:** `target` (the git ref / PR URL) is in `passthrough`, not a named variable. The shim never interprets the review target; it just passes it forward.

#### `audit_cmd` / `update_cmd`

Structurally identical to `review_cmd`: parse → validate → find script → invoke with `EDC_AGENT_CLI` + `EDC_CONTEXT_MODE`. The only difference is the resolved script name.

#### `mode_cmd`

Two behaviors:
- **No arg (read mode):** reads `policy.defaultMode` from `edc-context/manifest.json` via `jq`. Dies if manifest missing or mode field absent.
- **Arg present:** validates arg ∈ {advisory, inject}, verifies manifest exists, runs `jq --arg mode "$mode" '.policy.defaultMode = $mode'` → writes to a tempfile → `mv` into place. Atomic from the filesystem's perspective (same-filesystem mv).

`jq` is a hard dependency for `mode_cmd`. The shim uses `command -v jq || die` before any jq call.

#### `doctor_cmd`

Finds `edc-doctor.sh` and invokes it with no extra arguments. No agent validation, no context-mode, no `--ignore`. The simplest delegate.

### 2.6 Environment Variables Exported

| Variable | Set by | Consumed by |
|---|---|---|
| `EDC_AGENT_CLI` | `build_cmd`, `review_cmd`, `audit_cmd`, `update_cmd` | downstream `edc-*.sh` orchestrators |
| `EDC_CONTEXT_MODE` | `review_cmd`, `audit_cmd`, `update_cmd` | downstream orchestrators and hooks |

The shim itself reads `EDC_CONTEXT_MODE` from the manifest but does not read `EDC_AGENT_CLI` from the environment — it always sets it from `--agent`.

---

## 3. `scripts/edc-review.sh` — Standalone Review Orchestrator

This script is the most complex file in the module. It is simultaneously:
- A **user entry point** (invoked by `edc review` or directly).
- A **self-re-entrant orchestrator** (`auto_mode` calls `bash "$0" --build …`).
- A **sibling-module consumer**: it sources `edc-paths.sh`, `edc-runtime.sh`, `edc-assert-fresh.sh`, `edc-spawn.sh`, `edc-recover-context.sh` from its resolved `SCRIPT_DIR`.

### 3.1 Symlink Resolution

`_edc_resolve_script_dir` walks `BASH_SOURCE[0]` through symlinks until it finds the real file. This is critical: `scripts/edc-review.sh` is a symlink to `plugins/edc/scripts/edc-review.sh`. Without resolution, sourcing sibling helpers would fail because `dirname scripts/edc-review.sh` → `scripts/`, not `plugins/edc/scripts/`.

**Invariant:** All `SCRIPT_DIR`-relative helper paths resolve to `plugins/edc/scripts/`, regardless of how the script was invoked.

### 3.2 Dispatch Table

```
$1                 → mode
--build <target>   → build_mode (task generation only, no subprocess spawn)
--base <ref>       → auto_mode HEAD --base <ref> (shorthand)
--check-context    → check_context_mode
--consolidate      → consolidate_mode
--verify           → verify_mode
""                 → error (target required)
--*                → error (unknown flag)
*                  → auto_mode "$@" (default: full pipeline)
```

### 3.3 `auto_mode` — Full Pipeline

**Preconditions:**
- `EDC_AGENT_CLI` must be set and the corresponding binary must be on PATH.
- For `codex`: `ensure_codex_exec_home` is called to create an isolated `CODEX_HOME`.

**Flow:**

1. **Context gate** (`recover_context_if_needed`): sourced from `edc-recover-context.sh`. Checks freshness; if context is missing or stale, spawns a build or update agent subprocess. After this call, `$EDC_MANIFEST` is guaranteed fresh or the function exits non-zero.

2. **Build review tasks** (`bash "$0" --build "$target" "${extra_args[@]}"`): re-invokes this script in build mode. Output is captured into `out`. The script checks for `"Review tasks ready"` on stdout to detect success; absence → error.

3. **Parse TASK lines**: extracts `TASK review-tasks/<module>.md` lines from `out`. Zero tasks → error.

4. **Spawn one agent per module**: for each `task_path`, calls `resolve_prompt review "$task_path"` (from `edc-resolve-prompt.sh`, not shown) to get the review prompt, then `edc_spawn` (from `edc-spawn.sh`) to invoke the agent CLI as a subprocess. After each subprocess returns, `assert_report_valid` checks that `review-tasks/report-<module>.md` exists and contains at least one `##` heading.

5. **Consolidate**: `bash "$0" --consolidate` merges per-module reports into a single `review-<target>.md`.

6. **Verify**: `bash "$0" --verify` re-checks context freshness, report existence, and final file existence.

7. **Explicit `exit 0`** to prevent late subprocess output from poisoning the exit code.

**Key invariant:** `auto_mode` never interprets review findings. It is a pure pipeline orchestrator.

### 3.4 `build_mode` — Task Generation

This is the structural heart of the review pipeline. It does NOT spawn agent subprocesses.

**Inputs:** `target` (git ref, PR URL, or diff file path), optional `--base <ref>`, optional `--ignore <glob>` (repeatable), optional `--context-mode` (consumed and discarded — not used here).

**Step 1 — Context gate:**
- Checks HEAD with `git rev-parse HEAD` → not a git repo → exit 2.
- Checks `$MANIFEST` exists → missing → `CONTEXT_MISSING` on stdout → exit 1.
- Checks `$EDC_INDEX` exists and contains `^##` → missing/stub → `CONTEXT_MISSING` → exit 1.
- Reads `source_commit` from manifest via `read_manifest_source_commit` (from `edc-assert-fresh.sh`). If `source_commit != HEAD` → `CONTEXT_STALE` → exit 1.

Exit 1 (not 2) signals context problems to `auto_mode`'s recovery logic.

**Step 2 — File enumeration:**

Three target formats supported:
- `https://*` → `gh pr diff "$target" --name-only`
- File path (exists as file) → parse `+++ b/` lines from a diff file
- Anything else → `git diff "${baseline:-${target}^}..${target}" --name-only`

After enumeration, two filter passes:
1. Strip tool-internal paths: `grep -Ev "^(${EDC_CONTEXT_DIR}/|review-tasks/|review-[^/]+\.md$)"` — prevents the tool from reviewing its own state.
2. `filter_ignored_files`: applies `.edcignore` patterns (or CLI `--ignore` args) using `path_matches_ignore`.

**Step 3 — Module routing via `edc-route.sh`:**

`edc-route.sh "$MANIFEST" "$file"` is called for each file. Three return codes:
- `0` → mapped to a module
- `1` → no match (unmapped)
- `2` → ambiguous (multiple top-priority matches) → **always fatal**

Results accumulate in `declare -A MODULE_FILES` (bash 4+ associative array). Unmapped files go to the synthetic `"unmapped"` bucket. Ambiguous files cause immediate exit 2.

Unmapped handling is controlled by `policy.unmatchedPathPolicy` from the manifest:
- `warn-allow` (default) → warn on stderr, continue
- `allow` → silent, continue
- `fail` → exit 2

Expected-unmapped files (declared in `unmapped.allowedGlobs`) are silently excluded from the unexpected-unmapped count.

**Step 4 — Task file generation:**

Writes `review-tasks/` (wiped fresh each run):
- `review-tasks/manifest.json` — internal state for consolidate/verify phases.
- `review-tasks/<module>.md` — per-module task file with instructions: read `index.md`, `issues.md`, the module doc, invoke the `edc-review` skill, write `report-<module>.md`.

Emits `TASK review-tasks/<module>.md` lines on stdout for `auto_mode` to parse.

### 3.5 `load_ignore_patterns` and `filter_ignored_files`

**`load_ignore_patterns`:**
- If CLI args provided, uses them exclusively — `.edcignore` is not read.
- Otherwise reads `.edcignore`, stripping leading/trailing whitespace and `#` comment lines.

**`path_matches_ignore`:**
- Pattern ending in `/` → prefix match (`$path == ${pattern}*`).
- Otherwise: exact match, path-under-prefix match (`$path == "$pattern/"*`), or glob match (`[[ "$path" == $pattern ]]`).

**Invariant:** The glob match uses bash's `[[` unquoted right-hand-side glob, not `fnmatch`. This means patterns like `vendor/**` work but patterns with character classes `[abc]` would also match. There is no escaping layer.

### 3.6 `consolidate_mode` and `verify_mode`

Both require `review-tasks/manifest.json` to exist (written by `build_mode`).

`consolidate_mode`: asserts each expected module's report exists and has `##` headings via `assert_report_valid`, then writes a single `review-<target>.md` with header metadata (date, HEAD SHA, module list) and concatenated module sections.

`verify_mode`: re-asserts context freshness (`assert_context_fresh`), checks all expected reports and the final file exist. Does NOT re-check report content.

### 3.7 `final_review_filename`

`review-$(echo "$target" | sed 's|[^a-zA-Z0-9._-]|-|g' | cut -c1-40).md`

Sanitizes the target string for use as a filename. `cut -c1-40` caps at 40 characters. Non-alphanum chars (including `/`, `:`, `@`) become `-`. Two different targets could produce the same filename if their first 40 sanitized chars collide.

---

## 4. `install.sh` — Installer

### 4.1 Actors and Modes

| Invocation | Behavior |
|---|---|
| `curl -fsSL … \| bash -s <agent>` | Downloads and installs from `$BASE` (GitHub raw) |
| `bash install.sh --agent <agent>` | Installs from local clone (prefers local files via `copy_or_download`) |

Supported agents: `claude`, `cursor`, `codex`, `pi`.

### 4.2 `install_terminal_cli`

Copies (or downloads) the following scripts to `$HOME/.edc/scripts/`:

```
edc                     (the CLI shim)
edc-review.sh           (standalone review orchestrator)
edc-build.sh
edc-update.sh
edc-audit.sh
edc-doctor.sh
edc-route.sh
edc-manifest.sh
edc-clean-slate.sh
edc-runtime.sh
edc-assert-fresh.sh
edc-resolve-prompt.sh
edc-spawn.sh
edc-recover-context.sh
edc-paths.sh            (sourced-only, no chmod)
edc-build-plan.sh
```

`chmod +x` is applied to all except `edc-paths.sh` (which is sourced, not exec'd).

**Invariant:** `edc-paths.sh` is intentionally excluded from chmod. This is a design signal: it has no standalone execution role.

### 4.3 Per-Agent Install Paths

**`claude`:** `install_claude_runtime` → installs terminal CLI + the private EDC prompt bundle at `~/.edc/skills/`. Prints guidance to also install the claude plugin separately. Private bundle names: `edc-module-context-impl`, `edc-build-impl`, `edc-update-impl`, `edc-review`, `edc-audit`.

**`cursor`:** Installs only public skills (`edc-review`, `edc-audit`) to `~/.cursor/skills/`, installs the private prompt bundle to `~/.edc/skills/`, installs terminal CLI, and generates thin slash-command wrappers at `~/.cursor/commands/edc-{build,update,run-review,doctor}.md`. Each wrapper is a bash heredoc that exports `EDC_AGENT_CLI=cursor` and delegates to `.edc/scripts/edc-<script>.sh` (repo-local) or `$HOME/.edc/scripts/edc-<script>.sh` (global), failing with `SCRIPT_MISSING` if neither exists.

**`codex`:** Installs only public skills plus command wrappers to `~/.codex/skills/`, installs the private prompt bundle to `~/.edc/skills/`, installs terminal CLI, and writes `~/.codex/skills/edc-<action>/SKILL.md` wrappers for build/update/run-review/doctor. Subprocess agents run under an isolated `CODEX_HOME` per pipeline run.

**`pi`:** Checks `pi` CLI is on PATH. If running from a clone with `agents/pi/` present, runs `agents/pi/install.sh --from-source`. Otherwise runs `pi install git:github.com/almogdepaz/edc`. Always installs terminal CLI and the private prompt bundle to `~/.edc/skills` afterward.

### 4.4 `copy_or_download`

```
if [ -f "$SCRIPT_DIR/$src" ]; then cp …  # local clone wins
else curl -fsSL "$BASE/$src" -o "$dst"   # fall back to GitHub raw
fi
```

`$BASE = https://raw.githubusercontent.com/almogdepaz/EDC/main`. The `REPO` constant uses `almogdepaz/EDC` (capital E, D, C) — this must match the GitHub repo name exactly; a rename would silently break remote installs.

### 4.5 `write_cursor_commands` / `write_codex_skills`

These generate command/skill wrappers dynamically at install time. The wrapper template is embedded in `install.sh` as heredocs. The wrapper's only job is to find the matching orchestrator script (`edc-<action>.sh`) and execute it with `EDC_AGENT_CLI` set. It never contains business logic.

The Cursor wrapper searches `.edc/scripts/` (repo-local) before `$HOME/.edc/scripts/` (global) — same priority order as `find_*_script` in the CLI shim.

---

## 5. Ignore Rule Provenance

Two ignore mechanisms exist, with different scopes and precedence:

| Mechanism | Location | Scope | Precedence |
|---|---|---|---|
| `.edcignore` | Target repo root | Repo-wide, persistent | Lower — superseded by CLI flags |
| `--ignore <glob>` | CLI / slash command | Per-invocation | Higher — disables `.edcignore` entirely |

**Key invariant:** `--ignore` and `.edcignore` are mutually exclusive per invocation. If any `--ignore` flag is passed, `.edcignore` is not read at all (`load_ignore_patterns` short-circuits on `$# -gt 0`). There is no merging.

`.edcignore` in the EDC repo itself ignores `benchmark/curl/**` and `benchmark/redis/**` — these are large benchmark corpora used during development, not part of any production pipeline.

`.gitignore` in the EDC repo excludes:
- `review-tasks/`, `review-HEAD.md`, `PLAN.md` — scratch state
- `benchmark/**` noise files (logs, result tsvs, baseline jsons)
- `.edc/` — hidden local install artifacts
- `node_modules/`, `package-lock.json` — pi extension peer-deps
- Various local planning docs (`HANDOFF.md`, `EDC_V2_*`, etc.)

Neither `.edcignore` nor `.gitignore` is read by `scripts/edc` itself — they are consumed by `edc-review.sh`'s `load_ignore_patterns` and git, respectively.

---

## 6. Trust Boundaries and Blast Radius

### 6.1 Trust Model

```
User (terminal)
    ↓ (invokes)
scripts/edc                   [trust: caller is local user]
    ↓ (resolves + invokes)
edc-*.sh orchestrators        [trust: local filesystem]
    ↓ (spawns subprocess)
claude / cursor / codex CLI   [trust: agent binary on PATH]
    ↓ (reads/writes)
edc-context/, review-tasks/   [trust: local filesystem, gitignored]
```

### 6.2 Injection Surface

**`--ignore` glob patterns** are passed to `path_matches_ignore` which uses bash's unquoted `[[` glob. A crafted pattern could match unintended paths. Example: `--ignore '*'` silently drops all changed files, producing a `"no reviewable files"` error rather than reviewing everything. This is a denial-of-service, not privilege escalation.

**`.edcignore` content** is read line-by-line with whitespace stripping. Comment lines starting with `#` are dropped. An attacker who can write `.edcignore` in the target repo can suppress review of specific paths.

**`target` argument to `edc-review.sh`** is passed to `git diff`, `gh pr diff`, or used to open a file. It is not shell-quoted in the `git diff "${base}..${target}"` expansion — a target like `HEAD; rm -rf /` would execute the trailing command. However, this requires the user to pass the malicious string on the command line, so it's self-inflicted.

**`jq` invocation in `mode_cmd`** writes atomically via `mktemp` + `mv`. The `--arg mode "$mode"` prevents jq injection since `$mode` is validated to `advisory|inject` before the jq call.

### 6.3 Script Resolution Race

`find_*_script` returns the first candidate that `[ -f "$candidate" ]` matches at the moment of the check. The script is then invoked via `bash "$script"`. If the file is replaced between check and exec (TOCTOU), the wrong script runs. This is a local filesystem concern; no remote fetch is involved in script resolution after install.

### 6.4 Blast Radius of `install.sh`

- `install.sh` writes to `$HOME/.edc/scripts/`, `$HOME/.edc/skills/`, `$HOME/.cursor/`, or `$HOME/.codex/skills/` depending on agent. It never writes to system directories.
- `rm -rf "$dst"` is used in `copy_tree_or_fail` (for tree copies). `$dst` is always a constructed path under one of the above home-relative dirs; it is never derived from user input directly.
- Remote install (`curl | bash`) fetches from `https://raw.githubusercontent.com/almogdepaz/EDC/main` over HTTPS. No integrity check (no hash verification) on downloaded scripts. A GitHub compromise or MITM (if TLS were broken) would result in arbitrary code execution. This is the standard `curl | bash` threat model.

### 6.5 Context Mode Enforcement

`enforce_agent_context_mode` prevents `inject` mode from being requested for non-claude agents. This is a UX guard, not a security boundary — the inject hooks are Claude-specific and simply don't exist for other agents.

---

## 7. Key Invariants Summary

1. **Agent binary checked before script resolution.** An absent `claude`/`cursor`/`codex` binary always produces a clear error; it never silently proceeds.
2. **Script resolution is filesystem-ordered.** Clone → repo-local → user-global. No dynamic loading from network at runtime (only at install time).
3. **`edc-review.sh` is self-re-entrant.** `auto_mode` calls `bash "$0" --build …`, which re-executes the same script in a different mode. The dispatch table at the bottom of the file is the re-entry point.
4. **Context staleness is a hard gate.** `build_mode` exits 1 (not 0) when context is missing or stale. `auto_mode` checks for this exit code and triggers recovery. There is no path through the review pipeline that uses stale context without explicit recovery.
5. **`--ignore` and `.edcignore` are mutually exclusive.** Any CLI `--ignore` flag disables `.edcignore` for the entire run.
6. **Tool-internal paths are always filtered.** `edc-context/`, `review-tasks/`, and `review-*.md` files are stripped from changed-file lists before routing. The tool cannot review its own state.
7. **Consolidation requires non-trivial reports.** `assert_report_valid` enforces at least one `##` heading, preventing stub files from being consolidated as if they were real reviews.
8. **`mode_cmd` write is atomic.** Uses `mktemp` + same-filesystem `mv` to update `manifest.json`.
