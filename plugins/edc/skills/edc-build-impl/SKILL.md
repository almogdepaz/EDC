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

## Routing

Check if `.context/manifest.json` exists AND `--force` was NOT passed:

- **If `.context/manifest.json` exists** → invoke the `edc-update-impl` skill (incremental update based on branch changes).
- **If `.context/manifest.json` does NOT exist** (or `--force`) → run a full v2 build (see [Full Build](#full-build)).

The v2 layout has no v1 routing-metadata file. `manifest.json` is the only routing and policy contract; any legacy v1 routing-metadata file must be removed during cleanup (see step 7 of [Full Build](#full-build)).

**CRITICAL — Clean Slate Rule:** All analysis (`edc-context`, `edc-review-impl`, `edc-audit-impl`) MUST run in subagents that do NOT inherit the parent conversation. Findings must be based purely on code analysis, not influenced by what the user said or what files were previously discussed. The subagent sees only: the code, the skill instructions, and the task prompt. Nothing else.

## Full Build

A v2 full build emits the complete canonical layout in one pass. There is no separate split step.

The required outputs are:

```
AGENTS.md
.context/
  index.md
  manifest.json
  modules/<name>.md          (one per module)
  reports/
    issues.md
    complexity.md
  build/
    full-context.md
    build.json
```

Build steps:

1. **Deep analysis.** Invoke the `edc-context` skill (NOT `audit-context-building` — that is a different plugin) to perform the full deep-context workflow. The deep run authors per-module deep docs directly to `.context/modules/<name>.md` and a consolidated provenance dump to `.context/build/full-context.md`. Module names are kebab-case and stable across runs.

2. **Repo overview.** Author `.context/index.md` as a short startup orientation document. It must contain at least one `##` heading. Recommended sections: repo purpose, actor map, key flows, global invariants, trust boundaries, blast-radius summary, and a module table linking each module to `.context/modules/<name>.md`. Optimize for low token cost — this is the file loaded at session start.

3. **Reports.** Invoke the `edc-audit-impl` skill to emit cross-cutting analytical output:
   - `.context/reports/issues.md` — known problems and risks
   - `.context/reports/complexity.md` — overengineering / bloat / duplication signals

   Reports live under `.context/reports/`, never at the top level of `.context/`.

4. **Build provenance.** Write `.context/build/build.json` with the build metadata (build timestamp, EDC version, list of modules emitted, ignore-rule provenance, source-commit placeholder). `.context/build/full-context.md` is the consolidated deep-context dump from step 1. Adapters MUST NOT auto-load anything under `.context/build/`.

5. **Manifest.** Author a partial `manifest.json` (LLM-owned fields only) and pipe it through `plugins/edc/scripts/edc-manifest.sh` to produce the final `.context/manifest.json`. See [Manifest Authoring](#manifest-authoring).

6. **Universal entrypoint.** Write `AGENTS.md` at the repo root (see [AGENTS.md](#agentsmd)).

7. **Cleanup.** Delete any v1 leftovers in `.context/` that the v2 layout no longer uses: the v1 routing-metadata file, the top-level `context` overview file, and any top-level `issues`/`complexity`/`full-context`/per-module markdown files that v1 placed directly under `.context/` instead of under `modules/`, `reports/`, or `build/`. The build is not done while v1 artifacts coexist with v2 outputs.

The build is successful only when every required output above exists and the layout validates. `edc doctor` is the canonical end-to-end validator.

## Manifest Authoring

The schema and field-ownership rules are documented in `manifest-schema.md`. Summary of what the LLM authors during build:

- `schemaVersion` — `2`
- `edcVersion` — current EDC release semver string
- `repoContextFile` — `.context/index.md`
- `reports` — `{ "issues": ".context/reports/issues.md", "complexity": ".context/reports/complexity.md" }`
- `build` — `{ "fullContextFile": ".context/build/full-context.md", "buildInfoFile": ".context/build/build.json" }`
- `policy` — see below
- `modules[]` — one entry per module with `name`, `doc`, `summary`, `priority`, and `match` (any of `exactFiles`, `prefixes`, `globs`)
- `unmapped.allowedGlobs` — repo paths intentionally outside any module (e.g. top-level docs, build artifact dirs)

Do **not** populate `generatedAt`, `sourceCommit`, or `coverage.*`. The deterministic post-step (`edc-manifest.sh`) fills those.

### `policy` (LLM authors exactly two fields)

```json
"policy": {
  "defaultMode": "inject",
  "unmatchedPathPolicy": "warn-allow"
}
```

- `defaultMode`: default to `"inject"`. `"advisory"` is the only other allowed value during build authoring. Do not emit `"strict"` here — strict is a runtime install choice, not a build default.
- `unmatchedPathPolicy`: must be `"warn-allow"`.

Do not write any other `policy.*` fields during build (no `guardedTools`, `discoveryGatedOnIndex`, `bootstrapAlwaysReadable`, etc.). Those are runtime install concerns.

### Pipe through the post-step

After authoring the partial manifest, the build pipes it through the deterministic generator:

```sh
cat /tmp/partial-manifest.json | bash plugins/edc/scripts/edc-manifest.sh > .context/manifest.json
```

`edc-manifest.sh` validates the LLM-authored portion, fills `generatedAt` (UTC ISO-8601), `sourceCommit` (`git rev-parse HEAD`), and `coverage.mappedFileCount` / `coverage.unmappedFileCount` / `coverage.ambiguousPathCount` (computed by walking `git ls-files` and routing each path via `edc-route.sh`). It rejects with non-zero exit when required fields are missing, when `defaultMode` is outside `{"advisory","inject"}`, when `unmatchedPathPolicy` is missing, when any module lacks a `priority`, or when the LLM tried to populate the post-step fields itself.

A non-zero exit from `edc-manifest.sh` is a build failure. Do not write a hand-edited `.context/manifest.json` — it must come from the generator.

## AGENTS.md

`AGENTS.md` is the universal repo-root entrypoint for any agent that honors instruction files. It is regenerated by every full build. Required content:

- a short startup orientation header
- a pointer to `.context/index.md` as the architecture overview
- a pointer to `.context/manifest.json` as the authoritative routing/policy contract
- a one-line statement of the installed runtime mode (advisory / inject / strict), or "not installed" if no runtime adapter is present yet

Keep `AGENTS.md` short. It is not a substitute for `.context/index.md` — it just tells agents where to look.

## Output Validation

Before declaring the build done, verify:

- `AGENTS.md` exists at repo root
- `.context/index.md` exists and contains at least one `##` heading
- `.context/manifest.json` exists, parses as JSON, and `schemaVersion == 2`
- every entry in `manifest.modules[].doc` resolves to a file that exists
- `.context/reports/issues.md` and `.context/reports/complexity.md` exist
- `.context/build/full-context.md` and `.context/build/build.json` exist
- no legacy v1 routing-metadata file or top-level v1 markdown files remain under `.context/`

If any check fails, the build has failed. Surface the failure; do not silently continue.
