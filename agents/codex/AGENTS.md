# EDC — Every Day Carry Skills

This project uses EDC for deep codebase context and code review.

## Available Skills

- **$edc-context** — Ultra-granular line-by-line code analysis. Builds architectural context with invariants, trust boundaries, data flows, and fragility clusters.
- **$edc-review** — Structured code review with blast radius analysis, adversarial modeling, and comprehensive reporting.

## Workflow

### Build context (first time)
Run `$edc-context` on the codebase. Write output to `.context/full-context.md`. Then split into `context.md` (overview) + `.context/{module}.md` (per-module) + `.context/issues.md` (problems) + `.context/.meta.json`.

### Update context (on changes)
If `.context/.meta.json` exists, only re-analyze modules with changed files (based on `git diff`). Update `.meta.json` to the new HEAD commit.

### Review a PR

**Step 1 — Run the orchestrator:**
```bash
bash .edc/scripts/edc-review.sh <target> [--baseline <ref>]
```

Read the first line of output:
- `CONTEXT_MISSING` → run edc-context (full build) first, then re-run
- `CONTEXT_STALE` → run edc-context (incremental update) first, then re-run
- `Review tasks ready` → proceed

**Step 2 — Read the manifest:**
Read `review/manifest.json` for the list of modules and files.

**Step 3 — Process each module task sequentially:**
For each module in the manifest:
1. Read `review/{module}.md`
2. Follow its instructions exactly — do not paraphrase or skip steps
3. Do not move to the next module until `review/report-{module}.md` is written

**Step 4 — Consolidate:**
Write `review-{TARGET_SHORT}.md` with: header, full per-module reports (unedited), cross-module summary.

## Codebase Context (EDC)

Deep architectural context is available in `.context/`. Read `.context/context.md` first for the module map, then `.context/{module}.md` for the module you're working in. Check `.context/issues.md` before making changes.
