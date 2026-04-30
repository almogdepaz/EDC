# EDC — Every Day Carry Skills

This project uses EDC for deep codebase context and code review.

## Available Skills

- **edc-context** — Ultra-granular line-by-line code analysis. Builds architectural context with invariants, trust boundaries, data flows, and fragility clusters. See `.gemini/skills/edc-context/SKILL.md`.
- **edc-review** — Structured code review with blast radius analysis, adversarial modeling, and comprehensive reporting. See `.gemini/skills/edc-review/SKILL.md`.

## Workflow

### Build context (first time)
Activate the `edc-context` skill. Analyze the full codebase and write `.context/index.md` (overview) + `.context/modules/<name>.md` (per-module) + `.context/reports/issues.md` + `.context/reports/complexity.md` + `.context/manifest.json`.

### Update context (on changes)
If `.context/manifest.json` exists, only re-analyze modules with changed files (based on `git diff`) and refresh the manifest through `plugins/edc/scripts/edc-manifest.sh`.

### Review a PR

**Step 1 — Run the orchestrator:**
```bash
bash .edc/scripts/edc-review.sh <target> [--base <ref>]
```

Read the first line of output:
- `CONTEXT_MISSING` → activate edc-context (full build) first, then re-run
- `CONTEXT_STALE` → activate edc-context (incremental update) first, then re-run
- `Review tasks ready` → proceed

**Step 2 — Read the manifest:**
Read `review-tasks/manifest.json` for the list of modules and files.

**Step 3 — Process each module task sequentially:**
For each module in the manifest:
1. Read `review-tasks/{module}.md`
2. Follow its instructions exactly — do not paraphrase or skip steps
3. Do not move to the next module until `review-tasks/report-{module}.md` is written

**Step 4 — Consolidate:**
Write `review-{TARGET_SHORT}.md` with: header, full per-module reports (unedited), cross-module summary.

Gemini `--context-mode advisory|inject` install flows are not implemented yet and fail loudly by design.
