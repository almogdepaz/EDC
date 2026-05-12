# EDC — Every Day Carry Skills

Deep codebase understanding and context-aware review for AI coding agents. EDC builds a persistent `edc-context/` map of a repository, then uses that map for focused reviews, audits, and context loading.

Works with **Claude Code**, **Cursor**, **Codex**, and **pi**.

## What EDC Does

EDC separates deterministic orchestration from LLM analysis:

- Shell scripts own routing, freshness checks, manifest updates, and validation.
- Subagents write per-module architecture context and review reports.
- Agent integrations expose the same workflows through native commands or skills.

The generated context lives in the target repository under `edc-context/`. Build it once per repo, then update it when the code moves.

## Install

### Claude Code

```bash
claude plugin marketplace add almogdepaz/edc
claude plugin install edc@edc
```

For a local checkout:

```bash
bash install.sh --agent claude
```

### Cursor

```bash
curl -fsSL https://raw.githubusercontent.com/almogdepaz/edc/main/install.sh | bash -s cursor
```

### Codex

```bash
curl -fsSL https://raw.githubusercontent.com/almogdepaz/edc/main/install.sh | bash -s codex
```

### pi

```bash
pi install git:github.com/almogdepaz/edc
```

All installers also place the shared terminal CLI and orchestrators under `~/.edc/scripts/`.

## Use the CLI

Run these from the repository you want EDC to analyze:

```bash
edc build  --agent claude
edc update --agent claude
edc review --agent claude --base main
edc audit  --agent claude
edc doctor
```

`--agent` selects the subprocess runtime: `claude`, `cursor`, or `codex`. It is required for `build`, `update`, `review`, and `audit`; pi uses its installed slash commands instead.

Common options:

- `edc build --force` rebuilds context from scratch.
- `edc build --focus <module>` rebuilds one module.
- `edc review <target> --base <ref>` reviews a PR URL, branch, commit, or diff file.
- `--ignore <pattern>` may be repeated and overrides `.edcignore` for that run.

`review` and `audit` recover stale or missing context automatically before running.

## Agent Commands

The installed agent commands delegate to the same orchestrators as the CLI:

| Agent | Commands |
|-------|----------|
| Claude Code | `/edc:edc-build`, `/edc:edc-update`, `/edc:edc-audit`, `/edc:edc-run-review`, `/edc:edc-doctor` |
| Cursor | `/edc-build`, `/edc-update`, `/edc-audit`, `/edc-review` |
| Codex | `$edc-build`, `$edc-update`, `$edc-audit`, `$edc-review` |
| pi | `/edc-build`, `/edc-update`, `/edc-audit`, `/edc-run-review`, `/edc-doctor` |

## Runtime Modes

EDC stores its mode in `edc-context/manifest.json` as `policy.defaultMode`.

- `advisory` is the default. EDC writes context files, and agents read them when prompted by a command or by the user.
- `inject` auto-loads context for supported hook-based integrations by surfacing `edc-context/index.md` at session start and the relevant `modules/<name>.md` before touching files in that module.

Toggle the mode from a target repo:

```bash
edc mode
edc mode advisory
edc mode inject
```

Cursor and Codex are docs-only regardless of the mode flag. Claude Code and pi support injection.

## Generated Files

EDC writes scratch state into the target repository. Add these patterns to that repository's `.gitignore` unless you intentionally want to version the generated context:

```gitignore
edc-context/
review-tasks/
review-*.md
```

If these files are committed, `edc review` filters them from its own diffs, but ignoring them keeps normal repo history cleaner.

## Project Layout

- `install.sh` installs EDC for supported agents.
- `plugins/edc/` is the canonical plugin, skill, hook, and orchestrator source.
- `agents/pi/` contains the pi adapter.
- `tests/hardening/` contains shell regression tests.
- `benchmark/` contains the CVE-recall benchmark harness.

For implementation details, see `plugins/edc/README.md`. For generated architecture context, see `edc-context/index.md` after running `edc build`.
