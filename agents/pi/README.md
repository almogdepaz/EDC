# EDC for pi

Pi extension that ports the EDC ([Every Day Carry](../../README.md)) Claude Code plugin to [pi](https://github.com/mariozechner/pi).

## Install

```bash
pi install git:github.com/almogdepaz/edc
```

That's it. Pi clones the repo and registers `agents/pi/index.mjs` as the extension entry (declared in the repo-root `package.json`).

Project-local install (writes to `.pi/settings.json` in the current dir instead of global):

```bash
pi install git:github.com/almogdepaz/edc -l
```

From a local checkout (for development):

```bash
bash agents/pi/install.sh --from-source
```

## Commands

After install, pi exposes:

| Command | Purpose |
|---|---|
| `/edc-build` | Build deep architectural context (`edc-context/`) |
| `/edc-update` | Incrementally update context from branch diff |
| `/edc-audit` | Overengineering / bloat / duplication audit |
| `/edc-run-review` | Differential code review against a base ref |
| `/edc-doctor` | Validate the context tree, manifest, routing |
| `/edc-review` | Internal — per-module review (used by orchestrator) |

The command bodies are read verbatim from `plugins/edc/commands/*.md`, so behavior matches the Claude Code plugin.

## Modes

EDC has two runtime modes, controlled by `edc-context/manifest.json` `policy.defaultMode`:

- **`advisory`** (default) — pure docs. Hooks no-op. Zero per-tool token overhead.
- **`inject`** — `session_start` surfaces `edc-context/index.md`; `tool_call` (bash/edit/write) auto-injects the relevant `edc-context/modules/<name>.md` once per session.

Toggle:

```bash
bash agents/pi/install.sh --context-mode advisory
bash agents/pi/install.sh --context-mode inject
```

(equivalent to a one-line `jq` write — flip it whenever.)

## How it maps to pi

| EDC feature | Pi mechanism |
|---|---|
| Slash commands | `pi.registerCommand(name, …)` |
| `SessionStart` hook | `pi.on("session_start", …)` |
| `PreToolUse` hook | `pi.on("tool_call", …)` filtered to `bash|edit|write` |
| Skills | `pi.on("resources_discover", …)` returning `plugins/edc/skills/` |
| Per-session dedup | `ctx.sessionManager.getSessionId()` + tmp file |

The injection logic is shared with the Claude Code / Cursor hooks via `plugins/edc/hooks/lib/route.mjs` — single source of truth, no drift.

## Untested

Pi exposes no public test harness for extension lifecycle events. The shared lib (`plugins/edc/hooks/lib/route.mjs`) is exercised by the existing hardening tests via the Claude Code hook entry points; the pi-specific wiring (event handlers, command registration) is verified manually on first install.
