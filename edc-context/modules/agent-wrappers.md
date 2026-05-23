# Module: agent-wrappers

**Scope:** `agents/`
**Status:** one agent currently wrapped — `pi`. `codex` mentioned in `package.json` keywords but no adapter exists yet.

---

## Purpose

`agents/` contains thin adapter shims that port the EDC plugin surface (slash commands, lifecycle hooks, context injection) to non-Claude coding agents. Each adapter delegates all substantive logic to the shared library at `plugins/edc/hooks/lib/route.mjs` — the adapters themselves are pure wiring.

---

## Wrapped agents

### `pi` (`agents/pi/`)

[Pi](https://github.com/mariozechner/pi) is an open-source coding agent. The EDC pi extension mirrors the Claude Code plugin feature-for-feature.

Files:
- `agents/pi/index.mjs` — extension entry point, loaded by pi at startup
- `agents/pi/install.sh` — install helper / mode toggle
- `agents/pi/README.md` — user-facing docs

Pi discovers the entry point via the repo-root `package.json`:
```json
"pi": { "extensions": ["./agents/pi/index.mjs"] }
```
Pi clones the repo on `pi install git:github.com/almogdepaz/edc` and reads this key.

---

## `install.sh` — what it does

```
./install.sh                   # global install via git url
./install.sh --local           # project-local (.pi/settings.json)
./install.sh --from-source     # install from local checkout (dev)
./install.sh --context-mode advisory|inject
```

The first three modes ultimately call `pi install <source> [flags]`.

`--context-mode` is a standalone mode-toggle: it rewrites `edc-context/manifest.json`'s `policy.defaultMode` in-place using `jq`. It does not call `pi install`. This is the same value the shared lib reads at runtime; toggling it is instant and persistent per project.

---

## `index.mjs` — adapter wiring

### Slash commands

Four user-facing commands are registered via `pi.registerCommand(name, { handler })`:

| Command | Command file |
|---|---|
| `/edc-build` | `plugins/edc/commands/edc-build.md` |
| `/edc-update` | `plugins/edc/commands/edc-update.md` |
| `/edc-run-review` | `plugins/edc/commands/edc-run-review.md` |
| `/edc-doctor` | `plugins/edc/commands/edc-doctor.md` |

Command bodies are read verbatim from the plugin's `commands/` directory (YAML frontmatter stripped), so behavior is identical to Claude Code. `$ARGUMENTS` in the body is substituted with user-supplied args.

### Skills

On `resources_discover`, the adapter returns only the human-facing skill directories: `plugins/edc/skills/edc-review` and `plugins/edc/skills/edc-audit`. Private build/update/context prompt bundles are installed under `.edc/skills` for subprocess prompt resolution but are not exposed to pi autocomplete.

### `session_start` lifecycle

1. Calls `installOrchestratorScript(ctx.cwd, PLUGIN_ROOT)` — copies runtime scripts into `<project>/.edc/scripts/` and private prompt bundles into `<project>/.edc/skills/` if missing or stale (mtime-based). Best-effort; never throws.
2. Calls `buildSessionStartContent(ctx.cwd)`:
   - If no `edc-context/manifest.json`: sends a nudge message to run `/edc-build`.
   - If `policy.defaultMode === "advisory"`: no-op.
   - If `inject` mode: reads `edc-context/index.md`, prepends a staleness warning if HEAD ≠ `manifest.sourceCommit`, sends result as a `customType: "edc-session-context"` message.

### `tool_call` (pre-tool-use context injection)

Fires on every tool call but only acts on `bash`, `edit`, or `write` tool names (case-insensitive).

Flow:
1. Extracts candidate file paths from tool input via `extractFilePaths`.
2. Calls `buildToolCallInjection` from the shared lib, which:
   a. Loads and checks `manifest.json` — bails in advisory mode.
   b. Normalizes extracted paths.
   c. Calls `edc-route.sh` (via `routeFile`) to resolve a module name.
   d. File-based dedup check via `isDuplicate` (tmpfile keyed on session id).
   e. Reads `edc-context/modules/<name>.md`.
   f. Returns `{ moduleName, content, normalizedPath }` or null.
3. In-process dedup: adapter maintains `Map<sessionId, Set<moduleName>>` to prevent double-injection within a session if pi reloads the extension.
4. Sends result as `customType: "edc-context-inject"`.

### `session_shutdown`

Clears the in-process dedup map.

---

## Runtime guarantees

| Guarantee | Mechanism |
|---|---|
| Auto-mode respect | All hooks check `manifest.policy.defaultMode` via `loadManifest` before doing anything; advisory = no-op |
| Context injection | `inject` mode only; fires at session start (index.md) and once per module per session on tool use |
| Manifest awareness | Reads `edc-context/manifest.json` for mode, module list, doc paths, and staleness via `sourceCommit` |
| Staleness detection | `checkStaleness` diffs `manifest.sourceCommit` vs `git rev-parse HEAD`; warns on mismatch |
| Per-session dedup | Two-layer: file-based tmpfile (`/tmp/edc-injected-modules-<hash>.json`) + in-process Map — prevents repeat injection even across extension reloads |
| Idempotent install | `installOrchestratorScript` is mtime-gated; safe to run on every session start |

---

## Relationship to plugin hooks

The pi adapter is a thin platform translation layer. All core logic lives in `plugins/edc/hooks/lib/route.mjs`, which is the single source of truth shared by:

- `plugins/edc/hooks/session-start.mjs` (Claude Code / Cursor)
- `plugins/edc/hooks/pretooluse-context-inject.mjs` (Claude Code / Cursor)
- `agents/pi/index.mjs` (Pi)

The adapter maps pi's event API (`pi.on`, `pi.sendMessage`, `pi.registerCommand`) onto the same shared functions. No business logic is duplicated.

Hook-to-adapter mapping:

| EDC feature | Claude Code mechanism | Pi mechanism |
|---|---|---|
| Session start | `SessionStart` hook via Claude hooks JSON | `pi.on("session_start", …)` |
| Pre-tool-use injection | `PreToolUse` hook | `pi.on("tool_call", …)` filtered to bash/edit/write |
| Slash commands | Claude Code `commands/*.md` | `pi.registerCommand(…)` reading same `commands/*.md` |
| Skills | Claude Code skill runner | `pi.on("resources_discover", …)` → `skills/` dir |

---

## Untested areas

Pi provides no public test harness for extension lifecycle events. The shared lib (`route.mjs`) is covered by `tests/hardening/*.sh` via Claude Code hook entry points. Pi-specific wiring (event handlers, `pi.registerCommand`, `pi.sendMessage`) is verified manually.

---

## Extension points / future agents

Adding a new agent (e.g. `codex`) follows the same pattern:
1. Create `agents/<name>/index.mjs` — wire agent's lifecycle events to shared lib exports.
2. Create `agents/<name>/install.sh` — install helper if needed.
3. Declare entry point in `package.json` under the agent's extension key.
4. No changes to `plugins/edc/` required.
