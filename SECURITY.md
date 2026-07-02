# Security

EDC runs local orchestrator scripts and can spawn agent subprocesses through Claude Code, Cursor, Codex, or pi. Treat it like any other local automation package with access to your repository and shell.

## Reporting issues

Please report security-sensitive issues privately to the repository owner before opening a public issue.

## Operational notes

- Pi packages and EDC orchestrators run with your local user permissions.
- EDC build/update/review writes `AGENTS.md`, `edc-context/`, `.edc/`, and `review-*.md` in the target repository.
- Pi background review status/logs are stored under `.git/edc/`.
- Hidden prompt bundles under `plugins/edc/prompt-bundles/` are implementation material for spawned subprocesses, not user-facing skills.
- Review third-party pi packages before installing them beside EDC; permission gates, sandboxes, or SSH tool replacements can intentionally alter EDC behavior.

## Reviewing untrusted diffs

`edc review` feeds attacker-controlled diff content to a spawned agent. Treat review targets from forks or unknown authors as untrusted input.

Mitigations:

- EDC routes review work into per-module tasks and expects subprocesses to write only `edc-context/review-tasks/report-*.md`.
- The orchestrator snapshots repository state around each module review and fails if the review subprocess mutates source, context, or other unexpected paths.
- Codex runs with its workspace sandbox; other agent CLIs still execute with your local user permissions and their own tool/permission model.

Residual risk: agents may still read repository files needed for review, and backend/provider behavior is outside EDC's control. Run untrusted reviews in a disposable checkout if the repository contains secrets or sensitive local-only files.

## Credential handling

Do not paste API keys, npm tokens, or other credentials into prompts, issues, or logs. If a token is exposed, revoke it and issue a new one.
