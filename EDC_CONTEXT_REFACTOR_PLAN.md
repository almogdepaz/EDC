# EDC Context Build Refactor — Explicit Per-Module Orchestration

## Goal

Move the per-module fanout orchestration out of skill prose and into a deterministic script. The skill stops describing HOW to fan out; it just runs the script and executes the resulting task plan mechanically. This closes the gap where the agent could shortcut into a whole-project context pass.

## Constraints (from user)

1. Module discovery stays agent-based (no discovery script).
2. Per-module context creation works the same as today, just made explicit.
3. Parent context (`.context/index.md`) stays as short summary + references to module docs.
4. Per-module subagents may read sibling code if it improves their module's context.
5. No new doctor/validation checks.

## Deliverables

### 1. `plugins/edc/scripts/edc-build-plan.sh` (new)

Deterministic task planner.

- **Input (stdin):** JSON from the agent's discovery step:
  ```json
  {
    "modules": [
      {"name": "foo", "paths": ["src/foo/**"], "approxLoc": 1234},
      {"name": "bar", "paths": ["src/bar/**"], "approxLoc": 567}
    ]
  }
  ```

- **Output (stdout):** ordered task list with embedded subagent prompts:
  ```json
  {
    "tasks": [
      {
        "kind": "module-context",
        "module": "foo",
        "paths": ["src/foo/**"],
        "out": ".context/modules/foo.md",
        "prompt": "<standard per-module subagent prompt with name/paths interpolated>"
      },
      { "kind": "module-context", "module": "bar", ... }
    ]
  }
  ```

- **Behavior:**
  - One `module-context` task per input module — no exceptions, no whole-repo entries possible.
  - Output paths are computed by the script (`.context/modules/<kebab-name>.md`), not chosen by the agent.
  - The standard subagent prompt is baked into each task's `prompt` field. Template:
    > Build deep architectural context for module `<name>`. Files in scope: `<paths>`. Invoke the `edc-context` skill on these files. You may read sibling-module source if it materially improves this module's context. Write the deep doc directly to `<out>`. Return a ≤500-token summary for the orchestrator.
  - Validate: input is well-formed JSON, every module has `name` + `paths`, names are unique. Non-zero exit on validation failure.

- **Optional flag:** `--changed <name>[,<name>...]` filters task output to only the named modules — used by the update flow.

### 2. Trim `plugins/edc/skills/edc-build-impl/SKILL.md`

**Step 2 (per-module deep analysis) collapses to:**

> Pipe the discovered module list into `plugins/edc/scripts/edc-build-plan.sh`. For each `module-context` task in the output, spawn ONE subagent using the embedded `prompt` verbatim. Run subagents in parallel batches. Collect the ≤500-token summaries returned. Do not interpret, edit, or skip tasks — execute the plan as written.

**Delete from the skill (now script-enforced):**
- Per-module path/output convention prose (the script computes `out`).
- The verbose "subagent prompt template" prose (the prompt is in the task output).
- The "MUST NOT read source bodies at orchestrator level" callouts for step 2 (impossible by construction — the orchestrator only sees the task list, not source).
- The "if a module exceeds per-target budget, recursively split" prose. Per constraint #4 the subagent can read siblings; the recursive-split rule was a workaround for context limits that's now unnecessary at this layer. If we want a budget rule later, it goes in the script.

**Keep in the skill:**
- Step 1 (module discovery) — agent-driven per constraint #1.
- Step 3 (cross-module flow synthesis subagent).
- Step 4 (parent context / `.context/index.md` format) — short wrapper, references modules.
- Steps 5–9 (reports, build provenance, manifest, AGENTS.md, validation).
- Routing logic and v1 cleanup.
- The "Forbidden patterns" block (still relevant — no `edc:edc-split`, no top-level `edc:edc-context`, etc.).

### 3. Mirror in `plugins/edc/skills/edc-update-impl/SKILL.md`

Update flow uses the same script with `--changed` filter:

> For modules with changes, pipe the module subset into `edc-build-plan.sh --changed <names>`. Execute the resulting task list the same way as the build flow.

Trim any prose in `edc-update-impl` that re-describes the per-module subagent pattern.

## Out of Scope

- No discovery script (constraint #1).
- No change to parent-context format (constraint #3).
- No subagent isolation tightening (constraint #4 — siblings allowed).
- No doctor checks (constraint #5).
- ≤500-token summary cap stays as-is (already in the existing contract).

## Risks

- The agent must faithfully execute the script's task list without re-interpreting it. The skill prose needs to make "execute as written" unambiguous.
- If module discovery (still agent-driven) emits a single mega-module covering most of the repo, the script will dutifully plan one giant task. The script can't fix bad discovery — that's still the agent's responsibility.
- `edc-update-impl` may have additional logic (diff-driven scope) that needs to feed clean module-subset JSON into the script. Need to verify the update flow can produce the right input shape.

## Implementation Order

1. Write `edc-build-plan.sh` with input validation + golden-output test.
2. Trim `edc-build-impl/SKILL.md` step 2; verify the rest still reads coherently.
3. Trim `edc-update-impl/SKILL.md`; wire it to the same script.
4. Smoke-test on this repo: run a build, confirm one subagent per module, confirm `.context/modules/*.md` files appear with the right names.
