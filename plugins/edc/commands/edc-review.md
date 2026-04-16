---
name: edc:edc-review
description: Performs differential review of code changes using codebase context
argument-hint: "<pr-url|commit-sha|diff-path> [--baseline <ref>]"
allowed-tools:
  - Bash
  - Skill
---

# Differential Review

**Arguments:** $ARGUMENTS

You are an orchestrator. You have **only Bash and Skill** — no Read, Write, Grep, or Glob.
You **cannot** perform code review yourself. Your only job is to follow the script's
output and invoke skills. Every decision below comes from the script. Do not improvise.

If a step says HARD FAIL, stop immediately, report the script's error message verbatim,
and do not attempt the work inline. There is no fallback path.

---

## Step 1 — Locate and run the orchestrator script

```bash
if [ -f ".edc/scripts/edc-review.sh" ]; then
  SCRIPT=".edc/scripts/edc-review.sh"
elif [ -f "$HOME/.edc/scripts/edc-review.sh" ]; then
  SCRIPT="$HOME/.edc/scripts/edc-review.sh"
else
  echo "SCRIPT_MISSING"; exit 1
fi
bash "$SCRIPT" $ARGUMENTS
```

If the output is `SCRIPT_MISSING`: tell the user to run the EDC install script with
`--project <dir>`. Stop.

Otherwise, read the **first line** of the script's stdout and act:

| First line | Action |
|------------|--------|
| `CONTEXT_MISSING` | Go to Step 2a |
| `CONTEXT_STALE`   | Go to Step 2b |
| `Review tasks ready.` | Go to Step 3 |
| anything else | HARD FAIL |

---

## Step 2a — Recover from CONTEXT_MISSING

1. Invoke the `edc:edc-build` skill via the Skill tool. Wait for it to complete.
2. Verify the skill actually built context: `bash "$SCRIPT" --check-context`
3. If exit code is non-zero → HARD FAIL with the script's error message.
4. Re-run the script: `bash "$SCRIPT" $ARGUMENTS`
5. If the first line is **not** `Review tasks ready.` → HARD FAIL.
6. Otherwise continue to Step 3.

Do not retry edc-build on failure. Do not attempt to build context inline.

## Step 2b — Recover from CONTEXT_STALE

1. Invoke the `edc:edc-update` skill via the Skill tool. Wait for it to complete.
2. Verify the skill actually updated context: `bash "$SCRIPT" --check-context`
3. If exit code is non-zero → HARD FAIL with the script's error message.
4. Re-run the script: `bash "$SCRIPT" $ARGUMENTS`
5. If the first line is **not** `Review tasks ready.` → HARD FAIL.
6. Otherwise continue to Step 3.

Do not retry edc-update on failure. Do not attempt to update context inline.

---

## Step 3 — Parse TASK lines

The script's stdout contains one `TASK <path>` line per module, e.g.:

```
TASK review-tasks/src.md
TASK review-tasks/lib.md
TASK review-tasks/root.md
```

Collect every line that starts with `TASK ` from the most recent script run. The path
after `TASK ` is the task file for one module. These lines are your work queue.

You **cannot** read `manifest.json` or any other file. The TASK lines are the only
authoritative module list.

---

## Step 4 — Process each TASK sequentially

For each `TASK <path>` line, in order:

1. Derive `{module}` from the path: strip `review-tasks/` prefix and `.md` suffix.
2. Invoke the `edc:edc-review` skill via the Skill tool with arguments:
   `--task-file <path>`
3. Wait for the skill to complete.
4. Verify the report exists:
   ```bash
   [ -f "review-tasks/report-${module}.md" ] || { echo "MISSING REPORT: ${module}"; exit 1; }
   ```
5. If the bash check fails → HARD FAIL. Do not write the report yourself. Do not retry
   the skill. Surface the missing-report error.

Process tasks one at a time. Do not skip ahead. Do not parallelize.

---

## Step 5 — Consolidate

Run:

```bash
bash "$SCRIPT" --consolidate
```

If the exit code is non-zero → HARD FAIL with the script's error message.

The script writes the merged review file and prints `Consolidated: <path>`.

---

## Step 6 — Verify

Run:

```bash
bash "$SCRIPT" --verify
```

If the exit code is non-zero → HARD FAIL with the script's error message.

The script confirms context freshness, all expected reports, and the final file exist.

---

## Step 7 — Report

Tell the user the path printed by `--consolidate`. Done.

---

## Hard rules (do not violate)

- You have no Read/Write/Grep/Glob. You **physically cannot** review code or write reports.
- The script is the only router. Every branch decision comes from its output or exit code.
- If a skill fails, stop. Do not work around it. Do not try the task inline.
- Do not edit, parse, or replace `manifest.json`, task files, or report files yourself.
- Do not paraphrase the script's error messages — surface them verbatim.
