# Quality Checks

Run these checks against the assigned audit scope. Keep findings code-quality focused: correctness, maintainability, test value, interface clarity, and simplicity.

## LOC vs complexity estimate

For each assigned module or module-like scope:
1. Read the module purpose and the invariants/flows described.
2. Based on the described complexity, estimate what a senior engineer would write this in (LOC).
3. Count actual LOC of the module's source files.
4. Flag modules where actual LOC > 2x the estimate, unless extra size is justified by generated code, schema tables, fixtures, or explicit compatibility requirements.

## Dead exports / public surface

For each source file in scope, find exports (functions, classes, types, constants). Inspect references/usages enough to verify whether each export is unused. Flag exports with zero external references only when the export is not intentionally public API, plugin surface, test fixture, framework entrypoint, or compatibility shim.

## Wrapper functions

Find functions that:
- have a body of 1-3 lines
- call exactly one other function
- pass through all or most arguments unchanged
- add no logic, validation, naming clarity, typing boundary, telemetry, or compatibility value

These are indirection without value. List each with the function it wraps.

## Abstraction vs usage

For each module/scope, count:
- number of exported abstractions (interfaces, types, classes, functions)
- number of unique callers/importers across the codebase or assigned caller set

Flag modules where `abstractions > 3 * callers` only after verifying the abstractions are not stable public contracts or required adapter seams.

## Duplication detection

Find similar code blocks:
- functions with near-identical bodies (>80% token overlap)
- repeated patterns of 5+ lines that encode the same business rule or protocol
- types/interfaces that differ by 1-2 fields
- validation/parsing/serialization logic copied across files

Use the module doc's coupling notes to distinguish legitimate repeated adapters from accidental duplicate sources of truth.

## File and function size

List source files/functions by LOC. Flag:
- files > 3x the median file length
- files > 500 LOC
- single files holding >30% of the assigned scope LOC
- functions >50 LOC with mixed responsibilities

Downgrade orchestrators that are sequential delegation only and generated/schema/config files.

## Indirection depth

For key entrypoints documented in `edc-context/index.md` or the assigned module doc, trace the call chain from entrypoint to actual work. Count function hops. Flag chains where:
- depth > 4 for simple operations
- any hop is a pure pass-through wrapper
- responsibility is split so thinly that a future maintainer must open many files for one behavior

## Test mirroring

Compare test files against production modules. Flag tests that:
- reimplement production logic instead of importing it
- define helper functions that duplicate production functions
- have assertion logic that mirrors validation logic in production
- assert mocks were called instead of behavior happening

## Correctness smells

Look for correctness smells in scoped code:
- loop `break`/`return`/`continue` that handles only the first matching item when all items matter
- duplicate-key map/object construction where last-wins loses data
- unbounded list/query/file operations on user- or repo-controlled input
- mutable shared state that can leak across requests, jobs, sessions, or tests
- partial failure paths that leave inconsistent state

Promote these to `issues.md` when they can cause real wrong behavior, data loss, or broken code paths.

## Error handling

Flag error handling problems:
- swallowed exceptions or empty catch blocks
- catch-and-log-only when callers assume success
- broad fallback that masks corruption, stale context, failed writes, or failed external calls
- cleanup missing on early return/failure
- diagnostics made too vague for recovery

Do not report deliberate best-effort telemetry/logging failures unless they affect correctness.

## Interface honesty

Flag misleading interfaces:
- `get*`, `find*`, `check*`, `validate*`, `is*`, or `has*` functions that perform writes or irreversible side effects
- return types that hide failure, partial success, or mutation
- boolean flag parameters that create hidden modes in public APIs
- opaque `dict`/object/tuple returns where callers must know undocumented shape

## Side-effect breadth

Flag side-effect breadth when a leaf function mixes unrelated responsibilities such as validation, business logic, filesystem writes, network calls, database mutation, analytics, logging policy, and subprocess execution. Do not flag explicit orchestrator/coordinator functions that delegate sequentially and keep leaf logic separated.

## Type/contract weakness

Flag type/contract weakness:
- `any`, unchecked casts, loose dictionaries, or `unknown` without narrowing in typed code
- nullable/optional ambiguity at module boundaries
- stringly typed state, protocols, actions, or error categories where an enum/const/typed union exists or is warranted
- magic literals encoding durable state, protocol, status, timeout, or routing behavior

## Test value

Assess test value, not just test existence:
- changed behavior has behavior-level tests
- boundary/error cases are covered where risk justifies it
- tests fail for the right reason when production behavior breaks
- tests do not rely on arbitrary timing, excessive mocks, or implementation mirroring
- public APIs and cross-module contracts have integration-level coverage where unit tests cannot prove delivery

Promote missing or low-value tests to `issues.md` only when the untested path creates concrete correctness risk. Otherwise keep it in `complexity.md` as maintainability risk.

## Simplicity

Flag simplicity violations:
- YAGNI abstractions created before multiple real callers exist
- nth special-case branches indicating the data model is wrong
- copy-pasted blocks with one value changed
- magic literals that should be named constants/enums
- mixed-concern blobs that should be split by responsibility
- clever control flow where straightforward code would be safer
- Fowler smell baseline candidates that survive context verification and are not overridden by repo standards

Prefer boring, obvious recommendations. Do not suggest architectural rewrites for local issues.
