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

- `pi`, `git`, and `node` on `PATH`
- shell access for background build/update/review/delivery-review/quality-review subprocesses
- write access to `AGENTS.md`, `edc-context/`, `.edc/`, `.git/edc/`, and `review-*.md`

Permission gates, plan/read-only modes, path guards, sandboxes, and SSH tool replacements may intentionally block or redirect those operations. EDC does not try to bypass them.

## Quick path

1. Start `pi` in a git repository.
2. Run `/edc`.
3. Choose **build context** once.
4. Choose **review all changes** → **changed files vs default branch**.
5. Check progress with **job status**.

## Command

Pi exposes one interactive command:

| Command | Purpose |
|---|---|
| `/edc` | Open the EDC menu |

Menu actions:

- review all changes — choose a scope, then run security review, delivery/architecture review, and quality review
- security review — choose a scope, then start a background security-only review
- delivery review — choose a scope, then start a background delivery/architecture review
- quality review — choose a scope; changed-files scope audits only modules owning changed files, full scope audits all modules
- job status — shows the current background job status
- build context — starts a background context build
- update context — detects the repo default branch (`origin/HEAD`, `main`, or `master`) and starts a background context update
- doctor / validate context

`/edc` is interactive-only. For non-interactive use, use the terminal CLI:

```bash
edc review --agent pi --diff <default-branch>...HEAD
edc security-review --agent pi --diff <default-branch>...HEAD
edc delivery-review --agent pi --diff <default-branch>...HEAD
edc quality-review --agent pi
edc build --agent pi
edc update --agent pi --base <default-branch>
```

The unified installer (`bash install.sh --agent pi`) also adds `~/.edc/scripts` to `PATH` in `~/.zshrc` or `~/.bashrc` when possible. Restart your shell after install, or run `export PATH="$HOME/.edc/scripts:$PATH"` for the current shell. Use `--no-path` to skip shell rc edits.

Review actions first ask for scope: changed files vs default branch, full current repo where supported, or custom refs where the UI provides text input. Quality-review changed-files scope audits only modules owning changed files; full scope audits all modules. Review prompts before refreshing stale/missing context. Declining cancels and prints CLI examples for `--no-context-refresh` / `--ignore-context`.

## Background job state

Review, build, update, and quality-review/audit run in the background so the TUI stays usable. EDC keeps exactly one current job slot per git repo:

| File | Purpose |
|---|---|
| `.git/edc/status` | Machine-readable current job status (`kind`, `status`, `run_id`, `pid`, `args`, `started_head`, `finished_head`, `repo_changed`, `failure_reason`, `failure_hint`, `final_review`, etc.) |
| `.git/edc/<kind>.log` | Raw stdout/stderr from the current `edc-<kind>.sh` run (`review.log`, `delivery-review.log`, `build.log`, `update.log`, or `audit.log`) |

Both paths are resolved with `git rev-parse --git-path`, so they work with normal repos and worktrees. They are under git metadata, not the worktree, so they are never tracked and need no `.gitignore` entry. Starting a new background job overwrites the previous status and that job kind's log.

`edc-context/` remains disposable generated context. Recovery may wipe and rebuild it; active pi job status/logs survive because they live under `.git/edc/`. If a background job fails, `/edc` → Job status reports structured result fields when available: status, code, scope/base/target, failed phase, outputs, reason, hint, and child result. `success-with-warning` means durable outputs validated even though the agent transport reported an odd/nonzero finish; `failed` means durable outputs did not validate.

## Skills

Pi exposes only the human-facing EDC methodology skills:

| Skill | Use |
|---|---|
| `edc-review` | Apply the EDC security/adversarial review methodology directly in chat, without running the full orchestrator. |
| `edc-audit` | Apply the EDC quality-review methodology directly in chat. |
| `edc-delivery-review` | Apply the EDC goal/spec delivery + architecture-fit review methodology directly in chat. |

Hidden implementation prompt bundles (`edc-module-context-impl`, `edc-build-impl`, `edc-update-impl`) are installed under `~/.edc/skills` for orchestrator subprocesses, but are not advertised in pi's TUI skill list. The extension may also copy runtime scripts/private prompt bundles into a project-local `.edc/` cache so spawned subprocesses can resolve the same orchestrators from inside the target repo.

## Compatibility with other pi packages

EDC registers one `/edc` command, does not override built-in tools, and exposes only the human-facing skills above. It should coexist with provider packages and command-only helper packages.

Known interactions:

- Context-pruning packages are safest with EDC's default `advisory` mode. In `inject` mode, EDC intentionally adds repo/module context messages to the session.
- Permission gates, plan/read-only modes, path guards, sandboxes, and SSH tool replacements may block or redirect EDC's normal `bash`, `edit`, and `write` activity. That is expected plugin behavior, not an EDC bypass target.
- Build/update/review/delivery-review/quality-review need the requirements and write permissions listed above.

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
| `bash` not found | Install or restore the system Bash executable on `PATH`. macOS `/bin/bash` 3.2 is supported. |
| `node: command not found` | Install Node; EDC orchestrators use it for manifest, routing, and stream handling. |
| `/edc` job fails immediately under plan/read-only/sandbox packages | Check whether another extension blocked `bash`, writes to `AGENTS.md`, `edc-context/`, `.edc/`, `.git/edc/`, or `review-*.md`. This is expected for strict guard packages. |
| Review says context is missing or stale | Run `/edc` → **Build context** once, or `/edc` → **Update context from default branch** after HEAD moves. Use `/edc` → **Job status** and inspect `.git/edc/<kind>.log` for recovery details. |
| Background review reports provider websocket/transport failure | The nested pi subprocess lost provider transport. Rerun the job; if it repeats, run `edc update --agent pi` separately or reduce context/update scope. |
| Wrong model in nested pi subprocesses | EDC forwards the active pi model as `EDC_PI_MODEL` when `ctx.model.provider` and `ctx.model.id` are available. Check the job log for the propagated model and set explicit model env vars only if you need to override it. |

## How it maps to pi

| EDC feature | Pi mechanism |
|---|---|
| Interactive menu | `pi.registerCommand("edc", …)` + `ctx.ui.select` |
| `SessionStart` hook | `pi.on("session_start", …)` |
| `PreToolUse` hook | `pi.on("tool_call", …)` filtered to `bash|edit|write` |
| Skills | `pi.on("resources_discover", …)` returning only `edc-review`, `edc-audit`, and `edc-delivery-review` |
| Per-session dedup | `ctx.sessionManager.getSessionId()` + tmp file |

The injection logic is shared with the Claude Code / Cursor hooks via `plugins/edc/hooks/lib/route.mjs` — single source of truth, no drift.

## Source layout

`pi/` is the pi package surface and implementation home.
