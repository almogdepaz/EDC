# private analysis and persisted output

use these categories to check coverage, not as a demand to produce exhaustive scratch prose or meet numerical reasoning quotas. the [function example](FUNCTION_MICRO_ANALYSIS_EXAMPLE.md) illustrates analysis; it is not a mandatory output template.

## output authority

write the final distilled module doc only to the coordinator-declared staged path. the coordinator validates and promotes it to `edc-context/modules/<name>.md`; the worker never writes canonical context directly. follow [the final-doc contract](../SKILL.md).

## coverage categories

- **purpose and authority:** explain the role and non-obvious ownership boundary.
- **inputs and assumptions:** identify actual explicit/implicit inputs, preconditions, and trust assumptions; do not invent extras to meet a count.
- **outputs and effects:** trace relevant returns, state mutations, events, external interactions, and postconditions.
- **ordering and failure paths:** inspect branches, state transitions, cleanup, and external calls needed to establish the claimed contracts. use causal questions where they resolve uncertainty, not once per block as ceremony.
- **dependencies and coupling:** connect relevant callers, callees, shared state, and invariants within assigned scope. sibling source remains out of bounds unless separately authorized by the coordinator.

## evidence and limitations

support persisted claims with source pointers. record unresolved questions and uninspected paths as limitations; do not infer certainty from an analysis checklist. apply memory/arithmetic checks according to the actual language/runtime and ownership model.

persist only decision-useful read boundaries, authority, implicit contracts, ordering constraints, coupling, trust boundaries, historical hazards, and source pointers. omit copied constants, inventories, obvious function narration, and private scratch structure. no minimum sentence, invariant, assumption, effect, or dependency count applies.
