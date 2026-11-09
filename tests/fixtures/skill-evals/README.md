# EDC skill eval fixtures

Deterministic fixture corpus for future skill behavior evals.

Each fixture contains:

- `prompt.md` — input prompt for a fresh reviewer using the named EDC skill.
- source/spec/context files — realistic evidence the reviewer must inspect.
- `expected.json` — machine-checkable assertions for report behavior:
  - `requiredFiles` lists non-empty fixture-relative input files that must exist as regular files inside the fixture.
  - `requiredEvidence` lists non-empty text tokens or phrases that must occur in fixture input content outside `expected.json`.

Hardening validates fixture coverage and schema only. It does not call an LLM.

## State-derived audit cases

- `audit/state-sequence-gap`: current-response, immediate cancellation, and retry tests pass, but late completion of cancelled A can clear pending B's loading state. A reviewer should cite that cleanup ownership defect and suggest the missing bounded sequence using the existing harness.
- `audit/covered-independent-state`: guarded cleanup and existing late-success/late-failure tests cover that sequence. Independent panel/loading flags are intentional, not a reason to demand an enum or more tests.

Each case includes a runnable `node:test` harness: run `node --test test/loader.test.mjs` from its fixture directory. Passing those existing tests validates fixture behavior only; it neither proves complete coverage nor evaluates an LLM's report. The gap case intentionally lacks the late-completion assertion. `expected.json` describes future report assertions, not observed model performance.
