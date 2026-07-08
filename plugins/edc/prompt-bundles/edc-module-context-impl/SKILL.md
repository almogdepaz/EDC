---
name: edc-module-context-impl
description: Enables ultra-granular, line-by-line code analysis to build deep architectural context for any codebase.
---

# Module Context Methodology (Distilled High-Signal Context Mode)

## 1. Purpose

This skill governs **how the agent thinks** during the context-building phase of an audit.

When active, the agent will:
- Perform **line-by-line / block-by-block** code analysis by default.
- Apply **First Principles**, **5 Whys**, and **5 Hows** at micro scale.
- Continuously link insights → functions → modules → entire system.
- Maintain a stable, explicit mental model that evolves with new evidence.
- Identify invariants, assumptions, flows, and reasoning hazards.

Ultra-granular analysis depth is the reasoning method, not the persisted artifact shape. The final module doc must be distilled high-signal module context: persist only what saves a future agent time or prevents wrong assumptions. If an agent can discover it with one Read, Grep, or Glob, leave it out.

This skill defines a structured analysis format (see Example: Function Micro-Analysis below) and runs **before** the vulnerability-hunting phase.

When invoked from a v2 build, the per-module distilled-context output is written to `edc-context/modules/<name>.md` (one file per module, kebab-case names). Do not write per-module docs at the top level of `edc-context/`.

---

## 2. When to Use This Skill

Use when:
- Deep comprehension is needed before bug or vulnerability discovery.
- You want bottom-up understanding instead of high-level guessing.
- Reducing hallucinations, contradictions, and context loss is critical.
- Preparing for security auditing, architecture review, or threat modeling.

Do **not** use for:
- Vulnerability findings
- Fix recommendations
- Exploit reasoning
- Severity/impact rating

---

## 3. How This Skill Behaves

When active, the agent will:
- Default to **ultra-granular analysis** of each block and line.
- Apply micro-level First Principles, 5 Whys, and 5 Hows.
- Build and refine a persistent global mental model.
- Update earlier assumptions when contradicted ("Earlier I thought X; now Y.").
- Periodically anchor summaries to maintain stable context.
- Avoid speculation; express uncertainty explicitly when needed.

Goal: **deep, accurate understanding**, then a concise persisted doc containing non-obvious contracts and hazards, not exhaustive code narration.

---

## Rationalizations (Do Not Skip)

| Rationalization | Why It's Wrong | Required Action |
|-----------------|----------------|-----------------|
| "I get the gist" | Gist-level understanding misses edge cases | Line-by-line analysis required |
| "This function is simple" | Simple functions compose into complex bugs | Apply 5 Whys anyway |
| "I'll remember this invariant" | You won't. Context degrades. | Write it down explicitly |
| "External call is probably fine" | External = adversarial until proven otherwise | Jump into code or model as hostile |
| "I can skip this helper" | Helpers contain assumptions that propagate | Trace the full call chain |
| "This is taking too long" | Rushed context = hallucinated vulnerabilities later | Slow is fast |

---

## 4. Phase 1 — Initial Orientation (Bottom-Up Scan)

Before deep analysis, the agent performs a minimal mapping:

1. Identify major modules, components, and boundaries.
2. Note obvious public/external entrypoints.
3. Identify likely actors: users, operators, internal components, and external dependencies.
4. Identify mutable state, persistent stores, and configuration.
5. Build a preliminary structure without assuming behavior.

This establishes anchors for detailed analysis.

---

## 5. Phase 2 — Ultra-Granular Function Analysis (Default Mode)

Every non-trivial function receives full micro analysis.

### 5.1 Per-Function Microstructure Checklist

For each function:

1. **Purpose**
   - Why the function exists and its role in the system.

2. **Inputs & Assumptions**
   - Parameters and implicit inputs (state, sender, env).
   - Preconditions and constraints.

3. **Outputs & Effects**
   - Return values.
   - State/storage writes.
   - Events/messages.
   - External interactions.

4. **Block-by-Block / Line-by-Line Analysis**
   For each logical block:
   - What it does.
   - Why it appears here (ordering logic).
   - What assumptions it relies on.
   - What invariants it establishes or maintains.
   - What later logic depends on it.

   Apply per-block:
   - **First Principles**
   - **5 Whys**
   - **5 Hows**

5. **State Machine Analysis** (when function is part of a state machine or non-blocking protocol)
   - Map every state and transition. What causes each transition?
   - For non-blocking re-entry: when the function returns early (EAGAIN, WOULDBLOCK, partial completion) and is called again later, are all decisions from the previous call still valid?
   - What variables are set in one state but consumed in a different state? Can anything between those states invalidate the assumption?
   - What happens when a multi-step operation takes many calls to complete — do intermediate failures corrupt later logic?

6. **Flag/Boolean Variable Tracing** (for every flag or boolean that controls behavior)
   - **Where set:** which function, which state, under what conditions
   - **Where consumed:** which function, which state, how many transitions later
   - **Corruption window:** can ANY code path between set and use change it unexpectedly? Can a slow/interrupted operation cause the flag to be set in a state where it shouldn't be?
   - **Impact if wrong:** if the flag has the opposite value at point of use, what breaks? (e.g., wrong buffer size, skipped validation, wrong protocol path)
   - Pay special attention to flags that control: local vs remote resolution, protocol variant selection, buffer size decisions, security-relevant behavior

7. **Integer Arithmetic & Size Calculation Analysis** (for every expression that produces a value used as a size, offset, index, or length)
   - **Identify the arithmetic**: find every `+`, `-`, `*`, `/`, `<<` whose result feeds `malloc`/`calloc`/`realloc`, `memcpy`/`memmove`/`memset`, array subscript, pointer arithmetic, or a length-checked comparison
   - **Overflow/underflow path**: can the expression wrap? For `size_t` the wrap is at `SIZE_MAX`; for `int` it is undefined behavior AND wraps in practice. Ask: if both operands are attacker-controlled, what value makes `a + b < a` (overflow) or `a - b > a` (underflow)?
   - **Signedness mismatch**: is a signed value implicitly converted to an unsigned type (negative → huge positive) or vice versa (large unsigned → negative)? Note every implicit cast at call boundaries.
   - **Truncation**: is a 64-bit result narrowed to 32-bit or 16-bit before use? What input makes the top bits non-zero so the truncated value is wrong?
   - **Multiplication**: `count * element_size` is the canonical overflow vector. Check: is `calloc(count, size)` used (safe) or manual `malloc(count * size)` (unsafe without prior check)?
   - **Impact trace**: follow the arithmetic result to the first memory operation — if the value is wrong (too small), what buffer is allocated or indexed, and what write immediately follows? Document the full path: `attacker input → arithmetic → allocation/index → write target`.

8. **Error-Path Memory Safety** (for every function that allocates memory or holds a pointer)
   - **Enumerate all exit points**: list every `return`, `goto`, `break`, or exception path. For each, verify that every allocation made BEFORE that exit is freed exactly once on that path.
   - **Use-after-free pattern**: does any code after a `free(p)` / `curl_free(p)` / `Curl_safefree(p)` dereference `p`? Check: error handlers, retry loops, fallback branches that run after cleanup.
   - **Double-free pattern**: can two code paths both reach `free(p)` for the same pointer? Common in cleanup functions that call sub-cleaners which also free shared state.
   - **Dangling reference on reallocate**: `realloc(p, n)` may move the buffer — are there other pointers (cached offsets, substring pointers, iterator cursors) that still point into the OLD location?
   - **Cleanup ordering**: if function X frees A then B, and B's destructor references A, is A freed too early? Reverse-dependency order matters.
   - **NULL after free check**: after freeing, is the pointer zeroed? If not, a later NULL-check guard (`if (p)`) will pass on the dangling value and proceed unsafely.
   - **Impact trace**: document the exact path from `free(p)` to the next dereference of `p`, naming the variable, the line of free, and the line of use.

9. **Recursive Call Analysis** (for every function that calls itself directly or transitively)
   - **Enumerate ALL recursive call sites independently**: walk every branch of the function and list each site where recursion occurs. A function parsing tokens may recurse on `*`, on `[`, on `(`, and on nested calls — each is a separate entry. Do NOT stop after finding the first recursive path.
   - **Per-path depth guard**: does each recursive call site have its OWN depth check before recursing? A depth limit at function entry is bypassed by any branch that recurses without re-entering through that limit. Check: can a crafted input reach a recursive call site while the guard variable is stale or skipped?
   - **Stack frame size**: estimate local variable + buffer space per frame; multiply by reachable depth to check for stack exhaustion.
   - **Worst-case input per path**: for each recursive call site, identify the exact input character/value/pattern that drives that branch — e.g., `[` triggers bracket-expression recursion, `*` triggers wildcard recursion, `(` triggers group recursion. Name them explicitly.
   - **Impact**: unbounded recursion → stack overflow (crash, potential control-flow hijack on systems without stack cookies/canaries).

---

### 5.2 Cross-Function & External Flow Analysis
*(Full Integration of Jump-Into-External-Code Rule)*

When encountering calls, **continue the same micro-first analysis across boundaries.**

#### Internal Calls
- Jump into the callee immediately.
- Perform block-by-block analysis of relevant code.
- Track flow of data, assumptions, and invariants:
  caller → callee → return → caller.
- Note if callee logic behaves differently in this specific call context.

#### External Calls — Two Cases

**Case A — Dependency Whose Implementation Is Available**
Treat as an internal call:
- Jump into the target component.
- Continue block-by-block micro-analysis.
- Propagate invariants and assumptions seamlessly.
- Consider edge cases based on the *actual* code, not a black-box guess.

**Case B — External Dependency Without Available Code (True External / Black Box)**
Analyze as adversarial:
- Describe arguments, context, and resources consumed.
- Identify assumptions about the target.
- Consider all failure modes:
  - total failure (crash, exception, timeout, hang)
  - partial failure (incorrect or incomplete return values)
  - state corruption (callee modifies shared state unexpectedly)
  - contract violation (callee doesn't honor its interface)
  - re-entrant or recursive invocation (callee calls back into caller before original call completes)

#### Continuity Rule
Treat the entire call chain as **one continuous execution flow**.
Never reset context.
All invariants, assumptions, and data dependencies must propagate across calls.

---

### 5.3 Complete Analysis Example

See [FUNCTION_MICRO_ANALYSIS_EXAMPLE.md](resources/FUNCTION_MICRO_ANALYSIS_EXAMPLE.md) for a complete walkthrough demonstrating:
- Full micro-analysis of an HTTP route handler that spawns subprocesses
- Application of First Principles, 5 Whys, and 5 Hows
- Block-by-block analysis with invariants and assumptions
- Cross-function dependency mapping
- Risk analysis for external interactions

This example demonstrates the level of depth and structure required for all analyzed functions.

---

### 5.4 Output Requirements

When performing ultra-granular analysis, use [OUTPUT_REQUIREMENTS.md](resources/OUTPUT_REQUIREMENTS.md) as the private scratch/reasoning structure. Do not dump that scratch structure directly into the final module doc unless a detail passes the signal filter.

The final persisted doc MUST be distilled high-signal module context. Keep:
- read-boundary guidance when it changes agent behavior: when to read this module doc, when not to read it, and what adjacent docs are conditional rather than mandatory
- ownership/authority boundaries near the start of the doc
- implicit contracts and ordering constraints
- cross-module coupling and cascade risks
- trust boundaries and validation authority
- historical footguns, fragility points, and test/debug gotchas
- source-truth pointers for exact constants, schemas, enum values, timeouts, limits, generated artifacts, or protocol workflow details mentioned in prose
- rationale not obvious from reading source

Use explicit headings such as `## When To Read This` or `## Source Pointers` for ambiguous or high-blast-radius modules when they help scanning. Equivalent concise prose is acceptable for tiny/obvious modules. Do not add empty template sections just to satisfy a shape.

Avoid exact reference material. Do not copy numeric constants, enum values, schema fields, service lists, file modes, timeout/count tables, generated artifact lists, command inventories, or protocol message maps unless the exact literal is necessary to explain a non-obvious invariant. Prefer category-level prose plus a source pointer. If keeping a literal, mark it as a snapshot and name the authoritative source file.

Submodule/gitlink boundary rule: when the target is a git submodule/gitlink or otherwise only represented by a boundary pointer, write boundary-only context unless the task explicitly provides indexed submodule files. do not infer internal architecture, package structure, APIs, IPC, framework choices, permissions, or workflows from a submodule name. State that the parent repo owns only the visible integration boundary and that future agents must inspect the submodule checkout/source before relying on internals.

Drop:
- file inventories
- function-by-function summaries
- obvious call listings
- line-by-line narration
- copied constants, enum tables, schemas, message ids, field lists, timeout/count tables, service lists, or long workflow traces that should point to source truth
- facts discoverable with one Read, Grep, or Glob

Quality thresholds apply to the reasoning pass, not to persisted prose:
- Minimum 3 invariants per non-trivial function considered during analysis
- Minimum 5 assumptions documented in scratch while deriving module-level contracts
- Minimum 3 risk considerations for external interactions
- At least 1 First Principles application
- At least 3 combined 5 Whys/5 Hows applications

---

### 5.5 Completeness Checklist

Before concluding micro-analysis of a function, verify against the [COMPLETENESS_CHECKLIST.md](resources/COMPLETENESS_CHECKLIST.md):

- **Structural Completeness**: All required sections present (Purpose, Inputs, Outputs, Block-by-Block, Dependencies)
- **Content Depth**: Minimum thresholds met (invariants, assumptions, risk analysis, First Principles)
- **Continuity & Integration**: Cross-references, propagated assumptions, invariant couplings
- **Anti-Hallucination**: Line number citations, no vague statements, evidence-based claims

Analysis is complete when all checklist items are satisfied and no unresolved "unclear" items remain.

---

## 6. Phase 3 — Global System Understanding

After sufficient micro-analysis:

1. **State & Invariant Reconstruction**
   - Map reads/writes of each state variable.
   - Derive multi-function and multi-module invariants.

2. **Workflow Reconstruction**
   - Identify end-to-end flows.
   - Track how state transforms across these flows.
   - Record assumptions that persist across steps.

3. **Trust Boundary Mapping**
   - Actor → entrypoint → behavior.
   - Identify untrusted input paths.
   - Privilege changes and implicit role expectations.

4. **Complexity & Fragility Clustering**
   - Functions with many assumptions.
   - High branching logic.
   - Multi-step dependencies.
   - Coupled state changes across modules.

These clusters help guide the vulnerability-hunting phase.

---

## 7. Stability & Consistency Rules
*(Anti-Hallucination, Anti-Contradiction)*

The agent must:

- **Never reshape evidence to fit earlier assumptions.**
  When contradicted:
  - Update the model.
  - State the correction explicitly.

- **Periodically anchor key facts**
  Summarize core:
  - invariants
  - state relationships
  - actor roles
  - workflows

- **Avoid vague guesses**
  Use:
  - "Unclear; need to inspect X."
  instead of:
  - "It probably…"

- **Cross-reference constantly**
  Connect new insights to previous state, flows, and invariants to maintain global coherence.

---

## 8. Target Granularity & Subagent Usage

This skill governs analysis of a **single target**. The target may be a whole repository, one module, or one submodule. The invoking orchestrator decides granularity; this skill does not pick its own scope.

When invoked from the v2 build orchestrator (`edc-build-impl`), this skill is spawned **per-module**: the agent's target is one module, sibling modules are accessed only through their signature index (no sibling source bodies), and the orchestrator never reads source code itself.

**Large target rule.** If the target is broad or exceeds the agent's working budget (heuristic: > ~30k LOC, > ~80 source files, or any single file > ~3k LOC), preserve the whole-target mental model first. Produce a concise parent context that explains the shared authority, invariants, coupling, and failure modes across the target. For broad test/tooling/support targets, add internal sub-routing or harness/workflow guidance so future agents can choose the right source/test area without losing the general context.

Do not split solely because LOC or file count is high. Large coherent modules often need one general context doc so agents can reason across files. Split or promote only when subareas have independent durable ownership contracts, separate authority boundaries, or unrelated verification workflows that would make one parent doc misleading. If splitting would produce filesystem shards or inventory docs, keep the parent doc and add internal routing guidance instead.

Subagents (nested or top-level) must:
- Run with a clean context (no parent conversation inheritance).
- Follow the same micro-first rules defined in this skill.
- Write distilled high-signal context directly to disk at the path the orchestrator specifies.
- Return a bounded summary (≤500 tokens) for the parent to integrate.

Within a single-target run, the agent may also spawn nested subagents for:
- Dense or complex individual functions.
- Long data-flow or control-flow chains spanning many files within the target.
- Cryptographic / mathematical logic.
- Complex state machines.

---

## 9. Relationship to Other Phases

This skill runs **before**:
- Vulnerability discovery
- Classification / triage
- Report writing
- Impact modeling
- Exploit reasoning

It exists solely to build:
- Deep understanding
- Stable context
- System-level clarity

---

## 10. Non-Goals

While active, the agent should NOT:
- Identify vulnerabilities
- Propose fixes
- Generate proofs-of-concept
- Model exploits
- Assign severity or impact

This is **pure context building** only.
