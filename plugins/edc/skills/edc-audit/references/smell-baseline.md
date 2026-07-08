# Fowler Smell Baseline

Apply the Fowler smell baseline as heuristics, not hard violations. Each smell is a candidate that still requires context verification. Report surviving baseline findings as a possible smell unless they also violate a documented standard or create concrete code-quality risk.

| Smell | Audit interpretation | Preferred recommendation |
|---|---|---|
| Mysterious Name | Name does not reveal the concept, role, or value it carries. | Rename; if no honest name exists, simplify the design. |
| Duplicated Code | Same logic shape appears in multiple scoped locations. | Extract or consolidate the shared rule/source of truth. |
| Feature Envy | Code reaches deeply into another module/object's data instead of asking that owner to do the work. | Move behavior toward the data owner or expose a narrower method. |
| Data Clumps | Same fields/parameters travel together repeatedly. | Introduce a small value object/options type when it clarifies the contract. |
| Primitive Obsession | Primitive/string stands in for a durable domain concept. | Replace with enum/const/value type/typed union as appropriate. |
| Repeated Switches | Same switch/if cascade on the same type recurs. | Centralize dispatch through one map/table or better type model. |
| Shotgun Surgery | One logical change forces scattered edits across many files. | Gather co-changing behavior into one module or clearer boundary. |
| Divergent Change | One module changes for unrelated reasons. | Split responsibilities so each module has one reason to change. |
| Speculative Generality | Abstractions/hooks/options exist for needs not present in the codebase. | Delete or inline until a real second use appears. |
| Message Chains | Callers navigate long `a.b().c().d()` chains. | Hide traversal behind a method owned by the first stable object. |
| Middle Man | Type/function mostly delegates onward without adding value. | Remove the delegate or justify it as a boundary/compatibility seam. |
| Refused Bequest | Subtype/implementation ignores most inherited contract. | Prefer composition or a smaller interface. |
