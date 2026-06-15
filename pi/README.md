# EDC for pi

EDC adds repository architecture context and context-aware review workflows to [pi](https://pi.dev).

## Install

```bash
pi install npm:@sgtbeatdown/edc
```

Project-local install for a team repo:

```bash
pi install npm:@sgtbeatdown/edc -l
```

Git/source installs still work:

```bash
pi install git:github.com/almogdepaz/edc
bash pi/install.sh --from-source
```

Manage the package with pi's normal package commands:

```bash
pi list
pi update npm:@sgtbeatdown/edc
pi remove npm:@sgtbeatdown/edc
```

Use a pinned git ref when you need reproducible installs, e.g. `pi install git:github.com/almogdepaz/edc@v1.1.1`. Project-local installs use `.pi/settings.json`; global installs use `~/.pi/agent/settings.json`.

## Requirements and permissions

Orchestrated pi reviews require:

- `pi`, `git`, `jq`, and `python3` on `PATH`
- Bash >= 4; on macOS, install modern Bash with Homebrew if `/bin/bash` is 3.2
- shell access for background build/update/review/audit subprocesses
- write access to `AGENTS.md`, `edc-context/`, `.edc/`, `.git/edc/`, and `review-*.md`

Permission gates, plan/read-only modes, path guards, sandboxes, and SSH tool replacements may intentionally block or redirect those operations. EDC does not try to bypass them.

## Quick path

1. Start `pi` in a git repository.
2. Run `/edc`.
3. Choose **Build context** once.
4. Choose **Review current branch vs main**.
5. Check progress with **Job status**.

## Command

Pi exposes one interactive command:

| Command | Purpose |
|---|---|
| `/edc` | Open the EDC menu |

Menu actions:

- Review current branch vs `main` — starts a background review with `HEAD --base main`
- Job status — shows the current background job status
- Build context — starts a background context build
- Update context from `main` — starts a background context update
- Audit complexity — starts a background audit
- Doctor / validate context

`/edc` is interactive-only. For non-interactive use, use the terminal CLI:

```bash
edc review --agent pi HEAD --base main
edc build --agent pi
edc update --agent pi --base main
```

The unified installer (`bash install.sh --agent pi`) also adds `~/.edc/scripts` to `PATH` in `~/.zshrc` or `~/.bashrc` when possible. Restart your shell after install, or run `export PATH="$HOME/.edc/scripts:$PATH"` for the current shell. Use `--no-path` to skip shell rc edits.

Review prompts before refreshing stale/missing context. Declining cancels and prints CLI examples for `--no-context-refresh` / `--ignore-context`.

## Background job state

Review, build, update, and audit run in the background so the TUI stays usable. EDC keeps exactly one current job slot per git repo:

| File | Purpose |
|---|---|
| `.git/edc/status` | Machine-readable current job status (`kind`, `status`, `run_id`, `pid`, `args`, `started_head`, `finished_head`, `repo_changed`, `failure_reason`, `failure_hint`, `final_review`, etc.) |
| `.git/edc/<kind>.log` | Raw stdout/stderr from the current `edc-<kind>.sh` run (`review.log`, `build.log`, `update.log`, or `audit.log`) |

Both paths are resolved with `git rev-parse --git-path`, so they work with normal repos and worktrees. They are under git metadata, not the worktree, so they are never tracked and need no `.gitignore` entry. Starting a new background job overwrites the previous status and that job kind's log.

`edc-context/` remains disposable generated context. Recovery may wipe and rebuild it; active pi job status/logs survive because they live under `.git/edc/`. If a background job fails, `/edc` → Job status reports a classified reason when EDC can determine one, e.g. HEAD changed during the run or context recovery did not produce a complete layout.

## Skills

Pi exposes only the human-facing EDC methodology skills:

| Skill | Use |
|---|---|
| `edc-review` | Apply the EDC differential review methodology directly in chat, without running the full orchestrator. |
| `edc-audit` | Apply the EDC bloat / duplication / overengineering audit methodology directly in chat. |

Hidden implementation prompt bundles (`edc-module-context-impl`, `edc-build-impl`, `edc-update-impl`) are installed under `~/.edc/skills` for orchestrator subprocesses, but are not advertised in pi's TUI skill list. The extension may also copy runtime scripts/private prompt bundles into a project-local `.edc/` cache so spawned subprocesses can resolve the same orchestrators from inside the target repo.

## Compatibility with other pi packages

EDC registers one `/edc` command, does not override built-in tools, and exposes only the two human-facing skills above. It should coexist with provider packages and command-only helper packages.

Known interactions:

- Context-pruning packages are safest with EDC's default `advisory` mode. In `inject` mode, EDC intentionally adds repo/module context messages to the session.
- Permission gates, plan/read-only modes, path guards, sandboxes, and SSH tool replacements may block or redirect EDC's normal `bash`, `edit`, and `write` activity. That is expected plugin behavior, not an EDC bypass target.
- Build/update/audit/review need the requirements and write permissions listed above.

## Modes

EDC has two runtime modes, controlled by `edc-context/manifest.json` `policy.defaultMode`:

- **`advisory`** (default) — pure docs. Hooks no-op. Zero per-tool token overhead.
- **`inject`** — `session_start` surfaces `edc-context/index.md`; `tool_call` (bash/edit/write) auto-injects the relevant `edc-context/modules/<name>.md` once per session.

Toggle:

```bash
bash pi/install.sh --context-mode advisory
bash pi/install.sh --context-mode inject
```

You can also toggle from the shared CLI after context exists:

```bash
edc mode
edc mode advisory
edc mode inject
```

## Troubleshooting

| Symptom | What to check |
|---|---|
| `bash >=4` or array errors | macOS `/bin/bash` is 3.2. Install Homebrew Bash and ensure it is on `PATH`, or set `EDC_BASH=/opt/homebrew/bin/bash`. |
| `jq: command not found` | Install `jq`; EDC orchestrators use it for manifest and report validation. |
| `/edc` job fails immediately under plan/read-only/sandbox packages | Check whether another extension blocked `bash`, writes to `AGENTS.md`, `edc-context/`, `.edc/`, `.git/edc/`, or `review-*.md`. This is expected for strict guard packages. |
| Review says context is missing or stale | Run `/edc` → **Build context** once, or `/edc` → **Update context from main** after HEAD moves. Use `/edc` → **Job status** and inspect `.git/edc/<kind>.log` for recovery details. |
| Background review reports provider websocket/transport failure | The nested pi subprocess lost provider transport. Rerun the job; if it repeats, run `edc update --agent pi` separately or reduce context/update scope. |
| Wrong model in nested pi subprocesses | EDC forwards the active pi model as `EDC_PI_MODEL` when `ctx.model.provider` and `ctx.model.id` are available. Check the job log for the propagated model and set explicit model env vars only if you need to override it. |

## How it maps to pi

| EDC feature | Pi mechanism |
|---|---|
| Interactive menu | `pi.registerCommand("edc", …)` + `ctx.ui.select` |
| `SessionStart` hook | `pi.on("session_start", …)` |
| `PreToolUse` hook | `pi.on("tool_call", …)` filtered to `bash|edit|write` |
| Skills | `pi.on("resources_discover", …)` returning only `edc-review` and `edc-audit` |
| Per-session dedup | `ctx.sessionManager.getSessionId()` + tmp file |

The injection logic is shared with the Claude Code / Cursor hooks via `plugins/edc/hooks/lib/route.mjs` — single source of truth, no drift.

## Source layout

`pi/` is the pi package surface and implementation home.
