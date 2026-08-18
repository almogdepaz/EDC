# Audit Scope and Standards

Use this reference for audit setup and finding discipline.

## Scope discipline

The orchestrator assigns the audit scope. The scope may be a full module during build/audit, changed files in a future diff-quality review, or a synthesis/global pass. Follow the assigned scope exactly.

Audit workers:
- read only the assigned scope plus the minimum supporting files needed to verify a finding
- may inspect references/usages outside scope only to validate a local claim such as dead exports, duplication, or caller impact
- write only the assigned report artifact
- must not mutate source files, tests, git state, module docs, `manifest.json`, or canonical reports unless explicitly assigned to synthesize those reports
- must not scan the entire repo by default from a module-scoped task
- must not report global/cross-module conclusions from a local worker; global/cross-module conclusions belong to synthesis

For candidate verification, when Octocode is already installed and useful, prefer it for references, callers, duplication, and dead-export claims. Do not install or configure Octocode, widen assigned scope, treat unavailable semantic support as evidence of absence, or fail when Octocode is unavailable or unnecessary; existing Read, Grep, Glob, and Bash workflows remain valid fallbacks.

## Standards sources

Before scoring code quality, load documented standards sources when they exist:
- `AGENTS.md`
- `CLAUDE.md`
- `CONTRIBUTING.md`
- `CODING_STANDARDS.md`
- language style guides
- architecture docs
- relevant module docs

Documented repo standards override the smell baseline: if the repo explicitly endorses a pattern, do not report that pattern as a smell unless the local usage still creates concrete code-quality risk.

For every standards-based finding, cite the standard source file and rule/heading. For baseline-only smells, label the finding as a possible smell and explain the judgement call.

## Finding standards

Report only findings backed by evidence:
- specific file:line location where practical
- why it matters for correctness or maintainability
- one concrete recommendation
- severity based on actual risk, not aesthetic preference
- when a finding violates a documented repo/module standard, cite the standard with source file and rule/heading

Use a two-layer detection rule: cheap scans may identify candidates, but every reported finding must be verified in context. Downgrade or skip findings that are intentional, generated, framework-required, bounded, or documented tradeoffs.

Do not report formatter/linter/type errors as audit findings when normal tooling already enforces them, unless the tool is missing, disabled, ignored, or the issue represents a concrete correctness risk beyond the tool's normal output. Audit should find what routine tools do not.
