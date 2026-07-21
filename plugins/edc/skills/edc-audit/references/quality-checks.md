# Quality Checks

Run these checks against the assigned audit scope. Keep findings code-quality focused: correctness, maintainability, test value, interface clarity, and simplicity.

## Simplification ladder

Before recommending new code, climb this ladder and stop at the first rung that honestly fits the scoped evidence:

1. **Delete it** — does this need to exist at all, or is it dead/speculative surface?
2. **Existing repo helper** — does this codebase already have the helper, util, type, route, adapter, or pattern?
3. **Standard library** — does the language/runtime already solve it clearly?
4. **Native platform** — does the browser, database, shell, OS, framework, or package manager already provide the behavior?
5. **Installed dependency** — is an already-installed dependency the appropriate owner?
6. **One line** — can the same behavior be expressed directly without hiding intent?
7. **Minimum custom code** — only then recommend the smallest custom implementation that preserves documented behavior.

Use these tags for simplification findings when they fit:

- `delete:` dead code, unused flexibility, speculative feature, stale config, or boat anchor. Replacement: nothing.
- `stdlib:` hand-rolled behavior replaced by a standard library/runtime call.
- `native:` dependency or custom code replaced by a native platform capability.
- `yagni:` abstraction/config/extension point with no real second use.
- `shrink:` same behavior, fewer moving parts.

Rank biggest cuts first when findings have similar risk. Include estimated removal only when it is obvious from the diff or file read (`estimated removal: ~N lines / M deps`). Do not invent precision.

## Sharp simplification hunt list

Actively look for:
- dependencies that stdlib or native platform already covers
- single-implementation interfaces/classes/factories
- wrappers that only delegate
- files exporting one tiny thing with no boundary value
- dead flags, config, options, compatibility branches, or feature gates
- hand-rolled parsing, formatting, UUID/date/base64/path/debounce/grouping helpers
- custom queues/state machines/DSLs where the host platform already has the primitive

## Antipattern catalog overlap

Use these antipattern names as compatible code-quality heuristics when evidence survives context verification:

- **boat anchor** — kept code/config with no current use or owner.
- **cargo cult** — copied ceremony with no semantic value.
- **error hiding** — swallowed failure or vague fallback that callers treat as success.
- **action at a distance** — global/module state mutation that changes unrelated behavior later.
- **race hazard** — shared async state updated without a coherent owner/guard.
- **inner-platform** — custom DSL/interpreter/framework that recreates host-language features.
- **magic pushbutton** — UI/event handlers mixing validation, business rules, persistence, and side effects.
- **soft code** — config so large or expressive that it becomes untyped business logic.
- **shooting the messenger** — suppressing diagnostics (`@ts-ignore`, `eslint-disable`, type/lint silencing) instead of fixing the cause.
- **premature generalization** — flexibility before real variation exists.

Do not report catalog names by grep alone. Verify the code path, owner, and likely maintenance cost. Use LOW confidence when the pattern may be intentional.

## Accepted debt markers

Treat `edc-debt:` comments as intentional simplification/debt markers only when they name both the ceiling and the upgrade trigger, e.g.:

```text
edc-debt: global lock is enough for one worker; upgrade when parallel workers are enabled
```

Report markers missing `upgrade when` or another concrete trigger as maintainability risk. Do not automatically flag well-scoped markers with a clear trigger.

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

For bug-fix shaped changes, prefer the root-cause fix over symptom patches: grep every caller of the function or boundary being changed. One guard or contract fix in the shared owner is usually simpler and safer than per-caller guards.

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

For non-trivial scoped logic, prefer the smallest runnable check that would fail if the behavior broke: one behavior test, integration assertion, command smoke, or self-contained reproduction. Do not demand fixture-heavy test suites when a smaller check proves the risk.

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
