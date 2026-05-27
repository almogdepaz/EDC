---
name: edc:edc-run-review
description: Performs differential review of code changes, with optional EDC context
argument-hint: "--pr <number> [--base <ref>] [--no-context-refresh|--ignore-context] | --base <ref> [--no-context-refresh|--ignore-context] | <target> [--base <ref>] [--no-context-refresh|--ignore-context] | <pr-url>"
allowed-tools:
  - Bash
---

# Differential Review

**Arguments:** $ARGUMENTS

Run the EDC review orchestrator with Bash only. Do not review inline.

If EDC context is missing or stale, the orchestrator may build/update it before
reviewing. Warn the user this can take several minutes.

```bash
set -- $ARGUMENTS
if [ -f ".edc/scripts/edc-review.sh" ]; then
  review_script=".edc/scripts/edc-review.sh"
elif [ -f "$HOME/.edc/scripts/edc-review.sh" ]; then
  review_script="$HOME/.edc/scripts/edc-review.sh"
else
  echo "SCRIPT_MISSING: install EDC orchestrator first"
  exit 1
fi

echo "WARNING: if EDC context is missing or stale, review may first build/update context and can take several minutes."
bash "$review_script" "$@"
```

If the script exits non-zero, surface its error message verbatim and stop. Do not retry.

The script prints `Consolidated: <path>` and `Verified: <path>` on success. Tell the
user the path of the final review file.
