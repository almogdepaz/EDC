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
| `/edc-run-review` | Differential code review against a base ref or PR (`--pr <number>`) |
| `/edc-doctor` | Validate the context tree, manifest, routing |

Pi intentionally exposes only user-facing pipeline commands. The single-module review worker and standalone audit pipeline are not registered as TUI commands; use the `edc-review` / `edc-audit` skills for methodology-only work.

The command bodies are read verbatim from `plugins/edc/commands/*.md`, so behavior matches the Claude Code plugin where those commands are shared.

Review examples:

```text
# current branch against main
/edc-run-review --base main

# PR by number; requires gh auth in the target repo
/edc-run-review --pr 147 --base main

# pure direct review: no context build/update, and do not read existing edc-context/
/edc-run-review --pr 147 --base main --ignore-context

# no context build/update, but allow existing context if present
/edc-run-review --pr 147 --base main --no-context-refresh
```

`--ignore-context` is the hard skip: it neither creates/updates context nor reads existing `edc-context/`. `--no-context-refresh` only disables creation/update; stale or existing context may still be used.

## Skills

Pi exposes only the human-facing EDC methodology skills:

| Skill | Use |
|---|---|
| `edc-review` | Apply the EDC differential review methodology directly in chat, without running the full orchestrator. |
| `edc-audit` | Apply the EDC bloat / duplication / overengineering audit methodology directly in chat. |

Hidden implementation prompt bundles (`edc-module-context-impl`, `edc-build-impl`, `edc-update-impl`) are still installed under `~/.edc/skills` for orchestrator subprocesses, but are not advertised in pi's TUI skill list.

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
| Skills | `pi.on("resources_discover", …)` returning only `edc-review` and `edc-audit` |
| Per-session dedup | `ctx.sessionManager.getSessionId()` + tmp file |

The injection logic is shared with the Claude Code / Cursor hooks via `plugins/edc/hooks/lib/route.mjs` — single source of truth, no drift.

## Testing note

Pi exposes no public lifecycle test harness, so `tests/hardening/t10-pi-extension.sh` exercises the extension factory with a fake `ExtensionAPI`. That pins command registration, visible skills, session-start script install, and tool-call context injection.
