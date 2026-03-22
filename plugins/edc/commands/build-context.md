---
description: Build deep codebase context and write to context.md
argument-hint: "[--focus <module>]"
allowed-tools: [Read, Grep, Glob, Bash, Agent, Write]
---

# Build Context

**Arguments:** $ARGUMENTS

Build deep architectural context for the current codebase and write it to `context.md` in the repository root. If `context.md` already exists, regenerate it from scratch.

Parse arguments:
1. **Focus** (optional): `--focus <module>` for specific module/directory analysis

## Process

Follow these steps precisely:

### Step 1 — Initial Orientation (Bottom-Up Scan)

Before deep analysis, perform a minimal mapping:

1. Identify major modules/files/directories.
2. Note obvious public/external entrypoints.
3. Identify likely actors (users, services, CLI consumers, API callers).
4. Identify important state, storage, config, or data structures.
5. Build a preliminary structure without assuming behavior.

### Step 2 — Ultra-Granular Function Analysis

Read source files and analyze every non-trivial function. Use `Read` for full file reads (not Grep — you need to understand control flow and invariants, not search for keywords).

For each function, document:

1. **Purpose** — Why the function exists and its role in the system (2-3 sentences minimum).

2. **Inputs & Assumptions** — All parameters (explicit and implicit), preconditions, constraints, trust assumptions. Each input must identify: type, source, trust level. Minimum 3 assumptions documented.

3. **Outputs & Effects** — Return values, state writes, events/messages, external interactions. Minimum 3 effects documented.

4. **Block-by-Block / Line-by-Line Analysis** — For each logical block:
   - What it does
   - Why it appears here (ordering logic)
   - What assumptions it relies on
   - What invariants it establishes or maintains
   - What later logic depends on it

   Apply per-block:
   - **First Principles** (at least 1 per function)
   - **5 Whys** (at least 3 combined with 5 Hows per function)
   - **5 Hows**

5. **Cross-Function Dependencies** — Internal calls made, external calls made (with risk analysis), functions that call this function, shared state, invariant couplings. Minimum 3 dependency relationships documented.

### 2.1 Output Format

Structure per-function output following the format in [OUTPUT_REQUIREMENTS.md](resources/OUTPUT_REQUIREMENTS.md).

### 2.2 Complete Analysis Example

See [FUNCTION_MICRO_ANALYSIS_EXAMPLE.md](resources/FUNCTION_MICRO_ANALYSIS_EXAMPLE.md) for a complete walkthrough demonstrating:
- Full micro-analysis of an HTTP route handler that spawns subprocesses
- Application of First Principles, 5 Whys, and 5 Hows
- Block-by-block analysis with invariants and assumptions
- Cross-function dependency mapping with invariant coupling chains
- Risk analysis for external interactions (filesystem, subprocess, race conditions)

This example demonstrates the level of depth and structure required for all analyzed functions.

### 2.3 Completeness Verification

Before concluding micro-analysis of each function, verify against the [COMPLETENESS_CHECKLIST.md](resources/COMPLETENESS_CHECKLIST.md):

- **Structural Completeness**: All required sections present (Purpose, Inputs, Outputs, Block-by-Block, Dependencies)
- **Content Depth**: Minimum thresholds met (invariants, assumptions, risk analysis, First Principles)
- **Continuity & Integration**: Cross-references, propagated assumptions, invariant couplings
- **Anti-Hallucination**: Line number citations, no vague statements, evidence-based claims

Analysis is complete when all checklist items are satisfied and no unresolved "unclear" items remain.

### Step 3 — Cross-Function & External Flow Analysis

When encountering calls, continue the same micro-first analysis across boundaries:

- **Internal Calls**: Jump into the callee. Perform block-by-block analysis. Track flow of data, assumptions, and invariants: caller → callee → return → caller.
- **External Calls**: If code exists in codebase, treat as internal. If truly external/black box, analyze as adversarial — describe parameters, identify assumptions, consider all outcomes (failure, unexpected returns, misbehavior).

Treat the entire call chain as one continuous execution flow. Never reset context. All invariants, assumptions, and data dependencies must propagate across calls.

### Step 4 — Global System Understanding

After sufficient micro-analysis:

1. **State & Invariant Reconstruction** — Map reads/writes of each state variable. Derive multi-function and multi-module invariants.
2. **Workflow Reconstruction** — Identify end-to-end flows. Track how state transforms across these flows. Record assumptions that persist across steps.
3. **Trust Boundary Mapping** — Actor → entrypoint → behavior. Identify untrusted input paths. Privilege changes and implicit role expectations.
4. **Complexity & Fragility Clustering** — Functions with many assumptions. High branching logic. Multi-step dependencies. Coupled state changes across modules.

### Step 5 — Write context.md (architecture intro)

Write `context.md` in the repository root. This file is a BRIEF architecture overview — NOT a deep analysis. It should be short enough to load into an agent's context without waste.

The file must begin with:
```
<!-- generated by /build-context -->
```

Structure the file as:

1. **System Overview** — What the system is, what it does, who it's for. 3-5 sentences max.
2. **Module Map** — Table of modules with one-line descriptions and links to their deep context files:
   ```
   | Module | Purpose | Deep Context |
   |--------|---------|--------------|
   | server | HTTP + WebSocket server, tmux bridge | [.context/server.md](.context/server.md) |
   | cli    | CLI entry point, setup, config       | [.context/cli.md](.context/cli.md) |
   ```
3. **Actor Model** — Who interacts with the system (users, services, external systems). Brief list.
4. **Key Flows** — End-to-end workflows through the system. Each flow listed as a one-liner with the modules it touches:
   ```
   - **Session start**: cli → server → tmux bridge → WebSocket → PWA
   - **Agent orchestration**: CLI → ralph → tmux → claude code
   ```
5. **Global Invariants** — System-wide invariants that span modules. Bulleted list, no elaboration.
6. **Trust Boundaries** — Brief summary of where untrusted input enters and key privilege boundaries.
7. **Cross-Module Coupling** — Which modules are tightly coupled and why. Flags areas where changes cascade.

**context.md MUST NOT contain function-level analysis.** That lives in `.context/*.md`. The goal is: an agent reads context.md to understand what the system is and which `.context/` file to load for the part it needs to work on.

### Step 6 — Write per-module deep context files

Create a `.context/` directory in the repository root. Split the deep analysis from Steps 2-4 into per-module files: `.context/{module-name}.md`

Module boundaries should follow logical groupings, not strict directory structure. Related root-level files can be grouped (e.g. `validation.ts` + `triage.ts` → `.context/shared-utils.md`).

Each per-module file must begin with:
```
<!-- generated by /build-context — do not edit below the line -->
# {Module Name} — Deep Context
```

#### What belongs in context files

Context files capture ONLY insights that are hard to discover without a full codebase deep dive. An agent can `grep`, `Read`, and `Glob` on its own — don't duplicate what it can find in the code.

**DO include:**
- **Invariants & implicit contracts** — "this function assumes the caller already validated auth", "routes.ts expects tmuxList() to never return wp_ prefixed sessions"
- **Cross-module coupling** — "changing the tmux session name format breaks the websocket handler because it parses session names to derive PTY keys"
- **Non-obvious data flows** — "user input enters at POST /api/create, gets shell-escaped in tmux.ts, but the session name flows through 4 modules before reaching exec"
- **Fragility & gotchas** — "the PTY overlap dedup logic is stateful and order-dependent — if you change the prefill chunking you'll break the dedup"
- **Why decisions were made** — "rate limiting is per-IP not per-session because tailscale gives each device a stable IP"
- **Assumptions that propagate across call chains** — "shellEscape() output is assumed safe by all downstream tmux exec calls — if you bypass it, you get command injection"
- **State lifecycle & ownership** — which module owns a piece of state, who can mutate it, what order dependencies exist

**DO NOT include:**
- Function signatures or type definitions (read the code)
- File lists or directory structure (glob it)
- What a function does at surface level (read it)
- Dependency lists (package.json)
- Anything an agent can discover with a single grep or file read

Each per-module file should contain:
1. **Module purpose** — 2-3 sentences, what it does and its role in the system.
2. **Invariants & implicit contracts** — Rules that must hold but aren't enforced by types or tests. Reference specific functions/lines.
3. **Cross-module coupling** — How this module is coupled to others, what breaks if you change it, what it assumes about other modules' behavior.
4. **Non-obvious data flows** — Data paths that cross multiple functions/modules in ways that aren't obvious from reading any single file.
5. **Fragility notes** — Complex areas, stateful logic, order-dependent operations, things that have broken before or are easy to break.
6. **Trust boundaries** — Where untrusted input enters this module, what validation is assumed to have happened upstream.

## Quality Thresholds

A complete analysis MUST identify per function:
- Minimum 3 invariants
- Minimum 5 assumptions
- Minimum 3 risk considerations (especially for external interactions)
- At least 1 application of First Principles
- At least 3 applications of 5 Whys or 5 Hows (combined)

## Rationalizations (Do Not Skip)

| Rationalization | Why It's Wrong | Required Action |
|-----------------|----------------|-----------------|
| "I get the gist" | Gist-level understanding misses edge cases | Line-by-line analysis required |
| "This function is simple" | Simple functions compose into complex bugs | Apply 5 Whys anyway |
| "I'll remember this invariant" | You won't. Context degrades. | Write it down explicitly |
| "External call is probably fine" | External = adversarial until proven otherwise | Jump into code or model as hostile |
| "I can skip this helper" | Helpers contain assumptions that propagate | Trace the full call chain |
| "This is taking too long" | Rushed context = hallucinated vulnerabilities later | Slow is fast |

## Stability & Consistency Rules

- Never reshape evidence to fit earlier assumptions. When contradicted: update the model, state the correction explicitly.
- Avoid vague guesses. Use "Unclear; need to inspect X." instead of "It probably..."
- Cross-reference constantly. Connect new insights to previous state, flows, and invariants.
- All claims reference specific line numbers (L45, L98-102, etc.)
- No vague statements — replaced with "unclear; need to check X"

## Subagent Usage

Use subagents for:
- Dense or complex functions/modules
- Long data-flow or control-flow chains
- Complex state machines
- Multi-module workflow reconstruction

Subagents must follow the same micro-first rules and return summaries that get integrated into the global model.

## Non-Goals

While building context, do NOT:
- Identify vulnerabilities
- Propose fixes
- Generate proofs-of-concept
- Model exploits
- Assign severity or impact

This is **pure context building** only.
