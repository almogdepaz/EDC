# Architecture Fit Axis

Use this axis to answer: is the implementation in the right place, using the right owner/source of truth, and complete enough to integrate safely?

## EDC context loading

If `edc-context/` exists:
1. Read `edc-context/index.md` for routing, critical invariants, and coupling/blast-radius notes.
2. Use `edc-context/manifest.json` or orchestrator-provided task files for path-to-module routing; do not improvise routing from prose.
3. Read affected `edc-context/modules/{module}.md` files.
4. Read coupled module docs listed by the index when the change crosses a boundary.
5. Read `edc-context/reports/issues.md` only to check whether the delivery touches known correctness or architecture risks.

If generated context is missing, inspect local architecture docs, README/CONTRIBUTING, package boundaries, and adjacent modules. State the limitation.

## Detection discipline

Use two-layer detection:

1. **candidate scan** — identify possible fit problems from changed paths, imports, call sites, config/docs touched, and boundary-shaped names.
2. **context verification** — verify each candidate against EDC module docs, architecture docs, callers, public contracts, migrations, or adjacent implementation before reporting it.

Do not report architecture findings from path names, grep hits, or generic preferences alone.

When the prompt says `OCTOCODE_STATUS: available`, use its permitted queries to verify callers, public contracts, integration completeness, ownership evidence, and installed dependency behavior.

## Architecture checks

### Module ownership

Check whether the changed code belongs in the module/layer it touches:
- Is policy implemented in the owning module rather than a caller bypass?
- Is routing/state/config owned by a single authority?
- Are callers updated through the intended API rather than reaching into internals?
- Does the implementation respect documented module invariants?
- Is unit-of-work ownership consistent, with transaction commit/rollback controlled by the documented owner?
- Is session/resource ownership consistent, rather than mixing injected resources with locally-created resources in the same flow?
- Is orchestration depth appropriate, or did the change bury coordination in a leaf module that should be called by an owner/coordinator?

### Source of truth and data model

Check whether the change creates or preserves a coherent source of truth:
- no second durable state owner for the same fact
- no derived state that can drift without reconciliation
- no human-readable text parsed as a protocol when structured data exists
- data model changes match the requirement instead of patching symptoms downstream

### API/error contract

Check boundary contracts:
- API/request/response shapes match existing conventions and the spec
- error categories and status/results stay consistent at the boundary
- domain/service layers do not accept transport-specific objects unless that is the established architecture
- ORM/entities/internal structs do not leak across public boundaries when the architecture uses DTOs or adapters
- client/adapter abstraction is preserved for external systems instead of direct ad hoc calls from non-owner layers
- event publisher/subscriber names, payload shapes, and ownership stay consistent when event flows are touched

### Integration completeness

Check whether the change is wired through all necessary surfaces:
- callers and entrypoints updated
- config/env/example files updated when new configuration is required
- docs updated when public behavior or setup changes
- migrations/generated artifacts included when needed
- tests prove the user-visible requirement at the right level when unit tests cannot prove integration

### Migration, backward compatibility, rollout

Check delivery risks outside the local diff:
- migration order and rollback implications
- old data/config/API clients still work or the break is documented
- feature flags/version gates when the rollout requires staged adoption
- deployment/package/runtime contract still aligns with the repo's release path

## Calibration

Report architecture findings only when the design choice makes the goal incomplete, places behavior in the wrong owner, creates integration risk, or violates a documented invariant/contract. Do not report local maintainability smells; those belong to `edc-audit`.
