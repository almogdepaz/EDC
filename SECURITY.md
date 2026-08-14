# Security Policy

## Reporting a vulnerability

Report vulnerabilities privately through [GitHub private vulnerability reporting](https://github.com/almogdepaz/edc/security/advisories/new).

Do not open a public issue for an undisclosed vulnerability. Include affected versions, reproduction steps, impact, and any suggested mitigation. Never include real credentials or unrelated private data.

## Scope

Security reports may cover the installer, terminal runtime, Claude plugin, Pi extension, review-worker orchestration, filesystem boundaries, subprocess handling, and packaged skills.

EDC analyzes repository-controlled content with model-backed tools. Until stronger process isolation ships, use EDC only on repositories you trust and review the permissions granted to the selected agent backend.

## Response

Maintainers will acknowledge a complete report through the private advisory, validate impact, coordinate a fix and release when warranted, and publish disclosure details after users have a reasonable opportunity to update.
