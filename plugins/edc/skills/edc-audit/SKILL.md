---
name: edc-audit
description: Identifies code quality, maintainability, overengineering, bloat, duplication, and test-value risks by comparing EDC context expectations to actual code
---

# Audit Code Quality

Analyze code quality and maintainability using the `edc-context/` files as the baseline for what the code SHOULD look like. This is a read-only scoped analysis pass: audit workers must not mutate source code, branch state, generated context, or canonical reports outside their assigned report artifact.

**Clean Slate Rule:** The deterministic coordinator launches each audit worker without parent conversation context. This worker must analyze only its assigned scope and must not launch other agents.

## Required references

Read these bundled references before producing findings:

1. `references/scope-and-standards.md` — scope discipline, standards sources, evidence rules, and tooling-skip policy
2. `references/smell-baseline.md` — Fowler smell baseline; use as heuristics and label baseline-only findings as possible smell
3. `references/quality-checks.md` — concrete code-quality checks for maintainability, correctness smells, error handling, tests, type/contracts, and simplicity
4. `references/reporting.md` — canonical report targets and finding format

The runtime embeds these files below this `SKILL.md` for orchestrated audit runs. If invoking the skill manually and the references are not embedded, read them from this skill directory before continuing.

## Prerequisites

This skill usually runs inside an audit subprocess spawned by `plugins/edc/scripts/edc-audit.sh` or a build-time audit orchestration step. The orchestrator is responsible for context freshness and for assigning scope.

When invoked for the current whole-repo audit command, assume `edc-context/modules/` and `edc-context/manifest.json` exist and reflect HEAD. During build-time module audit, a task may provide module files directly before the final manifest exists; in that case, use the task-provided module doc and file list rather than requiring `manifest.json`.

If required scope inputs are missing, fail loudly. Do not repair the context layout from inside the skill.

## Workflow

1. **Load scope and standards.** Follow `references/scope-and-standards.md`. Identify documented standards sources for the assigned scope and record any rules that materially affect findings.
2. **Load smell baseline.** Follow `references/smell-baseline.md`. Repo standards override baseline smells; baseline-only findings are judgement calls.
3. **Run quality checks.** Follow `references/quality-checks.md`. Verify every candidate in context before reporting it.
4. **Write output.** Follow `references/reporting.md`. Scoped workers write only their assigned artifact; synthesis/whole-repo runs write `edc-context/reports/{complexity,issues}.md`.

## Quality-only boundary

This audit targets code quality only: maintainability, correctness smells, error handling, interface clarity, type/contracts, test value, duplication, bloat, and simplicity.

Do not turn this into a delivery/spec review. Do not judge whether the change implements the user's goal unless the issue is visible as code-quality evidence inside the assigned scope.

Do not turn this into an exploit-focused review. If a finding is primarily about adversarial misuse, leave it for the dedicated adversarial review workflow.

## Output summary

Reports should make quality tradeoffs actionable without prescribing a full refactor. Prefer small, boring recommendations tied to a specific file/line and explain why the issue matters for future changes or correctness.
