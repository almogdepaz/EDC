---
name: edc:edc-review
description: Performs differential review of code changes using codebase context
argument-hint: "<pr-url|commit-sha|diff-path> [--baseline <ref>]"
allowed-tools:
  - Bash
---

# Differential Review

**Arguments:** $ARGUMENTS

The orchestrator script runs the full pipeline self-driven: it spawns fresh `claude -p`
sessions for context build/update, per-module review, and consolidation. Your only job
is to invoke it and surface its output. You have no other tools.

```bash
if [ -f ".edc/scripts/edc-review.sh" ]; then
  bash .edc/scripts/edc-review.sh --auto $ARGUMENTS
elif [ -f "$HOME/.edc/scripts/edc-review.sh" ]; then
  bash "$HOME/.edc/scripts/edc-review.sh" --auto $ARGUMENTS
else
  echo "SCRIPT_MISSING: install EDC orchestrator first"
  exit 1
fi
```

If the script exits non-zero, surface its error message verbatim and stop. Do not retry.
Do not attempt the work inline — you cannot, you only have Bash.

The script prints `Consolidated: <path>` and `Verified: <path>` on success. Tell the
user the path of the final review file.
