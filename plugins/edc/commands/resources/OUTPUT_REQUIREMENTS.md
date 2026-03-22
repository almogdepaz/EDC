# Output Requirements

When performing ultra-granular analysis, output MUST follow this structure for EACH analyzed function.

---

## Required Structure

**1. Purpose** (mandatory)
- Clear statement of function's role in the system
- Impact on system state, data flow, or security
- Minimum 2-3 sentences

**2. Inputs & Assumptions** (mandatory)
- All parameters (explicit and implicit: env vars, global state, config, closures)
- All preconditions
- All trust assumptions (who calls this? is input validated upstream?)
- Each input must identify: type, source, trust level
- Minimum 3 assumptions documented

**3. Outputs & Effects** (mandatory)
- Return values (or "void" if none)
- All state writes (in-memory, disk, database, external service)
- All external interactions (network calls, subprocess spawns, file I/O)
- All events/signals emitted (EventEmitter, WebSocket messages, IPC)
- All postconditions
- Minimum 3 effects documented

**4. Block-by-Block Analysis** (mandatory)
For EACH logical code block, document:
- **What:** What the block does (1 sentence)
- **Why here:** Why this ordering/placement (1 sentence)
- **Assumptions:** What must be true (1+ items)
- **Depends on:** What prior state/logic this relies on
- **First Principles / 5 Whys / 5 Hows:** Apply at least ONE per block

Minimum standards:
- Analyze at minimum: ALL conditional branches, ALL external calls, ALL state modifications
- For complex blocks (>5 lines): Apply First Principles AND 5 Whys or 5 Hows
- For simple blocks (<5 lines): Minimum What + Why here + 1 Assumption

**5. Cross-Function Dependencies** (mandatory)
- Internal calls made (list all)
- External calls made (list all with risk analysis)
- Functions that call this function
- Shared state with other functions
- Invariant couplings (how this function's invariants interact with others)
- Minimum 3 dependency relationships documented

---

## Quality Thresholds

A complete micro-analysis MUST identify:
- Minimum 3 invariants (per function)
- Minimum 5 assumptions (across all sections)
- Minimum 3 risk considerations (especially for external interactions)
- At least 1 application of First Principles
- At least 3 applications of 5 Whys or 5 Hows (combined)

---

## Format Consistency

- Use markdown headers: `**Section Name:**` for major sections
- Use bullet points (`-`) for lists
- Use code blocks with language tag for code snippets
- Reference line numbers: `L45`, `lines 98-102`
- Separate blocks with `---` horizontal rules for readability
