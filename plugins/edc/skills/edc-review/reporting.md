# Security Report

Generate a durable markdown report for every scoped or standalone security review. The report may contain confirmed findings or explicitly state `No security findings`.

## Required structure

```md
# Security Review Report

## What Changed
- Target: `<target>`
- Baseline: `<base>` if known
- Files reviewed: N
- Security-relevant files: N
- Context loaded: index/module docs/issues as applicable

## Findings

Use the exact heading `## Findings`. Do not replace it with `## Critical Findings`, `## Security Findings`, severity-specific headings, or any other variant. Severity-specific findings belong under this section as `### ...` subsections.

### No security findings
Use this subsection when no exploitable or security-relevant issue survived verification. Include what was checked and key limitations.

### 🔴 CRITICAL / 🟠 HIGH / 🟡 MEDIUM / 🟢 LOW: <title>
- where: `file:line`
- commit/history: `<hash>` or `not applicable`
- affected trust boundary: ...
- attacker/misuser: ...
- concrete attack path: ...
- impact: ...
- evidence: ...
- security test coverage: yes/no/partial
- recommendation: ...

## Security Test Confidence
- security-sensitive paths with regression coverage
- missing security regression tests
- mocked-away trust boundaries, if relevant

## Blast Radius
- reachable entrypoints
- callers/modules affected
- EDC invariants or known issues touched

## Historical Context
- removed protections
- reintroduced risky code
- relevant `security` / `CVE` / `fix` commits

## Limitations
- files or call paths not analyzed
- unproven reachability
- external systems/dependencies not inspected

## Recommendation
APPROVE | CONDITIONAL | BLOCK

State the security reason only. Do not add generic code-quality, delivery, or technical-debt recommendations.
```

## Severity calibration

| Severity | Use when |
|---|---|
| CRITICAL | unauthenticated/easy exploit with severe confidentiality, integrity, availability, or privilege impact |
| HIGH | realistic exploit or bypass with meaningful impact |
| MEDIUM | plausible security issue requiring conditions, lower impact, or partially proven reachability |
| LOW | defense-in-depth weakness, incomplete hardening, or unproven but credible risk |

Do not inflate severity for style, maintainability, or missing non-security tests.

## Finding requirements

Each finding must include:
- specific file/line evidence
- concrete attack path or clear reachability limitation
- actual impact, not vague “could be bad” prose
- security-specific recommendation

If the issue is merely poor style, bloat, duplication, or goal mismatch, do not report it here.

## No-finding report

When no security findings are found, still write the report file. Under `## Findings`, include:

```md
### No security findings
No exploitable or security-relevant issue was found in the reviewed scope.

Checked:
- auth/authorization impact: ...
- validation/input boundaries: ...
- external calls/subprocess/filesystem: ...
- sensitive state mutation: ...
- security history/regression scan: ...

Limitations:
- ...
```

## Formatting

- Use markdown tables for concise summaries.
- Use `file:line` references.
- Quote short code snippets only when needed to prove the issue.
- Prefer specific remediation over broad advice.
