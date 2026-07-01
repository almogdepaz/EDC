# Delivery / Architecture Reporting

Report Goal / Spec Delivery and Architecture Fit side by side. Do not merge or rerank the axes.

## Required structure

```md
# Delivery / Architecture Review

## Summary
**Delivery verdict:** delivered | partially delivered | not delivered | unclear requirements | No spec available
**Architecture fit:** fits | questionable | violates boundary | insufficient context

## Review Calibration
- real goal: one sentence describing the intended outcome
- done evidence: observable evidence that would prove the goal is delivered
- not the goal: nearby work that should not be judged as required delivery
- non-obvious invariants: constraints from specs, EDC context, architecture docs, or compatibility rules

## Goal / Spec Delivery

| Requirement | Evidence in implementation | Status |
|---|---|---|
| quote or source pointer | file:line / behavior | delivered / partial / missing / wrong / scope creep |

### Findings

#### BLOCKER / IMPORTANT / ADVISORY — <title>
- category: missing requirement | partial requirement | implemented but wrong | scope creep | unclear requirement | spec/plan issue
- requirement: quote the requirement or say `No spec available`
- implementation evidence: file:line
- why it matters: ...
- action: IMPLEMENT_REQUIREMENT | REMOVE_SCOPE_CREEP | STANDARDIZE_CONTRACT | ADD_MIGRATION_OR_ROLLOUT
- recommendation: ...

## Architecture Fit

### Findings

#### BLOCKER / IMPORTANT / ADVISORY — <title>
- category: module ownership | source of truth | data model | API/error contract | integration completeness | migration | backward compatibility | rollout
- architecture source: EDC module/index/doc reference when available
- implementation evidence: file:line
- why it matters: ...
- action: MOVE_TO_OWNER | CHOOSE_SOURCE_OF_TRUTH | STANDARDIZE_CONTRACT | ADD_MIGRATION_OR_ROLLOUT
- recommendation: ...

## Integration / Rollout Notes
- docs/config/migration/generated artifacts checked
- known gaps or follow-up needed

## Limitations
- missing spec/source context
- modules/callers not inspected
- assumptions made
```

## Verdict calibration

### Delivery verdict

- **delivered** — every material requirement is implemented and no material scope creep was found.
- **partially delivered** — core path exists but required cases, wiring, docs/config/migrations, or acceptance criteria are missing.
- **not delivered** — implementation does not satisfy the main requirement.
- **unclear requirements** — spec exists but is too ambiguous to judge.
- **No spec available** — no requirement source was found; do not hallucinate requirements.

### Architecture fit

- **fits** — implementation is in the expected owner/layer and preserves documented contracts.
- **questionable** — likely fit issue or incomplete integration that needs confirmation.
- **violates boundary** — behavior is in the wrong owner/layer, creates a second source of truth, or breaks a documented contract.
- **insufficient context** — architecture docs/context are missing and local evidence is not enough.

## Severity calibration

- **BLOCKER** — likely to ship the wrong behavior, miss a required outcome, break a boundary contract, or require rework before merge.
- **IMPORTANT** — should be fixed or explicitly accepted before merge.
- **ADVISORY** — useful follow-up, clarification, or rollout note; not a blocker alone.

Do not add code-style, local refactor, or adversarial findings here. Route those to the appropriate EDC skill.
