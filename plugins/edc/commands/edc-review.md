---
name: edc:edc-review
description: Performs differential review of code changes using codebase context
argument-hint: "<pr-url|commit-sha|diff-path> [--baseline <ref>]"
allowed-tools:
  - Read
  - Write
  - Grep
  - Glob
  - Bash
  - Skill
---

# Differential Review

**Arguments:** $ARGUMENTS

---

## Step 1 — Run the orchestrator

Locate and run the orchestrator script:

```bash
if [ -f ".edc/scripts/edc-review.sh" ]; then
  bash .edc/scripts/edc-review.sh $ARGUMENTS
elif [ -f "$HOME/.edc/scripts/edc-review.sh" ]; then
  bash "$HOME/.edc/scripts/edc-review.sh" $ARGUMENTS
else
  echo "SCRIPT_MISSING"
fi
```

Read the first line of output and act immediately — do not pause or ask the user:

| Output starts with | Action |
|--------------------|--------|
| `CONTEXT_MISSING` | Invoke the `edc:edc-build` skill using the Skill tool. Wait for it to complete. Then re-run the orchestrator script. If it still fails, stop and report the error. |
| `CONTEXT_STALE` | Invoke the `edc:edc-update` skill using the Skill tool. Wait for it to complete. Then re-run the orchestrator script. If it still fails, stop and report the error. |
| `SCRIPT_MISSING` | Tell the user to run the EDC install script with `--project <dir>` to install the orchestrator. Stop. |
| `Review tasks ready` | Proceed to Step 2. |

Do not interpret or work around these conditions. The script is the authority.

---

## Step 2 — Read the manifest

Read `review-tasks/manifest.json`. It contains the list of modules and their changed files.

---

## Step 3 — Process each module task sequentially

For each module in the manifest:

1. Read `review-tasks/{module}.md`
2. Follow the instructions in that file exactly — do not paraphrase or skip steps
3. Do not begin the next module until `review-tasks/report-{module}.md` is written

---

## Step 4 — Consolidate

Write a single file named `review-{TARGET_SHORT}.md`:

1. Header: target, baseline, date, list of modules reviewed
2. One section per module — full contents of each `review-tasks/report-{module}.md`, unedited
3. Summary: cross-module findings, invariant violations spanning modules, overall risk rating
