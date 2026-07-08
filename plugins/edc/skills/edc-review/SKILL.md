---
name: edc-review
description: >
  Performs security/adversarial differential review of code changes (PRs, commits, diffs).
  Use this for auth, validation, trust-boundary, injection, crypto, memory-safety,
  external-call, state-mutation, or security-regression risk. It leverages git
  history and edc-context for blast radius and writes markdown security reports.
allowed-tools:
  - Read
  - Write
  - Grep
  - Glob
  - Bash
  - Skill
---

# Security Review

Review code changes for exploitable or misuse-oriented security risk. This is not a generic code-quality or delivery/spec review.

Use edc-audit for code quality, maintainability, bloat, duplication, and test-value analysis. Use edc-delivery-review for goal/spec delivery and architecture-fit review. Use this skill when the important question is: **can this change break a trust boundary, remove a protection, expose attacker-controlled input, or reintroduce a security bug?**

## Invocation modes

Check arguments first.

### Mode A — scoped (`--task-file <path>`)

The `edc-review.sh` orchestrator invokes this mode for per-module security reviews.

1. Read the task file at `<path>`.
2. Parse:
   - **Target** under `## Target`
   - **Baseline** under `## Baseline` when present
   - **Files to review** under `## Files to review`
3. Derive `{module}` from the task file basename.
4. Load context in this order, skipping missing files silently:
   - `edc-context/index.md` for routing/coupling/blast-radius guidance
   - `edc-context/reports/issues.md`
   - `edc-context/modules/{module}.md`
5. Scope review strictly to listed files. Inspect callers/dependencies only when security blast radius or reachability requires it.
6. Follow `methodology.md`, `adversarial.md`, `patterns.md`, and `reporting.md`.
7. Write `edc-context/review-tasks/report-{module}.md`. The report file is mandatory.

Do not write elsewhere, update `manifest.json`, or consolidate. The orchestrator handles consolidation.

### Mode B — standalone

When no task file is provided, classify the target, build/load context, run the same security workflow, and write a durable report such as `review-{target}.md`.

## Core rules

- **Security-only:** report vulnerabilities, security regressions, trust-boundary breaks, attacker-controlled data flow bugs, and missing security tests. Do not report style, bloat, generic maintainability, or spec-delivery issues.
- **Evidence-first:** every finding needs file:line evidence and a concrete attack path or misuse path. If reachability is unproven, say so and lower confidence.
- **History-aware:** inspect git history for removed auth, validation, escaping, sandboxing, crypto, memory-safety, or CVE/security-fix code.
- **Context-aware:** use EDC invariants, trust boundaries, known issues, and coupling notes to focus analysis.
- **No false drama:** a report with `No security findings` is valid when no exploitable or security-relevant issue is found.
- **Output-first:** create the required report early and finalize it even when there are no findings.

## Risk triggers

Treat these as security-relevant until proven otherwise:

| Risk | Examples |
|---|---|
| Access control | authn/authz, roles, permissions, tenant boundaries |
| Input/data validation | parsing, escaping, deserialization, path handling, SQL/shell/templates |
| State mutation | money, ownership, config, persistence, irreversible operations |
| Trust boundaries | public APIs, CLI args, env/config, filesystem, network, subprocesses |
| Crypto/secrets | key handling, randomness, signing, tokens, credentials, logs |
| Memory safety | C/C++ buffers, allocation math, signedness, lifetime/free patterns |
| Regression | removed/reintroduced security checks, code from CVE/fix/security commits |

## Supporting docs

- `methodology.md` — triage, history, security test confidence, blast radius, context checks
- `adversarial.md` — attacker model, concrete attack path, exploitability
- `patterns.md` — vulnerability pattern reference
- `reporting.md` — security report shape and no-finding format
