# EDC for pi

Pi extension that ports the EDC ([Every Day Carry](../../README.md)) Claude Code plugin to [pi](https://github.com/mariozechner/pi).

## Install

```bash
pi install git:github.com/almogdepaz/edc
```

Project-local install:

```bash
pi install git:github.com/almogdepaz/edc -l
```

From a local checkout:

```bash
bash agents/pi/install.sh --from-source
```

## Command

Pi exposes one interactive command:

| Command | Purpose |
|---|---|
| `/edc` | Open the EDC menu |

Menu actions:

- Review current branch vs `main` — starts a background review with `HEAD --base main`
- Review status — shows current background review status
- Build context
- Update context from `main`
- Audit complexity
- Doctor / validate context

`/edc` is interactive-only. For non-interactive use, use the terminal CLI:

```bash
edc review --agent pi HEAD --base main
edc build --agent pi
edc update --agent pi --base main
```

Review prompts before refreshing stale/missing context. Declining cancels and prints CLI examples for `--no-context-refresh` / `--ignore-context`.

## Background review state

Pi reviews run in the background so the TUI stays usable. EDC keeps exactly one current run slot per git repo:

| File | Purpose |
|---|---|
| `.git/edc/status` | Machine-readable current run status (`status`, `run_id`, `pid`, `args`, `started_head`, `finished_head`, `failure_reason`, `failure_hint`, `final_review`, etc.) |
| `.git/edc/review.log` | Raw stdout/stderr from the current `edc-review.sh` run |

Both paths are resolved with `git rev-parse --git-path`, so they work with normal repos and worktrees. They are under git metadata, not the worktree, so they are never tracked and need no `.gitignore` entry. Starting a new background review overwrites the previous status/log.

`edc-context/` remains disposable generated context. Recovery may wipe and rebuild it; active pi review status/logs survive because they live under `.git/edc/`. If the background review fails, `/edc` → Review status reports a classified reason when EDC can determine one, e.g. HEAD changed during the run or context recovery did not produce a complete layout.

## Skills

Pi exposes only the human-facing EDC methodology skills:

| Skill | Use |
|---|---|
| `edc-review` | Apply the EDC differential review methodology directly in chat, without running the full orchestrator. |
| `edc-audit` | Apply the EDC bloat / duplication / overengineering audit methodology directly in chat. |

Hidden implementation prompt bundles (`edc-module-context-impl`, `edc-build-impl`, `edc-update-impl`) are installed under `~/.edc/skills` for orchestrator subprocesses, but are not advertised in pi's TUI skill list. The extension may also copy runtime scripts/private prompt bundles into a project-local `.edc/` cache so spawned subprocesses can resolve the same orchestrators from inside the target repo.

## Modes

EDC has two runtime modes, controlled by `edc-context/manifest.json` `policy.defaultMode`:

- **`advisory`** (default) — pure docs. Hooks no-op. Zero per-tool token overhead.
- **`inject`** — `session_start` surfaces `edc-context/index.md`; `tool_call` (bash/edit/write) auto-injects the relevant `edc-context/modules/<name>.md` once per session.

Toggle:

```bash
bash agents/pi/install.sh --context-mode advisory
bash agents/pi/install.sh --context-mode inject
```

## How it maps to pi

| EDC feature | Pi mechanism |
|---|---|
| Interactive menu | `pi.registerCommand("edc", …)` + `ctx.ui.select` |
| `SessionStart` hook | `pi.on("session_start", …)` |
| `PreToolUse` hook | `pi.on("tool_call", …)` filtered to `bash|edit|write` |
| Skills | `pi.on("resources_discover", …)` returning only `edc-review` and `edc-audit` |
| Per-session dedup | `ctx.sessionManager.getSessionId()` + tmp file |

The injection logic is shared with the Claude Code / Cursor hooks via `plugins/edc/hooks/lib/route.mjs` — single source of truth, no drift.

## Testing note

Pi exposes no public lifecycle test harness, so `tests/hardening/t10-pi-extension.sh` exercises the extension factory with a fake `ExtensionAPI`. That pins command registration, visible skills, session-start script install, and tool-call context injection.
