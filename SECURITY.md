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

## Credential handling

Do not paste API keys, npm tokens, or other credentials into prompts, issues, or logs. If a token is exposed, revoke it and issue a new one.
