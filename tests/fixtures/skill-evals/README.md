# EDC skill eval fixtures

Deterministic fixture corpus for future skill behavior evals.

Each fixture contains:

- `prompt.md` — input prompt for a fresh reviewer using the named EDC skill.
- source/spec/context files — realistic evidence the reviewer must inspect.
- `expected.json` — machine-checkable assertions for report behavior.

Hardening validates fixture coverage and schema only. It does not call an LLM.
