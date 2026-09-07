# completeness checklist

before concluding analysis of the assigned scope, verify evidence rather than counts of statements.

## contracts and effects

- [ ] the function/module's purpose and authority are clear.
- [ ] relevant explicit/implicit inputs, trust assumptions, outputs, state writes, and external effects are identified.
- [ ] inspected branches and transitions support the claimed behavior, including relevant failure/cleanup paths.
- [ ] actual invariants and dependencies are tied to source evidence; no invented minimum count is required.

## continuity and scope

- [ ] caller/callee assumptions and shared-state couplings are traced where needed within the assigned boundary.
- [ ] sibling-module evidence remains limited to coordinator-supplied signatures/docs.
- [ ] language/runtime-specific arithmetic and resource rules apply to the code actually inspected.
- [ ] unresolved external behavior, uninspected paths, and remaining questions are explicit limitations.

## evidence and output

- [ ] claims have source pointers and contradictions are explicitly corrected.
- [ ] speculation is marked unknown rather than made certain to satisfy a completion gate.
- [ ] the persisted document contains decision-useful contracts/hazards, not scratch narration.
- [ ] output goes only to the coordinator-declared staged path; canonical promotion is coordinator-owned.

completion means the reported inspected scope is supported. it does not mean all unknowns disappeared or that unrelated scope was analyzed.
