---
name: edc-build-impl
description: Builds or updates deep architectural context for any codebase (v2 layout)
---

# Build Context (v2)

**Arguments:** optional `--force` to rebuild from scratch even if context exists, `--focus <module>` for specific module analysis, and repeatable `--ignore <glob>` to exclude files from analysis for this run.

## Ignore Rules

Before building or updating context, resolve ignore patterns in this order:

1. If one or more `--ignore <glob>` arguments were provided, use only those patterns.
2. Otherwise, if `.edcignore` exists in the repo root, read non-empty, non-comment lines from it.
3. Otherwise, do not exclude any additional files.

Apply ignore rules to repo-relative file paths before selecting files or modules to analyze.

## Routing (orchestrator-owned)

Routing is decided by `plugins/edc/scripts/edc-build.sh` BEFORE this skill is invoked. By the time this skill runs, the orchestrator has already:

- run `edc-clean-slate.sh --check` to inspect on-disk state
- decided whether to spawn a full build or an incremental update
- wiped any partial-v2 state if needed (via `edc-clean-slate.sh --force`)
- chosen this skill because the route is "full build"

**This skill always runs a full build.** Do not call `edc-clean-slate.sh`. Do not decide build-vs-update. Do not check for v1 markers — v1 is unsupported and the orchestrator already failed loudly if v1 markers were present.

### Forbidden patterns (do not do these)

- DO NOT invoke `Skill(edc:edc-context)` at the orchestrator level. The `edc-context` skill is invoked ONLY inside per-module subagents spawned in step 2.
- DO NOT invoke `Skill(edc:edc-audit)` (the slash-command-style skill). The build calls `edc-audit-impl` directly in step 5.
- DO NOT write to v1 paths (`edc-context/.meta.json`, `edc-context/context.md`, or top-level per-module markdown). v2 paths are listed in [Full Build](#full-build).

**CRITICAL — Clean Slate Rule:** All analysis (`edc-context`, `edc-review-impl`, `edc-audit-impl`) MUST run in subagents that do NOT inherit the parent conversation. Findings must be based purely on code analysis, not influenced by what the user said or what files were previously discussed. The subagent sees only: the code, the skill instructions, and the task prompt. Nothing else.

## Full Build

A v2 full build emits the complete canonical layout in one pass. There is no separate split step.

The required outputs are:

```
AGENTS.md
edc-context/
  index.md
  manifest.json
  modules/<name>.md          (one per module)
  reports/
    issues.md
    complexity.md
  build/
    build.json
```

Build steps:

1. **Module discovery (orientation pass).** Identify module boundaries before any deep analysis. Walk `git ls-files` (with ignore rules applied) and group by language convention: python packages (top-level `__init__.py`), rust crates (`Cargo.toml`), typescript workspace packages (`package.json` with `name`), or top-level directories as fallback. Emit a module list with file count, approximate LOC, and kebab-case name per entry. Module names are stable across runs. The orchestrator MUST NOT read source-code bodies during this pass — only paths and lightweight metadata.

2. **Per-module deep analysis (mandatory fanout).** Pipe the discovered module list into `plugins/edc/scripts/edc-build-plan.sh`. For each `module-context` task in the output, spawn ONE subagent using the embedded `prompt` verbatim. Run subagents in parallel batches. Collect the ≤500-token summaries returned. Do not interpret, edit, or skip tasks — execute the plan as written.

3. **Cross-module flow synthesis.** Spawn a final subagent that consumes the module summaries from step 2 plus the signature index, traces top entrypoints across module boundaries, and writes cross-module flow notes that will be incorporated into `edc-context/index.md` in the next step. This subagent does NOT read full source bodies; it relies on the module docs and signature index.

4. **Repo overview.** Author `edc-context/index.md` as a short startup orientation document by stitching together the module summaries from step 2 and the cross-module flow notes from step 3. It must contain at least one `##` heading. Recommended sections: repo purpose, actor map, key flows, global invariants, trust boundaries, blast-radius summary, and a module table linking each module to `edc-context/modules/<name>.md`. Optimize for low token cost — this is the file loaded at session start. The orchestrator MUST NOT re-read source bodies to produce this file.

5. **Reports.** Invoke the `edc-audit-impl` skill to emit cross-cutting analytical output:
   - `edc-context/reports/issues.md` — known problems and risks
   - `edc-context/reports/complexity.md` — overengineering / bloat / duplication signals

   Reports live under `edc-context/reports/`, never at the top level of `edc-context/`.

6. **Build provenance.** Write `edc-context/build/build.json` with the build metadata (build timestamp, EDC version, list of modules emitted, ignore-rule provenance, source-commit placeholder). Adapters MUST NOT auto-load anything under `edc-context/build/`.

7. **Manifest.** Author a partial `manifest.json` (LLM-owned fields only) and pipe it through `plugins/edc/scripts/edc-manifest.sh` to produce the final `edc-context/manifest.json`. See [Manifest Authoring](#manifest-authoring).

8. **Universal entrypoint.** Write `AGENTS.md` at the repo root (see [AGENTS.md](#agentsmd)).

9. **Final validation.** Run the validator (see [Output Validation](#output-validation)). Any failure is a build failure — surface it; do not silently continue.

   The orchestrator runs `edc-doctor.sh` after this skill returns, as an additional deterministic end-to-end check. Skill-internal validation must still pass; doctor is a backstop, not a substitute.

The build is successful only when every required output above exists and the layout validates. `edc doctor` is the canonical end-to-end validator.

## Manifest Authoring

The schema and field-ownership rules are documented in `manifest-schema.md`. Summary of what the LLM authors during build:

- `schemaVersion` — `2`
- `edcVersion` — current EDC release semver string
- `repoContextFile` — `edc-context/index.md`
- `reports` — `{ "issues": "edc-context/reports/issues.md", "complexity": "edc-context/reports/complexity.md" }`
- `build` — `{ "buildInfoFile": "edc-context/build/build.json" }`
- `policy` — see below
- `modules[]` — one entry per module with `name`, `doc`, `summary`, `priority`, and `match` (any of `exactFiles`, `prefixes`, `globs`)
- `unmapped.allowedGlobs` — repo paths intentionally outside any module (e.g. top-level docs, build artifact dirs)

Do **not** populate `generatedAt`, `sourceCommit`, or `coverage.*`. The deterministic post-step (`edc-manifest.sh`) fills those.

### `policy` (LLM authors exactly two fields)

```json
"policy": {
  "defaultMode": "advisory",
  "unmatchedPathPolicy": "warn-allow"
}
```

- `defaultMode`: **if `edc-context/manifest.json` already exists, preserve its `policy.defaultMode` value** — it may have been set by `edc mode advisory|inject` and rebuilds must not silently revert that choice. If no prior manifest exists, default to `"advisory"`. `"inject"` is the only other allowed value.
- `unmatchedPathPolicy`: must be `"warn-allow"`.

Do not write any other `policy.*` fields during build (no `guardedTools`, `discoveryGatedOnIndex`, `bootstrapAlwaysReadable`, etc.). Those are runtime install concerns.

### Pipe through the post-step

After authoring the partial manifest, the build pipes it through the deterministic generator:

```sh
cat /tmp/partial-manifest.json | bash plugins/edc/scripts/edc-manifest.sh > edc-context/manifest.json
```

`edc-manifest.sh` validates the LLM-authored portion, fills `generatedAt` (UTC ISO-8601), `sourceCommit` (`git rev-parse HEAD`), and `coverage.mappedFileCount` / `coverage.unmappedFileCount` / `coverage.ambiguousPathCount` (computed by walking `git ls-files` and routing each path via `edc-route.sh`). It rejects with non-zero exit when required fields are missing, when `defaultMode` is outside `{"advisory","inject"}`, when `unmatchedPathPolicy` is missing, when any module lacks a `priority`, or when the LLM tried to populate the post-step fields itself.

A non-zero exit from `edc-manifest.sh` is a build failure. Do not write a hand-edited `edc-context/manifest.json` — it must come from the generator.

## AGENTS.md

`AGENTS.md` is the universal repo-root entrypoint for any agent that honors instruction files. It is regenerated by every full build. Required content:

- a short startup orientation header
- a pointer to `edc-context/index.md` as the architecture overview
- a pointer to `edc-context/manifest.json` as the authoritative routing/policy contract
- a one-line statement of the current runtime mode (advisory or inject), read from `edc-context/manifest.json`'s `policy.defaultMode`

Keep `AGENTS.md` short. It is not a substitute for `edc-context/index.md` — it just tells agents where to look.

## Output Validation

Before declaring the build done, run these exact checks. If `plugins/edc/scripts/edc-doctor.sh` is present, prefer it (`bash plugins/edc/scripts/edc-doctor.sh`); it covers the layout requirements below plus orphan-path routing.

Manual checklist (must all pass):

- `AGENTS.md` exists at repo root
- `edc-context/index.md` exists and contains at least one `##` heading
- `edc-context/manifest.json` exists, parses as JSON, and `schemaVersion == 2`
- every entry in `manifest.modules[].doc` resolves to a file that exists
- `edc-context/reports/issues.md` and `edc-context/reports/complexity.md` exist
- `edc-context/build/build.json` exists

If any check fails, the build has failed. Surface the specific failure (which file/check); do not declare success. The orchestrator will run `edc-doctor.sh` after this skill returns; a half-built layout will fail doctor and the orchestrator will surface the failure to the caller. A "successful" build that doesn't produce `manifest.json` is a CRITICAL bug and must be reported.
