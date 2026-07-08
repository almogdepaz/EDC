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

- DO NOT invoke `Skill(edc-module-context-impl)` at the orchestrator level. The `edc-module-context-impl` skill is invoked ONLY inside per-module subagents spawned in step 2.
- DO NOT invoke any audit command wrapper. The build calls the `edc-audit` skill directly in step 5.
- DO NOT write to v1 paths (`edc-context/.meta.json`, `edc-context/context.md`, or top-level per-module markdown). v2 paths are listed in [Full Build](#full-build).

**CRITICAL — Clean Slate Rule:** All analysis (`edc-module-context-impl`, `edc-review`, `edc-audit`) MUST run in subagents that do NOT inherit the parent conversation. Findings must be based purely on code analysis, not influenced by what the user said or what files were previously discussed. The subagent sees only: the code, the skill instructions, and the task prompt. Nothing else.

## Full Build

A v2 full build emits the complete canonical layout in one pass. There is no separate split step.

The required outputs are:

```
<agent-entrypoint>              (AGENTS.md by default, or EDC_AGENTS.md when the prompt preamble says so)
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

1. **Module discovery (orientation pass).** Identify module boundaries before any deep analysis. Walk `git ls-files -s` (with ignore rules applied) and group by language convention: python packages (top-level `__init__.py`), rust crates (`Cargo.toml`), typescript workspace packages (`package.json` with `name`), or top-level directories as fallback. Detect mode 160000 entries as submodule/gitlink boundaries. Do not treat a submodule/gitlink as normal indexed source unless recursive submodule indexing was explicitly requested; emit boundary-only context for it when the parent repo has visible integration/build/runtime coupling, otherwise prefer `contextless.entries` with a promotion-oriented policy. Emit a module list with file count, approximate LOC, and kebab-case name per entry. Module names are stable across runs. The orchestrator MUST NOT read source-code bodies during this pass — only paths and lightweight metadata.

2. **Per-module deep analysis (mandatory fanout).** Pipe the discovered module list into `plugins/edc/scripts/edc-build-plan.sh`. For each `module-context` task in the output, spawn ONE subagent using the embedded `prompt` verbatim. Run subagents in parallel batches. Collect the ≤500-token summaries returned. Do not interpret, edit, or skip tasks — execute the plan as written.

3. **Cross-module flow synthesis.** Spawn a final subagent that consumes the module summaries from step 2 plus the signature index, traces top entrypoints across module boundaries, and writes cross-module flow notes that will be incorporated into `edc-context/index.md` in the next step. This subagent does NOT read full source bodies; it relies on the module docs and signature index.

4. **Single operational context index.** Author `edc-context/index.md` as the repo's single operational context index by stitching together the module summaries from step 2 and the cross-module flow notes from step 3. It must contain at least one `##` heading and MUST be routing-first, not architecture-overview-first. Optimize for low token cost — this is the file loaded at session start. The orchestrator MUST NOT re-read source bodies to produce this file.

   Signal filter: only persist content that saves an agent time or prevents wrong assumptions. If an agent can discover it with one Read, Grep, or Glob, leave it out.

   Required top-level section order:

   ```md
   # <repo> context index

   ## How to use
   - read this file first
   - choose module docs by changed path/task
   - for cross-boundary changes, read related modules listed in the routing table
   - contextless.entries are machine coverage only and must not appear in the human index read path
   - reports are not part of the ordinary index read path; review/audit workflows find them through manifest/report paths

   ## Route by path/task
   | touching / task | read first | also inspect | why |

   ## Critical global invariants
   short list only; include non-obvious contracts agents would otherwise rediscover.

   ## Cross-module coupling / blast radius
   bounded cascade paths and review-relevant module relationships only.
   ```

   Optional compact sections, only when they materially improve first-read decisions:

   ```md
   ## Architecture overview
   at most a tiny orientation: repo purpose, actors, and global trust-boundary shape. Do not write an architecture essay or detailed flow narration.

   ## Module table
   compact module discoverability only when route rows do not already make every active module findable. Use module link plus short purpose phrase.
   ```

   If optional sections are included, they must appear after `## Route by path/task`. Do not include generated file counts, LOC estimates, or manifest priority values in `edc-context/index.md`; those are machine/build metadata, not first-read guidance.

   Derive `Route by path/task` rows from module summaries, manifest module data, and cross-module flow notes. Do not duplicate the deterministic routing algorithm; `manifest.json` remains authoritative for machine routing.

5. **Reports.** Invoke the `edc-audit` skill to emit cross-cutting analytical output:
   - `edc-context/reports/issues.md` — known problems and risks
   - `edc-context/reports/complexity.md` — code quality / maintainability signals

   Reports live under `edc-context/reports/`, never at the top level of `edc-context/`.

6. **Build provenance.** Write `edc-context/build/build.json` with the build metadata (build timestamp, EDC version, list of modules emitted, ignore-rule provenance, source-commit placeholder). Adapters MUST NOT auto-load anything under `edc-context/build/`.

7. **Manifest.** Author a partial `manifest.json` (LLM-owned fields only) and pipe it through `plugins/edc/scripts/edc-manifest.sh` to produce the final `edc-context/manifest.json`. See [Manifest Authoring](#manifest-authoring).

8. **Universal entrypoint.** Write the EDC agent entrypoint at the exact path named by `EDC_AGENTS_TARGET` in the prompt preamble (normally `AGENTS.md`; use `EDC_AGENTS.md` when instructed). See [Agent entrypoint](#agent-entrypoint).

9. **Final validation.** Run the validator (see [Output Validation](#output-validation)). Any failure is a build failure — surface it; do not silently continue.

   The shell orchestrator runs `edc-context-curator-impl` as a separate runtime report-only step after this skill returns and doctor validates the generated context. Do not invoke the curator from inside this build skill.

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
- `modules[]` — one entry per real human context module with `name`, `doc`, `summary`, `priority`, and `match` (any of `exactFiles`, `prefixes`, `globs`)
- `contextless.entries[]` — structured machine coverage for paths intentionally absent from human docs; each entry needs `id`, `globs`, `reason`, and `reviewPolicy` (`account-only`, `promotion-check`, or `no-context-review`)
- `unmapped.allowedGlobs` — legacy migration compatibility only; prefer `contextless.entries` for new coverage

Do not create fake modules such as `misc`, `other`, or directory buckets whose only durable instruction is "inspect the files." Cover those paths with `contextless.entries` unless they have a real operational contract worth a human doc.

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
# if this build was invoked with --ignore flags, pass the same flags to edc-manifest.sh
```

`edc-manifest.sh` validates the LLM-authored portion, fills `generatedAt` (UTC ISO-8601), `sourceCommit` (`git rev-parse HEAD`), and coverage counters by walking `git ls-files` through the Node batch classifier: `contextMappedFileCount`, `contextlessFileCount`, `uncoveredFileCount`, `ambiguousPathCount`, `ignoredFileCount`, `ignoreSource`, and `ignoreGlobs`. It also writes deprecated one-release aliases `mappedFileCount` and `unmappedFileCount`. It rejects with non-zero exit when required fields are missing, when `defaultMode` is outside `{"advisory","inject"}`, when `unmatchedPathPolicy` is missing, when any module lacks a `priority`, when `contextless.entries` has an invalid `reviewPolicy`, or when the LLM tried to populate the post-step fields itself.

A non-zero exit from `edc-manifest.sh` is a build failure. Do not write a hand-edited `edc-context/manifest.json` — it must come from the generator.

## Agent entrypoint

The EDC agent entrypoint is the short repo-root orientation for agent harnesses. By default it is `AGENTS.md`. If the prompt preamble says `EDC_AGENTS_TARGET: EDC_AGENTS.md`, write the same EDC-generated orientation to `EDC_AGENTS.md` instead and do not overwrite or edit the repo's existing `AGENTS.md` or `CLAUDE.md`; the shell orchestrator tells the user how to replace, append, or reference it after the build. Required content:

- a short startup orientation header
- a pointer to `edc-context/index.md` as the routing index with critical invariants and coupling/blast-radius guidance
- a pointer to `edc-context/manifest.json` as the authoritative routing/policy contract
- a one-line statement of the current runtime mode (advisory or inject), read from `edc-context/manifest.json`'s `policy.defaultMode`

Keep the entrypoint short. It is not a substitute for `edc-context/index.md` — it just tells agents where to look.

## Output Validation

Before declaring the build done, run these exact checks. If `plugins/edc/scripts/edc-doctor.sh` is present, prefer it (`bash plugins/edc/scripts/edc-doctor.sh`); it covers the layout requirements below plus orphan-path routing.

Manual checklist (must all pass):

- the configured EDC agent entrypoint exists at repo root (`AGENTS.md` or `EDC_AGENTS.md`, matching `EDC_AGENTS_TARGET`)
- `edc-context/index.md` exists and contains at least one `##` heading
- `edc-context/manifest.json` exists, parses as JSON, and `schemaVersion == 2`
- every entry in `manifest.modules[].doc` resolves to a file that exists
- `edc-context/reports/issues.md` and `edc-context/reports/complexity.md` exist
- `edc-context/build/build.json` exists

If any check fails, the build has failed. Surface the specific failure (which file/check); do not declare success. The orchestrator will run `edc-doctor.sh` after this skill returns; a half-built layout will fail doctor and the orchestrator will surface the failure to the caller. A "successful" build that doesn't produce `manifest.json` is a CRITICAL bug and must be reported.
