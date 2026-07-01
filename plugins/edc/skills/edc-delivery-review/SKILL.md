---
name: edc-delivery-review
description: >
  Reviews whether code changes deliver the stated goal/spec and fit the repository architecture.
  Use this for PRs, branches, task implementations, plans, or diffs when the question is
  whether the implementation built the right thing in the right place: requirement coverage,
  scope creep, module ownership, source-of-truth choices, contracts, migrations, docs, and rollout.
allowed-tools:
  - Read
  - Write
  - Grep
  - Glob
  - Bash
  - Skill
---

# Delivery / Architecture Review

Review a change along two separate axes:

1. **Goal / Spec Delivery** — did the implementation faithfully satisfy the originating issue, plan, PRD, task, or stated goal?
2. **Architecture Fit** — does the implementation belong in the touched module/layer and preserve the system's documented contracts?

Do not merge or rerank the axes. A change can deliver the requested behavior while violating architecture, or fit the architecture while missing the goal. Report both side by side.

Use edc-audit for code quality, maintainability, bloat, and test-value analysis. Use edc-review for security and adversarial review.

## Required references

Read these bundled references before producing findings:

1. `references/spec-axis.md` — spec source discovery, requirement coverage, missing/partial/wrong/scope-creep taxonomy
2. `references/architecture-axis.md` — EDC context loading, module ownership, source of truth, API/error contract, migration, backward compatibility, rollout checks
3. `references/reporting.md` — side-by-side report format and verdicts

## Scope discipline

This skill is read-only. Do not mutate source, tests, git state, context files, or plans. Write only the requested report artifact, or answer in chat if no artifact path was requested.

When reviewing a diff, pin the base once and use it consistently:

```bash
git rev-parse <base>
git diff <base>...HEAD --stat
git diff <base>...HEAD --name-only
git log <base>..HEAD --oneline
```

If no base is provided, infer the repository default branch or ask for the fixed point. Empty diffs or bad refs should fail before analysis.

## Workflow

1. **Discover the spec source.** Follow `references/spec-axis.md`. If no spec exists, report `No spec available` and do not hallucinate unstated requirements.
2. **Load EDC architecture context.** Follow `references/architecture-axis.md`: read `edc-context/index.md`, affected module docs, known issues, and coupled modules when available.
3. **Calibrate the review.** Before findings, write the `Review Calibration` block from `references/reporting.md`: real goal, done evidence, not the goal, and non-obvious invariants.
4. **Review Goal / Spec Delivery.** Check requirement coverage, missing work, partial work, implemented-but-wrong behavior, scope creep, and spec/plan issue cases. Quote the requirement when available.
5. **Review Architecture Fit.** Use candidate scan then context verification. Check module ownership, source of truth, data model fit, API/error contract, integration completeness, migration, backward compatibility, docs/config, and rollout concerns.
6. **Write the report.** Follow `references/reporting.md` with separate Delivery verdict and Architecture fit verdict.

## Boundaries

Stay out of code-quality smell review unless the issue directly changes delivery or architecture fit. Stay out of adversarial analysis unless the issue is necessary to explain architecture/goal delivery; otherwise defer to `edc-review`.
