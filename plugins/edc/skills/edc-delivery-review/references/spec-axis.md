# Goal / Spec Delivery Axis

Use this axis to answer: did the implementation deliver what was asked, without silently adding unrelated behavior?

## Spec source discovery

Find the originating requirement source in this order:

1. Issue or PR references in commit messages, branch names, or PR text: `#123`, `Closes #45`, task IDs, or linked planning docs.
2. A path passed by the user or task file.
3. Repo-local plans/specs under `docs/`, `specs/`, `.plans/`, `plans/`, `tasks/`, or issue templates matching the branch/task name.
4. If none exists, write `No spec available` and do not hallucinate unstated requirements. Review only observable delivery claims from commit messages, PR text, or user-provided context.

When a spec exists, quote the requirement for each delivery finding. Use file/line when possible.

## Requirement coverage taxonomy

Classify delivery findings into these categories:

- **missing requirement** — the spec asked for behavior that is absent.
- **partial requirement** — some required cases are handled but others are omitted.
- **implemented but wrong** — code appears to target the requirement but behavior, edge case, data shape, or integration point does not match the requirement.
- **scope creep** — behavior, API surface, refactor, config, migration, or user-visible change not asked for and not necessary to deliver the requirement.
- **unclear requirement** — the source is ambiguous enough that the reviewer cannot judge without clarification.
- **spec/plan issue** — the requirement source is internally inconsistent, impossible under the documented architecture, or would make the implementation worse if followed literally.

## What to inspect

- changed files and directly connected callers/config/docs/tests needed to prove delivery
- public API behavior and contract changes
- user-visible behavior promised by the spec
- acceptance criteria and edge cases
- config, docs, migrations, generated artifacts, or packaging touched by the requirement

## Calibration

Only flag issues that would make an implementer build the wrong thing, miss a required behavior, ship unrelated behavior, or require rework because a requirement was misunderstood. Do not flag wording polish or internal style here.

If the implementation intentionally deviates from the spec and the rationale is documented in the diff or plan, report it as `needs confirmation` rather than a hard failure.

If the plan or spec itself is flawed, report `spec/plan issue` and explain the conflict. Do not force bad spec compliance when the documented requirement would violate an invariant, contradict another requirement, or require the wrong architecture.
