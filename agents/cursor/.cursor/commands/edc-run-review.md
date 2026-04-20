---
description: Performs differential review of code changes using codebase context
---

# Review

**Arguments:** passed from command input (PR URL, commit SHA, or diff path; optional `--baseline <ref>`)

## Step 1 — Run the orchestrator

```bash
if [ -f ".edc/scripts/edc-review.sh" ]; then
  bash .edc/scripts/edc-review.sh <target> [--baseline <ref>]
elif [ -f "$HOME/.edc/scripts/edc-review.sh" ]; then
  bash "$HOME/.edc/scripts/edc-review.sh" <target> [--baseline <ref>]
else
  echo "SCRIPT_MISSING"
fi
```

Read the first line of output:

| Output starts with | Action |
|--------------------|--------|
| `CONTEXT_MISSING` | Run `edc-run-build` first. Stop. Tell the user to re-run after the build. |
| `CONTEXT_STALE` | Run `edc-run-build` first. Stop. Tell the user to re-run after the update. |
| `SCRIPT_MISSING` | Tell the user to run `install.sh --project <dir>` from the EDC repo. Stop. |
| `Review tasks ready` | Proceed to Step 2. |

Do not work around these conditions. The script is the authority.

## Step 2 — Read the manifest

Read `review/manifest.json` for the list of modules and changed files.

## Step 3 — Process each module task sequentially

For each module in the manifest:
1. Read `review/{module}.md`
2. Follow the instructions in that file exactly — do not paraphrase or skip steps
3. Do not begin the next module until `review/report-{module}.md` is written

## Step 4 — Consolidate

Write `review-{TARGET_SHORT}.md`:
1. Header: target, baseline, date, modules reviewed
2. Full contents of each `review/report-{module}.md`, unedited
3. Summary: cross-module findings, overall risk rating
